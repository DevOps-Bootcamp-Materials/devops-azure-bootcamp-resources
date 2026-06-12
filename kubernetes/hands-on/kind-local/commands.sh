#!/usr/bin/env bash
# kind multi-node — full command sequence.
# This file is a quick reference; the narrative walkthrough lives in README.md.

# --- 1. Create the cluster from the config file ---------------------------
kind create cluster --config kind-config.yaml
kind get clusters
kubectl config current-context          # kind-dev

# --- 2. Three nodes = three containers -------------------------------------
kubectl get nodes
docker ps --filter name=dev- --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"

# --- 3. Build the image and load it into every node ------------------------
docker build -t hello-kind:1.0 ./app
kind load docker-image hello-kind:1.0 --name dev
# verify it landed inside a node:
docker exec dev-worker crictl images | grep hello-kind

# --- 4. Install ingress-nginx (kind-specific manifest) ---------------------
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# IMPORTANT (manifests >= v1.13 dropped the ingress-ready nodeSelector):
# on a multi-node cluster the controller may land on a worker with no host
# port mapping -> "empty reply from server". Pin it to the labeled node:
kubectl get pods -n ingress-nginx -o wide       # check the NODE column
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}'
kubectl -n ingress-nginx rollout status deployment ingress-nginx-controller

# --- 5. Deploy the app -------------------------------------------------------
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/service.yaml
kubectl apply -f manifests/ingress.yaml
kubectl get pods -n hello -o wide       # note the NODE column: spread across workers

# --- 6. Reach it through localhost ------------------------------------------
curl http://localhost -H "Host: hello.kind"

# --- 7. Scheduling observations ----------------------------------------------
kubectl describe node dev-control-plane | grep -A2 Taints   # control-plane taint
kubectl get pods -n hello -o wide                            # all pods on workers

# --- 8. A second cluster lives happily beside the first (optional) -----------
# kind create cluster --name ci
# kind get clusters
# kubectl config use-context kind-ci
# kind delete cluster --name ci

# --- 9. Cleanup ---------------------------------------------------------------
kind delete cluster --name dev
docker image rm hello-kind:1.0
