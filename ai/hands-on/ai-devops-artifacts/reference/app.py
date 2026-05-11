# A minimal Python web application used as the target for DevOps artifact generation.
# Students will ask an AI to write Dockerfiles, CI/CD pipelines, and Terraform
# for this application without providing this file — they will describe it in words.
#
# Application characteristics:
#   - Python 3.11, Flask web framework
#   - Reads DATABASE_URL from environment
#   - Listens on port 8080 by default (configurable via PORT env var)
#   - Has a /health endpoint that returns {"status": "ok"}
#   - Has a /api/users endpoint that queries the database
#   - Dependencies: flask==3.0.0, psycopg2-binary==2.9.9, gunicorn==21.2.0

from flask import Flask, jsonify
import os
import psycopg2

app = Flask(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://localhost/mydb")
PORT = int(os.environ.get("PORT", 8080))


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/api/users")
def users():
    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()
    cur.execute("SELECT id, name FROM users LIMIT 10")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify([{"id": r[0], "name": r[1]} for r in rows])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
