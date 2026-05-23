import logging
import os
import time

from fastapi import FastAPI, HTTPException
from prometheus_client import make_asgi_app
from pydantic import BaseModel

from app.metrics import (
    INFERENCE_LATENCY,
    INFERENCE_REQUESTS,
    MODEL_VERSION,
    RESPONSE_TOKENS,
    TOKENS_PER_SECOND,
)
from app.ollama_client import OllamaClient

MODEL_NAME = os.environ.get("MODEL_NAME", "qwen2.5:1.5b")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://ollama:11434")

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("inference-api")

app = FastAPI(title="inference-api", version="1.0.0")
client = OllamaClient(OLLAMA_HOST)

MODEL_VERSION.labels(model=MODEL_NAME).set(1)


class PredictRequest(BaseModel):
    prompt: str
    max_tokens: int = 256


class PredictResponse(BaseModel):
    response: str
    model: str
    tokens: int
    duration_seconds: float


@app.get("/health")
def health():
    ollama_up = client.health()
    return {
        "status": "ok" if ollama_up else "degraded",
        "model": MODEL_NAME,
        "ollama_reachable": ollama_up,
    }


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    start = time.perf_counter()
    try:
        result = client.generate(MODEL_NAME, req.prompt, req.max_tokens)
    except Exception as exc:
        INFERENCE_REQUESTS.labels(status="error", model=MODEL_NAME).inc()
        log.exception("inference failure")
        raise HTTPException(status_code=503, detail=str(exc))

    duration = time.perf_counter() - start
    tokens = int(result.get("eval_count") or 0)

    INFERENCE_REQUESTS.labels(status="success", model=MODEL_NAME).inc()
    INFERENCE_LATENCY.labels(model=MODEL_NAME).observe(duration)
    RESPONSE_TOKENS.labels(model=MODEL_NAME).observe(tokens)
    if duration > 0 and tokens > 0:
        TOKENS_PER_SECOND.labels(model=MODEL_NAME).observe(tokens / duration)

    return PredictResponse(
        response=result.get("response", ""),
        model=MODEL_NAME,
        tokens=tokens,
        duration_seconds=duration,
    )


app.mount("/metrics", make_asgi_app())
