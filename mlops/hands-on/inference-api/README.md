# MLOps — Containerize a model, serve it, monitor it

Deep-dive companion to [`week-17/mlops/hands-on/01_inference_api_monitoring.md`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp/blob/main/week-17/mlops/hands-on/01_inference_api_monitoring.md) in the bootcamp repo. The bootcamp file walks the live demo; this README expands every step with the misconceptions, edge cases, and design discussions a platform engineer needs to handle production model serving.

The hands-on serves an LLM (qwen2.5:1.5b through Ollama) wrapped in a small FastAPI app. The point of the exercise is not the model — it is the platform-engineer plumbing around the model: container packaging, golden signals, model-quality signals, drift early-warning, and how the same stack maps to Kubernetes.

## What this folder contains

- `README.md` — this file: the complete walkthrough with every detail, tangent, and reference.
- `app/` — FastAPI inference service:
  - `main.py` — HTTP endpoints (`/health`, `/predict`, `/metrics`).
  - `ollama_client.py` — thin wrapper around the Ollama HTTP API.
  - `metrics.py` — `prometheus_client` counter, histograms, and gauge definitions.
- `Dockerfile` — the recommended image build (small wrapper; model lives in Ollama).
- `Dockerfile.runtime-fetch` — anti-pattern reference, not built. See Part 2.
- `requirements.txt` — Python dependencies pinned to specific versions.
- `docker-compose.yml` — runs ollama + model-puller + inference-api + prometheus + grafana.
- `prometheus/prometheus.yml` — scrape config for the inference-api.
- `prometheus/alerts.yml` — three rules: `ResponseLengthShift`, `HighInferenceLatency`, `InferenceErrorRate`.
- `grafana/provisioning/` — auto-provisioned datasource + dashboard provider.
- `grafana/dashboards/inference.json` — the four-panel dashboard.
- `send_traffic.py` — synthetic traffic generator with `--mode normal | drift | mixed`.
- `k8s/` — reference manifests (Deployment, Service, ServiceMonitor, HPA). Not applied in the hands-on; covered in Part 8.
- `training/` — placeholder; explains why this hands-on does not train a model.

## Prerequisites

- Docker Desktop or Docker Engine with Compose v2 (`docker compose ...`, not the legacy `docker-compose` binary).
- ~5 GB free disk: ~2.7 GB for the Ollama image, ~1 GB for qwen2.5:1.5b weights, the rest for prometheus, grafana, and your inference-api image.
- A working internet connection on first start so Ollama can pull the model weights from the registry. After the first pull they live in the `ollama_data` Docker volume.
- Python 3.10+ on your host to run `send_traffic.py`. The `requests` library is the only dependency; install with `pip install requests`.

