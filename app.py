import logging
import os

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)
logger = logging.getLogger(__name__)

def get_db_password():
    # Mot de passe lu depuis le secret monté (/run/secrets)
    password_file = os.getenv("DB_PASSWORD_FILE")
    if password_file:
        with open(password_file, encoding="utf-8") as f:
            return f.read().strip()
    return os.getenv("DB_PASSWORD", "testpass")

DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "testdb")
DB_USER = os.getenv("DB_USER", "testuser")
DB_PASSWORD = get_db_password()


@app.route("/health")
def health_check():
    return jsonify({"status": "ok"})


@app.route("/hello")
def hello():
    return jsonify({"message": "Hello world"})


def get_db_connection():
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
        connect_timeout=5,
    )
    return conn


@app.route("/dbtest")
def db_test():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        result = cur.fetchone()
        cur.close()
        conn.close()
        if result:
            return jsonify({"db_connection": "successful"})
        return jsonify({"db_connection": "failed"}), 500
    except psycopg2.Error:
        # Detail logged server-side only: never leak DB internals to the client
        logger.exception("Database connection failed")
        return jsonify({"db_connection": "failed"}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
