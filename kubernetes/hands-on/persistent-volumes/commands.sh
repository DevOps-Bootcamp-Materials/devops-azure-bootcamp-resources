#!/usr/bin/env bash
# =============================================================================
# Lab 04 — Persistent Volumes and Storage: command walkthrough
# =============================================================================
# Purpose: prove that Pod storage is ephemeral by default, then show how PVs,
#          PVCs, and StorageClasses solve data persistence across Pod restarts.
#
# How to use:
#   Run each block manually. Read the explanation before executing each command.
#
# Prerequisites:
#   minikube start
# =============================================================================

# --- 0. SETUP ----------------------------------------------------------------

kubectl create namespace lab04
kubectl config set-context --current --namespace=lab04


# =============================================================================
# PART 1 — Prove that default Pod storage is ephemeral
# =============================================================================

# Create a Pod and write a file to its local filesystem:
kubectl run ephemeral-test \
  --image=busybox:1.36 \
  --restart=Never \
  -- sh -c "mkdir -p /data && echo 'important data' > /data/test.txt && sleep 3600"

kubectl wait --for=condition=Ready pod/ephemeral-test --timeout=30s

# Verify the file exists inside the container:
kubectl exec ephemeral-test -- cat /data/test.txt
# Expected: "important data"

# Delete the Pod — this simulates a crash, OOM kill, or node drain:
kubectl delete pod ephemeral-test

# Recreate with the same name and try to read the file:
kubectl run ephemeral-test \
  --image=busybox:1.36 \
  --restart=Never \
  -- sh -c "cat /data/test.txt 2>/dev/null || echo 'FILE NOT FOUND — data was lost'; sleep 3600"

kubectl wait --for=condition=Ready pod/ephemeral-test --timeout=30s
kubectl exec ephemeral-test -- sh -c "cat /data/test.txt 2>/dev/null || echo 'FILE NOT FOUND'"
# Expected: FILE NOT FOUND — the ephemeral filesystem was gone with the Pod.

kubectl delete pod ephemeral-test


# =============================================================================
# PART 2 — PersistentVolume: define the storage resource
# =============================================================================

# Create the PV (admin action):
kubectl apply -f manifests/pv.yaml

# KEY FIELDS to observe in the output:
#   CAPACITY     → 1Gi (total size)
#   ACCESS MODES → RWO (ReadWriteOnce)
#   RECLAIM POLICY → Retain (data survives PVC deletion)
#   STATUS       → Available (no PVC has claimed it yet)
#   STORAGECLASS → "" (static provisioning, no dynamic provisioner)
kubectl get pv local-pv

# Full detail — shows the hostPath configuration, node affinity (if any), and events:
kubectl describe pv local-pv

# PVs are NOT namespaced — they are visible cluster-wide:
kubectl get pv    # lists ALL PVs in the cluster, regardless of namespace


# =============================================================================
# PART 3 — PersistentVolumeClaim: request storage
# =============================================================================

# Create the PVC (developer action):
kubectl apply -f manifests/pvc.yaml

# Watch the binding happen immediately:
kubectl get pvc my-pvc -w
# STATUS should change from Pending → Bound within seconds. Ctrl+C when Bound.

# Describe the PVC to see which PV it was bound to:
kubectl describe pvc my-pvc
# Look for: Volume: local-pv (or whatever PV name was chosen)

# Verify the PV status has changed from Available → Bound:
kubectl get pv local-pv
# STATUS → Bound    CLAIM → lab04/my-pvc

# The CLAIM column shows namespace/pvc-name — who is using this PV.
# A Bound PV cannot be claimed by another PVC (for RWO access mode).


# =============================================================================
# PART 4 — Mount the PVC into a Pod and test persistence
# =============================================================================

# Create the Pod that mounts the PVC:
kubectl apply -f manifests/pod-with-pvc.yaml
kubectl wait --for=condition=Ready pod/storage-demo --timeout=30s

