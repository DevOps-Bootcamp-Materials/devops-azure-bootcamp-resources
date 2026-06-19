# Tunnels — ngrok CLI, Cloudflare quick tunnels, and the ngrok Kubernetes Operator

This is the deep-dive companion to the bootcamp hands-on `week-18/saas-devops/hands-on/02_tunnels_ngrok_cloudflare.md`. The bootcamp file walks the three flows; this README explains how tunnels actually work, the credential model, every verified quirk (interstitial behavior, the `.ngrok-free.dev` vs `.ngrok-free.app` split, the agent API), the operator's architecture, the alternatives landscape, and the security conversation every team eventually has about tunnels.

## What this folder contains

- `README.md` — this file
- `commands.sh` — the complete command sequence for all three parts
- `manifests/app.yaml` — namespace + whoami Deployment + Service for the operator demo
- `manifests/ingress-ngrok.yaml` — the standard Ingress with `ingressClassName: ngrok` (edit the host to your static dev domain)

## Prerequisites

- Docker Desktop, `ngrok` and `cloudflared` CLIs, `k3d` + `kubectl` + `helm` for Part C
- A free ngrok account; authtoken AND API key stored via `ngrok config add-authtoken` / `ngrok config add-api-key`
- The free-tier DevOps toolbox lesson

---

## Part 1 — How a tunnel actually works

The mechanism behind every tunnel product is the same inversion:

```
WITHOUT a tunnel:  internet → (router/NAT/firewall blocks) → your laptop          [fails]
WITH a tunnel:     your laptop → outbound TLS connection → provider edge           [allowed]
                   internet → provider edge → (rides the existing connection back) [works]
```

Outbound connections are almost never blocked — that is the same reason HTTPS works from any café Wi-Fi. The agent (ngrok, cloudflared) opens a persistent outbound connection to the provider's edge; the provider assigns a public hostname that terminates at *their* servers; traffic to that hostname is multiplexed back down the connection you initiated. Nothing about your network changed: no port forwarding, no public IP, no firewall rules.

Two consequences worth internalizing:

1. **The provider sees your traffic.** TLS terminates at their edge (that is how they route by hostname). For learning and demos this is fine; for anything sensitive it is a data-flow decision someone should sign off on.
2. **The tunnel is only as alive as the agent process.** Kill the process, the URL dies (quick tunnels) or goes offline (reserved domains). This is why the operator (Part 4) runs the agent *in* the cluster as a Deployment.

## Part 2 — ngrok credentials, domains, and verified quirks

### The two-credential model

| Credential | Stored by | Used for |
|---|---|---|
| **Authtoken** | `ngrok config add-authtoken` → `ngrok.yml` | The data plane: lets an agent open tunnels on your account |
| **API key** | `ngrok config add-api-key` → same `ngrok.yml` | The control plane: `ngrok api ...` commands and anything that provisions endpoints programmatically (the Kubernetes operator needs it) |

Both live in `%LOCALAPPDATA%\ngrok\ngrok.yml` (Windows) / `~/Library/Application Support/ngrok/` (macOS) / `~/.config/ngrok/` (Linux). The split matters in Part C: the operator's **agent** pod uses the authtoken, the **manager** pod uses the API key.

### Domains (verified 2026-06)

- **Random per-run URLs** use `https://<random>.ngrok-free.app`.
- **The free static dev domain** uses **`.ngrok-free.dev`** — e.g. `unreceptive-maplelike-linwood.ngrok-free.dev`. Every account gets exactly one, auto-assigned; list it with `ngrok api reserved-domains list`. Older tutorials that show static domains under `.ngrok-free.app` predate the split.
- Custom branded domains (your own DNS) are a paid feature.

### The interstitial, precisely (verified)

The free-tier warning page (`ERR_NGROK_6024`, "You are about to visit ... served for free through ngrok.com") is keyed on the **User-Agent**:

| Client | Result |
|---|---|
| Real browser / browser-like UA | Interstitial first; "Visit Site" sets a cookie that suppresses it for a while |
| Plain `curl`, webhook senders, SDKs | Content directly — no interstitial at all |
| Any client sending `ngrok-skip-browser-warning: <anything>` | Content directly |