You should have already completed week 14's monitoring hands-on (Prometheus, Grafana, PromQL, dashboards). This hands-on assumes you can read a `histogram_quantile` expression without explanation; if not, re-read [`02_full_stack_prometheus_grafana.md`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp/blob/main/week-14/monitoring/hands-on/02_full_stack_prometheus_grafana.md) first.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/mlops/hands-on/inference-api
docker compose up -d --build
```

If you only want to follow along reading, the same content (shorter) is in the bootcamp hands-on file. Open this README when you want the full treatment of a particular step.

---

## Part 1 — Understand what the ML engineer handed you

Recall from the lesson (section 1): the data scientist experiments, the ML engineer productionises, and the DevOps engineer operates. In this hands-on the "handover" is the contents of the `app/` folder plus the Dockerfile and the requirements.txt. **You are not writing the model code.** Your job is to package it, run it reliably, and make it observable.

Open `app/main.py`. Three pieces matter:

1. The HTTP surface: `GET /health` returns liveness + whether Ollama is reachable; `POST /predict` is the inference endpoint; `/metrics` is mounted as a separate ASGI app so `prometheus_client` exports it on the same port.
2. The Ollama client call: this is the only ML-specific piece. It forwards the prompt to Ollama's `/api/generate` endpoint with `stream: false` (we want a single JSON blob, not a token stream — keeps the metric collection simple).
3. The metric updates after each request: success/error counter, latency histogram, response-length histogram, and a tokens-per-second histogram derived from the response.

Open `app/metrics.py`. The histogram bucket choices are deliberate:

- `inference_latency_seconds`: buckets at 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60 s. CPU inference on a small model spans roughly 0.5–5 s for short responses and 5–30 s for long ones. Buckets must straddle the SLO threshold (here, 10 s) and span the full observed range — too few buckets and `histogram_quantile` lies; too many and Prometheus memory grows linearly.
- `inference_response_tokens`: buckets at 8, 16, 32, 64, 128, 256, 512, 1024. Powers of 2 because response lengths tend to be exponentially distributed (most are short, a long tail).
- `inference_tokens_per_second`: buckets up to 320 — a generous upper bound; qwen2.5:1.5b on a modern laptop CPU lands around 20–60 tok/s.

> **Misconception:** "More buckets is better." False. Each labelled bucket is a separate time series — `bucket_count × cardinality(labels)` series live in Prometheus's TSDB. 8–12 buckets that straddle the quantiles you care about is the right number.

Open `app/ollama_client.py`. Nothing surprising. The 180-second timeout is there because long-output generation on CPU can genuinely take that long, and you want the Python client to wait rather than fail fast (which would mark the request as an error in your counter even though the model was still producing tokens).

---

## Part 2 — Bake vs runtime fetch (a recurring trap)

This is the most important distinction in containerising any ML workload. The lesson (section 4.1) stated the rule. Here is the depth.

### The rule

Model artifacts go into the image **at build time**, not at container startup.

### Why this matters

A pod that downloads a 2 GB model file on every cold start has a startup time measured in minutes, not seconds. That breaks three things:

1. **Kubernetes readiness probes.** The default `initialDelaySeconds` is 0; even if you raise it to 60, a 90-second download still fails. The pod ends up CrashLoopBackOff, even though the code is correct.
2. **HPA scale-out under load.** If load spikes and HPA tries to add three replicas, each takes 90 seconds to become ready. Existing pods get overwhelmed and start erroring before the new ones arrive.
3. **Rollback determinism.** If the model artifact in remote storage is replaced or deleted, two pods built from the same image can serve different models depending on when they last fetched. This is a confused-deputy waiting to happen.

### The LLM twist

For a classical model (sklearn `.pkl`, ONNX, TensorFlow `SavedModel`) you bake the artifact into the inference image directly. For an LLM, the model weights are usually larger (several GB) and the model server (Ollama, vLLM, TGI) is a separate process with its own optimised loading path. The right pattern is:

- The **inference-api image** stays small (~150 MB). It contains only the Python wrapper and dependencies.
- The **model server image** (here, `ollama/ollama:0.5.4`) is downloaded once.
- The model **weights** are pulled by the model server on first startup and stored in a persistent volume (`ollama_data` in our compose file). Subsequent restarts find the weights in the volume — no re-download.

`Dockerfile.runtime-fetch` in this folder is the anti-pattern reference. It is **never built**. Open it to see what to avoid: a `CMD` that downloads a model file from a remote URL on every container start.

### When runtime fetch is acceptable

Two cases:

1. **Init containers in K8s.** An init container can fetch the artifact into an `emptyDir` before the main container starts. This makes the cold-start cost explicit and the main container's readiness probe meaningful. Use this when the artifact is small (< 200 MB) or when you genuinely cannot bake it in (per-tenant models in a multi-tenant cluster, for example).
2. **A dedicated model server with a persistent cache.** Ollama, vLLM, and Triton all fall here. The model is fetched once into a PV, and subsequent restarts mount that PV. This is what we do in this hands-on.

---

## Part 3 — Building the image

```bash
docker compose build inference-api
```

**Output (trimmed):**

```
[+] Building 15.2s (10/10) FINISHED
 => [internal] load build definition from Dockerfile
 => [internal] load .dockerignore
 => [internal] load metadata for docker.io/library/python:3.11-slim
 => [1/5] FROM docker.io/library/python:3.11-slim@sha256:...
 => [internal] load build context
 => [2/5] WORKDIR /srv
 => [3/5] COPY requirements.txt .
 => [4/5] RUN pip install --no-cache-dir -r requirements.txt
 => [5/5] COPY app/ /srv/app/
 => exporting to image
 => => naming to docker.io/library/inference-api:latest
