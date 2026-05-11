# Hands-on 07: Capstone — WordPress + MySQL on AKS

## Objective

Bring together every concept from labs 01–06 to deploy a **realistic two-tier stateful application** on Azure Kubernetes Service:

- **Stateful tier:** MySQL as a `StatefulSet` with a dynamically provisioned **Azure Disk (RWO)** for its data directory
- **Stateless tier:** WordPress as a `Deployment` scaled to multiple replicas, all sharing an **Azure Files (RWX)** volume for user uploads
- **Exposure:** a public **Ingress** routes browser traffic to the WordPress Service
- **Operations:** a `VolumeSnapshot` of the MySQL disk lets us roll back a "bad deploy"

By the end of this lab you will understand:
- Why the same application requires **two different access modes** (RWO for the DB, RWX for shared media)
- The difference between Azure Disk and Azure Files in practice, when to choose each
- How `StatefulSet` + `volumeClaimTemplates` ties a Pod identity to its PVC
- How VolumeSnapshots provide a point-in-time recovery primitive at the storage layer
- How to wire an Ingress in front of a real application

> **Cost warning.** Running this lab uses real Azure resources (AKS nodes, Azure Disk, Azure Files, public IP). Estimated cost: ~0.30–0.80 EUR/hour with the recommended VM sizes. **Always run the cleanup section** when you are done. Forgotten PVCs continue to bill Azure Disks/Files even after the cluster is deleted.

---

## Architecture

```
                  Internet
                     │
                     ▼
            ┌────────────────────┐
            │ Ingress (NGINX)    │   public IP, port 80
            │ host: wordpress... │
            └─────────┬──────────┘
                      │
            ┌─────────▼──────────┐
            │ Service: wordpress │   ClusterIP
            └─────────┬──────────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
   ┌────▼───┐   ┌────▼───┐    ┌────▼───┐
   │ WP-1   │   │ WP-2   │    │ WP-3   │   Deployment, 3 replicas
   └────┬───┘   └────┬───┘    └────┬───┘
        │            │             │
        └────────────┼─────────────┘
                     │
        ┌────────────▼────────────────┐
        │ Azure Files PVC (RWX)       │   /var/www/html/wp-content
        │ azurefile-csi, 5 Gi         │   shared media + plugins + themes
        └─────────────────────────────┘

        ┌──────────────────────┐
        │ Service: mysql       │  headless (clusterIP: None)
        └──────────┬───────────┘
                   │   DNS: mysql-0.mysql.wordpress.svc.cluster.local
        ┌──────────▼────────────┐
        │ StatefulSet: mysql    │  replicas=1
        │ Pod: mysql-0          │
        └──────────┬────────────┘
                   │
        ┌──────────▼────────────────┐
        │ Azure Disk PVC (RWO)      │   /var/lib/mysql
        │ managed-csi, 10 Gi        │   tied to mysql-0 by volumeClaimTemplate
        └───────────────────────────┘
```

**Why MySQL is a StatefulSet of 1 and WordPress is a Deployment of 3:**

- MySQL needs **stable identity** (the Pod is always `mysql-0`, its PVC is always `mysql-data-mysql-0`) and **stable storage** (Azure Disk is RWO — only one node attaches it at a time). Running multiple writers against the same Azure Disk would corrupt the data files. Running multiple MySQL Pods against *separate* disks would give you three independent databases, not high-availability MySQL (that requires Group Replication / Operator — out of scope).
- WordPress is **stateless** at the application layer: any replica can serve any request, because the truth lives in MySQL. The only piece of WordPress that persists locally is `wp-content/` (uploaded images, installed plugins, custom themes). That **must be shared across all replicas** → Azure Files with `ReadWriteMany`.

---

## Prerequisites

You need an AKS cluster. Two options:

**Option A — Reuse the cluster from lab 06.** Recommended. It already has the disk and file CSI drivers installed. Just verify it is running:

