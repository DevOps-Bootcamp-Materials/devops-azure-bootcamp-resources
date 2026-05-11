# Hands-on 04: Persistent Volumes and Storage

## Objective

Demonstrate that storage inside a Pod is ephemeral by default: when the Pod dies, the data is lost. Kubernetes addresses this with a three-layer abstraction: **PersistentVolume (PV)** (the actual disk), **PersistentVolumeClaim (PVC)** (a request for disk), and **StorageClass** (a dynamic disk provisioner).

By the end of this lab you will understand:
- Why stateful workloads (databases, file storage) need PVs
- The separation of concerns between admin (provisions PVs) and developer (creates PVCs)
- How dynamic provisioning works with StorageClass
- Access modes: ReadWriteOnce, ReadOnlyMany, ReadWriteMany

---

## Prerequisites

```bash
minikube start

kubectl create namespace lab04
kubectl config set-context --current --namespace=lab04
```

---

## Part 1 — The problem: ephemeral data

```bash
# Create a Pod that writes data to its local filesystem
kubectl run ephemeral-test \
  --image=busybox:1.36 \
  --restart=Never \
  -- sh -c "echo 'important data' > /data/test.txt && sleep 3600"

# Verify the file exists
kubectl exec ephemeral-test -- cat /data/test.txt

# Kill the Pod
kubectl delete pod ephemeral-test

# Recreate with the same name
kubectl run ephemeral-test \
  --image=busybox:1.36 \
  --restart=Never \
  -- sh -c "cat /data/test.txt 2>/dev/null || echo 'FILE NOT FOUND'; sleep 3600"

kubectl exec ephemeral-test -- cat /data/test.txt
# → FILE NOT FOUND: the data was lost with the previous Pod
kubectl delete pod ephemeral-test
```

---

## Part 2 — PersistentVolume: the actual disk

A **PV** represents a real piece of storage in the cluster. It is created by the cluster administrator (or dynamically via a StorageClass). It is a cluster-scoped resource, not namespaced.

### 2.1 Create the PV manually (static provisioning)

```bash
kubectl apply -f manifests/pv.yaml
kubectl get pv
kubectl describe pv local-pv
```

Pay attention to:
- `CAPACITY`: volume size
- `ACCESS MODES`: RWO = ReadWriteOnce (only one node can mount it in write mode)
- `RECLAIM POLICY`: what happens to the PV when the PVC is released (Retain, Delete, Recycle)
- `STATUS`: Available → waiting for a PVC to claim it

---

## Part 3 — PersistentVolumeClaim: the request

A **PVC** is a storage request made by a developer. Kubernetes finds a PV that satisfies the requirements (capacity, access mode, StorageClass) and binds them together.

```bash
kubectl apply -f manifests/pvc.yaml
kubectl get pvc
kubectl describe pvc my-pvc
```

Check the PV status now:

```bash
kubectl get pv
# STATUS changes from 'Available' to 'Bound' → the PVC has claimed it
```

---

## Part 4 — Mounting the PVC into a Pod

```bash
kubectl apply -f manifests/pod-with-pvc.yaml
kubectl get pod storage-demo
kubectl describe pod storage-demo
```

### 4.1 Write data to the persistent volume

```bash
kubectl exec -it storage-demo -- sh

# Inside the Pod:
echo "persistent data from the bootcamp" > /mnt/data/test.txt
cat /mnt/data/test.txt
exit
```

### 4.2 Verify that data survives a Pod restart

```bash
# Delete the Pod
kubectl delete pod storage-demo

# Recreate the Pod using the same PVC
kubectl apply -f manifests/pod-with-pvc.yaml

# Data is still there
kubectl exec -it storage-demo -- cat /mnt/data/test.txt
# → persistent data from the bootcamp ✓
```

**Conclusion:** the volume persists independently of the Pod lifecycle.

---

## Part 5 — StorageClass: dynamic provisioning

In cloud environments (AWS, GCP, Azure) or with minikube, you do not need to create PVs manually. A **StorageClass** defines the provisioner and disk parameters, and Kubernetes creates the PV automatically when a PVC is created.

```bash
# Check available StorageClasses (minikube includes 'standard')
kubectl get storageclass
kubectl describe storageclass standard

# Create a PVC that uses dynamic provisioning (no PV needed beforehand)
kubectl apply -f manifests/pvc-dynamic.yaml

# Kubernetes creates the PV automatically
kubectl get pvc dynamic-pvc
kubectl get pv   # You will see a new dynamically-created PV
```

---

## Part 6 — Access modes

| Mode | Abbreviation | Meaning |
|------|-------------|---------|
| ReadWriteOnce | RWO | A single node can mount in read/write |
| ReadOnlyMany | ROX | Multiple nodes can mount in read-only |
| ReadWriteMany | RWX | Multiple nodes can mount in read/write |

> **Important:** not all storage types support all modes. A local disk only supports RWO. NFS, CephFS, or EFS support RWX.

```bash
# Check access modes of your PVs
kubectl get pv -o custom-columns='NAME:.metadata.name,CAPACITY:.spec.capacity.storage,ACCESS:.spec.accessModes'
```

---

## Part 7 — Cleanup

```bash
kubectl delete -f manifests/
kubectl delete namespace lab04
kubectl config set-context --current --namespace=default

# PVs are cluster-scoped resources, delete them explicitly
kubectl delete pv local-pv 2>/dev/null || true
```

---

## Discussion questions

1. Why does a database like PostgreSQL running on Kubernetes need a PVC with RWO mode instead of RWX?
2. What happens to the data in a PV if its `reclaimPolicy` is `Delete` and the PVC is deleted?
3. In what scenario would you use a StatefulSet instead of a Deployment to manage Pods with PVCs?

---

## Key concepts

| Object | Created by | Represents |
|--------|-----------|-----------|
| PersistentVolume (PV) | Admin / StorageClass | Actual disk (NFS, EBS, hostPath…) |
| PersistentVolumeClaim (PVC) | Developer | Storage request with requirements |
| StorageClass | Admin | Template for dynamic provisioning |

**Binding flow:**
```
PVC created → Kubernetes finds compatible PV → Bound → Pod mounts the PVC
```