```

**Explanation:**

The Dockerfile is minimal on purpose. Three layers that matter:

1. **`python:3.11-slim` base.** ~120 MB compressed. The `slim` variant lacks build tools, so any wheel with a C extension that needs compilation will fail. For the dependencies we use (`fastapi`, `uvicorn`, `prometheus-client`, `requests`, `pydantic`), pre-built wheels exist on PyPI for the slim image's glibc, so no compilation is needed.
2. **Pinned versions in `requirements.txt`.** A platform engineer who does not pin versions inherits a different image every Tuesday. Pin to exact versions; let dependabot bump them deliberately.
3. **`COPY app/` last.** Python source code changes most often. Putting it after `pip install` means rebuilds reuse the dependency layer cache.

The image is ~250 MB total. Check with `docker image ls inference-api`. The `uvicorn[standard]` extras (`uvloop`, `httptools`, `watchfiles`, `websockets`) add ~80 MB on top of the bare wrapper; if image size were a hard constraint you could swap to plain `uvicorn` and lose maybe 20% on cold start under high concurrency. Compare to a baked-in classical model image (300 MB to 2 GB depending on the model) or a baked-in LLM image (typically 4–10 GB) — keeping the wrapper separate from the model server is what keeps this small.

### What gets baked

Nothing about the model itself is in this image. That is the whole point of using Ollama as a separate service. If you replace the `MODEL_NAME` env var in `docker-compose.yml` and re-deploy, the same image serves a different model. This is a real production pattern: one inference-api image, many model variants, controlled by env vars or labels.

### Scanning

This image should still go through your normal CVE scan policy. The Python base image accumulates CVEs at the same rate as any Debian-derived image; check periodically with Trivy or Defender for Containers:

```bash
trivy image inference-api:latest --severity HIGH,CRITICAL
```

---

## Part 4 — Bringing the stack up

```bash
docker compose up -d
```

**Expected sequence:**

1. `ollama` container starts. Healthcheck transitions from `starting` to `healthy` within ~10 s.
2. `model-puller` runs once: `ollama pull qwen2.5:1.5b`. First time this takes 2–4 min on a 100 Mbps connection (the weights are ~1 GB). Watch with `docker compose logs -f model-puller`.
3. `inference-api` starts only after ollama is healthy. uvicorn binds to 0.0.0.0:8080.
4. `prometheus` starts and immediately begins scraping `inference-api:8080/metrics/` every 5 s.
5. `grafana` starts, provisions the Prometheus datasource, and loads the dashboard.

### The depends_on subtlety

The compose file uses two forms of `depends_on`:

- `condition: service_healthy` (inference-api → ollama) — waits for the healthcheck to pass before starting the dependent.
- No condition (model-puller → ollama with `condition: service_healthy`) — runs once after Ollama is up, then exits.

Without `condition: service_healthy`, compose would start inference-api as soon as the ollama container was *created*, not as soon as it was *ready*. The inference-api would then hit Ollama before Ollama is listening, fail the first health check, and recover only once requests started succeeding. Not catastrophic, but the cleaner sequencing is worth the extra two lines.

### What about the model-puller's exit code?

`restart: "no"` is important. Without it, compose would restart the puller forever after each successful exit, re-pulling the model unnecessarily. With `"no"`, the puller runs to completion and stays in `Exited (0)` state, which is what you want.

### Verify everything came up

```bash
docker compose ps
```

**Output:**

```
NAME            STATUS                 PORTS
grafana         Up                     0.0.0.0:3000->3000/tcp
inference-api   Up                     0.0.0.0:8080->8080/tcp
model-puller    Exited (0)
ollama          Up (healthy)           0.0.0.0:11434->11434/tcp
prometheus      Up                     0.0.0.0:9090->9090/tcp
```

`model-puller` being `Exited (0)` is success. If it shows `Restarting` or `Exited (1)`, check its logs — usually a transient network error pulling the model.

---

## Part 5 — Hitting the inference endpoint

```bash
curl -s http://localhost:8080/health | jq
```

**Output:**

```json
{
  "status": "ok",
  "model": "qwen2.5:1.5b",
  "ollama_reachable": true
}
```

The `/health` endpoint reports both the API's own status and whether Ollama is reachable. This is the right pattern for any service that depends on a downstream — the health check should report on the dependency too, so Kubernetes does not route traffic to a pod whose backend is broken.

```bash
curl -s -X POST http://localhost:8080/predict \
  -H 'content-type: application/json' \
  -d '{"prompt": "What is the capital of France?", "max_tokens": 64}' | jq