```bash
kubectl config use-context aks-lab05
kubectl get nodes
```

**Option B — Create a new cluster** (~5 minutes):

```bash
az group create --name rg-aks-lab07 --location westeurope

az aks create \
  --resource-group rg-aks-lab07 \
  --name aks-lab07 \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --enable-managed-identity \
  --generate-ssh-keys

az aks get-credentials --resource-group rg-aks-lab07 --name aks-lab07
```

### Enable the AKS-managed NGINX Ingress (app routing addon)

AKS ships an officially supported NGINX Ingress Controller as an addon. Enable it once per cluster:

```bash
# Replace RG and CLUSTER if you used Option B
RG=rg-aks-lab05
CLUSTER=aks-lab05

az aks approuting enable --resource-group "$RG" --name "$CLUSTER"

# Verify the IngressClass appeared:
kubectl get ingressclass
# Expected: webapprouting.kubernetes.azure.com   k8s.io/ingress-nginx   ...
```

### Verify the CSI drivers and VolumeSnapshot CRDs

```bash
kubectl get storageclass
# Expected at minimum:
#   managed-csi                (provisioner: disk.csi.azure.com)   ← Azure Disk, RWO
#   managed-csi-premium        (Premium SSD)
#   azurefile-csi              (provisioner: file.csi.azure.com)   ← Azure Files, RWX
#   azurefile-csi-premium

kubectl get crd | grep snapshot
# Expected: volumesnapshotclasses.snapshot.storage.k8s.io,
#           volumesnapshotcontents.snapshot.storage.k8s.io,
#           volumesnapshots.snapshot.storage.k8s.io
```

If the snapshot CRDs are missing, AKS may need them installed manually — see Part 9 troubleshooting.

---

## Part 1 — Storage design exercise

Before applying any manifest, fill in this table. Then read on and check your answers.

| Resource | Access mode | StorageClass | Size | Why |
|----------|-------------|--------------|------|-----|
| MySQL data dir (`/var/lib/mysql`) | ? | ? | ? | ? |
| WordPress media (`/var/www/html/wp-content`) | ? | ? | ? | ? |

**Answers:**

| Resource | Access mode | StorageClass | Size | Why |
|----------|-------------|--------------|------|-----|
| MySQL `/var/lib/mysql` | `ReadWriteOnce` | `managed-csi` (Azure Disk) | 10 Gi | Single writer (only `mysql-0`). Azure Disk gives lower latency than Files and is what every managed MySQL service uses under the hood. |
| WordPress `wp-content/` | `ReadWriteMany` | `azurefile-csi` | 5 Gi | All 3 WP replicas must see the same uploaded media. Files is the only Azure option for RWX. Lower performance than Disk is acceptable here — these are mostly cold reads. |

---

## Part 2 — Namespace and credentials

```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl config set-context --current --namespace=wordpress

# Secret with MySQL credentials. We use stringData so the YAML is readable;
# Kubernetes base64-encodes it before storing in etcd.
kubectl apply -f manifests/01-secrets.yaml

kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d
# Confirm the password decoded matches the stringData value in the manifest.
```

> **In production, don't store passwords in plain YAML in git.** Use Sealed Secrets, External Secrets Operator, or — on AKS — the **Azure Key Vault provider for Secrets Store CSI Driver** to inject secrets from Key Vault directly into the Pod.

---

## Part 3 — MySQL on Azure Disk (RWO)

```bash
kubectl apply -f manifests/02-mysql-statefulset.yaml

# Watch the StatefulSet bring up mysql-0:
kubectl get statefulset,pod,pvc,pv -l app=mysql -w
# Ctrl+C when mysql-0 is Running and the PVC is Bound.
```

Inspect what was created:

```bash
# The StatefulSet auto-created a PVC named mysql-data-mysql-0 from the
# volumeClaimTemplate. This name pattern is <template-name>-<sts-name>-<ordinal>.
kubectl get pvc

# That PVC triggered the managed-csi provisioner, which created a real Azure Disk:
kubectl get pv

# Verify it's an Azure Disk and find its Azure resource ID:
PV_NAME=$(kubectl get pvc mysql-data-mysql-0 -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
# Expected: /subscriptions/.../resourceGroups/MC_.../providers/Microsoft.Compute/disks/pvc-<uuid>

# You can see the disk in the Azure CLI too:
az disk list --resource-group "MC_${RG}_${CLUSTER}_westeurope" --output table
```

Test MySQL is alive:

```bash
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)

kubectl exec mysql-0 -- mysql -uroot -p"$PASS" -e "SHOW DATABASES;"
# Expected: information_schema, mysql, performance_schema, sys, wordpress
```

### Why the headless Service?

`StatefulSet`s require a headless Service (`clusterIP: None`) to give each Pod a stable DNS name. WordPress will reach the database as `mysql-0.mysql.wordpress.svc.cluster.local`, not via a regular load-balanced ClusterIP. Even with one replica, this is the standard pattern.

---

## Part 4 — WordPress on Azure Files (RWX)

```bash
# 4.1 Create the shared Azure Files PVC for wp-content
kubectl apply -f manifests/03-wordpress-pvc.yaml

kubectl get pvc wordpress-content -w
# STATUS goes Pending → Bound once the Azure Files share is provisioned.
# Provisioning Azure Files takes longer than Azure Disk (~30–60s).

# 4.2 Deploy WordPress (1 replica to start)
kubectl apply -f manifests/04-wordpress-deployment.yaml

kubectl get pod -l app=wordpress -w
# Wait for Running. WordPress's first start unpacks ~50 MB into wp-content;
# you'll see the readiness probe fail for ~30 seconds, that's normal.
```

Quick smoke test before adding the Ingress:

```bash
kubectl port-forward svc/wordpress 8080:80 &
curl -sI http://localhost:8080 | head -3
# Expected: HTTP/1.1 302 Found  → WordPress redirects to /wp-admin/install.php
kill %1
```

---

## Part 5 — Expose to the internet with an Ingress

```bash
kubectl apply -f manifests/05-wordpress-ingress.yaml

# Wait for the Ingress to receive an external IP from the AKS app routing addon:
kubectl get ingress wordpress -w
# ADDRESS: <pending> → <public-ip>

INGRESS_IP=$(kubectl get ingress wordpress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Open this in your browser: http://$INGRESS_IP"
```

WordPress's installer should appear. Run through the installation:
- Site title: `Bootcamp Capstone`
- Admin username: `admin`
- Admin password: anything you'll remember (this is a throwaway lab)
- Email: anything

After installation, log in to `/wp-admin/`. **Create one Post with an image attachment** — the upload goes to `wp-content/uploads/YYYY/MM/`, which is on the Azure Files share. Keep this tab open.

---

## Part 6 — Scale WordPress and prove RWX works

```bash
kubectl scale deployment wordpress --replicas=3
kubectl get pod -l app=wordpress -w
# Wait until all 3 are Ready.
```

Now exercise the load balancing:

```bash
# Every request hits a different Pod (the Service round-robins).
# Each replica checks the SAME Azure Files share for media:
for i in $(seq 1 6); do
  curl -s "http://$INGRESS_IP/wp-json/wp/v2/posts" \
    | python -c "import sys,json; d=json.loads(sys.stdin.read()); print(d[0].get('link','no post yet'))"
done
```

**The visual proof:** refresh the post you created several times in the browser. The image keeps loading regardless of which replica handles the request. If you put the same uploads dir on a `ReadWriteOnce` PVC instead, two of the three replicas would not be able to mount the volume — try it as Part 6 bonus (it is described in `commands.sh` as an optional experiment).

---

## Part 7 — Disaster recovery: kill the database Pod

