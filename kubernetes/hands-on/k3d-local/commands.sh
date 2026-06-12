#!/usr/bin/env bash
# k3d — full command sequence.
# This file is a quick reference; the narrative walkthrough lives in README.md.

# --- 1. Create cluster + registry from the config file ----------------------
k3d cluster create --config k3d-config.yaml
k3d cluster list
k3d node list                              # servers, agents, serverlb, registry
kubectl config current-context             # k3d-dev

# --- 2. What K3s ships by default --------------------------------------------
kubectl get nodes
kubectl get pods -n kube-system            # traefik, svclb-*, coredns, metrics-server, local-path-provisioner
kubectl get storageclass                   # local-path (default)
kubectl get svc -n kube-system traefik     # type LoadBalancer, EXTERNAL-IP populated (klipper)

# --- 3. Push the image through the local registry ----------------------------
# Cluster-side name: registry.localhost:5000 (what manifests reference)
# Host-side name:    localhost:5000          (what you push through on Docker Desktop)
docker build -t registry.localhost:5000/hello-k3d:1.0 ./app
docker tag registry.localhost:5000/hello-k3d:1.0 localhost:5000/hello-k3d:1.0
docker push localhost:5000/hello-k3d:1.0
curl -s http://localhost:5000/v2/_catalog   # {"repositories":["hello-k3d"]}

# --- 4. Deploy: the cluster PULLS from the registry ---------------------------
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/service.yaml
kubectl apply -f manifests/ingress.yaml
kubectl get pods -n hello -o wide

# --- 5. Ingress via the bundled Traefik ---------------------------------------
curl http://localhost:8080 -H "Host: hello.k3d"

# --- 6. LoadBalancer with a real EXTERNAL-IP out of the box -------------------
kubectl apply -f manifests/service-lb.yaml
kubectl get svc -n hello hello-k3d-lb      # EXTERNAL-IP populated, no tunnel needed
curl http://localhost:8081

# --- 7. Stop/start (state survives) and multi-cluster -------------------------
# k3d cluster stop dev && k3d cluster start dev
# k3d cluster create second --servers 1 --agents 0
# k3d cluster list
# k3d cluster delete second

# --- 8. Cleanup -----------------------------------------------------------------
# The config-created registry is deleted together with the cluster.
k3d cluster delete dev
docker image rm registry.localhost:5000/hello-k3d:1.0 localhost:5000/hello-k3d:1.0
