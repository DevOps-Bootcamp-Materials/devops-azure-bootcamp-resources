#!/usr/bin/env bash
# Tunnels hands-on — full command sequence.
# Part A: ngrok CLI. Part B: Cloudflare quick tunnel (no account). Part C: ngrok Kubernetes Operator.

# ========== PART A — ngrok CLI ===============================================
# One-time: paste your authtoken from https://dashboard.ngrok.com
ngrok config add-authtoken <YOUR_AUTHTOKEN>

# A local service to expose
docker run -d --name tunnel-demo -p 8089:80 nginx:1.27-alpine
curl -s http://localhost:8089 | head -1

# Expose it (random URL; leave running, watch the inspector at http://localhost:4040)
ngrok http 8089

# In another terminal: curl the printed https://....ngrok-free.app URL
# Note the browser interstitial on free HTML traffic; curl bypasses it with:
#   curl -H "ngrok-skip-browser-warning: 1" https://....ngrok-free.app

# Your permanent free static domain (auto-assigned; note the .dev TLD):
ngrok api reserved-domains list
ngrok http 8089 --url https://YOUR-DOMAIN.ngrok-free.dev

# ========== PART B — Cloudflare quick tunnel (no account at all) =============
cloudflared tunnel --url http://localhost:8089
# -> prints https://<random-words>.trycloudflare.com ; curl it from anywhere.
# No bandwidth caps, no signup; URL changes every run. Ctrl+C to close.

docker rm -f tunnel-demo

# ========== PART C — ngrok Kubernetes Operator ================================
# Needs: authtoken + an API key (dashboard -> API). Free plan works.
k3d cluster create tunnel-demo --servers 1 --agents 1

helm repo add ngrok https://charts.ngrok.com
helm repo update
helm install ngrok-operator ngrok/ngrok-operator \
  --namespace ngrok-operator --create-namespace \
  --set credentials.apiKey=<YOUR_API_KEY> \
  --set credentials.authtoken=<YOUR_AUTHTOKEN>

kubectl get pods -n ngrok-operator

# The app + the ngrok-class Ingress (edit YOUR-DOMAIN first)
kubectl apply -f manifests/app.yaml
kubectl apply -f manifests/ingress-ngrok.yaml
kubectl get ingress -n tunnel-demo

# From anywhere on the internet:
curl -H "ngrok-skip-browser-warning: 1" https://YOUR-DOMAIN.ngrok-free.dev

# Cleanup
k3d cluster delete tunnel-demo
