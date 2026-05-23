"""
broken-app: a small multi-service stack used as a diagnostic exercise.

One Python image runs as four different roles, chosen by the SERVICE_NAME env var:
  - gateway   — fronts the three backends, generates its own load, exposes a
                downstream-call client histogram so the gateway can tell you
                which backend is slow.
  - orders    — fast endpoint with a bounded concurrency pool. Under scenario 3
                the pool is shrunk and request work is slowed, producing a
                textbook saturation signature.
  - users     — fast endpoint. Under scenario 2 every request appends a chunk
                to an in-process buffer, producing a memory leak that ends in
                OOMKill given the container's memory limit.
  - payments  — moderate-latency endpoint. Under scenario 1 a fixed sleep is
                added on top of its baseline latency, producing the "your
                downstream dependency is slow" signature on the gateway.

Scenario control:
  Each backend exposes POST /control/scenario  with body {"scenario": "1|2|3|none"}
  The gateway exposes POST /control/scenario/<id> that fans out to every
  backend. /control/reset clears state. The instructor only talks to the
  gateway; students never need to call the backends directly.

All four roles expose /metrics for Prometheus.
"""

import os
import random
import sys
import threading
import time

import requests as http_client
from flask import Flask, abort, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

SERVICE = os.environ.get("SERVICE_NAME", "gateway")
PORT = int(os.environ.get("PORT", "8080"))

app = Flask(__name__)

# ── Common metrics emitted by every role ──────────────────────────────────────

REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests handled by this service",
    ["service", "endpoint", "status"],
)
DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["service", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)

# Each backend keeps its own scenario flag. The gateway fans out to set them.
STATE = {"scenario": "none"}


def observe(endpoint: str, status: int, started_at: float) -> None:
    REQUESTS.labels(service=SERVICE, endpoint=endpoint, status=str(status)).inc()
    DURATION.labels(service=SERVICE, endpoint=endpoint).observe(
        time.perf_counter() - started_at
    )


# ── Role-specific extras ──────────────────────────────────────────────────────

if SERVICE == "gateway":
    DOWNSTREAM = Histogram(
        "downstream_request_duration_seconds",
        "Time spent calling a downstream service (client-side, gateway view)",
        ["downstream"],
        buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
    )
    DOWNSTREAM_ERRORS = Counter(
        "downstream_request_errors_total",
        "Errors returned by a downstream service (gateway view)",
        ["downstream", "status"],
    )

if SERVICE == "orders":
    INFLIGHT = Gauge(
        "orders_inflight_requests",
        "Number of /api/orders requests currently being processed",
    )
    POOL_CAPACITY = Gauge(
        "orders_pool_capacity",
        "Current concurrency cap for /api/orders",
    )
    REJECTED = Counter(
        "orders_pool_rejected_total",
        "/api/orders requests rejected because the pool was full",
    )
    _orders_pool_lock = threading.Lock()
    _orders_sem = threading.BoundedSemaphore(50)
    _orders_pool_size = 50
    POOL_CAPACITY.set(50)

if SERVICE == "users":
    LEAK_BYTES = Gauge(
        "users_leaked_bytes",
        "Bytes currently held by the in-process leak buffer",
    )
    _leak_buffer: list = []
    _leak_lock = threading.Lock()


# ── Backend role: shared work() helper ────────────────────────────────────────


