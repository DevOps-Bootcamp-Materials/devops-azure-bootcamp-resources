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

---

## Appendix — PV and PVC in depth

### The problem they solve

In Kubernetes, Pods are **disposable**. They die from crashes, OOM kills, node drains, rolling updates. When a Pod disappears, **its filesystem disappears with it**. That breaks anything with state: databases, shared file storage, on-disk caches, user uploads.

The naive solution would be to tell the Pod "mount this disk for me". That clashes with two realities:

1. **The developer does not (and should not) know where the physical disk lives.** Is it an AWS EBS volume? An Azure Disk? An NFS share? A Ceph volume? That decision belongs to whoever administers the cluster.
2. **The admin does not know what each app needs.** They cannot manually create disks every time a developer ships something new.

Kubernetes resolves this with **a separation of concerns** through two distinct objects.

### The two pieces

#### PersistentVolume (PV) — "the disk"

A **cluster-scoped** resource (it does not belong to any namespace). It represents **a real chunk of storage** that exists somewhere: an AWS disk, an NFS export, a path on a node, etc.

Created by **the admin** (or automatically by Kubernetes — see dynamic provisioning below). Its key fields:

- `capacity`: how much space it offers (e.g. `1Gi`)
- `accessModes`: how it can be mounted (RWO / ROX / RWX)
- `persistentVolumeReclaimPolicy`: what to do with the data when no one is using it (`Retain` / `Delete`)
- The **backend**: `hostPath`, `awsElasticBlockStore`, `nfs`, `csi`, etc.

PV lifecycle states:
```
Available  →  Bound  →  Released  →  (reclaimed according to policy)
```

#### PersistentVolumeClaim (PVC) — "the storage request"

A **namespaced** resource (it belongs to a namespace, like most things developers create). It is **a request** that says: "I need X GB with this access mode".

Created by **the developer**. It mentions no AWS, no paths, nothing physical. Only requirements:

- `accessModes`: how it wants to mount the volume
- `resources.requests.storage`: how much it asks for
- `storageClassName`: which storage class to use (or `""` for static)

### The binding: how they connect

When you create a PVC, Kubernetes looks for a PV that satisfies **all** of these criteria:

1. **`storageClassName` matches** (or both are empty, for static provisioning)
2. **The PV supports every accessMode** the PVC requests
3. **PV `capacity` ≥ PVC `requests.storage`**
4. (Optional) The PVC's label selector matches the PV's labels

If a match exists → Kubernetes **binds them**. The PV moves to `Bound` and becomes **exclusively** associated with that PVC. No other PVC can claim it (while the mode is RWO).

If no match exists → the PVC stays `Pending` indefinitely, until someone creates a compatible PV (or, with a StorageClass, until the provisioner creates one).

> **Important detail:** Kubernetes does not look for an exact match, it looks for **the best fit**. If you request 500Mi and only a 1Gi PV is available, the binding still happens. The PVC "occupies" the entire PV, not just the 500Mi — the extra capacity sits unused while the binding exists.

### How the Pod consumes it

The Pod **never** references the PV directly. It only knows the PVC:

```yaml
spec:
  containers:
    - name: app
      volumeMounts:
        - name: persistent-storage   # internal logical name of the Pod
          mountPath: /mnt/data       # where it appears inside the container
  volumes:
    - name: persistent-storage
      persistentVolumeClaim:
        claimName: my-pvc            # ← only this
```

The full resolution chain is:

```
container → volumeMount → volume → PVC → PV → real disk
```

The Pod only knows the first half. Kubernetes resolves the second half automatically when scheduling the Pod.

If the PVC is not yet `Bound`, **the Pod stays in `Pending`** until it is.

### The two provisioning modes

#### Static (what `pv.yaml` + `pvc.yaml` show in this lab)

1. Admin manually creates the PV (`kubectl apply -f pv.yaml`)
2. Developer creates the PVC (`kubectl apply -f pvc.yaml`)
3. Kubernetes binds them

Useful for understanding the model. Unworkable in production because the admin becomes a bottleneck.

