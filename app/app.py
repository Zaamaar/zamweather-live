from flask import Flask, request, jsonify
import requests
import mysql.connector
import os
from datetime import datetime

app = Flask(__name__)

# Configuration from environment variables
# These get injected by the user data script on EC2 boot
DB_HOST     = os.environ.get('DB_HOST')
DB_USER     = os.environ.get('DB_USER')
DB_PASSWORD = os.environ.get('DB_PASSWORD')
DB_NAME     = os.environ.get('DB_NAME')
API_KEY     = os.environ.get('OPENWEATHER_API_KEY')

def get_db_connection():
    """Create and return a database connection"""
    return mysql.connector.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME
    )

def init_db():
    """Create the searches table if it doesn't exist"""
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
                condition   VARCHAR(100),
                wind_speed  FLOAT,
                searched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        conn.commit()
        cursor.close()
        conn.close()
    except Exception as e:
        print(f"Database init error: {e}")

# Initialise the database table on app startup
init_db()

@app.route('/health', methods=['GET'])
def health():
    """
    Health check endpoint for the ALB.
    ALB hits this every 30 seconds.
    Returns 200 OK if the app is running.
    """
    return jsonify({"status": "healthy"}), 200

@app.route('/weather', methods=['GET'])
def get_weather():
    """
    Fetch live weather data for a given city.
    Saves the search to RDS.
    Returns weather data as JSON.
    """
    city = request.args.get('city')

    if not city:
        return jsonify({
            "error": "Please enter a city name to search."
        }), 400

    try:
        # Call OpenWeatherMap API
        url = "https://api.openweathermap.org/data/2.5/weather"
        params = {
            "q":     city,
            "appid": API_KEY,
            "units": "metric"
        }

        try:
            response = requests.get(url, params=params, timeout=10)
        except requests.exceptions.Timeout:
            # OpenWeatherMap took too long to respond
            return jsonify({
                "error": "timeout",
                "message": "The weather service is taking longer than usual. Please wait a moment and try again."
            }), 503
        except requests.exceptions.ConnectionError:
            # No network connection at all
            return jsonify({
                "error": "connection",
                "message": "Unable to reach the weather service right now. Please check your connection and try again."
            }), 503

        data = response.json()

        # City not found
        if response.status_code == 404:
            return jsonify({
                "error": "not_found",
                "message": f"We could not find a city called '{city}'. Please check the spelling and try again."
            }), 404

        # Any other non-200 response from OpenWeatherMap
        if response.status_code != 200:
            return jsonify({
                "error": "service_error",
                "message": "The weather service returned an unexpected response. Please try again shortly."
            }), 502

        # Extract the data we need
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

        # Save to RDS
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO searches
                    (city, temperature, feels_like, humidity, condition, wind_speed)
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
            # Database write failed but we still have the weather data
            # Return the weather to the user anyway - do not let a DB
            # issue prevent the user from seeing their result
            print(f"Database write error: {db_error}")

        return jsonify(weather), 200

    except Exception as e:
        return jsonify({
            "error": "unexpected",
            "message": "Something went wrong on our end. Please try again in a moment."
        }), 500
 

@app.route('/history', methods=['GET'])
def get_history():
    """
    Retrieve the last 10 weather searches from RDS.
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor(dictionary=True)
        cursor.execute('''
            SELECT city, temperature, feels_like,
                   humidity, condition, wind_speed,
                   searched_at
            FROM searches
            ORDER BY searched_at DESC
            LIMIT 10
        ''')
        searches = cursor.fetchall()
        cursor.close()
        conn.close()

        # Convert datetime objects to strings for JSON
        for search in searches:
            search['searched_at'] = str(search['searched_at'])

        return jsonify({"searches": searches}), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