def backend_work(endpoint: str):
    """Run the body of a backend request. Returns (payload, status_code)."""
    if SERVICE == "payments":
        # Baseline latency: ~150ms log-normal-ish
        base = random.expovariate(1.0 / 0.15)
        time.sleep(min(base, 1.0))
        # Scenario 1: inject extra latency on payments
        if STATE["scenario"] == "1":
            time.sleep(random.uniform(2.0, 3.5))
        # Baseline error rate 3%
        if random.random() < 0.03:
            return {"error": "gateway timeout"}, 502
        return {"payment_id": random.randint(10000, 99999), "status": "approved"}, 200

    if SERVICE == "users":
        # Baseline latency ~30ms
        time.sleep(random.expovariate(1.0 / 0.03))
        # Scenario 2: leak ~1 MiB per request, never freed. Combined with the
        # 192 MiB container memory limit and ~6 r/s on this endpoint, OOMKill
        # arrives around 25 s after the scenario is triggered — fast enough to
        # fit in a teaching window, slow enough that the RSS climb shows up
        # clearly as a rising line on the dashboard rather than a vertical jump.
        if STATE["scenario"] == "2":
            chunk = bytearray(1024 * 1024)
            with _leak_lock:
                _leak_buffer.append(chunk)
                LEAK_BYTES.set(sum(len(b) for b in _leak_buffer))
        # Baseline error rate ~1%
        if random.random() < 0.01:
            return {"error": "db read failed"}, 500
        uid = request.view_args.get("user_id") if request.view_args else None
        return {"user_id": uid or random.randint(1, 1000), "name": f"User {uid or '?'}"}, 200

    if SERVICE == "orders":
        # Bounded concurrency pool. Under scenario 3 we shrink the pool and slow
        # the request, producing queueing and a long tail of slow requests.
        acquired = _orders_sem.acquire(timeout=4.0)
        if not acquired:
            REJECTED.inc()
            return {"error": "pool full, request timed out in queue"}, 503
        INFLIGHT.inc()
        try:
            if STATE["scenario"] == "3":
                time.sleep(random.uniform(0.8, 1.4))
            else:
                time.sleep(random.expovariate(1.0 / 0.04))
            if random.random() < 0.01:
                return {"error": "downstream stock service unavailable"}, 500
            return {
                "order_id": random.randint(1, 99999),
                "items": ["sku-1", "sku-7"],
            }, 200
        finally:
            INFLIGHT.dec()
            _orders_sem.release()

    return {"error": f"unknown service {SERVICE}"}, 500


# ── HTTP handlers ─────────────────────────────────────────────────────────────


@app.get("/health")
def health():
    return jsonify({"service": SERVICE, "status": "ok"})


@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# Backend roles expose /api/<role>
if SERVICE == "orders":
    @app.get("/api/orders")
    def orders_handler():
        started = time.perf_counter()
        payload, status = backend_work("/api/orders")
        observe("/api/orders", status, started)
        return jsonify(payload), status


if SERVICE == "users":
    @app.get("/api/users/<user_id>")
    def users_handler(user_id):
        started = time.perf_counter()
        payload, status = backend_work("/api/users")
        observe("/api/users", status, started)
        return jsonify(payload), status


if SERVICE == "payments":
    @app.post("/api/payments")
    def payments_handler():
        started = time.perf_counter()
        payload, status = backend_work("/api/payments")
        observe("/api/payments", status, started)
        return jsonify(payload), status


# Each backend has its own control endpoint
if SERVICE in ("orders", "users", "payments"):
    @app.post("/control/scenario")
    def set_scenario():
        body = request.get_json(silent=True) or {}
        scenario = str(body.get("scenario", "none"))
        if scenario not in {"none", "1", "2", "3"}:
            return jsonify({"error": "scenario must be one of: none, 1, 2, 3"}), 400
        STATE["scenario"] = scenario
        # Pool-shrink hook for orders
        if SERVICE == "orders":
            _resize_orders_pool(target=3 if scenario == "3" else 50)
        # Leak-clear hook for users
        if SERVICE == "users":
            if scenario == "none":
                with _leak_lock:
                    _leak_buffer.clear()
                    LEAK_BYTES.set(0)
        return jsonify({"service": SERVICE, "scenario": scenario})


def _resize_orders_pool(target: int) -> None:
    """Resize the orders concurrency pool to `target`. Called from /control."""
    global _orders_sem, _orders_pool_size
    with _orders_pool_lock:
        _orders_sem = threading.BoundedSemaphore(target)
        _orders_pool_size = target
        POOL_CAPACITY.set(target)


