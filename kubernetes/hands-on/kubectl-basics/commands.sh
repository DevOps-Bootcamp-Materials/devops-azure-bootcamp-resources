#!/usr/bin/env bash
# =============================================================================
# Lab 00 — kubectl Basics: imperative command walkthrough
# =============================================================================
# No YAML manifests. Every object is created with a direct kubectl command.
# Run each block manually, one at a time. Read the comment before executing.
#
# Prerequisites:
#   minikube start
#   kubectl config current-context   →  minikube
# =============================================================================


# =============================================================================
# PART 1 — Inspect the cluster before touching anything
# =============================================================================

# High-level cluster info: API server URL and CoreDNS address.
kubectl cluster-info

# List the worker (and control-plane) nodes.
# In minikube there is only one node that plays both roles.
kubectl get nodes

# -o wide adds: OS image, kernel version, container runtime (containerd/docker).
# In production this helps spot nodes running outdated kernels.
kubectl get nodes -o wide

# Full node detail: CPU/memory capacity, allocatable resources, conditions,
# running system Pods, and events. This is where you diagnose node pressure.
kubectl describe node minikube

# List all namespaces. kube-system is where Kubernetes' own components live.
kubectl get namespaces

# See what Kubernetes itself runs (DNS, kube-proxy, metrics-server if enabled…)
kubectl get all -n kube-system

# Full list of object types this cluster knows about.
# SHORTNAMES column shows aliases (po=pod, svc=service, deploy=deployment…)
kubectl api-resources

# Only cluster-scoped objects (no namespace — accessible to all tenants):
kubectl api-resources --namespaced=false


# =============================================================================
# PART 2 — Run your first Pod
# =============================================================================

# 'kubectl run' is the imperative equivalent of writing a Pod manifest.
# --image sets the container image. No manifest file needed.
kubectl run my-pod --image=nginx:1.25

# WHY nginx? It starts instantly and serves HTTP on port 80 out of the box,
# making it easy to verify the Pod is working.

# Watch the Pod start. Observe the status progression:
#   Pending → ContainerCreating → Running
kubectl get pods -w
# Ctrl+C once Running.

# Show the Pod IP and which node it landed on:
kubectl get pods -o wide

# Dump the complete YAML object as stored in etcd.
# This is the FULL spec Kubernetes inferred from your one-line command,
# including fields you never typed (defaultMode, terminationMessagePath, etc.).
kubectl get pod my-pod -o yaml

# ---- Describe: your main debugging tool ------------------------------------
# Shows: scheduling events, image pull, container state, probes, volumes, events.
# ALWAYS check 'describe' first when a Pod is not behaving as expected.
kubectl describe pod my-pod


# ---- Logs ------------------------------------------------------------------
# Kubernetes captures stdout/stderr of the container process (PID 1).
# nginx writes access and error logs to stdout by default.
kubectl logs my-pod

# Follow logs in real time (Ctrl+C to stop):
kubectl logs my-pod -f

# Only last 10 lines — useful when logs are very long:
kubectl logs my-pod --tail=10

# Logs from the last 2 minutes:
kubectl logs my-pod --since=2m


# ---- Exec: shell inside the container -------------------------------------
# Opens a process in the container's namespaces (network, PID, filesystem).
# You are NOT on the node — you are inside the container isolation boundary.
kubectl exec -it my-pod -- /bin/bash

# Try these inside the shell:
#   hostname                        # = Pod name
#   ip addr                         # container's network interface
#   curl localhost                  # nginx default page
#   cat /etc/nginx/nginx.conf       # nginx configuration
#   ls /usr/share/nginx/html        # default web root
#   env                             # all environment variables
#   ps aux                          # running processes inside the container
#   exit

# Run a single command without an interactive shell:
kubectl exec my-pod -- nginx -v
kubectl exec my-pod -- cat /etc/nginx/nginx.conf


# =============================================================================
# PART 3 — Expose the Pod
# =============================================================================

# A Pod's IP is only reachable from within the cluster.
# 'kubectl expose' creates a Service that opens a stable port.
kubectl expose pod my-pod --port=80 --type=NodePort --name=my-svc

# Read the PORT(S) column: "80:3XXXX/TCP"
#   80     → the Service port (internal cluster traffic)
#   3XXXX  → the NodePort (external, open on the minikube node)
kubectl get service my-svc

# Describe the Service to see the selector and endpoints:
kubectl describe service my-svc

# minikube builds the correct external URL for you:
minikube service my-svc --url

# Hit it from your terminal:
curl $(minikube service my-svc --url)

# Inspect the Endpoints object (Kubernetes keeps Pod IPs here):
kubectl get endpoints my-svc


