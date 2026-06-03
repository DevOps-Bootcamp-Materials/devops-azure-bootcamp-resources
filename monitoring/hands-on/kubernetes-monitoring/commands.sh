#!/usr/bin/env bash
# commands.sh — reference script for hands-on 04
# Run commands manually following the README. Do not execute this file as a whole.
set -euo pipefail

# ── Prerequisites ──────────────────────────────────────────────────────────────

# Add the Prometheus Community Helm chart repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# ── Install kube-prometheus-stack ──────────────────────────────────────────────

# Create a dedicated namespace
kubectl create namespace monitoring

# Install the stack (may take 2-3 minutes)
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values.yaml \
  --wait

# Verify all pods are Running
kubectl get pods -n monitoring

# ── Access Grafana ─────────────────────────────────────────────────────────────

# Port-forward Grafana to your local machine
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80 &
# Open: http://localhost:3000  (admin / prom-operator)

# Port-forward Prometheus
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-prometheus 9090:9090 &
# Open: http://localhost:9090

# Port-forward Alertmanager
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093 &
# Open: http://localhost:9093

# ── Deploy the instrumented sample app ────────────────────────────────────────

kubectl apply -f manifests/

kubectl get all -n demo-app

# ── Clean up ──────────────────────────────────────────────────────────────────

# Remove the sample app
kubectl delete -f manifests/

# Uninstall kube-prometheus-stack
helm uninstall kube-prom -n monitoring
kubectl delete namespace monitoring
