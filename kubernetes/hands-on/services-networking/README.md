# Hands-on 02: Services and Networking

## Objective

Demonstrate that Pods are ephemeral and their IPs change constantly, which is why Kubernetes introduces **Services** as a stable abstraction layer over a set of Pods. Additionally, explore how to expose applications outside the cluster using **NodePort** and **Ingress**.

By the end of this lab you will understand:
- Why a Pod IP is not a reliable address
- How Kubernetes internal DNS works (`kube-dns`)
- The practical differences between ClusterIP, NodePort, and LoadBalancer
- How Ingress unifies external HTTP/S access

---

## Prerequisites

```bash
minikube start
minikube addons enable ingress   # enables the Ingress Controller (nginx)

kubectl create namespace lab02
kubectl config set-context --current --namespace=lab02
```

---

## Part 1 — The problem: Pod IPs are not stable

```bash
# Deploy the base Deployment
kubectl apply -f manifests/deployment-base.yaml

# Check Pod IPs
kubectl get pods -o wide

# Kill a Pod and observe that the replacement gets a different IP
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD
kubectl get pods -o wide   # New IP → any hardcoded address would have broken
```

**Conclusion:** you need a stable address that always points to the correct set of Pods.

---

## Part 2 — ClusterIP: internal communication

A `ClusterIP` Service (the default type) creates a stable virtual IP accessible only from within the cluster. `kube-proxy` redirects traffic to the healthy Pods that match the selector.

### 2.1 Apply the Service

```bash
kubectl apply -f manifests/service-clusterip.yaml
kubectl get service web-service
```

The `CLUSTER-IP` field is the virtual IP. It never changes as long as the Service exists.

### 2.2 Test internal DNS resolution

```bash
# Launch a temporary debugging Pod
kubectl run debug --image=busybox:1.36 --restart=Never -it --rm -- sh

# Inside the Pod:
nslookup web-service                              # resolves to CLUSTER-IP
nslookup web-service.lab02.svc.cluster.local      # full FQDN
wget -qO- http://web-service                      # HTTP request to the Service
exit
```

The DNS pattern is: `<service>.<namespace>.svc.cluster.local`

### 2.3 Inspect the Endpoints

Kubernetes maintains an `Endpoints` object that lists the actual IPs of the selected Pods:

```bash
kubectl get endpoints web-service
kubectl describe endpoints web-service

# Compare with Pod IPs
kubectl get pods -o wide -l app=web
```

If a Pod fails its readinessProbe, its IP is removed from Endpoints and the Service stops sending traffic to it.

---

## Part 3 — NodePort: external access from outside the cluster

A `NodePort` Service opens a static port (range 30000–32767) on **every** node in the cluster. External traffic arriving on that port is forwarded to the Service and then to the Pods.

```bash
kubectl apply -f manifests/service-nodeport.yaml
kubectl get service web-nodeport

# In minikube, get the URL directly
minikube service web-nodeport --url -n lab02

# Open in the browser or use curl
curl $(minikube service web-nodeport --url -n lab02)
```

**NodePort limitations in production:**
- Exposes one port per service → hard to manage at scale
- No path/host routing → all services share the same node IP
- In cloud environments, prefer `LoadBalancer` or `Ingress`

---

## Part 4 — Ingress: intelligent HTTP routing

An **Ingress** is a Kubernetes object that defines HTTP/S routing rules. It requires an **Ingress Controller** (nginx, Traefik, HAProxy…) that reads those rules and enforces them.

### 4.1 Deploy a second service to demonstrate path-based routing

```bash
kubectl apply -f manifests/deployment-v2.yaml
kubectl apply -f manifests/service-v2.yaml
```

### 4.2 Apply the Ingress

```bash
kubectl apply -f manifests/ingress.yaml
kubectl get ingress
kubectl describe ingress web-ingress
```

### 4.3 Test routing

```bash
# Get the Ingress Controller IP in minikube
INGRESS_IP=$(minikube ip)

# Path-based routing
curl http://$INGRESS_IP/app       # → web-service (v1)
curl http://$INGRESS_IP/app-v2    # → web-v2-service (v2)

# Host-based routing (requires /etc/hosts entry or DNS)
echo "$INGRESS_IP ironhack.local" | sudo tee -a /etc/hosts
curl http://ironhack.local/app
```

---

## Part 5 — Accessing the service from your browser (AKS)

In AKS the nodes are not publicly exposed, so NodePort is not directly reachable from outside. Use `kubectl port-forward` to create a local tunnel to the cluster:

```bash
# Forward localhost:8080 to the ClusterIP service in AKS
kubectl port-forward svc/web-service 8080:80 -n lab02
```

Open **http://localhost:8080** in your browser. The response comes from an nginx Pod running inside AKS.

### Proving the response comes from AKS

```bash
# 1. List pods — note the pod name
kubectl get pods -n lab02

# 2. Hit the service through the tunnel
curl http://localhost:8080

# 3. Confirm the pod hostname matches — it will equal the pod name from step 1
kubectl exec -n lab02 deployment/web-deployment -- hostname
```

The hostname returned in step 3 matches the pod name shown in step 1, proving the HTTP response is served by a container running inside the AKS cluster.

---

## Part 6 — Cleanup

```bash
kubectl delete -f manifests/
kubectl delete namespace lab02
kubectl config set-context --current --namespace=default

# Clean up /etc/hosts if you modified it
sudo sed -i '/ironhack.local/d' /etc/hosts
```

---

## Discussion questions

1. Why does a `LoadBalancer` Service in a minikube cluster stay in `<pending>` state?
2. What advantage does `Ingress` have over having a `NodePort` per microservice?
3. If a Pod fails its `readinessProbe`, will it still receive traffic from the Service?

---

## Key concepts

| Type | Scope | Use case |
|------|-------|----------|
| ClusterIP | Inside the cluster only | Inter-service communication |
| NodePort | Cluster nodes | Testing, direct access without LB |
| LoadBalancer | Internet (requires cloud) | Production exposure in cloud |
| Ingress | Internet (requires controller) | HTTP/S routing with path and host rules |
