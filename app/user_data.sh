#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting ZamWeather setup..."

# Update OS
yum update -y

# Install Python 3 and pip
yum install -y python3 python3-pip

# Install Flask dependencies
pip3 install flask mysql-connector-python requests urllib3==1.26.15 flask-cors

# Create app directory
mkdir -p /home/ec2-user/app

# Write environment variables
# Export variables for immediate use during script execution
export DB_HOST=${db_host}
export DB_USER=${db_user}
export DB_PASSWORD=${db_password}
export DB_NAME=${db_name}
export OPENWEATHER_API_KEY=${api_key}

# Write dedicated environment file for systemd
# This is what Flask reads every time it starts
cat > /etc/zamweather.env << EOF
DB_HOST=${db_host}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
DB_NAME=${db_name}
OPENWEATHER_API_KEY=${api_key}
EOF

# Secure the environment file
chmod 600 /etc/zamweather.env

# Write the Flask app directly inline
cat > /home/ec2-user/app/app.py << 'PYEOF'
from flask import Flask, request, jsonify
import requests as http_requests
import mysql.connector
import os

app = Flask(__name__)
from flask_cors import CORS
CORS(app)

DB_HOST     = os.environ.get('DB_HOST')
DB_USER     = os.environ.get('DB_USER')
DB_PASSWORD = os.environ.get('DB_PASSWORD')
DB_NAME     = os.environ.get('DB_NAME')
API_KEY     = os.environ.get('OPENWEATHER_API_KEY')

def get_db_connection():
    return mysql.connector.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME
    )

def init_db():
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS searches (
                id          INT AUTO_INCREMENT PRIMARY KEY,
                city        VARCHAR(100),
                temperature FLOAT,
                feels_like  FLOAT,
                humidity    INT,
                condition_text VARCHAR(100),
                wind_speed  FLOAT,
                searched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        conn.commit()
        cursor.close()
        conn.close()
        print("Database initialised successfully")
    except Exception as e:
        print(f"Database init error: {e}")

init_db()

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy"}), 200

@app.route('/weather', methods=['GET'])
def get_weather():
    city = request.args.get('city')
    if not city:
        return jsonify({"error": "Please enter a city name"}), 400
    try:
        url = "https://api.openweathermap.org/data/2.5/weather"
        params = {"q": city, "appid": API_KEY, "units": "metric"}
        try:
            response = http_requests.get(url, params=params, timeout=10)
        except http_requests.exceptions.Timeout:
            return jsonify({
                "error": "timeout",
                "message": "The weather service is taking longer than usual. Please try again."
            }), 503
        except http_requests.exceptions.ConnectionError:
            return jsonify({
                "error": "connection",
                "message": "Unable to reach the weather service. Please try again."
            }), 503

        data = response.json()

        if response.status_code == 404:
            return jsonify({
                "error": "not_found",
                "message": f"City '{city}' not found. Please check the spelling."
            }), 404

        if response.status_code != 200:
            return jsonify({
                "error": "service_error",
                "message": "Weather service returned an unexpected response."
            }), 502

        weather = {
            "city":        data["name"],
            "country":     data["sys"]["country"],
            "temperature": round(data["main"]["temp"], 1),
            "feels_like":  round(data["main"]["feels_like"], 1),
            "humidity":    data["main"]["humidity"],
            "condition":   data["weather"][0]["description"].title(),
            "wind_speed":  data["wind"]["speed"],
            "icon":        data["weather"][0]["icon"]
        }

        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO searches
                    (city, temperature, feels_like, humidity, condition_text, wind_speed)
                VALUES (%s, %s, %s, %s, %s, %s)
            ''', (
                weather["city"],
                weather["temperature"],
                weather["feels_like"],
                weather["humidity"],
                weather["condition"],
                weather["wind_speed"]
            ))
            conn.commit()
            cursor.close()
            conn.close()
        except Exception as db_error:
            print(f"Database write error: {db_error}")

        return jsonify(weather), 200

    except Exception as e:
        return jsonify({
            "error": "unexpected",
            "message": "Something went wrong. Please try again."
        }), 500

@app.route('/history', methods=['GET'])
def get_history():
    try:
        conn = get_db_connection()
        cursor = conn.cursor(dictionary=True)
        cursor.execute('''
            SELECT city, temperature, feels_like,
                   humidity, condition_text, wind_speed,
                   searched_at
            FROM searches
            ORDER BY searched_at DESC
            LIMIT 10
        ''')
        searches = cursor.fetchall()
        cursor.close()
        conn.close()
        for search in searches:
            search['searched_at'] = str(search['searched_at'])
        return jsonify({"searches": searches}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/forecast', methods=['GET'])
def get_forecast():
 city = request.args.get('city')
    if not city:
       return jsonify({"error": "City parameter is required"}), 400
    try:
        url = "https://api.openweathermap.org/data/2.5/forecast"
        params = {"q": city, "appid": API_KEY, "units": "metric"}
        try:
            response = http_requests.get(url, params=params, timeout=10)
        except http_requests.exceptions.Timeout:
            return jsonify({"error": "timeout", "message": "Forecast service timed out"}), 503
        except http_requests.exceptions.ConnectionError:
            return jsonify({"error": "connection", "message": "Cannot reach forecast service"}), 503

        if response.status_code != 200:
            return jsonify({"error": "not_found", "message": "City not found"}), 404
        data = response.json()
        # Extract one reading every 24 hours for 5 days
        # OpenWeatherMap returns data every 3 hours - we take every 8th entry
        forecast = []
        for i, item in enumerate(data['list']):
            if i % 8 == 0:
                forecast.append({
                    "time": item['dt_txt'],
                    "temperature": round(item['main']['temp'], 1),
                    "condition": item['weather'][0]['description'].title()
                })
            if len(forecast) >= 5:
                break
        return jsonify({"city": data['city']['name'], "forecast": forecast}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/cityhistory', methods=['GET'])
def get_city_history():
    city = request.args.get('city')
    if not city:
        return jsonify({"error": "city parameter is required"}), 400
    try:
        conn = get_db_connection()
        cursor = conn.cursor(dictionary=True)
        cursor.execute('''
            SELECT temperature, searched_at
            FROM searches
            WHERE LOWER(city) = LOWER(%s)
            ORDER BY searched_at DESC
            LIMIT 14
        ''', (city,))
        history = cursor.fetchall()
        cursor.close()
        conn.close()
        for item in history:
            item['searched_at'] = str(item['searched_at'])
        return jsonify({"city": city, "history": history}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
PYEOF

# Set correct ownership
chown -R ec2-user:ec2-user /home/ec2-user/app

# Create systemd service
cat > /etc/systemd/system/zamweather.service << EOF
[Unit]
Description=ZamWeather Flask App
After=network-online.target
Wants=network-online.target

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user/app
EnvironmentFile=/etc/zamweather.env
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/python3 /home/ec2-user/app/app.py
Restart=on-failure
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zamweather
systemctl start zamweather

echo "ZamWeather setup complete"