```

**Output (example):**

```json
{
  "response": "The capital of France is Paris.",
  "model": "qwen2.5:1.5b",
  "tokens": 8,
  "duration_seconds": 2.94
}
```

The first request after Ollama starts is slower because Ollama loads the model into memory on the first call. With qwen2.5:1.5b on a modern laptop CPU it lands around 2–4 s; with larger models (phi3:mini, llama3.2:3b) it can reach 8–15 s. Subsequent calls return in 0.3–1.5 s for short responses. This first-call latency is the reason readiness probes for K8s deployments of inference services need a generous `initialDelaySeconds` — see Part 8.

### What `eval_count` is

The `tokens` field comes from Ollama's `eval_count` in the response JSON. It is the number of tokens the model generated, NOT the total request size and NOT including the prompt tokens (which Ollama reports separately as `prompt_eval_count`). We instrument `eval_count` because the response-length signal is what shifts under drift; the prompt size shifts too, but it shifts because *we* sent different prompts, which is not a signal about model quality.

---

## Part 6 — Generating traffic and reading the dashboard

Start the synthetic traffic in another terminal:

```bash
python send_traffic.py --mode normal --duration 120 --rps 0.5
```

This sends roughly one short factual prompt every two seconds for two minutes. Open Grafana at <http://localhost:3000> (anonymous admin, no login). The dashboard `Inference API — model serving and monitoring` should already be visible.

Walk through each panel.

### Panel 1: Request rate by status

```promql
sum by (status) (rate(inference_requests_total[1m]))
```

A flat green line around 0.5 req/s. If `error` ever shows up red, something on the path failed. The counter labels are `status="success"` and `status="error"`, set explicitly in `main.py`. Recall from week 14 that `rate()` over a counter gives you per-second rate — never expose a counter directly on a dashboard.

### Panel 2: Inference latency p50/p95/p99

```promql
histogram_quantile(0.95, sum by (le) (rate(inference_latency_seconds_bucket[1m])))
```

For short prompts on qwen2.5:1.5b, p50 should sit around 0.5–1 s, p95 around 1–2 s, p99 not much higher. The red threshold line is at 10 s — the SLO defined in `alerts.yml` as the latency alert threshold.

> **Misconception:** "p99 from a histogram is the actual 99th percentile of observed values." False. It is an interpolated estimate based on bucket boundaries. If your buckets are too coarse near the relevant percentile, `histogram_quantile` can be off by a wide margin. For latency, having buckets at 0.5, 1, 2, 5 s is enough for short-response inference. For longer responses, the higher buckets matter.

### Panel 3: Response tokens distribution (drift signal)

```promql
histogram_quantile(0.95, sum by (le) (rate(inference_response_tokens_bucket[2m])))
```

With the `--mode normal` traffic, p50 sits around 12–40 tokens, but p95 lands around 150–200 — qwen2.5:1.5b regularly elaborates beyond the strict minimum answer (this is expected LLM behaviour; small instruction-tuned models are not deterministic in response length). The point of the baseline is *stability*, not low absolute numbers. The 2-minute window is wider than the latency panel's 1-minute window so the line is smoother; for a drift signal you want stability over short-term noise.

### Panel 4: Tokens per second (throughput)

A model-performance signal. On a modern laptop CPU, qwen2.5:1.5b runs at ~20–40 tok/s. If this drops, either the host is CPU-starved or you swapped to a larger model. This signal is more useful for capacity planning than for alerting.

### Panel 5: Deployed model

A `stat` panel showing the value of the `inference_model_version` gauge. The label `qwen2.5:1.5b` is displayed. In a multi-pod K8s deployment this panel would show one line per pod with their respective model labels — useful when you're rolling out a model swap and want to see how many pods are on the new version.

---

## Part 7 — Simulating drift

Stop the normal traffic (`Ctrl+C`). Run the drift mode:

```bash
python send_traffic.py --mode drift --duration 180 --rps 0.3
```

The prompts in drift mode are open-ended generative tasks ("write a short story", "explain the theory of relativity in detail"). Per-response length jumps to 300–512 tokens routinely (`send_traffic.py --mode drift` uses `max_tokens=512` so the histogram saturates the top bucket cleanly).

Watch Panel 3 (Response tokens distribution) in Grafana. The p95 line crosses the 256 threshold within a couple of minutes. Within the 2-minute `for:` clause on the `ResponseLengthShift` alert, Prometheus marks the alert as firing.

Check Prometheus directly at <http://localhost:9090/alerts>:

```
ResponseLengthShift  (firing)
  labels: {alertname="ResponseLengthShift", model="qwen2.5:1.5b",
           owner="ml-team", severity="warning"}
  value:  492