#### Dynamic (what `pvc-dynamic.yaml` shows)

1. Admin creates **once** a `StorageClass` (preconfigured in most clusters: minikube has `standard`, AKS has `default`, etc.)
2. Developer creates a PVC referencing that StorageClass by name
3. Kubernetes **invokes the StorageClass provisioner**, which creates the real disk and registers the PV automatically
4. The PVC binds to the freshly created PV

The developer does not wait for anyone. The admin does not touch anything per new app. This is the standard model in cloud environments.

### Lifecycle and reclaim policy

When you delete the PVC (`kubectl delete pvc my-pvc`), the associated PV enters the `Released` state. Then the PV's **reclaim policy** kicks in:

- **`Retain`** — the PV stays in `Released` with the data intact. Nobody can claim it again until the admin deletes and recreates it. **The safe choice for important data**, because it forces a conscious decision before any data loss.

- **`Delete`** — the PV is deleted automatically, **and so is the underlying disk** (in cloud: the EBS/Disk/etc gets destroyed). This is the default for dynamic PVs. Convenient but dangerous: deleting a PVC deletes the data forever.

> That is why in production many teams change the reclaim policy of dynamic PVs to `Retain` after creation, as a safety net against accidental deletes.

### Access modes — what they mean in practice

| Mode | Abbreviation | Who can mount it |
|------|--------------|------------------|
| ReadWriteOnce | RWO | **A single node** read/write |
| ReadOnlyMany | ROX | Many nodes read-only |
| ReadWriteMany | RWX | Many nodes read/write |

The mode constrains which **nodes** the volume can be attached to, not how many Pods. With RWO you can have several Pods on the same node sharing the volume (if the binding allows it), but not Pods on different nodes.

The choice depends on the **storage backend**:
- Block disks (EBS, Azure Disk, GCE PD) → RWO only
- Network filesystems (NFS, EFS, Azure Files, CephFS) → support RWX

That is why a classic **database** like PostgreSQL uses RWO: a single process must write to its files to avoid corruption. A **file server** shared between several Pods of a web app would use RWX.

### The end-to-end flow

```
1. Admin (one time):
   - creates a StorageClass (or the cloud provider ships one by default)

2. Developer (per stateful app):
   - writes PVC.yaml requesting 10Gi RWO with storageClass="standard"
   - kubectl apply -f pvc.yaml
       └─ PVC enters Pending

3. Kubernetes (automatic):
   - sees the Pending PVC with a storageClassName
   - calls the "standard" provisioner
   - the provisioner creates a real disk (e.g. a 10Gi Azure Disk)
   - registers that disk as a PV in the cluster
   - binds PV ↔ PVC
       └─ PVC moves to Bound

4. Developer:
   - writes Pod.yaml referencing the PVC by claimName
   - kubectl apply -f pod.yaml

5. Kubernetes (automatic):
   - before scheduling the Pod, checks the PVC is Bound
   - schedules the Pod on a node compatible with the PV
   - attaches the disk to the node and mounts it inside the container

6. The container sees /mnt/data as if it were a local directory,
   but the data lives on the persistent disk, outside the Pod.
```

If the Pod dies and is recreated, step 5 repeats and the new Pod sees the same data. If it is rescheduled to another node (when the access mode allows it), Kubernetes detaches from the old node and attaches on the new one.

### The most common mental misconceptions

> "If I delete the Pod, do I lose the data?"

**No.** The data lives in the PV, not in the Pod. The Pod is just the "window" that mounts the volume.

> "If I delete the PVC, do I lose the data?"

**It depends on the PV's reclaim policy.** With `Delete`, yes. With `Retain`, no — the data stays on the disk even though the cluster no longer binds it to anything.

> "Can two Pods share the same PVC?"

**Yes**, if the access mode permits it and they are on the same node (RWO) or on different nodes (RWX). But this **does not** give you safe concurrency by itself: your applications still have to coordinate writes (lockfiles, database, etc.). The PV only gives you the disk, not the synchronization.

