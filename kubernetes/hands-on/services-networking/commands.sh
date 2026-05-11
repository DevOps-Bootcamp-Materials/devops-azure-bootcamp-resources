#!/usr/bin/env bash
# =============================================================================
# Lab 02 — Services and Networking: command walkthrough
# =============================================================================
# Purpose: demonstrate why Pod IPs are unreliable, how Services provide a
#          stable abstraction, and how traffic flows from outside to inside
#          the cluster through NodePort and Ingress.
#
# How to use:
#   Run each block manually. Read the explanation before executing each command.
#
# Prerequisites:
#   minikube start
#   minikube addons enable ingress   ← required for Part 4
# =============================================================================

# --- 0. SETUP ----------------------------------------------------------------

kubectl create namespace lab02
kubectl config set-context --current --namespace=lab02

# Enable the Ingress addon if not already done:
minikube addons enable ingress

# Wait for the IngressController Pod to be Ready before Part 4:
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s


# =============================================================================
# PART 1 — Demonstrate that Pod IPs are not stable
# =============================================================================

# Deploy the base application (3 replicas of nginx)
kubectl apply -f manifests/deployment-base.yaml

# Show the current Pod IPs. Note them down.
# -o wide adds: NODE, IP, NOMINATED NODE, READINESS GATES
kubectl get pods -o wide

# Delete one Pod and observe it gets a DIFFERENT IP when recreated:
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
echo "Pod being deleted: $POD"
kubectl delete pod "$POD"

# Watch the replacement Pod come up with a new IP:
kubectl get pods -o wide -w
# Ctrl+C once the new Pod is Running.
# Conclusion: any hardcoded Pod IP would be broken now.


# =============================================================================
# PART 2 — ClusterIP: stable internal address
# =============================================================================

# Create the ClusterIP Service
kubectl apply -f manifests/service-clusterip.yaml

# Inspect the Service object:
#   TYPE      → ClusterIP
#   CLUSTER-IP → virtual IP, stable for the life of the Service
#   EXTERNAL-IP → <none> (ClusterIP is not reachable from outside the cluster)
#   PORT(S)   → 80/TCP
kubectl get service web-service

# See the full spec including selector:
kubectl describe service web-service


# --- 2.1 Inspect the Endpoints object ----------------------------------------

# Kubernetes automatically creates an Endpoints object with the same name.
# It lists the real Pod IPs that match the Service selector AND are Ready.
kubectl get endpoints web-service

# Detailed view — see each IP:port pair
kubectl describe endpoints web-service

# Compare with Pod IPs:
kubectl get pods -o wide -l app=web,version=v1

# Delete a Pod and watch the Endpoints object update in real time:
POD=$(kubectl get pods -l app=web,version=v1 -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$POD" &
kubectl get endpoints web-service -w
# Ctrl+C after the endpoint is updated.
# You will see the Pod IP disappear from Endpoints (traffic stops going to it)
# and a new IP appear once the replacement Pod passes its readinessProbe.


# --- 2.2 Test DNS resolution from inside the cluster -------------------------

# Launch a temporary Pod with networking tools. --rm deletes it on exit.
kubectl run debug \
  --image=busybox:1.36 \
  --restart=Never \
  --rm \
  -it \
  -- sh

# --- Inside the debug Pod (copy these commands into the shell) ---
# Short hostname (works within the same namespace):
nslookup web-service

# Fully Qualified Domain Name — works across namespaces:
nslookup web-service.lab02.svc.cluster.local

# The DNS format is: <service>.<namespace>.svc.<cluster-domain>
# 'cluster.local' is the default cluster domain.

# HTTP request to the Service (round-robins across Pod IPs transparently):
wget -qO- http://web-service
wget -qO- http://web-service.lab02.svc.cluster.local

# Cross-namespace request (how microservices call each other):
# wget -qO- http://web-service.lab02.svc.cluster.local

exit
# -----------------------------------------------------------------


# =============================================================================
# PART 3 — NodePort: expose the application externally
# =============================================================================

kubectl apply -f manifests/service-nodeport.yaml

# EXTERNAL-IP is still <none> for NodePort in minikube.
# The PORT column shows '80:30080/TCP' — meaning:
#   - Internal Service port: 80
#   - NodePort (open on each node): 30080
kubectl get service web-nodeport

# minikube provides a helper that builds the correct external URL:
minikube service web-nodeport --url -n lab02

# Test access from your local machine:
curl $(minikube service web-nodeport --url -n lab02)

# Show which node port is open:
kubectl describe service web-nodeport | grep NodePort

# Demonstrate that the NodePort is open on the minikube node IP:
NODE_IP=$(minikube ip)
curl http://$NODE_IP:30080


# =============================================================================
# PART 4 — Ingress: path and host-based routing
# =============================================================================

# Deploy v2 of the application (httpd instead of nginx — different response)
kubectl apply -f manifests/deployment-v2.yaml
kubectl apply -f manifests/service-v2.yaml

# Wait for v2 Pods to be ready:
kubectl rollout status deployment/web-v2-deployment

# Apply the Ingress rules:
kubectl apply -f manifests/ingress.yaml

# Inspect the Ingress:
#   HOSTS   → ironhack.local
#   ADDRESS → will populate once the IngressController picks it up (may take 30-60s)
#   PORTS   → 80
kubectl get ingress web-ingress
kubectl get ingress web-ingress -w    # Watch ADDRESS appear. Ctrl+C when it does.

# Full detail: shows rules, backend services, TLS config, and events:
kubectl describe ingress web-ingress


# --- 4.1 Test path-based routing ---------------------------------------------

INGRESS_IP=$(kubectl get ingress web-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress IP: $INGRESS_IP"

# /app → web-service (v1, nginx) → should return nginx welcome page
curl -v http://$INGRESS_IP/app

# /app-v2 → web-v2-service (v2, httpd) → should return Apache welcome page
curl -v http://$INGRESS_IP/app-v2

# Notice the different Server headers:
curl -s -o /dev/null -D - http://$INGRESS_IP/app    | grep Server   # nginx
curl -s -o /dev/null -D - http://$INGRESS_IP/app-v2 | grep Server   # Apache


# --- 4.2 Test host-based routing ---------------------------------------------

# Add a fake DNS entry so your browser/curl resolves ironhack.local:
echo "$INGRESS_IP ironhack.local" | sudo tee -a /etc/hosts

curl http://ironhack.local/app
curl http://ironhack.local/app-v2

# Without a matching Host header, Ingress returns 404:
curl http://$INGRESS_IP/app    # works (host matches)
curl http://$INGRESS_IP/other  # 404 — no rule for this path


# --- 4.3 Watch the IngressController logs in real time -----------------------

# In a second terminal run this to see every HTTP request the controller processes:
kubectl logs -n ingress-nginx \
  -l app.kubernetes.io/component=controller \
  -f


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete -f manifests/
kubectl delete namespace lab02
kubectl config set-context --current --namespace=default

# Remove /etc/hosts entry:
sudo sed -i '/ironhack.local/d' /etc/hosts