HighInferenceLatency  (firing)
  labels: {alertname="HighInferenceLatency", model="qwen2.5:1.5b",
           owner="devops-team", severity="warning"}
  value:  27.7
```

Notice that `HighInferenceLatency` fires too. Longer responses take longer to generate, so a drift in response length naturally pushes latency over the 10 s SLO. One symptom (long generations) produces two alerts with different owners — exactly the structure the lesson described. The ML team investigates whether the drift is real; the DevOps team decides whether to mitigate the latency by adding replicas, capping `max_tokens` at the gateway, or routing long requests to a separate pool.

### What this teaches

The alert label `owner: ml-team` is the key idea. From the lesson section 5.2:

> If the alert traces to "a pod is down" or "the node is OOM", that is yours. If the alert traces to "the model is producing different outputs than it should", that is the ML team's — you hand it off with the metric values and let them decide whether to retrain.

In production, this alert would route to a different channel in your notification policy: latency / error / OOM alerts go to the SRE on-call; response-length drift goes to the ML on-call. Same Alertmanager, different routing tree (the deep treatment of routing lives in [`monitoring/hands-on/alertmanager-deep-dive/`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources/tree/main/monitoring/hands-on/alertmanager-deep-dive)).

### Real-world drift detection goes further

Histogram of response length is a coarse drift signal — it tells you *something* shifted but not *what*. Production-grade ML monitoring uses tools like Evidently AI or whylogs to do statistical comparison between the current distribution of inputs/outputs and a reference baseline (KS test, PSI, JS divergence). The DevOps engineer's role does not change — you provision and operate whichever tool the ML team chooses; the ML team interprets the result.

For a sanity check that this is the right level of detail for the platform engineer to own, see Jeremy Jordan's "A simple solution for monitoring ML systems" linked in `learning_resources.md`.

---

## Part 8 — What changes in Kubernetes

The `k8s/` folder contains the manifests that would deploy this same stack to AKS (or any K8s cluster with kube-prometheus-stack installed). They are not applied in the hands-on — running them requires a cluster with the Prometheus Operator already installed (W15.1 lesson territory). Read them for the structural shape.

### Deployment

`k8s/deployment.yaml`. Two non-obvious choices:

- `readinessProbe.initialDelaySeconds: 20`. Generous because the first `/predict` call to Ollama loads the model into memory. The /health check itself is cheap, but the first real inference call is slow.
- `resources.requests.memory: 256Mi`. This is for the FastAPI wrapper alone — the model weights live in the Ollama pod, not here. If you co-located Ollama and the wrapper in the same pod (which you shouldn't, for scaling reasons), the request would need to cover the model weights too: 2–4 GiB for qwen2.5:1.5b.

### Service

`k8s/service.yaml`. A standard ClusterIP service. Nothing ML-specific. The named port `http` is what the ServiceMonitor selector targets.

### ServiceMonitor

`k8s/servicemonitor.yaml`. The K8s equivalent of the static `scrape_configs` block in the docker-compose `prometheus.yml`. A CRD from the Prometheus Operator. Two things matter:

- `selector.matchLabels: app: inference-api` selects which Services the Prometheus instance scrapes.
- `metadata.labels.release: kube-prometheus-stack` matches the default ServiceMonitor selector on the Prometheus CR created by the standard Helm chart. If you installed the operator with a different `--release` name, this label needs to match it. Forgetting this label is the #1 reason "my ServiceMonitor exists but Prometheus is not scraping" — see the troubleshooting table.

### HPA

`k8s/hpa.yaml`. CPU-based autoscaling between 2 and 10 replicas. The lesson mentioned a custom metric (`requests_in_flight`) as the preferred signal, but that requires `prometheus-adapter` or KEDA, both of which are operator installs in their own right. CPU is a reasonable default for a CPU-bound inference service.

### What is NOT here

- An Ollama deployment manifest. In a real cluster you would deploy Ollama as a separate StatefulSet with a PV for the weights, or replace it with a more production-friendly model server (vLLM, TGI, Triton). The pattern of "wrapper API talks to a model-server pod" is correct; only the choice of model server differs.
- An Ingress / external exposure. Inference APIs in production are usually behind an API gateway with auth + rate limiting. That is the same conversation as any other service.

---

## Part 9 — What would change for a classical scikit-learn model

The lesson previewed an iris-classification model with `predict_proba` returning confidence scores. The platform-engineer plumbing is nearly identical; only the metric semantics differ.

| Concept | LLM (this hands-on) | Classical model |
|---|---|---|
| Where the model lives | Ollama service + persistent volume | Baked into the inference-api image |
| `Dockerfile` | Small wrapper image, no model | Wrapper + serialized artifact (`COPY model/model.pkl /srv/`) |
| First-call cold start | Loading weights into Ollama memory (5–10 s) | Loading the pickle (under 1 s for small models) |
| Quality signal | `inference_response_tokens` (length distribution) | `prediction_confidence` (predicted-class probability) |
| Drift early-warning | Response length shifts upward → likely longer/more complex prompts | Mean confidence drops → inputs are increasingly out-of-distribution |
| Who owns the threshold | ML team | ML team |
| Who wires the alert | DevOps team | DevOps team |
| Who investigates | ML team (model issue) or DevOps (infra issue) | Same split |

The DevOps responsibility line does not move. What moves is the specific metric the ML team asks you to expose. Stay flexible: instrument whatever histogram or gauge they specify, name them consistently (`inference_*` prefix), and let the dashboards and alerts compose.

---

## Cleanup

```bash
docker compose down -v
```

The `-v` removes the `ollama_data` volume — the next `up` will re-pull qwen2.5:1.5b. If you plan to re-run the hands-on within a few days, omit `-v` to keep the weights cached:

```bash
docker compose down
```

Reclaim disk if you are done permanently:

```bash
docker image rm inference-api:latest ollama/ollama:0.5.4 prom/prometheus:v2.55.1 grafana/grafana:11.4.0
docker volume rm $(basename $PWD)_ollama_data
```

---

## Discussion questions

1. The `inference_response_tokens` p95 threshold is set to 256 in the alert rule. Who decides what the correct value is, and what would they need to know to choose it well?
2. If the ML team replaces `qwen2.5:1.5b` with `qwen2.5:7b`, which panels on the dashboard would change "naturally" and which would need human attention?
3. Why is `eval_count` (response tokens) a better drift signal than `total_duration` (which Ollama also returns)?
4. In Kubernetes, what would the consequence be of setting `readinessProbe.initialDelaySeconds: 0` for the inference-api Deployment? Walk through the pod's first 60 seconds.
5. The hands-on uses anonymous admin access to Grafana for convenience. What is the minimum production-acceptable change to fix that, and where would the credentials live?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `model-puller` exits with error `pull model manifest: file does not exist` | Typo in model name in `docker-compose.yml`. | Confirm the model name is `qwen2.5:1.5b` (case-sensitive, includes the tag). |
| `inference-api` returns 503 with `Connection refused` | Container started before Ollama was actually listening, healthcheck condition skipped. | `docker compose restart inference-api`. If recurring, check the ollama healthcheck status. |
| First `/predict` call hangs for 30+ seconds | First call after Ollama starts loads the model into memory. Subsequent calls are fast. | Wait for the first call; or warm Ollama with a dummy generate before opening the API to traffic. |
| `prometheus` shows `inference-api` target as `DOWN` | Scrape path mismatch. `prometheus_client.make_asgi_app()` mounted at `/metrics` exposes `/metrics/` (note the trailing slash); the scrape path needs the slash. | Confirm `metrics_path: /metrics/` in `prometheus.yml`. |
| Grafana dashboard shows "No data" even though Prometheus has data | Datasource UID mismatch between the dashboard JSON and the provisioned datasource. | Confirm both are `prometheus`. The dashboard JSON references `"uid": "prometheus"`. |
| `ResponseLengthShift` alert never fires under `--mode drift` | Rate window too narrow vs the duration of the drift run, or qwen response lengths happen to stay under 256 tokens. | Run `send_traffic.py --mode drift` for at least 4 minutes; reduce the alert threshold temporarily to 128 to confirm the wiring works. |
| ServiceMonitor exists but kube-prometheus-stack does not scrape (K8s appendix) | Missing label `release: kube-prometheus-stack` on the ServiceMonitor, or the Prometheus CR is selecting on a different label. | `kubectl get prometheus -n monitoring -o yaml` and inspect the `serviceMonitorSelector` block; match it. |
| `docker compose` complains it cannot find `host.docker.internal` (Linux hosts) | Linux Docker does not auto-resolve `host.docker.internal`. Only macOS/Windows do. | Use `--add-host=host.docker.internal:host-gateway` in the compose service, or run Ollama in compose (the default in this folder). |
| `bind: address already in use` on port 11434 when running `docker compose up` | A host-side Ollama is already listening on 11434. | The compose file in this folder intentionally does NOT publish 11434 to the host; if you re-added it, remove the `ports:` block under `ollama`. The inference-api reaches Ollama on the internal compose network — no host port mapping needed. |
| You want the inference-api to use your host's Ollama instead of the compose one | Save the model-pull time when you already have it locally. | `docker compose stop ollama model-puller`, then set `OLLAMA_HOST=http://host.docker.internal:11434` on the inference-api service (Linux: add `--add-host=host.docker.internal:host-gateway`). |

## References

- [Ollama API documentation](https://github.com/ollama/ollama/blob/main/docs/api.md) — `/api/generate`, `/api/tags`, and the response fields including `eval_count`, `eval_duration`, and `prompt_eval_count`.
- [prometheus_client Python library](https://github.com/prometheus/client_python) — Counter, Histogram, Gauge usage; `make_asgi_app` for the ASGI integration.
- [Prometheus operator — ServiceMonitor reference](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor) — the full CRD spec.
- [Histogram and Summary best practices](https://prometheus.io/docs/practices/histograms/) — bucket selection, `histogram_quantile` accuracy, and the trade-offs vs Summaries.
- [Jeremy Jordan — A simple solution for monitoring ML systems](https://www.jeremyjordan.me/ml-monitoring/) — the practical model behind the signals exposed in this hands-on.
- [Evidently AI documentation](https://docs.evidentlyai.com/) — production-grade drift detection (KS, PSI, JS divergence) for when histogram-based signals are too coarse.
- [Google SRE Book — Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — the four golden signals, which apply directly to inference services.
