# Kubernetes — IronHack DevOps Bootcamp Module

> **Language policy:** All documentation in this module is written in English.
> This applies to READMEs, YAML comments, and any supporting material.

This module covers the core Kubernetes concepts required to operate and deploy applications in production environments. It follows a logical progression: understand the theory and available resources first, then validate that knowledge through hands-on labs.

## Structure

```
kubernetes/
├── README.md                        ← This file
├── learning-resources.md            ← Where and how to learn Kubernetes
└── hands-on/
    ├── kubectl-basics/           ← Lab: kubectl CLI, no YAML required
    ├── pods-deployments/         ← Lab: minimum execution unit and replica management
    ├── services-networking/      ← Lab: exposing applications and internal networking
    ├── configmaps-secrets/       ← Lab: configuration and sensitive data management
    ├── volumes/                  ← Lab: ephemeral volume primitives (emptyDir, hostPath, configMap/secret as volume)
    ├── persistent-volumes/       ← Lab: persistent storage in clusters (PV, PVC, StorageClass)
    ├── aks/                      ← Lab: managed cluster on Azure, app reachable from the browser
    ├── wordpress-mysql-aks/      ← Capstone: full WordPress + MySQL stack on AKS combining everything
    ├── labels-and-resources/    ← Lab: labels/selectors, requests/limits, QoS, LimitRange, ResourceQuota
    └── scheduling/               ← Lab: nodeSelector, nodeAffinity, podAffinity, taints/tolerations, topologySpreadConstraints
```

## Prerequisites

- Docker installed with a basic understanding of containers
- `kubectl` installed ([official guide](https://kubernetes.io/docs/tasks/tools/))
- A local cluster available: [minikube](https://minikube.sigs.k8s.io/docs/start/) or [kind](https://kind.sigs.k8s.io/)
- For the `aks` and `wordpress-mysql-aks` labs: Azure CLI installed and an active Azure subscription

### Starting the local environment

```bash
# With minikube
minikube start

# Verify the cluster is responding
kubectl cluster-info
kubectl get nodes
```

## Recommended order

Follow the labs in numerical order. Each one introduces concepts that the next one builds upon.

| Lab | Key concept | Estimated time |
|-----|-------------|----------------|
| 00 | kubectl CLI: run, expose, scale, logs, exec, dry-run | 30 min |
| 01 | Pods, ReplicaSets, Deployments | 45 min |
| 02 | Services (ClusterIP, NodePort), Ingress | 45 min |
| 03 | ConfigMaps, Secrets, config injection | 30 min |
| 04 | Volumes: emptyDir, hostPath, configMap/secret as volumes, sidecar pattern | 45 min |
| 05 | PersistentVolumes, PVCs, StorageClass, dynamic provisioning | 40 min |
| 06 | AKS: managed cluster, LoadBalancer Service, browser access | 60 min |
| 07 | Capstone: WordPress + MySQL on AKS — Azure Disk (RWO) + Azure Files (RWX), Ingress, VolumeSnapshot | 90 min |
| 08 | Labels & selectors, resource requests/limits, QoS classes, LimitRange, ResourceQuota | 60 min |
| 09 | Scheduling: nodeSelector, nodeAffinity, podAffinity, taints/tolerations, topology spread (on AKS multi-pool) | 75 min |
