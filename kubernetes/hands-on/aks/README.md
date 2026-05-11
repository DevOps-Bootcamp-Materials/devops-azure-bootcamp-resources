# Hands-on 05: Azure Kubernetes Service (AKS)

## Objective

Deploy a managed Kubernetes cluster on Azure, deploy a web application inside it, and expose it to the internet so you can access it from your browser — without touching any VM or load balancer configuration manually.

By the end of this lab you will understand:
- What AKS is and how it differs from a self-managed cluster
- How Azure provisions a Load Balancer automatically when you create a `Service` of type `LoadBalancer`
- How to connect to a remote cluster with `kubectl` using Azure credentials
- The full flow: cluster → namespace → ConfigMap → Deployment → Service → browser

---

## What is AKS?

**Azure Kubernetes Service (AKS)** is a managed Kubernetes offering. Azure handles:

| What Azure manages | What you manage |
|--------------------|-----------------|
| Control plane (API server, etcd, scheduler) | Worker nodes (though AKS can also auto-manage these) |
| Cluster upgrades | Your workloads (Deployments, Services…) |
| Load balancer provisioning | Resource sizing and costs |
| Azure AD / RBAC integration | Namespaces and access policies |

When you create a `Service` of type `LoadBalancer` in AKS, Azure automatically provisions an **Azure Load Balancer** and assigns it a **public IP**. That IP is then reachable from anywhere on the internet — including your browser.

---

## Architecture of this lab

```
Internet
   │
   ▼
Azure Load Balancer (Public IP)   ← created automatically by Kubernetes
   │
   ▼  port 80
Service: web-lb (LoadBalancer)    ← Kubernetes Service object
   │
   ├──▶ Pod 1 (nginx)  ┐
   ├──▶ Pod 2 (nginx)  ├── Deployment: ironhack-web (3 replicas)
   └──▶ Pod 3 (nginx)  ┘
            │
            └── mounts ConfigMap with custom HTML page
```

---

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- `kubectl` installed
- An active Azure subscription

---

## Part 1 — Create the AKS cluster

```bash
# 1.1 Create a dedicated resource group
az group create \
  --name rg-aks-lab05 \
  --location westeurope

# 1.2 Create the AKS cluster (2 nodes, cost-optimised VM size)
az aks create \
  --resource-group rg-aks-lab05 \
  --name aks-lab05 \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --enable-managed-identity \
  --generate-ssh-keys

# 1.3 Download the cluster credentials into your kubeconfig
az aks get-credentials \
  --resource-group rg-aks-lab05 \
  --name aks-lab05

# 1.4 Verify you are talking to the right cluster
kubectl config current-context   # should print "aks-lab05"
kubectl get nodes                # should show 2 nodes in Ready state
```

> **Note:** `az aks create` takes 3–5 minutes. Use that time to review the manifests.

---

## Part 2 — Inspect the cluster

```bash
# What control-plane components does AKS expose?
kubectl cluster-info

# The nodes Azure provisioned for you
kubectl get nodes -o wide

# System Pods that AKS pre-installs (CoreDNS, kube-proxy, metrics-server…)
kubectl get pods -n kube-system

# Azure-specific DaemonSet — runs on every node to integrate with Azure networking
kubectl get pods -n kube-system -l component=azure-cni-networkmonitor
```

Notice the nodes have a `kubernetes.azure.com/role=agent` label — AKS uses this to distinguish worker nodes from the hidden control-plane nodes.

---

## Part 3 — Deploy the web application

### 3.1 Create the namespace

```bash
kubectl apply -f manifests/namespace.yaml
kubectl config set-context --current --namespace=lab05
```

### 3.2 Apply all manifests

```bash
kubectl apply -f manifests/
```

This creates:
- A **ConfigMap** with a custom HTML page
- A **Deployment** with 3 nginx replicas that serve that page
- A **LoadBalancer Service** that exposes port 80

### 3.3 Watch resources come up

```bash
# Monitor all resources in the namespace
kubectl get all -n lab05 -w

# The Service will start with EXTERNAL-IP = <pending>
# Azure is provisioning the Load Balancer behind the scenes (takes ~1 minute)
kubectl get service web-lb -n lab05 -w
```

Once `EXTERNAL-IP` changes from `<pending>` to a real IP address, the load balancer is ready.

---

## Part 4 — Access from the browser

```bash
# Get the public IP
EXTERNAL_IP=$(kubectl get service web-lb -n lab05 \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Open this in your browser: http://$EXTERNAL_IP"

# Or test with curl
curl http://$EXTERNAL_IP
```

Open `http://<EXTERNAL_IP>` in your browser. You should see the IronHack DevOps bootcamp welcome page served by nginx running inside your AKS cluster.

---

## Part 5 — Scale and observe load balancing

```bash
# Scale the deployment up to 5 replicas
kubectl scale deployment ironhack-web --replicas=5

# Watch new Pods distribute across both nodes
kubectl get pods -o wide -n lab05

# Hit the endpoint multiple times — the Service load-balances across all Pods
for i in $(seq 1 10); do curl -s http://$EXTERNAL_IP | grep "Hostname"; done
```

---

## Part 6 — Verify what Azure created

```bash
# AKS automatically creates a second resource group for infrastructure resources
# Its name is MC_<resource-group>_<cluster-name>_<region>
az resource list \
  --resource-group MC_rg-aks-lab05_aks-lab05_westeurope \
  --output table

# Find the public IP resource that was provisioned for our Service
az network public-ip list \
  --resource-group MC_rg-aks-lab05_aks-lab05_westeurope \
  --output table

# Find the load balancer rules
az network lb rule list \
  --resource-group MC_rg-aks-lab05_aks-lab05_westeurope \
  --lb-name kubernetes \
  --output table
```

This illustrates the **Azure-Kubernetes integration**: the Kubernetes controller manager talks to the Azure API and creates real Azure infrastructure on your behalf.

---

## Part 7 — Cleanup

> **Important:** AKS clusters incur costs even when idle. Always delete the resource group when you are done.

```bash
# Remove Kubernetes resources
kubectl delete -f manifests/
kubectl config set-context --current --namespace=default

# Delete the entire Azure resource group (cluster + all infrastructure)
az group delete --name rg-aks-lab05 --yes --no-wait

echo "Resource group deletion started in the background."
```

---

## Discussion questions

1. When you delete the `LoadBalancer` Service, what happens to the Azure Load Balancer that was provisioned?
2. Why does AKS create a **second** resource group (`MC_*`) instead of putting everything in the one you specified?
3. What would happen if you used `type: NodePort` instead of `type: LoadBalancer` — could you still reach the app from the internet?
4. How does the nginx Pod know what HTML to serve? Trace the path from ConfigMap to the browser response.

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Managed control plane | API server, etcd, and scheduler are run and maintained by Azure — you never see them |
| Node pool | Group of VMs that form the worker nodes; you can add multiple pools (Linux, Windows, GPU…) |
| `LoadBalancer` Service in AKS | Automatically provisions an Azure Load Balancer + public IP via the cloud controller manager |
| `MC_*` resource group | Automatically created by AKS to hold the infrastructure resources it manages (NICs, IPs, LBs, disks) |
| Managed Identity | AKS uses a system-assigned managed identity to call Azure APIs without storing credentials |
