#!/usr/bin/env bash
# =============================================================================
# Lab 07 — Capstone: WordPress + MySQL on AKS — command walkthrough
# =============================================================================
# Purpose: deploy a realistic two-tier application on AKS that exercises every
#          storage concept from labs 04 and 05 (volumes, PV/PVC, dynamic
#          provisioning, RWO vs RWX, StatefulSet, VolumeSnapshot) plus Ingress.
#
# Cost warning:
#   This lab spins up REAL Azure resources. Budget ~0.30–0.80 EUR/hour at the
#   defaults below. ALWAYS run the cleanup section at the end.
# =============================================================================

# --- 0. CONFIGURATION --------------------------------------------------------
# Adjust these if you used a different resource group / cluster name.
RG=rg-aks-lab05
CLUSTER=aks-lab05
REGION=westeurope
MC_RG="MC_${RG}_${CLUSTER}_${REGION}"   # AKS-managed RG holding the infra resources


# --- 1. CLUSTER PREREQUISITES ------------------------------------------------

# 1.1 Confirm you're targeting the right cluster:
kubectl config use-context "$CLUSTER"
kubectl get nodes

# 1.2 Enable the AKS app routing addon (NGINX Ingress). Idempotent.
az aks approuting enable --resource-group "$RG" --name "$CLUSTER"

# 1.3 Verify CSI drivers and snapshot CRDs are present:
kubectl get storageclass | grep -E 'managed-csi|azurefile-csi'
kubectl get crd | grep snapshot.storage.k8s.io


# --- 2. NAMESPACE + SECRETS --------------------------------------------------

kubectl apply -f manifests/00-namespace.yaml
kubectl config set-context --current --namespace=wordpress

kubectl apply -f manifests/01-secrets.yaml

# Quick sanity check that the Secret decodes correctly:
kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d
echo


# --- 3. MYSQL (StatefulSet + Azure Disk) -------------------------------------

kubectl apply -f manifests/02-mysql-statefulset.yaml

# Watch until mysql-0 is Running and its PVC is Bound:
kubectl get statefulset,pod,pvc -l app=mysql -w
# Ctrl+C once mysql-0 is Running.

kubectl wait --for=condition=Ready pod/mysql-0 --timeout=180s

# Inspect what was dynamically created in Azure:
PV_NAME=$(kubectl get pvc mysql-data-mysql-0 -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

az disk list --resource-group "$MC_RG" --query "[?starts_with(name,'pvc-')].{name:name, size:diskSizeGb}" --output table

# Sanity check: MySQL is alive and the 'wordpress' database was created
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" -e "SHOW DATABASES;"


# --- 4. WORDPRESS (Deployment + Azure Files RWX) -----------------------------

# 4.1 Provision the shared Azure Files volume first
kubectl apply -f manifests/03-wordpress-pvc.yaml

# Azure Files provisioning takes longer than Azure Disk (~30–60s):
kubectl get pvc wordpress-content -w
# Ctrl+C when STATUS=Bound.

# 4.2 Deploy WordPress (replicas=1 initially)
kubectl apply -f manifests/04-wordpress-deployment.yaml
kubectl rollout status deployment/wordpress --timeout=180s

# Smoke test the Service before adding Ingress:
kubectl port-forward svc/wordpress 8080:80 &
PF_PID=$!
sleep 3
curl -sI http://localhost:8080 | head -3   # Should redirect 302 to /wp-admin/install.php
kill $PF_PID 2>/dev/null


# --- 5. INGRESS (expose to the internet) -------------------------------------

kubectl apply -f manifests/05-wordpress-ingress.yaml

# The AKS app routing addon assigns an external IP. Takes ~60s.
kubectl get ingress wordpress -w
# Ctrl+C once ADDRESS shows a real IP.

INGRESS_IP=$(kubectl get ingress wordpress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Open this in your browser: http://$INGRESS_IP"

# At this point: complete the WordPress installer in the browser. Create one
# Post with an image attachment, then come back here.


# --- 6. SCALE WORDPRESS AND VERIFY RWX ---------------------------------------

kubectl scale deployment wordpress --replicas=3
kubectl rollout status deployment/wordpress

# All 3 replicas mount the SAME Azure Files share — verify they see the same
# uploaded media:
for POD in $(kubectl get pod -l app=wordpress -o name); do
  echo "=== $POD ==="
  kubectl exec "$POD" -- ls /var/www/html/wp-content/uploads/ 2>/dev/null || echo "(no uploads dir yet)"
done
# All three Pods should list the same files. That is RWX working as expected.


# --- 7. DISASTER RECOVERY: kill the MySQL Pod --------------------------------

kubectl get pod mysql-0 -o wide
kubectl delete pod mysql-0

# StatefulSet recreates the SAME Pod with the SAME PVC:
kubectl wait --for=condition=Ready pod/mysql-0 --timeout=180s

PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" wordpress -e "SELECT COUNT(*) AS posts FROM wp_posts;"
# Should be > 0 (the post you created earlier is still there).


# --- 8. VOLUMESNAPSHOT: point-in-time recovery -------------------------------

# 8.1 Snapshot the current MySQL disk
kubectl apply -f manifests/snapshot-recovery/06-volumesnapshot.yaml

kubectl get volumesnapshot mysql-snapshot -w
# Wait until READYTOUSE=true. Ctrl+C.

# 8.2 Simulate a destructive operation
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" wordpress -e "DROP TABLE wp_posts;"

# Refresh the WordPress homepage in the browser — it is now broken.

# 8.3 Restore from the snapshot
kubectl apply -f manifests/snapshot-recovery/07-volumesnapshot-restore.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/mysql-data-restored --timeout=180s

# Stop the current StatefulSet (keep the data PVCs intact with --cascade=orphan
# so we can replace the binding cleanly):
kubectl delete statefulset mysql --cascade=orphan
kubectl wait --for=delete pod/mysql-0 --timeout=60s

# Delete the original (corrupted) PVC — it is no longer referenced by anything:
kubectl delete pvc mysql-data-mysql-0

# Re-apply the StatefulSet pointing at the restored PVC:
kubectl apply -f manifests/snapshot-recovery/02b-mysql-statefulset-from-snapshot.yaml
kubectl wait --for=condition=Ready pod/mysql-0 --timeout=180s

# 8.4 Verify the data is back
PASS=$(kubectl get secret mysql-credentials -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec mysql-0 -- mysql -uroot -p"$PASS" wordpress -e "SELECT COUNT(*) AS posts FROM wp_posts;"
# The pre-DROP row count is back. Refresh the WordPress homepage — the post returns.


# --- 9. CLEANUP --------------------------------------------------------------

# ⚠️ DO NOT SKIP. Forgotten PVCs continue to bill Azure Disks / Files.

# 9.1 Delete Kubernetes resources
kubectl delete volumesnapshot --all -n wordpress
kubectl delete -f manifests/snapshot-recovery/ --ignore-not-found
kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace wordpress

# 9.2 Verify Azure resources were reclaimed by the CSI drivers
az disk list --resource-group "$MC_RG" --query "[?starts_with(name,'pvc-')]" --output table
# Expected: empty. If any disks remain, delete them manually:
# az disk delete --resource-group "$MC_RG" --name <name> --yes

# Azure Files shares created by azurefile-csi live inside a storage account
# named something like 'fXXXXXXXX'. Verify nothing dangling:
az storage account list --resource-group "$MC_RG" --query "[].name" --output table

kubectl config set-context --current --namespace=default
echo "Cleanup complete."