```bash
# Note the IP of the current mysql-0 Pod
kubectl get pod mysql-0 -o wide

# Delete it — simulates a crash, node drain, or rescheduling
kubectl delete pod mysql-0

# The StatefulSet recreates it with the SAME name and re-attaches the SAME PVC:
kubectl get pod mysql-0 -w
# Wait for Running again (~30s on AKS while the Azure Disk reattaches)

# Verify the database content survived:
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" wordpress -e "SELECT COUNT(*) AS posts FROM wp_posts;"
```

The post you created is still there. Pod identity (`mysql-0`) is **the** thing that ties it to its PVC.

---

## Part 8 — VolumeSnapshot: point-in-time recovery

You will simulate a bad operation against the database, then roll back the disk to a snapshot taken just before.

### 8.1 Take a snapshot of the MySQL disk

```bash
# This manifest references a VolumeSnapshotClass for Azure Disk. Check it exists:
kubectl get volumesnapshotclass

# If none exists yet, the manifest below creates one named csi-azuredisk-vsc.
# Apply the snapshot resource:
kubectl apply -f manifests/snapshot-recovery/06-volumesnapshot.yaml

# Wait for the snapshot to become ReadyToUse:
kubectl get volumesnapshot mysql-snapshot -w
# READYTOUSE: false → true. Typically 15–60 seconds.

# Inspect:
kubectl describe volumesnapshot mysql-snapshot
# The 'Bound Volume Snapshot Content' field links to the underlying snapshot
# resource. Behind the scenes, the disk CSI driver called Azure's snapshot API.
```

### 8.2 Cause "damage": drop the wp_posts table

```bash
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)

# Simulate a bad migration that wipes a critical table:
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" wordpress -e "DROP TABLE wp_posts;"

# Confirm WordPress is now broken — refresh the browser, you should see
# "Error establishing a database connection" or PHP errors on the homepage.
```

### 8.3 Restore the snapshot into a new PVC

We cannot restore a snapshot into the existing PVC directly. The standard workflow is:
1. Create a **new** PVC from the snapshot
2. Stop MySQL
3. Swap the StatefulSet's PVC reference (or re-create with the restored PVC name)

For pedagogical simplicity, we delete the entire StatefulSet (keeping the data PVCs and PV intact), rename the restored PVC to match what the StatefulSet expects, and let the controller pick it up again.

```bash
# Create a new PVC populated from the snapshot:
kubectl apply -f manifests/snapshot-recovery/07-volumesnapshot-restore.yaml
kubectl get pvc mysql-data-restored -w
# Wait for Bound.

# Scale MySQL down to release the original PVC's volume attachment:
kubectl scale statefulset mysql --replicas=0
kubectl wait --for=delete pod/mysql-0 --timeout=60s

# Replace the existing PVC binding by deleting it and recreating with the
# same name, pointing at the restored snapshot. We use a JSON Patch to retain
# the volumeName reference. (Simpler alternative: delete the StatefulSet with
# --cascade=orphan, rename the PVC, recreate the STS.)
#
# For the lab we take the simpler path:
kubectl delete statefulset mysql --cascade=orphan   # keep mysql-0 PVC reference intact
kubectl delete pvc mysql-data-mysql-0               # release the original PVC
kubectl patch pvc mysql-data-restored \
  --type=merge \
  -p '{"metadata":{"name":"mysql-data-mysql-0"}}' 2>/dev/null || true
# (kubectl cannot rename PVCs in place — in real life you re-create the
#  StatefulSet pointing at the new PVC name. For this lab the simpler proof
#  is just: re-apply the StatefulSet AFTER the original PVC is gone, and
#  configure the volumeClaimTemplate to dataSource: mysql-snapshot. The
#  re-applied manifest 02-mysql-statefulset-from-snapshot.yaml does this.)

kubectl apply -f manifests/snapshot-recovery/02b-mysql-statefulset-from-snapshot.yaml

kubectl get pod mysql-0 -w
# Wait for Running. The new PVC is hydrated from the snapshot.

# Verify the wp_posts table is BACK:
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" wordpress -e "SELECT COUNT(*) AS posts FROM wp_posts;"
# Expected: the count you had before the DROP.

# Refresh the WordPress homepage — the post is back.
```

