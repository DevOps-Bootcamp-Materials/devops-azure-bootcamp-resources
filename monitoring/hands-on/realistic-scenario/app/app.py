"""
faulty-app: a synthetic REST API that generates realistic Prometheus metrics.

Endpoints:
  GET  /api/orders    — order list (low latency, low error rate)
  GET  /api/users     — user list (medium latency, very low error rate)
  GET  /api/payments  — payment processing (high latency, configurable error rate)
  GET  /health        — liveness check
  GET  /metrics       — Prometheus metrics endpoint
  POST /chaos?error_rate=<0-1>  — set the payments error rate (teacher use)
  POST /reset                   — restore default error rates (teacher use)

Background traffic is generated automatically so dashboards show activity
even without manual requests.
"""

import random
import threading
import time

import requests as http_client
from flask import Flask, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

app = Flask(__name__)

# ── Prometheus instrumentation ─────────────────────────────────────────────────

REQUEST_TOTAL = Counter(
    "app_requests_total",
    "Total HTTP requests",
    ["endpoint", "status_code"],
)

REQUEST_DURATION = Histogram(
    "app_request_duration_seconds",
    "HTTP request duration in seconds",
    ["endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5],
)

# ── Configurable error rates ───────────────────────────────────────────────────
# These can be modified at runtime via POST /chaos

ERROR_RATES = {
    "/api/orders": 0.02,    # 2% baseline
    "/api/users": 0.01,     # 1% baseline
    "/api/payments": 0.04,  # 4% baseline — higher because payments are fragile
}

# Base latency (mean of an exponential distribution) per endpoint in seconds
BASE_LATENCY = {
    "/api/orders": 0.05,
    "/api/users": 0.08,
    "/api/payments": 0.25,   # payments are intentionally slower
}

# ── Helpers ────────────────────────────────────────────────────────────────────


def simulate_work(endpoint: str) -> None:
    """Sleep for a realistic duration and raise with the configured probability."""
    latency = random.expovariate(1.0 / BASE_LATENCY[endpoint])
    time.sleep(min(latency, 3.0))
    if random.random() < ERROR_RATES[endpoint]:
        raise RuntimeError(f"Downstream dependency failed for {endpoint}")


def handle_endpoint(endpoint: str, payload):
    """Instrument a request and return a Flask response tuple."""
    start = time.perf_counter()
    try:
        simulate_work(endpoint)
        REQUEST_TOTAL.labels(endpoint=endpoint, status_code="200").inc()
        return jsonify(payload), 200
    except RuntimeError as exc:
        REQUEST_TOTAL.labels(endpoint=endpoint, status_code="500").inc()
        return jsonify({"error": str(exc)}), 500
    finally:
        REQUEST_DURATION.labels(endpoint=endpoint).observe(
            time.perf_counter() - start
        )


# ── API endpoints ──────────────────────────────────────────────────────────────


@app.get("/api/orders")
def orders():
    payload = {"orders": [{"id": i, "status": "shipped"} for i in range(1, 6)]}
    return handle_endpoint("/api/orders", payload)


@app.get("/api/users")
def users():
    payload = {"users": [{"id": i, "name": f"User {i}"} for i in range(1, 4)]}
    return handle_endpoint("/api/users", payload)


@app.get("/api/payments")
def payments():
    payload = {"payment_id": random.randint(10000, 99999), "status": "approved"}
    return handle_endpoint("/api/payments", payload)


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# ── Chaos control (teacher-facing) ────────────────────────────────────────────


@app.post("/chaos")
def chaos():
    """Raise the payments error rate to simulate an incident.

    Usage: curl -X POST "http://localhost:8080/chaos?error_rate=0.5"
    """
    try:
        rate = float(request.args.get("error_rate", 0.5))
        rate = max(0.0, min(1.0, rate))
    except ValueError:
        return jsonify({"error": "error_rate must be a float between 0 and 1"}), 400

    ERROR_RATES["/api/payments"] = rate
    return jsonify(
        {
            "message": f"Payments error rate set to {rate:.0%}",
            "current_rates": ERROR_RATES,
        }
    )


@app.post("/reset")
def reset():
    """Restore all error rates to their default values."""
    ERROR_RATES["/api/orders"] = 0.02
    ERROR_RATES["/api/users"] = 0.01
    ERROR_RATES["/api/payments"] = 0.04
    return jsonify({"message": "Error rates reset to defaults", "current_rates": ERROR_RATES})


# ── Background traffic generator ──────────────────────────────────────────────


def _generate_traffic() -> None:
    """
    Continuously hit the application's own endpoints so Prometheus always has
    fresh data to scrape. Requests per second: ~5 orders, ~3 users, ~2 payments.
    """
    base_url = "http://localhost:8080"
    # Weighted endpoint selection: more orders than payments (realistic mix)
    endpoints = (
        ["/api/orders"] * 5
        + ["/api/users"] * 3
        + ["/api/payments"] * 2
    )

    # Wait for Flask to start before sending requests
    time.sleep(3)

    while True:
        endpoint = random.choice(endpoints)
        try:
            http_client.get(f"{base_url}{endpoint}", timeout=5)
        except Exception:
            pass
        time.sleep(random.uniform(0.08, 0.3))


traffic_thread = threading.Thread(target=_generate_traffic, daemon=True)
traffic_thread.start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
