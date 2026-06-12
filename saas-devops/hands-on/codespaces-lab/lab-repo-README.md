# codespaces-k8s-lab

A ready-to-open GitHub Codespaces lab for running Docker and Kubernetes entirely in the browser: the devcontainer ships docker-in-docker, kubectl, helm, and kind, so a laptop that cannot run Docker locally still gets a full DevOps playground on a 2-core cloud machine — within the Codespaces free tier for personal accounts. Open it with **Code → Codespaces → Create codespace on main** (or `gh codespace create -R iscoct/codespaces-k8s-lab`), wait for the container build to finish, and run the commands below in the integrated terminal.

```bash
# 1. Verify the toolbox
docker --version && kind version && kubectl version --client

# 2. Create a Kubernetes cluster inside the codespace
kind create cluster --config kind-config.yaml
kubectl get nodes

# 3. Deploy nginx
kubectl apply -f manifests/deploy.yaml
kubectl rollout status deploy/web

# 4. Expose it - Codespaces auto-detects the listening port
kubectl port-forward --address 0.0.0.0 deploy/web 8080:80

# 5. In a second terminal: confirm nginx answers locally
curl -s localhost:8080 | head -5
```

Then open the **Ports** panel (or run `gh codespace ports`), make port 8080 **Public**, and the forwarded URL `https://<codespace-name>-8080.app.github.dev` serves your in-cluster nginx to anyone on the internet.

When you are done: stop or delete the codespace (**Codespaces** menu, or `gh codespace delete`) so it stops consuming free-tier core-hours.
