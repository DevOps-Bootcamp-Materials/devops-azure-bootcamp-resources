# Hands-on 01: Pods, ReplicaSets and Deployments

## Objective

Demonstrate that Kubernetes does not manage containers directly, but abstract objects with their own semantics. A **Pod** is the minimum scheduling unit; a **ReplicaSet** guarantees that N replicas of that Pod are always running; a **Deployment** manages the ReplicaSet lifecycle and enables zero-downtime updates.

By the end of this lab you will understand:
- Why you rarely create Pods directly in production
- How Kubernetes reconciles desired state with current state
- How to perform a rollout and rollback an application version

---

## Prerequisites

```bash
# Start the cluster
minikube start

# Verify the active context
kubectl config current-context

# Create a dedicated namespace for this lab
kubectl create namespace lab01
kubectl config set-context --current --namespace=lab01
```

---

## Part 1 — Pod: the minimum unit

A Pod encapsulates one or more containers that share network and storage. It is ephemeral by nature: if it dies, nothing brings it back (that is the ReplicaSet's job).

### 1.1 Create a Pod imperatively (not recommended in production)

```bash
kubectl run nginx-pod --image=nginx:1.25 --port=80
```

### 1.2 Inspect the Pod

```bash
# Status and node where it was scheduled
kubectl get pod nginx-pod -o wide

# Full description: events, conditions, containers
kubectl describe pod nginx-pod

# Container logs
kubectl logs nginx-pod

# Interactive shell inside the Pod
kubectl exec -it nginx-pod -- /bin/bash
```

### 1.3 Create the same Pod with a declarative manifest

The manifest that reproduces the Pod above is in `manifests/pod.yaml`. Apply it:

```bash
kubectl apply -f manifests/pod.yaml
```

Notice that `kubectl apply` is idempotent: if the object already exists with the same spec, it does nothing. This is the foundation of GitOps.

### 1.4 Delete the Pod and confirm it does not recover

```bash
kubectl delete pod nginx-pod

# It does not come back. Kubernetes has no instruction to replace it.
kubectl get pods
```

**Conclusion:** Pods are ephemeral. In production you need a controller to manage them.

---

## Part 2 — ReplicaSet: availability guarantee

A ReplicaSet watches how many Pods matching a given **label selector** are in Running state and reconciles toward the desired count (`replicas`).

### 2.1 Apply the ReplicaSet

```bash
kubectl apply -f manifests/replicaset.yaml
kubectl get replicaset
kubectl get pods --show-labels
```

### 2.2 Simulate a failure: kill a Pod

```bash
# Get the name of one Pod
POD=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')

# Delete it
kubectl delete pod $POD

# The ReplicaSet detects the deficit and immediately creates a new one
kubectl get pods -w   # -w watches in real time (Ctrl+C to exit)
```

### 2.3 Scale manually

```bash
# Imperative (useful in emergencies, not in production)
kubectl scale replicaset nginx-rs --replicas=5
kubectl get pods

# Scale back down to 2
kubectl scale replicaset nginx-rs --replicas=2
```

**Conclusion:** the ReplicaSet solves availability, but it does not manage image updates. That is the Deployment's job.

---

## Part 3 — Deployment: lifecycle management

A Deployment is the object you will use almost all the time. It creates and manages ReplicaSets automatically, enabling rolling updates (zero downtime) and rollbacks.

### 3.1 Apply the Deployment

```bash
kubectl apply -f manifests/deployment.yaml

# The Deployment creates its ReplicaSet, which creates the Pods
kubectl get deployment
kubectl get replicaset
kubectl get pods
```

### 3.2 Inspect the rollout

```bash
kubectl rollout status deployment/nginx-deployment
kubectl describe deployment nginx-deployment
```

### 3.3 Update the image (rolling update)

```bash
# Update to nginx 1.26
kubectl set image deployment/nginx-deployment nginx=nginx:1.26

# Watch new Pods come up before old ones are terminated
kubectl rollout status deployment/nginx-deployment
kubectl get pods -w

# Verify the current image
kubectl describe deployment nginx-deployment | grep Image
```

Kubernetes keeps the ReplicaSet history to allow reversions:

```bash
kubectl get replicaset
# You will see two RS: the new one (DESIRED=3, CURRENT=3) and the previous one (DESIRED=0, CURRENT=0)
```

### 3.4 Rollback

```bash
# View revision history
kubectl rollout history deployment/nginx-deployment

# Revert to the previous version
kubectl rollout undo deployment/nginx-deployment

# Or to a specific revision
kubectl rollout undo deployment/nginx-deployment --to-revision=1

kubectl rollout status deployment/nginx-deployment
```

---

## Part 4 — Cleanup

```bash
kubectl delete -f manifests/
kubectl delete namespace lab01

# Switch back to the default namespace
kubectl config set-context --current --namespace=default
```

---

## Discussion questions

1. What would happen if you set `replicas: 0` in a Deployment? What could that be useful for?
2. Why are `maxUnavailable` and `maxSurge` in the RollingUpdate strategy important in production?
3. What is the relationship between the Pod template labels and the Deployment selector?

---

## Key concepts

| Object | Responsibility |
|--------|---------------|
| Pod | Run one or more containers sharing the same network/storage context |
| ReplicaSet | Keep N Pod replicas active at all times |
| Deployment | Manage ReplicaSets: rolling updates, rollbacks, revision history |
