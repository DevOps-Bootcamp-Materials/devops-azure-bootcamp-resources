#!/usr/bin/env bash
# Traefik end-to-end — full command sequence.
# Part A: Docker provider. Part B: Kubernetes (k3d's bundled Traefik).

# ========== PART A — Docker ==================================================
cd docker

# --- A1. Bring up Traefik + two labeled services ------------------------------
docker compose up -d
docker compose ps

# --- A2. The dashboard: Traefik's discovered state ----------------------------
# Open http://localhost:8080  -> HTTP routers: whoami@docker, echo@docker

# --- A3. Route by hostname (zero config files) --------------------------------
curl http://whoami.localhost
curl http://echo.localhost          # note the X-Taught-By response header:
curl -i http://echo.localhost | grep -i x-taught-by

# --- A4. Dynamic discovery: scale and watch -----------------------------------
docker compose up -d --scale whoami=3
# repeat a few times: the Hostname line rotates across the 3 containers
curl -s http://whoami.localhost | grep Hostname
curl -s http://whoami.localhost | grep Hostname
curl -s http://whoami.localhost | grep Hostname

# --- A5. Scale back down: the route heals itself --------------------------------
docker compose up -d --scale whoami=1
# (a request fired in the same instant as the scale-down can fail once —
#  sub-second convergence window; just retry)
curl -s http://whoami.localhost | grep Hostname   # still answers

# --- A6. Tear down Part A -------------------------------------------------------
docker compose down
cd ..

# ========== PART B — Kubernetes (k3d) ========================================
# --- B1. A k3d cluster: Traefik is already there ------------------------------
k3d cluster create traefik-demo --servers 1 --agents 1 --port "8080:80@loadbalancer"
# The helm-install jobs take ~30-60s; helm-install-traefik may show Error/restarts
# while it waits for the CRD job — expected. Script the wait:
kubectl wait --for=condition=complete job --all -n kube-system --timeout=240s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=180s
kubectl get pods -n kube-system | grep traefik
kubectl get ingressclass

# --- B2. The app + the standard Ingress ---------------------------------------
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/ingress.yaml
kubectl wait --for=condition=Ready pod -l app=whoami -n traefik-demo --timeout=120s
kubectl get pods -n traefik-demo
curl -H "Host: whoami.k3d" http://localhost:8080

# --- B3. The native CRDs: Middleware + IngressRoute ----------------------------
kubectl get crd | grep traefik          # the CRDs K3s's Traefik installed
kubectl apply -f kubernetes/middleware.yaml
kubectl apply -f kubernetes/ingressroute.yaml
# Traefik picks up new CRD objects asynchronously (~5s observed) — a 404 right
# after apply just means "retry in a few seconds".
curl -i -H "Host: whoami-crd.k3d" http://localhost:8080 | grep -i x-taught-by

# --- B4. Compare the two routes side by side -----------------------------------
kubectl get ingress,ingressroute,middleware -n traefik-demo

# --- B5. Cleanup -----------------------------------------------------------------
k3d cluster delete traefik-demo
