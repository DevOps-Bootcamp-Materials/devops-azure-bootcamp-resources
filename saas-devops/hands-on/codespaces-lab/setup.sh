#!/usr/bin/env bash
# Install the Kubernetes toolbox inside the codespace, robustly.
#
# Why not the kubectl-helm-minikube devcontainer feature? Its Helm install
# verifies the download against a public GPG keyserver that is frequently
# unreachable; when it is, the whole container build fails and Codespaces
# drops you into a recovery container with no tools. Official binaries +
# sha256 checksums have no such external dependency.
set -euo pipefail

echo "== kubectl =="
KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSLo /tmp/kubectl     "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLo /tmp/kubectl.sha "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat /tmp/kubectl.sha)  /tmp/kubectl" | sha256sum --check
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

echo "== helm =="
# Install from the official tarball + sha256 and `install -m 0755`. We do NOT
# use the get-helm-3 convenience script: it installs helm mode 0754, which is
# not executable by the non-root `vscode` user (it falls in the "other" class),
# so `helm` then fails with "Permission denied".
HELM_VERSION="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | grep -oP '"tag_name": "\K[^"]+')"
curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLo /tmp/helm.sha "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256"
echo "$(cat /tmp/helm.sha)  /tmp/helm.tgz" | sha256sum --check
tar -xzf /tmp/helm.tgz -C /tmp
sudo install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
rm -rf /tmp/helm.tgz /tmp/helm.sha /tmp/linux-amd64

echo "== kind =="
curl -fsSLo /tmp/kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind

rm -f /tmp/kubectl /tmp/kubectl.sha /tmp/kind
echo "== toolbox ready =="
docker --version
kind version
kubectl version --client | head -1
helm version --short