> **Real-world note.** Production restore procedures usually clone the snapshot into a *separate* PVC, point a *new* Pod at it, validate the data, and only then cut traffic over. Doing it in-place against a live StatefulSet is fast for labs but risky in production.

---

## Part 9 — Cleanup

> **⚠️ READ THIS BEFORE SKIPPING.**
> Deleting the namespace removes the Kubernetes objects but the **Azure Disk and Azure Files share keep existing and keep billing** until you delete the underlying resources. The PVCs use `reclaimPolicy: Delete` by default for dynamic provisioning, so deleting the PVCs *should* delete the Azure resources — verify it actually happened.

```bash
# 9.1 Delete Kubernetes resources in the wordpress namespace
kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace wordpress

# 9.2 Verify the Azure Disk and Azure Files share were actually deleted
RG="MC_rg-aks-lab05_aks-lab05_westeurope"   # Adjust to your cluster's MC_* RG

az disk list --resource-group "$RG" --output table | grep -i wordpress || echo "No wordpress disks left"
az storage account list --resource-group "$RG" --output table
# If any 'pvc-...' disk or storage account remains and you don't recognize it,
# delete it manually:
# az disk delete  --resource-group "$RG" --name <name> --yes
# az storage account delete --resource-group "$RG" --name <name> --yes
```

If you created a dedicated cluster (Option B), delete the resource group:

```bash
az group delete --name rg-aks-lab07 --yes --no-wait
```

---

## Discussion questions

1. You scale WordPress to 10 replicas. The Pods come up but the page is slow to serve images. What is the bottleneck and which Azure storage tier would you switch to?
2. Why does the MySQL `volumeClaimTemplate` survive `kubectl delete statefulset mysql` but not `kubectl delete pvc`? What is the design rationale?
3. Your VolumeSnapshot is `ReadyToUse: true`, but the restored PVC stays `Pending`. Where do you look first, and what is the most likely cause?
4. The Azure Files PVC for `wp-content` is RWX. What stops two WordPress replicas from corrupting `wp-config.php` if they both write to it at the same time?
5. How would you change this architecture to back up MySQL **off-cluster** (i.e. to Azure Blob Storage) every night? Sketch the pieces.

---

## Key concepts

| Concept | Why it matters here |
|---------|---------------------|
| `StatefulSet` + `volumeClaimTemplates` | Each replica gets its own PVC, named `<template>-<sts>-<ordinal>`, and the binding is permanent — survives Pod deletion, node failure, and StatefulSet recreation |
| Headless Service (`clusterIP: None`) | Required by StatefulSet to give each Pod a stable DNS name (`mysql-0.mysql.<ns>.svc.cluster.local`) |
| Azure Disk (`managed-csi`) | Block storage attached to one node at a time. Low latency. RWO. The right default for any single-writer database |
| Azure Files (`azurefile-csi`) | SMB file share, mountable by many Pods on many nodes. RWX. The right default for shared media, legacy apps that need a real filesystem, multi-replica web frontends |
| `VolumeSnapshot` | A Kubernetes-native point-in-time copy of a PVC's underlying volume. Used for backups, dev-environment hydration, "oh no" rollbacks |
| AKS app routing addon | The supported way to get an NGINX Ingress Controller on AKS without managing Helm releases yourself |

**Storage decision flow:**

```
Single writer + low latency required?           → Azure Disk (RWO)        managed-csi
Multiple writers OR many readers, shared FS?    → Azure Files (RWX)       azurefile-csi
Object storage (large blobs, archives)?         → Azure Blob via blobfuse  blob-fuse-csi
Logs from many DaemonSets to a node directory?  → hostPath (DaemonSet only)
Cache or scratch within a Pod?                  → emptyDir (medium: Memory for sensitive)
```