Practical upshot: **webhooks are never affected** (Stripe/GitHub don't send browser UAs), demos to humans are — tell your audience to expect one click, or front the demo with the header via your reverse proxy.

### The agent's local API (verified)

`ngrok http` also serves `http://localhost:4040`: the human inspector UI and a JSON API. `curl localhost:4040/api/tunnels` returns the active tunnels with their public URLs — the scriptable way to discover the random URL from CI scripts or test harnesses (we used it in testing instead of scraping the TUI).

### Free-tier limits in practice

1 GB transfer + 20k HTTP requests/month + 3 concurrent endpoints (verified against the [free plan limits page](https://ngrok.com/docs/pricing-limits/free-plan-limits)). The 3-endpoint cap is the one that bites during this hands-on: a CLI tunnel left running counts against the operator's endpoint. Stop tunnels you are not using.

## Part 3 — Cloudflare quick tunnels (verified) and named tunnels

```bash
cloudflared tunnel --url http://localhost:8089
# -> https://<four-random-words>.trycloudflare.com   (verified: served nginx over the public internet)
```

No account, no bandwidth cap, no interstitial; URL dies with the process, changes every run, and TryCloudflare comes with dev/test-only expectations (no SLA, in-flight request caps). The grown-up version — **named tunnels** — needs a free Cloudflare account and your own domain: `cloudflared tunnel create`, a config file mapping hostnames to local services, and DNS records on your zone. That gives you permanent URLs on your own domain at zero cost, which is the standard self-hosting setup. The decision rule from the bootcamp file stands: inspector/replay/webhook work → ngrok; instant anonymous share → quick tunnel; permanent free URLs on your domain → named Cloudflare tunnel.

Honorable mentions in the same space: `localhost.run` (pure SSH, zero install: `ssh -R 80:localhost:8089 nokey@localhost.run`), Pinggy (similar, 60-min sessions), Tailscale Funnel (tunnel into your private tailnet, then expose selectively). The [awesome-tunneling list](https://github.com/anderspitman/awesome-tunneling) catalogs the whole ecosystem including self-hosted options (frp, rathole).

## Part 4 — The ngrok Kubernetes Operator in depth

### Architecture (verified)

```
helm install ngrok-operator → two Deployments in ngrok-operator namespace:
  ngrok-operator-manager   watches Ingress/CRDs, calls ngrok API (API key)   [control plane]
  ngrok-operator-agent     maintains the tunnels that carry traffic (authtoken) [data plane]
```

When you apply an Ingress with `ingressClassName: ngrok`:

1. The manager validates it and calls ngrok's API to create an endpoint for the rule's host.
2. The agent attaches the tunnel for that endpoint.
3. The Ingress `ADDRESS` is patched to the public hostname (verified: fills within seconds).
4. Traffic: internet → ngrok edge → tunnel → agent pod → Service → your pods.

The operator also installs its own CRDs (`AgentEndpoint`, `CloudEndpoint`, traffic policies — see `kubectl api-resources | grep ngrok`) for ngrok-native features the Ingress API cannot express: same pattern you saw with Traefik's IngressRoute, and the same reason.

### What this replaces

To make a lab cluster publicly reachable you would otherwise need: a cloud LoadBalancer (money), or a VPS + reverse proxy + your own tunnel (work), or port forwarding on your router (pain, and impossible behind CGNAT). The operator is none of that — but remember it carries the free-tier limits (1 GB/mo) and the public-exposure responsibility (Part 5).

### Verified install (chart values that matter)

```bash
helm install ngrok-operator ngrok/ngrok-operator \
  --namespace ngrok-operator --create-namespace \
  --set credentials.apiKey=<API_KEY> \
  --set credentials.authtoken=<AUTHTOKEN>
```

For anything beyond a demo, put the credentials in a Secret instead of `--set` (the chart supports `credentials.secret.name`) — helm release values are readable by anyone with namespace access (`helm get values`), the same lesson as imagePullSecrets.

## Part 5 — The security conversation

A tunnel is a controlled hole through every network control between your laptop and the internet. The checklist before running one anywhere that matters:

1. **Authentication on the exposed service** — assume the URL leaks. Tunnel-domain enumeration is a real scanning hobby. ngrok can enforce auth at the edge (OAuth, basic auth via traffic policies) so unauthenticated requests never even reach you.
2. **Company policy** — many orgs ban unsanctioned tunnels outright (data exfiltration channel, shadow IT). The same tool that demos your app can bypass a DLP program. Ask first; "it was for a demo" is not a control.
3. **Scope and lifetime** — expose one port, not a dashboard that can reach everything; kill tunnels when done (`Get-Process ngrok | Stop-Process` on Windows cleans strays).
4. **Secrets in responses** — whoami-style debug endpoints echo headers; behind a tunnel those are now public. Audit what the exposed service actually returns.

## Cleanup

```bash
k3d cluster delete tunnel-demo        # removes the operator and closes its endpoint
docker rm -f tunnel-demo              # the Part A nginx
# Windows: ensure no stray agents keep endpoints open
Get-Process ngrok -ErrorAction SilentlyContinue | Stop-Process -Force
```

Your static dev domain and account state persist — nothing to clean server-side.

## Discussion questions

1. Draw the path of a request from a phone on mobile data to a Pod in your k3d cluster through the operator. Mark where TLS terminates, and who can read the plaintext.
2. Why do webhook providers never hit the interstitial while your classmates' browsers always do? What single request header proves your answer?
3. The free plan allows 3 concurrent endpoints. You have a CLI tunnel running and the operator managing two Ingresses. What happens when you apply a third Ingress, and how would you diagnose it?
4. Your company's security team asks why the ngrok agent's outbound connection isn't blocked by the corporate firewall. Explain the mechanism, and one control they could deploy.
5. When is a named Cloudflare tunnel on your own domain the better answer than ngrok's static dev domain — and what does it cost you in setup that ngrok doesn't?
6. The operator needs an API key but the CLI only needed an authtoken for the same outcome. What does the manager pod do that `ngrok http` does not?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `ERR_NGROK_4018` / auth errors on `ngrok http` | No/invalid authtoken in config | `ngrok config add-authtoken <token>`; `ngrok config check` |
| `ngrok api ...` → 401/403 | API key missing (authtoken is not enough) | `ngrok config add-api-key <key>` |
| Browser shows a warning page before the app | Free-tier interstitial (`ERR_NGROK_6024`), browser UAs only | Expected; click Visit Site, or send `ngrok-skip-browser-warning` header |
| `curl` works but the phone browser shows the warning | Same as above — UA-keyed | Same |
| Static domain rejected / not found | Using `.ngrok-free.app` for a dev domain, or another agent holds it | `ngrok api reserved-domains list` for the exact `.ngrok-free.dev` name; stop other agents |
| New endpoint refused | 3 concurrent endpoints on free plan | Stop unused tunnels (CLI ones count) |
| Operator Ingress ADDRESS stays empty | Manager can't reach ngrok API (bad API key) or host not your domain | `kubectl logs -n ngrok-operator deploy/ngrok-operator-manager`; verify the host matches your reserved domain |
| Public URL → 502/503 | Service/Pod not ready behind the Ingress | `kubectl get pods -n tunnel-demo`; endpoints of the Service |
| trycloudflare URL stopped working | Quick tunnels die with the process and rotate per run | Restart `cloudflared`; use a named tunnel for stability |
| Tunnel works, then quota errors mid-month | 1 GB / 20k requests free cap reached | Wait for reset, prune traffic, or upgrade |

## References

- [ngrok — Getting started](https://ngrok.com/docs/getting-started/) — install, authtoken, first tunnel
- [ngrok — Free plan limits](https://ngrok.com/docs/pricing-limits/free-plan-limits) — the numbers this hands-on quotes
- [ngrok — Kubernetes Operator docs](https://ngrok.com/docs/k8s/) — install, Ingress support, CRDs, traffic policies
- [ngrok — Agent API](https://ngrok.com/docs/agent/api/) — the `localhost:4040/api` endpoints used in testing
- [Cloudflare — TryCloudflare](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) — quick tunnels, scope and limits
- [Cloudflare — Preview a local project via Tunnel](https://developers.cloudflare.com/pages/how-to/preview-with-cloudflare-tunnel/) — the quick-tunnel flow we verified
- [awesome-tunneling](https://github.com/anderspitman/awesome-tunneling) — the ecosystem map, including self-hosted options