---

## Appendix — What does the PV actually create?

This is the part that usually confuses people. We need to separate **the Kubernetes object** from **the physical storage**.

### A PV is two distinct things

When you apply `pv.yaml`, **two things happen at different levels**:

#### 1. An object in the Kubernetes API

This always happens. It is metadata in etcd: "there is a PV named `local-pv`, it has 1Gi, RWO mode, points to a hostPath at `/mnt/data`". It is just **a record**, an inventory entry. You see it with `kubectl get pv`.

#### 2. The actual storage behind it

**This depends on the PV's `spec`.** And here is the key insight: a PV **does not always create a disk**. Sometimes it just **points** to storage that already exists (or that will be created on demand).

### In this lab specifically: hostPath

`pv.yaml` uses:

```yaml
hostPath:
  path: /mnt/data
  type: DirectoryOrCreate
```

Meaning: **"the real storage is the `/mnt/data` directory on whichever node the Pod runs on"**.

Concretely, when you apply this PV in minikube:

- **In the Kubernetes API:** the `PersistentVolume/local-pv` object is created. Instantly.
- **On the minikube node's disk:** **nothing is created yet.** `type: DirectoryOrCreate` means the `/mnt/data` directory is created **only when a Pod first mounts it**, not when the manifest is applied.

To see this with your own eyes, after running the lab you can SSH into the minikube node:

```bash
minikube ssh
ls -la /mnt/data
cat /mnt/data/test.txt
```

You will see the `test.txt` file you wrote from inside the Pod. **Physically it lives on the minikube node's filesystem**, not in the Pod and not in "Kubernetes". The Pod only mounts it.

### What if you do not use hostPath?

The interesting bit is how "what gets created" changes depending on the backend:

| PV backend | What it creates when you apply the PV | Where the data lives |
|------------|---------------------------------------|----------------------|
| `hostPath` (this lab) | **No physical new resource**; just the K8s object. The directory is created when the Pod mounts. | On the node's filesystem, at `/mnt/data` |
| `nfs` | **Nothing new**; the NFS server must already exist. The PV only points at `server:/export/path`. | On the external NFS server |
| `awsElasticBlockStore` (static) | **Nothing new**; the EBS volume must already exist in AWS, you just provide its `volumeID`. | In AWS, on that preexisting EBS volume |
| `csi` (static) | Same: the volume already exists, the PV references it. | On the underlying storage system |

**In static provisioning, the PV never creates the storage.** It only **registers** it with Kubernetes so a PVC can claim it.

### The dynamic case is different

Here storage really is created:

When `pvc-dynamic.yaml` sets `storageClassName: standard`, the flow is:

1. **You do not create a PV**, only the PVC.
2. The `standard` StorageClass has a **provisioner** (in minikube it is `k8s.io/minikube-hostpath`; in AKS it would be `disk.csi.azure.com`).
3. That provisioner **does perform real actions**:
   - On minikube: it creates a new directory under `/tmp/hostpath-provisioner/<namespace>/<pvc-name>/`
   - On Azure: it calls the Azure API and **creates an actual Azure Disk** (you would see it in the portal)
4. Once the storage is created, the provisioner **registers a PV automatically** in Kubernetes pointing at that resource.
5. That new PV gets bound to the PVC.

Here a disk really is born because of the PVC. In the static case of this lab, **no**.

### Mental summary

> A PV is **an inventory record**, not a storage creator.

- In **static** mode, someone (the admin) already has storage somewhere and writes the PV to "introduce" it to Kubernetes.
- In **dynamic** mode, the StorageClass is what actually **creates** the storage, and as a side effect a PV is registered automatically.

In this lab:
- `pv.yaml` only tells Kubernetes: "treat the node's `/mnt/data` directory as a 1Gi volume available for binding".
- When the Pod writes `/mnt/data/test.txt` (from its point of view, inside the container), the file ends up at **`/mnt/data/test.txt` on the minikube node**, outside the Pod, and survives the Pod's death because it lives on the node, not in the container.
