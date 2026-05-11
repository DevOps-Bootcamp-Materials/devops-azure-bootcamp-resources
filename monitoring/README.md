# Monitoring — IronHack DevOps Bootcamp Module

> **Language policy:** All documentation in this module is written in English.
> This applies to READMEs, YAML comments, and any supporting material.

This module covers the monitoring and observability skills required to operate applications and infrastructure in production. It progresses from the Prometheus data model and PromQL to a full observability stack running on Kubernetes.

## Structure

```
monitoring/
├── README.md                              ← This file
└── hands-on/
    ├── prometheus-basics/              ← Prometheus data model, Expression Browser, first PromQL
    ├── full-stack/                     ← Prometheus + Grafana + Node Exporter via Docker Compose
    ├── container-monitoring/           ← cAdvisor: container-level metrics
    ├── promql-alerting/                ← PromQL in depth + Alertmanager
    └── kubernetes-monitoring/          ← kube-prometheus-stack on a real cluster
```

## Prerequisites

- Docker and Docker Compose installed
- `kubectl` and Helm installed (for hands-on 04)
- A running Kubernetes cluster for hands-on 04 — use the AKS cluster from `kubernetes/hands-on/aks` or a local minikube/kind cluster

### Verify your environment

```bash
docker --version
docker compose version
```

## Recommended order

Follow the hands-on in numerical order. Each one introduces concepts the next one builds on.

| Hands-on | Key concept | Estimated time |
|----------|-------------|----------------|
| 00 | Prometheus data model, pull model, Expression Browser, basic PromQL | 30 min |
| 01 | Full monitoring stack with Docker Compose, Grafana dashboards | 45 min |
| 02 | Container metrics with cAdvisor, `container_` namespace | 30 min |
| 03 | PromQL depth: rate, aggregation, histograms; alerting rules, Alertmanager | 50 min |
| 04 | kube-prometheus-stack, cluster dashboards, custom app instrumentation | 60 min |
