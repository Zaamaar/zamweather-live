from flask import Flask, request, jsonify
import requests
import sqlite3
import os
from datetime import datetime

app = Flask(__name__)

# Configuration from environment variables
# DB_PATH points to a local SQLite file instead of a remote MySQL host —
# this deployment trades RDS for a file on disk (see README trade-offs)
DB_PATH = os.environ.get('DB_PATH', 'zamweather.db')
API_KEY = os.environ.get('OPENWEATHER_API_KEY')

def get_db_connection():
    """Create and return a database connection"""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    """Create the searches table if it doesn't exist"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS searches (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                city        TEXT,
                temperature REAL,
                feels_like  REAL,
                humidity    INTEGER,
                condition   TEXT,
                wind_speed  REAL,
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
    Health check endpoint.
    Returns 200 OK if the app is running.
    """
    return jsonify({"status": "healthy"}), 200

@app.route('/weather', methods=['GET'])
def get_weather():
    """
    Fetch live weather data for a given city.
    Saves the search to SQLite.
    Returns weather data as JSON.
    """
    city = request.args.get('city')

    if not city:
        return jsonify({
            "error": "Please enter a city name to search."
        }), 400

    try:
        url = "https://api.openweathermap.org/data/2.5/weather"
        params = {
            "q":     city,
            "appid": API_KEY,
            "units": "metric"
        }

        try:
            response = requests.get(url, params=params, timeout=10)
        except requests.exceptions.Timeout:
            return jsonify({
                "error": "timeout",
                "message": "The weather service is taking longer than usual. Please wait a moment and try again."
            }), 503
        except requests.exceptions.ConnectionError:
            return jsonify({
                "error": "connection",
                "message": "Unable to reach the weather service right now. Please check your connection and try again."
            }), 503

        data = response.json()

        if response.status_code == 404:
            return jsonify({
                "error": "not_found",
                "message": f"We could not find a city called '{city}'. Please check the spelling and try again."
            }), 404

        if response.status_code != 200:
            return jsonify({
                "error": "service_error",
                "message": "The weather service returned an unexpected response. Please try again shortly."
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

        # Save to SQLite
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO searches
                    (city, temperature, feels_like, humidity, condition, wind_speed)
                VALUES (?, ?, ?, ?, ?, ?)
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
            "message": "Something went wrong on our end. Please try again in a moment."
        }), 500


@app.route('/history', methods=['GET'])
def get_history():
    """
    Retrieve the last 10 weather searches from SQLite.
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('''
            SELECT city, temperature, feels_like,
                   humidity, condition, wind_speed,
                   searched_at
            FROM searches
            ORDER BY searched_at DESC
            LIMIT 10
        ''')
        searches = [dict(row) for row in cursor.fetchall()]
        cursor.close()
        conn.close()

        for search in searches:
            search['searched_at'] = str(search['searched_at'])

        return jsonify({"searches": searches}), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