# ── Gateway role: routing + downstream client metrics ─────────────────────────

BACKENDS = {
    "orders":   "http://orders:8080/api/orders",
    "users":    "http://users:8080/api/users",
    "payments": "http://payments:8080/api/payments",
}


def _call_downstream(name: str, method: str = "GET") -> tuple[dict, int]:
    url = BACKENDS[name]
    if name == "users":
        url = f"{url}/{random.randint(1, 1000)}"
    started = time.perf_counter()
    try:
        if method == "POST":
            r = http_client.post(url, timeout=10)
        else:
            r = http_client.get(url, timeout=10)
        elapsed = time.perf_counter() - started
        DOWNSTREAM.labels(downstream=name).observe(elapsed)
        if r.status_code >= 400:
            DOWNSTREAM_ERRORS.labels(downstream=name, status=str(r.status_code)).inc()
        return ({"downstream": name, "status_code": r.status_code}, r.status_code)
    except http_client.RequestException as exc:
        elapsed = time.perf_counter() - started
        DOWNSTREAM.labels(downstream=name).observe(elapsed)
        DOWNSTREAM_ERRORS.labels(downstream=name, status="exception").inc()
        return ({"error": str(exc)}, 599)


if SERVICE == "gateway":
    @app.get("/api/orders")
    def gw_orders():
        started = time.perf_counter()
        payload, status = _call_downstream("orders", "GET")
        observe("/api/orders", status, started)
        return jsonify(payload), status

    @app.get("/api/users")
    def gw_users():
        started = time.perf_counter()
        payload, status = _call_downstream("users", "GET")
        observe("/api/users", status, started)
        return jsonify(payload), status

    @app.get("/api/checkout")
    def gw_checkout():
        """Realistic composite call: needs orders + payments."""
        started = time.perf_counter()
        _, st1 = _call_downstream("orders", "GET")
        payload, st2 = _call_downstream("payments", "POST")
        status = st2 if st2 >= 400 else (st1 if st1 >= 400 else 200)
        observe("/api/checkout", status, started)
        return jsonify({"checkout": payload, "orders_status": st1, "payments_status": st2}), status

    @app.post("/control/scenario/<sid>")
    def gw_set_scenario(sid):
        if sid not in {"none", "1", "2", "3"}:
            return jsonify({"error": "scenario must be one of: none, 1, 2, 3"}), 400
        results = {}
        for name, url in BACKENDS.items():
            backend_host = url.split("/api/")[0]
            try:
                r = http_client.post(
                    f"{backend_host}/control/scenario",
                    json={"scenario": sid},
                    timeout=5,
                )
                results[name] = r.json()
            except http_client.RequestException as exc:
                results[name] = {"error": str(exc)}
        return jsonify({"scenario": sid, "backends": results})

    @app.post("/control/reset")
    def gw_reset():
        # equivalent to scenario "none"
        return gw_set_scenario("none")

    # Background traffic generator — keeps Prometheus fed with realistic load.
    def _traffic_worker(endpoints):
        time.sleep(3)
        while True:
            ep = random.choice(endpoints)
            try:
                http_client.get(f"http://localhost:8080{ep}", timeout=12)
            except Exception:
                pass
            time.sleep(random.uniform(0.05, 0.15))

    # Three worker threads so total offered load is ~25 r/s on the gateway —
    # enough to make scenario 2 OOM in ~30 s and scenario 3 saturate orders
    # within ~15 s without overwhelming a laptop.
    _gw_endpoints = (
        ["/api/checkout"] * 4
        + ["/api/orders"] * 3
        + ["/api/users"] * 3
    )
    for _ in range(3):
        threading.Thread(target=_traffic_worker, args=(_gw_endpoints,), daemon=True).start()


if __name__ == "__main__":
    print(f"Starting service: {SERVICE} on port {PORT}", flush=True)
    app.run(host="0.0.0.0", port=PORT, threaded=True)
