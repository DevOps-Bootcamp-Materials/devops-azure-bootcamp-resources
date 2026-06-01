# DevOps Azure Bootcamp — External Resources

> **Language policy:** All documentation in this repository is written in English.
> This applies to READMEs, YAML comments, and any supporting material.

This repository hosts the **technical artifacts** (manifests, scripts, Terraform code, Docker Compose files…) used by the hands-on sessions of the DevOps Azure Bootcamp.

It is the companion to the bootcamp classes: the lessons and explanations are delivered in class and through the bootcamp portal, while this repository contains everything you need to run the exercises on your own machine.

## Structure

```
.
├── README.md                ← This file
├── ai/
│   ├── README.md
│   ├── learning-resources.md
│   └── hands-on/            ← AI-assisted DevOps practice
├── kubernetes/
│   ├── README.md
│   ├── learning-resources.md
│   └── hands-on/            ← kubectl, Pods/Deployments, Services, Storage, AKS, scheduling…
└── monitoring/
    ├── README.md
    ├── learning-resources.md
    └── hands-on/            ← Prometheus, Grafana, cAdvisor, Alertmanager, kube-prometheus-stack
```

Each module has its own `README.md` with prerequisites, environment setup and a description of every hands-on inside.

## Companion repository — reference architecture

The instructor builds a separate, end-to-end **reference architecture** project that the bootcamp uses for in-class demos: a production-shaped Azure platform stack (Terraform + AKS + OIDC CI/CD + GitOps + observability + DevSecOps). It lives in its own repository so it stays self-contained, deployable, and forkable:

➡️ **https://github.com/iscoct/globalretail-platform**

Students are not expected to build it from scratch. The instructor demos individual layers in class when the corresponding topic comes up in the schedule, and the layer READMEs serve as self-study material afterwards.

## How to use this repository

1. Clone it once:

   ```bash
   git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
   cd devops-azure-bootcamp-resources
   ```

2. Navigate to the module and hands-on referenced from the bootcamp portal, for example:

   ```bash
   cd kubernetes/hands-on/pods-deployments
   ```

3. Follow the steps in the `README.md` of that hands-on.

## Common prerequisites

Each module lists its own specific tooling, but you will need at least:

- **Git** and a working terminal (Bash, Zsh, or PowerShell)
- **Docker** and **Docker Compose**
- **kubectl** and a local cluster ([minikube](https://minikube.sigs.k8s.io/) or [kind](https://kind.sigs.k8s.io/)) for the Kubernetes and Monitoring modules
- **Azure CLI** and an active Azure subscription for the AKS-based hands-on

See the module-level README for the full list.

## Contributing

This repository is maintained alongside `devops-azure-bootcamp`. If you spot a bug or want to add a new hands-on:

1. Open an issue describing the problem or the new exercise.
2. Submit a pull request from a feature branch.
3. Keep all documentation in English and follow the structure above.
