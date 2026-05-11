# Hands-on 00: kubectl Basics — No YAML Required

## Objective

Get comfortable with the `kubectl` CLI before touching any manifest. Everything
in this lab is done imperatively — you type a command and Kubernetes does the
work. The goal is to build intuition for what the cluster looks like from the
inside and what the basic objects feel like before you write them in YAML.

By the end of this lab you will be able to:
- Inspect a cluster and understand its structure
- Run, expose, scale, and delete workloads with a single command each
- Read Pod logs and open a shell inside a running container
- Use `--dry-run=client -o yaml` to generate manifest stubs from imperative commands

No manifest files are needed. All commands go straight to the API server.

---

## Prerequisites

```bash
# A local cluster must be running
minikube start

# kubectl must be configured to talk to it
kubectl version --short
kubectl config current-context   # should show: minikube
```

---

## Part 1 — Explore the cluster

Before running anything, understand what you are working with.

### Cluster info and health

```bash
kubectl cluster-info
kubectl get nodes
kubectl get nodes -o wide          # adds OS, kernel, container runtime
kubectl describe node minikube     # full node status, capacity, allocatable resources
```

### Namespaces — the isolation boundary

```bash
kubectl get namespaces             # lists all namespaces
kubectl get all -n kube-system     # what Kubernetes itself runs (DNS, scheduler, API server proxy…)
```

### API resources — everything kubectl can manage

```bash
kubectl api-resources              # full list of object kinds with their API group and scope
kubectl api-resources --namespaced=false   # cluster-scoped objects (Nodes, PVs, ClusterRoles…)
```

---

## Part 2 — Your first Pod

### Run a Pod

```bash
kubectl run my-pod --image=nginx:1.25
```

That single command creates a Pod running nginx. No YAML written.

### Check its status

```bash
kubectl get pods
kubectl get pods -o wide           # adds IP and node
kubectl get pod my-pod -o yaml     # the full object as Kubernetes stored it
```

### What happened internally?

```bash
kubectl describe pod my-pod
# Read the Events section at the bottom — it shows:
#   Scheduled   → which node was selected
#   Pulling     → image being downloaded
#   Pulled      → image ready
#   Created     → container created
#   Started     → container running
```

### Logs

```bash
kubectl logs my-pod                # stdout of the container
kubectl logs my-pod -f             # follow (like tail -f), Ctrl+C to stop
kubectl logs my-pod --tail=20      # last 20 lines
kubectl logs my-pod --since=5m     # logs from the last 5 minutes
```

### Shell inside the container

```bash
kubectl exec -it my-pod -- /bin/bash

# Inside: explore the nginx container environment
ls /usr/share/nginx/html           # default web root
cat /etc/nginx/nginx.conf          # nginx config
curl localhost                     # works — you are inside the container's network
hostname                           # the Pod name
env                                # all environment variables
exit
```

### Run a one-off command without an interactive shell

```bash
kubectl exec my-pod -- nginx -v    # nginx version
kubectl exec my-pod -- ls /etc/nginx
```

---

## Part 3 — Expose the Pod

A Pod has an IP but it is only reachable from within the cluster. Expose it
with a Service to reach it from your laptop.

```bash
# Creates a NodePort Service pointing to the Pod's port 80
kubectl expose pod my-pod --port=80 --type=NodePort --name=my-svc

kubectl get service my-svc
# PORT(S) column shows something like 80:31234/TCP
# 31234 is the port open on the minikube node

# Get the full URL
minikube service my-svc --url

# Test it
curl $(minikube service my-svc --url)
```

---

## Part 4 — Deployment and scaling

A standalone Pod is not resilient. Use a Deployment to get automatic restarts
and the ability to scale.

```bash
# Create a Deployment (manages a ReplicaSet which manages the Pods)
kubectl create deployment my-app --image=nginx:1.25 --replicas=1

kubectl get deployment my-app
kubectl get replicaset
kubectl get pods
```

### Scale up

```bash
kubectl scale deployment my-app --replicas=4

kubectl get pods                   # 4 pods
kubectl get deployment my-app      # READY: 4/4
```

### Scale down

```bash
kubectl scale deployment my-app --replicas=2
kubectl get pods -w                # watch 2 pods terminate. Ctrl+C when stable.
```

### Expose the Deployment

```bash
kubectl expose deployment my-app --port=80 --type=NodePort --name=my-app-svc
minikube service my-app-svc --url
curl $(minikube service my-app-svc --url)
```

---

## Part 5 — Update and rollback

```bash
# Update the image
kubectl set image deployment/my-app nginx=nginx:1.26

# Check rollout progress
kubectl rollout status deployment/my-app

# View history
kubectl rollout history deployment/my-app

# Undo
kubectl rollout undo deployment/my-app
kubectl rollout status deployment/my-app
```

---

## Part 6 — Quick debugging commands

These are the commands you will use most often when something is broken.

```bash
# Why is my Pod not starting?
kubectl describe pod <pod-name>        # look at Events at the bottom

# CrashLoopBackOff — check the crash logs
kubectl logs <pod-name> --previous     # logs from the PREVIOUS (crashed) container

# Is the Service sending traffic to the right Pods?
kubectl get endpoints my-app-svc       # should list Pod IPs
kubectl describe endpoints my-app-svc

# What is the cluster doing right now?
kubectl get events --sort-by='.lastTimestamp'

# Watch all Pod state changes in real time
kubectl get pods -w

# Resource usage (requires metrics-server)
minikube addons enable metrics-server
kubectl top nodes
kubectl top pods
```

---

## Part 7 — Bridge to manifests (dry-run)

Every imperative command can generate the equivalent YAML instead of applying
it. This is the fastest way to learn manifest syntax: let kubectl write it for you.

```bash
# See the YAML that 'kubectl run' would create, without creating anything
kubectl run nginx-test \
  --image=nginx:1.25 \
  --dry-run=client \
  -o yaml

# Save it to a file and use it as a starting point
kubectl run nginx-test \
  --image=nginx:1.25 \
  --dry-run=client \
  -o yaml > my-first-pod.yaml

cat my-first-pod.yaml

# Same for a Deployment
kubectl create deployment my-app \
  --image=nginx:1.25 \
  --replicas=3 \
  --dry-run=client \
  -o yaml > my-first-deployment.yaml

# Same for a Service
kubectl expose deployment my-app \
  --port=80 \
  --type=NodePort \
  --dry-run=client \
  -o yaml > my-first-service.yaml
```

These generated files are where the next labs start.

---

## Cleanup

```bash
kubectl delete pod my-pod
kubectl delete service my-svc
kubectl delete deployment my-app
kubectl delete service my-app-svc
rm -f my-first-pod.yaml my-first-deployment.yaml my-first-service.yaml
```

---

## Key commands cheatsheet

| Goal | Command |
|------|---------|
| Run a Pod | `kubectl run <name> --image=<image>` |
| Create a Deployment | `kubectl create deployment <name> --image=<image> --replicas=N` |
| Expose as Service | `kubectl expose pod/deployment <name> --port=80 --type=NodePort` |
| Scale | `kubectl scale deployment <name> --replicas=N` |
| See logs | `kubectl logs <pod>` |
| Shell into container | `kubectl exec -it <pod> -- /bin/bash` |
| Describe (debug) | `kubectl describe pod/deployment/service <name>` |
| Update image | `kubectl set image deployment/<name> <container>=<image>:<tag>` |
| Rollback | `kubectl rollout undo deployment/<name>` |
| Generate YAML | `kubectl ... --dry-run=client -o yaml` |
| Delete anything | `kubectl delete pod/deployment/service <name>` |
