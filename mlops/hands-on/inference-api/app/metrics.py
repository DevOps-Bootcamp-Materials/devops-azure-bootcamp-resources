from prometheus_client import Counter, Histogram, Gauge

INFERENCE_REQUESTS = Counter(
    "inference_requests_total",
    "Total number of inference requests handled by the API",
    ["status", "model"],
)

INFERENCE_LATENCY = Histogram(
    "inference_latency_seconds",
    "End-to-end inference latency in seconds (API receives request to API returns response)",
    ["model"],
    buckets=(0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0),
)

RESPONSE_TOKENS = Histogram(
    "inference_response_tokens",
    "Number of tokens in the model response (eval_count from Ollama)",
    ["model"],
    buckets=(8, 16, 32, 64, 128, 256, 512, 1024),
)

TOKENS_PER_SECOND = Histogram(
    "inference_tokens_per_second",
    "Throughput in generated tokens per second for the request",
    ["model"],
    buckets=(2, 5, 10, 20, 40, 80, 160, 320),
)

MODEL_VERSION = Gauge(
    "inference_model_version",
    "Currently deployed model. Value is always 1; the model label carries the information.",
    ["model"],
)