# Describe the Pod and look at the Volumes and Mounts sections:
kubectl describe pod storage-demo
# You should see:
#   Volumes: persistent-storage (PersistentVolumeClaim, my-pvc)
#   Mounts:  /mnt/data from persistent-storage (rw)


# --- 4.1 Write data to the persistent volume ---------------------------------

kubectl exec -it storage-demo -- sh -c \
  "echo 'persistent data from the bootcamp' > /mnt/data/test.txt && cat /mnt/data/test.txt"


# --- 4.2 Simulate Pod deletion (crash / restart / rescheduling) --------------

kubectl delete pod storage-demo

# The PVC and PV still exist — the data is on the volume, not in the Pod:
kubectl get pvc my-pvc
kubectl get pv local-pv


# --- 4.3 Recreate the Pod and verify the data survived -----------------------

kubectl apply -f manifests/pod-with-pvc.yaml
kubectl wait --for=condition=Ready pod/storage-demo --timeout=30s

kubectl exec storage-demo -- cat /mnt/data/test.txt
# Expected: "persistent data from the bootcamp"
# The data survived the Pod deletion because it lives in the PV, not the container.


# =============================================================================
# PART 5 — Dynamic provisioning with StorageClass
# =============================================================================

# See what StorageClasses are available:
# '(default)' means it is used when a PVC omits storageClassName.
kubectl get storageclass

# Inspect the 'standard' StorageClass (minikube's default):
# Look for: Provisioner (hostpath.storage.k8s.io), ReclaimPolicy (Delete for dynamic PVs)
kubectl describe storageclass standard


# Create a PVC that uses dynamic provisioning (no pre-existing PV required):
kubectl apply -f manifests/pvc-dynamic.yaml

# Watch the dynamic PV appear automatically:
kubectl get pvc dynamic-pvc -w   # Pending → Bound. Ctrl+C when Bound.

# The provisioner created a new PV:
kubectl get pv
# You will see a new PV alongside local-pv, with a generated name like 'pvc-<uuid>'

# Inspect it:
PV_NAME=$(kubectl get pvc dynamic-pvc -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV_NAME"


# =============================================================================
# PART 6 — Access modes and what they mean in practice
# =============================================================================

# Show all PVs with their access modes in a custom columnar format:
kubectl get pv -o custom-columns=\
'NAME:.metadata.name,CAPACITY:.spec.capacity.storage,ACCESS:.spec.accessModes,POLICY:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase'

# Demonstrate what happens when you try to mount a RWO PVC on two Pods:
# (Note: with hostPath on minikube this might succeed because it's single-node.
# In a real multi-node cluster, the second Pod would stay Pending.)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: second-pod
  namespace: lab04
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: storage
          mountPath: /mnt/data
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: my-pvc
EOF

kubectl describe pod second-pod | grep -A5 Events
# On a real multi-node cluster you would see:
# "Multi-Attach error: volume is already used by pod storage-demo on node X"

kubectl delete pod second-pod


# =============================================================================
# PART 7 — Reclaim policy: what happens when you delete the PVC
# =============================================================================

# Delete the dynamic PVC:
kubectl delete pvc dynamic-pvc

# Check the state of the dynamically-created PV:
kubectl get pv "$PV_NAME" 2>/dev/null || echo "PV was deleted (reclaimPolicy: Delete)"
# The PV disappears because the StorageClass default reclaimPolicy is Delete.

# The manually created PV (local-pv) still exists even after PVC deletion
# because its reclaimPolicy is Retain:
# kubectl delete pvc my-pvc       # (uncomment to test)
# kubectl get pv local-pv         # STATUS → Released, not deleted


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete -f manifests/
kubectl delete namespace lab04
kubectl config set-context --current --namespace=default

# PVs are cluster-scoped — delete explicitly:
kubectl delete pv local-pv 2>/dev/null || true