# =============================================================================
# PART 4 — Deployment and scaling
# =============================================================================

# A Deployment is the production-grade way to run Pods.
# It manages a ReplicaSet which manages the Pods.
# If a Pod dies, the Deployment recreates it automatically.
kubectl create deployment my-app --image=nginx:1.25 --replicas=1

# The hierarchy: Deployment → ReplicaSet → Pod(s)
kubectl get deployment my-app
kubectl get replicaset
kubectl get pods

# ---- Scale up --------------------------------------------------------------
# Scale to 4 replicas. The ReplicaSet creates 3 new Pods.
kubectl scale deployment my-app --replicas=4

# Watch 4 Pods come up:
kubectl get pods -w
# Ctrl+C when all 4 show Running.

kubectl get deployment my-app
# READY should show 4/4.

# ---- Observe self-healing --------------------------------------------------
# Delete one Pod manually. The ReplicaSet notices the deficit and creates a new one.
POD=$(kubectl get pods -l app=my-app -o jsonpath='{.items[0].metadata.name}')
echo "Deleting: $POD"
kubectl delete pod "$POD"

kubectl get pods -w
# Ctrl+C after you see a replacement Pod appear. This is self-healing.

# ---- Scale down ------------------------------------------------------------
kubectl scale deployment my-app --replicas=2
kubectl get pods -w
# Ctrl+C when only 2 remain.

# ---- Expose the Deployment -------------------------------------------------
kubectl expose deployment my-app --port=80 --type=NodePort --name=my-app-svc
kubectl get service my-app-svc

curl $(minikube service my-app-svc --url)


# =============================================================================
# PART 5 — Update and rollback
# =============================================================================

# Update the nginx image from 1.25 to 1.26.
# The Deployment performs a rolling update: new Pods come up before old ones go down.
kubectl set image deployment/my-app nginx=nginx:1.26

# Watch the rolling update:
kubectl rollout status deployment/my-app

# After completion, verify the new image is in use:
kubectl describe deployment my-app | grep Image

# Revision history (each rollout = one revision):
kubectl rollout history deployment/my-app

# Roll back to the previous revision:
kubectl rollout undo deployment/my-app
kubectl rollout status deployment/my-app

# Confirm image reverted to 1.25:
kubectl describe deployment my-app | grep Image


# =============================================================================
# PART 6 — Debugging commands you'll use daily
# =============================================================================

# Pod not starting? Check events at the bottom of describe:
kubectl describe pod $(kubectl get pods -l app=my-app -o name | head -1)

# CrashLoopBackOff? Read the logs of the previous (crashed) container:
# kubectl logs <pod-name> --previous

# Is the Service routing to the right Pods?
kubectl get endpoints my-app-svc

# See everything Kubernetes has been doing recently, sorted by time:
kubectl get events --sort-by='.lastTimestamp'

# Watch all events streaming in real time (open in a second terminal):
kubectl get events -w

# Resource consumption (needs metrics-server):
minikube addons enable metrics-server
# Wait ~30s for metrics-server to start, then:
kubectl top nodes
kubectl top pods


# =============================================================================
# PART 7 — Generate YAML from imperative commands (--dry-run)
# =============================================================================

# --dry-run=client -o yaml prints the manifest WITHOUT creating anything.
# Use this to:
#   a) Learn what a manifest looks like
#   b) Generate a starting template you then customise
#   c) Quickly scaffold objects during the CKA/CKAD exam

# Generate a Pod manifest:
kubectl run nginx-test --image=nginx:1.25 --dry-run=client -o yaml

# Save to file:
kubectl run nginx-test --image=nginx:1.25 --dry-run=client -o yaml > my-first-pod.yaml
cat my-first-pod.yaml

# Generate a Deployment manifest:
kubectl create deployment my-app \
  --image=nginx:1.25 \
  --replicas=3 \
  --dry-run=client \
  -o yaml > my-first-deployment.yaml

# Generate a Service manifest from an existing Deployment:
kubectl expose deployment my-app \
  --port=80 \
  --type=NodePort \
  --dry-run=client \
  -o yaml > my-first-service.yaml

# Compare: what kubectl create wrote vs what you would write from scratch.
# In labs 01-04, the manifests you find in the manifests/ folder are the
# hand-authored version of exactly these generated stubs.
cat my-first-deployment.yaml


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete pod my-pod
kubectl delete service my-svc
kubectl delete deployment my-app
kubectl delete service my-app-svc
rm -f my-first-pod.yaml my-first-deployment.yaml my-first-service.yaml

echo "Lab 00 complete. Ready for Lab 01 — Pods, ReplicaSets and Deployments."
