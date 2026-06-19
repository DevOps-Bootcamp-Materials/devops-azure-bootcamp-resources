#!/usr/bin/env bash
# minikube end-to-end — full command sequence.
# This file is a quick reference; the narrative walkthrough lives in README.md.

# --- 1. Cluster lifecycle -----------------------------------------------
minikube start --driver=docker
minikube status
kubectl get nodes -o wide

# --- 2. Under the hood --------------------------------------------------
docker ps --filter name=minikube          # the "node" is just a container
minikube ssh -- docker ps                 # what runs INSIDE the node (control plane)

# --- 3. Addons ----------------------------------------------------------
minikube addons list
minikube addons enable ingress
minikube addons enable metrics-server
kubectl get pods -n ingress-nginx
kubectl get pods -n kube-system | grep metrics-server

# --- 4. Deploy the sample app -------------------------------------------
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/configmap-html.yaml
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/service.yaml
kubectl get pods -n hello -w              # Ctrl+C when 2/2 Running

# --- 5. Reach the app: port-forward (works everywhere) -------------------
kubectl port-forward -n hello svc/hello-svc 8080:80
# in another terminal: curl http://localhost:8080

# --- 6. Reach the app: LoadBalancer + tunnel ------------------------------
kubectl apply -f manifests/service-lb.yaml
kubectl get svc -n hello hello-lb         # EXTERNAL-IP: <pending>
# In a SEPARATE terminal (leave it running):
#   minikube tunnel
kubectl get svc -n hello hello-lb         # EXTERNAL-IP populated now
# curl http://127.0.0.1:8080

# --- 7. Reach the app: Ingress -------------------------------------------
kubectl apply -f manifests/ingress.yaml
kubectl get ingress -n hello
# With the tunnel still running:
# curl http://127.0.0.1 -H "Host: hello.local"

# --- 8. The image-into-cluster trap ---------------------------------------
docker build -t hello-local:1.0 ./app
kubectl apply -f manifests/deployment-local-image.yaml
kubectl get pods -n hello -l app=hello-local      # ErrImagePull / ImagePullBackOff
minikube image load hello-local:1.0
minikube image ls | grep hello-local
kubectl get pods -n hello -l app=hello-local -w   # recovers to Running
kubectl port-forward -n hello deploy/hello-local 8081:80
# curl http://localhost:8081

# --- 9. Metrics ------------------------------------------------------------
kubectl top nodes
kubectl top pods -n hello

# --- 10. Profiles (optional) -----------------------------------------------
minikube profile list
# minikube start -p second --driver=docker
# kubectl config get-contexts
# minikube delete -p second

# --- 11. Cleanup ------------------------------------------------------------
kubectl delete namespace hello
minikube stop          # keeps the cluster on disk
# minikube delete      # removes it entirely
