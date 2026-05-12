# Hands-on 02 — Alternative setup on Windows with kind + ngrok

This guide replicates the [02-services-networking](README.md) lab on a **Windows machine without minikube**, using:

- **kind** (Kubernetes in Docker) as the local cluster.
- **ngrok** to expose the NodePort and the Ingress to the internet via a public HTTPS URL.

All lab material (`manifests/*.yaml`) works **unchanged**. The only differences are the commands used to access the cluster (the `minikube ...` ones) and how services are exposed externally.

---

## Setup architecture

```
Internet
  │
  ▼  (public HTTPS URL, e.g. https://abc123.ngrok-free.app)
ngrok
  │  outbound tunnel
  ▼
Your PC (localhost:80 or localhost:30080)
  │  kind port-mapping
  ▼
kind node Docker container
  │
  ▼
Ingress Controller (nginx)  ──►  Service (ClusterIP) ──► Pods
                  or
NodePort (30080)            ──►  Service (NodePort)  ──► Pods
```

Key points:

- ngrok opens an **outbound tunnel** from your PC. **You do not open any ports on your router**, so your home network stays protected.
- Only traffic going through that tunnel is reachable from the internet, and it stops the moment you kill `ngrok`.

---

## Prerequisites

Install these tools (PowerShell):

```powershell
# Docker Desktop (must be running)
winget install Docker.DockerDesktop

# kind
winget install Kubernetes.kind

# kubectl (if you don't have it)
winget install Kubernetes.kubectl

# ngrok (requires a free account at https://ngrok.com to get a token)
winget install Ngrok.Ngrok
```

Authenticate ngrok once with your account token:

```powershell
ngrok config add-authtoken <YOUR_TOKEN>
```

---

## Note: `curl` in PowerShell

In PowerShell, `curl` is an **alias** for `Invoke-WebRequest`, which uses a different syntax (no `-H`, no `-o`, etc.). All `curl ...` commands in this guide will fail if executed as-is. You have two options:

**Option 1 (recommended) — Use `curl.exe`**: Windows 10/11 ships with real curl at `C:\Windows\System32\curl.exe`. Just call it explicitly:

```powershell
curl.exe http://localhost:30080
curl.exe http://localhost/app -H "Host: ironhack.local"
```

**Option 2 — Use PowerShell-native `Invoke-WebRequest`**: equivalent of each common case:

```powershell
# Plain GET
Invoke-WebRequest http://localhost:30080

# GET with custom Host header
Invoke-WebRequest http://localhost/app -Headers @{ Host = "ironhack.local" }

# Show only the response body (like `curl -s`)
(Invoke-WebRequest http://localhost/app -Headers @{ Host = "ironhack.local" }).Content

# Show response headers (like `curl -D -`)
(Invoke-WebRequest http://localhost/app -Headers @{ Host = "ironhack.local" }).Headers
```

The rest of this guide uses `curl.exe`. If you prefer `Invoke-WebRequest`, translate using the patterns above.

---

## Step 1 — Create the kind cluster with the right ports

The trick to make NodePort and Ingress reachable from `localhost` is declaring **`extraPortMappings`** in the kind config. This maps ports from the kind node container to your Windows host.

Create `kind-config.yaml` at the root of the lab:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # For the Ingress Controller (Part 4)
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      # For the NodePort in Part 3 (web-nodeport uses 30080)
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
```

> The `ingress-ready=true` label is what the official ingress-nginx manifest for kind looks for: with it, the controller is scheduled on this node and binds ports 80/443.

Create the cluster:

```powershell
kind create cluster --name lab02 --config kind-config.yaml
kubectl cluster-info --context kind-lab02
```

---

## Step 2 — Install the Ingress Controller (nginx) for kind

This replaces `minikube addons enable ingress` from the original lab:

```powershell
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for the controller to become Ready (same wait as the original lab)
kubectl wait --namespace ingress-nginx `
  --for=condition=Ready pod `
  --selector=app.kubernetes.io/component=controller `
  --timeout=120s
```

Verify the controller is running and listening on 80/443:

```powershell
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

---

## Step 3 — Run the lab (identical to the original README)

```powershell
kubectl create namespace lab02
kubectl config set-context --current --namespace=lab02
```

From here on you follow **Parts 1, 2, 3 and 4** of the original [README.md](README.md). **Manifests do not change.**

> ⚠️ **Do not skip Parts 1 and 2.** Each part builds on the previous one. The NodePort Service (`web-nodeport`) selects Pods with labels `app=web, version=v1`, which only exist after applying `deployment-base.yaml` from Part 1. Likewise, the Ingress rule `/app` points to `web-service` (ClusterIP) from Part 2. If you jump straight to Part 3 or 4 you will see Services with empty `Endpoints` and `curl` requests will hang or return 503.

The only adaptations are the commands that used `minikube ...`. Here is the mapping:

| Original lab (minikube)                           | kind equivalent                                       |
| ------------------------------------------------- | ----------------------------------------------------- |
| `minikube ip`                                     | `127.0.0.1` (or `localhost`)                          |
| `minikube service web-nodeport --url -n lab02`    | `http://localhost:30080`                              |
| `curl http://$(minikube ip):30080`                | `curl.exe http://localhost:30080`                     |
| `curl http://$(minikube ip)/app`                  | `curl.exe http://localhost/app -H "Host: ironhack.local"` |
| `echo "$INGRESS_IP ironhack.local" >> /etc/hosts` | Edit `C:\Windows\System32\drivers\etc\hosts` (see §3.4) |

### 3.1 — Part 1 and Part 2

No changes. Apply the manifests and run the internal DNS tests from the `debug` Pod as the README explains.

### 3.2 — Part 3 (NodePort) on kind

```powershell
kubectl apply -f manifests/service-nodeport.yaml
kubectl get service web-nodeport

# Direct access (instead of `minikube service ... --url`)
curl.exe http://localhost:30080
```

### 3.3 — Part 4 (Ingress) on kind

```powershell
kubectl apply -f manifests/deployment-v2.yaml
kubectl apply -f manifests/service-v2.yaml
kubectl rollout status deployment/web-v2-deployment

kubectl apply -f manifests/ingress.yaml
kubectl get ingress web-ingress
kubectl describe ingress web-ingress
```

The `ADDRESS` field will show as `localhost` (in kind, ingress-nginx publishes the address as the node, which is your host).

### 3.4 — Testing path-based and host-based routing locally

Because the Ingress rule requires `host: ironhack.local`, you get a 404 without that header. Two options:

**Option A — Force the header with curl** (quick, doesn't touch the system):

```powershell
curl.exe http://localhost/app    -H "Host: ironhack.local"
curl.exe http://localhost/app-v2 -H "Host: ironhack.local"

# Compare Server headers (-s silent, -o NUL discard body, -D - dump headers to stdout)
curl.exe -s -o NUL -D - http://localhost/app    -H "Host: ironhack.local" | Select-String Server
curl.exe -s -o NUL -D - http://localhost/app-v2 -H "Host: ironhack.local" | Select-String Server
```

Equivalent with `Invoke-WebRequest`:

```powershell
(Invoke-WebRequest http://localhost/app    -Headers @{ Host = "ironhack.local" }).Headers.Server
(Invoke-WebRequest http://localhost/app-v2 -Headers @{ Host = "ironhack.local" }).Headers.Server
```

**Option B — Edit the Windows hosts file** (so it also works from a browser):

1. Open Notepad **as administrator**.
2. Open `C:\Windows\System32\drivers\etc\hosts`.
3. Append:
   ```
   127.0.0.1 ironhack.local
   ```
4. Save.

Now you can run:

```powershell
curl.exe http://ironhack.local/app
curl.exe http://ironhack.local/app-v2
```

And open `http://ironhack.local/app` in your browser.

---

## Step 4 — Expose to the internet with ngrok

This is the added value over minikube: with ngrok you can demo the lab to remote students from a public URL.

The two parts worth exposing are the **NodePort** and the **Ingress**. ngrok can only tunnel one port per process, so open a separate terminal for each.

### 4.1 — Expose the NodePort (Part 3)

In a separate terminal:

```powershell
ngrok http 30080
```

ngrok prints something like:

```
Forwarding   https://abc123.ngrok-free.app -> http://localhost:30080
```

Share that URL. From any machine (the `bash` block is what your students would run; locally use `curl.exe`):

```bash
# From a remote machine (Linux/macOS) or WSL
curl https://abc123.ngrok-free.app
```

```powershell
# From your Windows PowerShell to test the public URL yourself
curl.exe https://abc123.ngrok-free.app
```

And the request flows: ngrok → your PC:30080 → kind → NodePort Service → nginx Pod.

> **ngrok dashboard**: open `http://localhost:4040` in your browser. You will see every HTTP request live (method, headers, response). Great for teaching.

### 4.2 — Expose the Ingress (Part 4)

The Ingress requires `Host: ironhack.local`. By default ngrok rewrites the `Host` header to its own domain (`abc123.ngrok-free.app`), so the Ingress would return 404. You have to tell ngrok to use a different Host:

```powershell
ngrok http 80 --host-header=ironhack.local
```

Now when someone hits the public URL, ngrok forwards to `localhost:80` rewriting the `Host` header to `ironhack.local`, and the Ingress matches the rule.

Tests (replace `abc123` with the subdomain ngrok gives you):

```bash
# From a remote machine (Linux/macOS) or WSL
curl https://abc123.ngrok-free.app/app       # /app    → nginx (v1)
curl https://abc123.ngrok-free.app/app-v2    # /app-v2 → httpd (v2)
curl https://abc123.ngrok-free.app/other     # no rule → 404 from the Ingress
```

```powershell
# From your Windows PowerShell
curl.exe https://abc123.ngrok-free.app/app
curl.exe https://abc123.ngrok-free.app/app-v2
curl.exe https://abc123.ngrok-free.app/other
```

In parallel, in another terminal, tail the Ingress Controller logs so you can show that every request visible on the ngrok dashboard also shows up here:

```powershell
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller -f
```

### 4.3 — ngrok browser warning interstitial

When someone first opens the ngrok public URL in a **browser**, ngrok injects an HTML warning page. It does not appear for `curl`.

If you want to skip the warning from a browser or an HTTP client:

```bash
# bash
curl -H "ngrok-skip-browser-warning: 1" https://abc123.ngrok-free.app/app
```

```powershell
# PowerShell
curl.exe -H "ngrok-skip-browser-warning: 1" https://abc123.ngrok-free.app/app
```

> If the interstitial is annoying for browser demos, a cleaner alternative is **Cloudflare Tunnel** (`cloudflared`), which does not insert an interstitial. The mechanics are very similar.

---

## Command cheatsheet

| Action                              | Command                                                                 |
| ----------------------------------- | ----------------------------------------------------------------------- |
| Create cluster                      | `kind create cluster --name lab02 --config kind-config.yaml`           |
| Install ingress-nginx               | `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml` |
| Local NodePort                      | `curl.exe http://localhost:30080`                                      |
| Local Ingress (without hosts edit)  | `curl.exe http://localhost/app -H "Host: ironhack.local"`              |
| Local Ingress (with hosts edited)   | `curl.exe http://ironhack.local/app`                                   |
| Expose NodePort via ngrok           | `ngrok http 30080`                                                     |
| Expose Ingress via ngrok            | `ngrok http 80 --host-header=ironhack.local`                           |
| Inspect ngrok traffic               | Open `http://localhost:4040`                                           |

---

## Cleanup

```powershell
# Stop ngrok with Ctrl+C in each terminal

# Delete the whole cluster (faster than `kubectl delete -f manifests/`)
kind delete cluster --name lab02

# Clean up the hosts file if you modified it (Notepad as admin → remove the ironhack.local line)
```

---

## Is it safe?

**Yes**, with two caveats:

1. **Without ngrok running**, everything you do in kind is only reachable from `localhost`. Docker Desktop binds to `127.0.0.1` by default, and Windows Firewall + your router NAT block any inbound traffic. Even your phone on the same Wi-Fi cannot reach it.

2. **With ngrok running**, the tunnel is public for as long as it is open. Anyone with the URL can access it. Recommendations:
   - Close ngrok when the class ends (Ctrl+C).
   - Do not expose secrets or sensitive data in the Pods.
   - If you need to restrict access, configure **basic auth** on ngrok: `ngrok http 80 --basic-auth="user:password"`.

---

## Troubleshooting

**`curl.exe http://localhost:30080` hangs or returns nothing.**
Check the Service Endpoints:

```powershell
kubectl get endpoints web-nodeport -n lab02
```

If you see `ENDPOINTS: <none>`, the Service has no Pods behind it. The selector is `app=web, version=v1`, which is satisfied only by the Pods from `deployment-base.yaml`. Make sure Part 1 was applied.

**`curl.exe http://localhost/app` returns 404 from `openresty` or `nginx`.**
The Ingress rule requires `Host: ironhack.local`. Either add the header (`-H "Host: ironhack.local"`) or edit your hosts file (§3.4).

**`curl.exe http://localhost/app -H "Host: ironhack.local"` returns 503.**
The Ingress backend Service has no healthy endpoints. Run `kubectl get endpoints web-service -n lab02` and check that the v1 Pods are Ready.

**Port 80 conflict when creating the kind cluster.**
Something else on your machine is binding port 80 (IIS, Skype, another container). Stop it or change the `hostPort` in `kind-config.yaml` (e.g. `hostPort: 8080`) and adjust every `http://localhost/...` accordingly.

---

## Extra discussion for class

About the original README question *"why does a LoadBalancer Service in a minikube cluster stay in `<pending>` state?"*: the same happens in kind. But kind/k3d can be combined with **MetalLB** to emulate real LoadBalancers locally. It's a good follow-up lab if you want to go deeper.
