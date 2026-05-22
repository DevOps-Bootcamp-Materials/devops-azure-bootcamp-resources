# Monitoring — Alertmanager deep-dive: routing, grouping, inhibition, silencing, Slack + email

Companion deep-dive for `week-14/monitoring/hands-on/07_alertmanager_deep_dive.md`. The bootcamp file walks through the demo end-to-end with focused explanations; this README expands every concept, addresses common misconceptions, lists every edge case worth knowing, and ships the heavy assets.

By the end of this folder you should be able to:

- Read any Alertmanager `route:` block and predict which receiver(s) a given alert hits, including the effect of `continue`.
- Pick reasonable values for `group_by`, `group_wait`, `group_interval` and `repeat_interval` for a real service.
- Understand the difference between **silencing** (manual, time-boxed mute) and **inhibition** (automatic, rule-based suppression).
- Wire a real Slack incoming webhook and a real Gmail SMTP relay with a single one-line swap from the mock setup.

## What this folder contains

| File | Role |
|---|---|
| `README.md` | this file — the full walkthrough |
| `docker-compose.yml` | seven services: Prometheus, Alertmanager, MailDev, webhook-logger, demo-app, node-exporter, an on-demand `cpu-stressor` |
| `prometheus.yml` | scrape config + Alertmanager target |
| `rules/host.yml` | host alerts labelled `team=platform`: `TargetDown` (critical), `HighCpuUtilization` (warning) |
| `rules/app.yml` | app alerts labelled `team=app`: `AppHighErrorRate` (critical), `AppHighRequestLatency` (warning) |
| `alertmanager.yml` | the central artifact — routing tree, grouping, inhibition, receivers |
| `templates/slack.tmpl` | Go template that formats the Slack message body |

## Prerequisites

- Docker and Docker Compose installed.
- Familiarity with Prometheus alerting rules and the **Inactive → Pending → Firing** lifecycle (covered in hands-on `04_promql_alerting.md`).
- A shell capable of running `curl`. On Windows, PowerShell works (`Invoke-WebRequest` if you prefer, but `curl.exe` is shipped with Windows 10+).

No Slack workspace, no email account, no Azure subscription required for the mock setup. The "Going real" section at the end shows the swap.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/monitoring/hands-on/alertmanager-deep-dive
docker compose up -d
```

Open three browser tabs:

- `http://localhost:9090` — Prometheus (Status → Rules; Alerts tab).
- `http://localhost:9093` — Alertmanager (Status, Alerts, Silences).
- `http://localhost:1080` — MailDev inbox (any email Alertmanager sends shows up here).

The `cpu-stressor` service is **not started by default**. To bring it up the first time:

```bash
docker compose --profile stress up -d cpu-stressor
```

After that, control it like any other service:

```bash
docker compose stop cpu-stressor   # let the alert resolve
docker compose start cpu-stressor  # fire CPU load again
```

This is the "fire alerts on demand" knob used throughout the walkthrough.

---

## Part 1 — Default route: the catch-all

Open `alertmanager.yml`. The root `route:` block has a `receiver:` field — that is the catch-all. Every alert that does not match any child route lands there.

If you delete every route under `routes:` and reload, the config becomes minimal:

```yaml
route:
  receiver: default-webhook
  group_by: ["alertname"]
```

Now every alert from Prometheus hits `default-webhook`, which posts to the webhook-logger container at `http://webhook-logger:9000/default`.

Fire any alert and look at the webhook-logger output:

```bash
docker compose stop demo-app
# wait ~45s for TargetDown to fire
docker logs --tail 50 webhook-logger
```

You will see a JSON envelope like:

```json
{
  "version": "4",
  "groupKey": "{}:{alertname=\"TargetDown\"}",
  "status": "firing",
  "receiver": "default-webhook",
  "groupLabels": { "alertname": "TargetDown" },
  "commonLabels": { "alertname": "TargetDown", "severity": "critical", "team": "platform", "instance": "demo-app:8080", "job": "demo" },
  "alerts": [ { "status": "firing", "labels": {...}, "annotations": {...}, "startsAt": "...", "fingerprint": "..." } ]
}
```

A few things worth pinning to your mental model now, because they show up over and over:

- **`groupKey`** uniquely identifies the active *group* in Alertmanager. It is a hash of the `group_by` label values. Notifications for the same `groupKey` are deduplicated within `group_interval`.
- **`commonLabels`** is the intersection of all labels across alerts in the group — fields present and identical in every alert. When an alert is alone in its group, this equals its full label set.
- **`status: firing`** vs **`status: resolved`** — Alertmanager re-sends the notification when an alert resolves *if* `send_resolved: true` is set on the receiver. Production teams almost always set it; otherwise you have no closure signal in chat.

Bring the demo app back so it stops firing:

```bash
docker compose start demo-app
```

You should now see a second payload arrive at the webhook-logger with `status: resolved`.

### Why the catch-all should never receive in production

Any alert reaching the catch-all means **you forgot to route it**. Best practice is to alert on this: configure `default-webhook` to point at PagerDuty (or similar) with severity "warning, fix your routing". A live catch-all that goes to nobody is a silent failure.

---

## Part 2 — The routing tree: matchers, the first-match rule, and `continue`

Restore the full `alertmanager.yml`. The routing tree under `route.routes` is:

```yaml
routes:
  - matchers: [ 'severity = "critical"' ]
    receiver: oncall-email
    group_wait: 0s
    continue: true
  - matchers: [ 'team = "platform"' ]
    receiver: platform-slack
    group_by: ["alertname", "instance"]
  - matchers: [ 'team = "app"' ]
    receiver: app-slack
    group_by: ["alertname", "handler"]
```

### How routing actually evaluates

Alertmanager evaluates routes **top to bottom**. The first child route whose matchers match the alert's label set wins, and evaluation stops — *unless* that route sets `continue: true`, in which case evaluation also falls through to siblings below it.

Trace a few examples mentally:

| Alert | `severity` | `team` | Receivers it lands in |
|---|---|---|---|
| `AppHighErrorRate` | `critical` | `app` | `oncall-email` + `app-slack` (route 1 matches, continues; route 3 also matches) |
| `AppHighRequestLatency` | `warning` | `app` | `app-slack` only (route 1 does not match, route 2 does not match, route 3 matches) |
| `TargetDown` | `critical` | `platform` | `oncall-email` + `platform-slack` |
| `HighCpuUtilization` | `warning` | `platform` | `platform-slack` only |
| (hypothetical alert with no team label) | `warning` | `–` | `default-webhook` (no child matches, root receiver fires) |

This is the bread-and-butter pattern: **a severity-based "always page" route at the top with `continue: true`, then team-based routes for chat notification.**

### Verifying routing without firing real alerts: `amtool config routes test`

You don't have to wait for an alert to fire to validate the routing tree. The `amtool` CLI (shipped inside the Alertmanager image) has a `config routes test` subcommand:

```bash
docker exec alertmanager amtool config routes test \
  --config.file=/etc/alertmanager/alertmanager.yml \
  severity=critical team=app
```

Output:

```
oncall-email  app-slack
```

That is the list of receivers the alert with those labels would be routed to. Run it for every combination you support — it is the fastest way to catch a misindented route block.

You can also dump the tree visually:

```bash
docker exec alertmanager amtool config routes show \
  --config.file=/etc/alertmanager/alertmanager.yml
```

### Matchers vs the legacy `match` / `match_re`

Older configs use `match:` (exact equality) and `match_re:` (regex). Both still work and are not deprecated, but `matchers:` is the modern form: a list of strings with PromQL-like syntax (`=`, `!=`, `=~`, `!~`). The README and `alertmanager.yml` use `matchers:` throughout because it composes more cleanly when you start mixing equality and regex.

```yaml
matchers:
  - severity = "critical"
  - team =~ "platform|app"        # regex
  - environment != "dev"          # negated equality
```

### Common misconceptions about `continue`

- **Misconception:** `continue: true` makes the route "match more" alerts. False — it only changes what happens *after* a match: stop here, or keep evaluating siblings.
- **Misconception:** Without `continue`, Alertmanager picks the most specific match. False — it picks the *first* match in document order. Reordering your routes silently changes routing behaviour. Always write the most specific routes at the top.
- **Misconception:** `continue` falls through to deeper routes (nested under the matched one). False — it falls through to **sibling** routes below the current one, not to child routes. Child routes are always evaluated when the parent matches.

---

## Part 3 — Grouping: `group_by`, `group_wait`, `group_interval`, `repeat_interval`

The four grouping knobs are the single most misunderstood part of Alertmanager. Each controls a different question.

### `group_by`

Decides **which alerts get bundled into the same notification**. Alertmanager hashes the values of the listed labels — alerts with identical hashes are grouped.

- `group_by: ["alertname"]` — one notification per alert kind, regardless of instance.
- `group_by: ["alertname", "instance"]` — one notification per (alert, instance) pair.
- `group_by: ["cluster", "service"]` — one notification per (cluster, service); great for incidents where a whole service is in trouble across many pods.
- `group_by: ["..."]` (literal three-dot string) — **special value meaning "every label"**. Every alert becomes its own group. Use with care: you lose the noise-reduction benefit of grouping.

The platform team route sets `group_by: ["alertname", "instance"]` because in their world, two `HighCpuUtilization` alerts on different hosts are two different problems and should be separate notifications. The app team sets `group_by: ["alertname", "handler"]` because their granularity is per-handler.

### `group_wait`

When a *new* group is created (no alert with this groupKey was active before), Alertmanager buffers it for `group_wait` before sending the first notification. The point: if a related second alert is about to fire 5 seconds later, both go out in the same Slack message instead of two.

- Typical: `10s`–`1m`.
- Too short: spammy at the start of an incident.
- Too long: people wait for the first notification, eroding trust in the alerting pipeline.
- The critical-route override `group_wait: 0s` says "for critical alerts, do not buffer at all — send immediately". This trades one extra notification for lower MTTR.

### `group_interval`

Once a group is active, if **new** alerts join that group, how long to wait before sending a *follow-up* notification.

- Default: `5m`.
- Lower it (`30s` in this config) when you want fast feedback as an incident expands. Raise it in noisier environments.
- Note: `group_interval` does *not* control re-sending the same alert — that is `repeat_interval`.

### `repeat_interval`

If the group is still firing (no new alerts, no resolution), how often to re-send the same notification as a reminder.

- Default: `4h`.
- Tuned tightly here to `5m` so the demo is fast. In production, somewhere between `1h` and `24h` is typical.
- Lower it when your team needs the chat ping as a tracker; raise it when alerts are mirrored elsewhere (PagerDuty, ticketing) and chat is just an FYI.

### Observing the four knobs in action

Fire two alerts in quick succession to see grouping with your own eyes:

```bash
# Fires TargetDown for demo-app (~30s after stopping)
docker compose stop demo-app

# 5 seconds later, fires HighCpuUtilization on the host
docker compose --profile stress up -d cpu-stressor
```

Watch the webhook-logger logs. With `group_wait: 0s` on the critical route, `TargetDown` (critical) hits `oncall-email` immediately. `HighCpuUtilization` (warning) hits `platform-slack` after `group_wait: 10s` and is grouped with any other host alert on the same instance.

Bring both back:

```bash
docker compose start demo-app
docker compose stop cpu-stressor
```

You should see two `status: resolved` notifications, one per receiver.

### A grouping rule of thumb

Group by the label that identifies **the thing you would act on as a unit**. A pod restart, a service rollback, an instance reboot. If your runbook says "for any X-typed alert on the same instance, do Y", group by `(alertname, instance)`.

---

## Part 4 — Templating the message: `slack.tmpl`

By default `slack_configs.text` ships a Go-template-rendered JSON message Slack accepts. The defaults are usable but ugly: long, untrimmed, no runbook link. The template at `templates/slack.tmpl` defines two named templates referenced from the receiver block:

```yaml
slack_configs:
  - title: '{{ template "slack.title" . }}'
    text:  '{{ template "slack.text" . }}'
```

Inside `slack.tmpl`:

```gotemplate
{{ define "slack.title" }}
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }} ({{ .CommonLabels.severity }})
{{ end }}
```

- `.Status` is `firing` or `resolved`.
- `.Alerts.Firing` is the slice of currently-firing alerts in the group; `| len` gives the count, so the title reads e.g. `[FIRING:3]`.
- `.CommonLabels` is the labels common to every alert in the group; perfect for headline metadata.

The text block iterates `.Alerts` and pulls per-alert annotations:

```gotemplate
{{ range .Alerts -}}
*Summary:* {{ .Annotations.summary }}
*Description:* {{ .Annotations.description }}
{{ if .Annotations.runbook_url }}*Runbook:* {{ .Annotations.runbook_url }}{{ end }}
{{ end }}
```

The `-` in `{{ range .Alerts -}}` trims the leading whitespace so the output doesn't have stray newlines. Subtle but important — Slack treats each newline as a paragraph break and the message looks broken without trimming.

### Why the template lives in a separate file

It could live inline in `alertmanager.yml`, but separating it is the convention because:

1. The same template is reused across multiple receivers (`platform-slack` and `app-slack` both call it).
2. Template syntax errors are easier to spot in a `.tmpl` file with editor support than in a YAML string.
3. Modifying a template doesn't require touching the routing config, which reduces the blast radius of changes during an incident.

### The `amtool template render` shortcut

You can render the template against a sample alert without firing anything:

```bash
docker exec alertmanager amtool template render \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --template.text='{{ template "slack.title" . }}' \
  --template.data.commonLabels.alertname=TargetDown \
  --template.data.commonLabels.severity=critical \
  --template.data.status=firing
```

Use this aggressively while iterating on templates; it beats waiting for an alert.

---

## Part 5 — Email via MailDev (and the swap to real Gmail)

The `oncall-email` receiver looks like this:

```yaml
- name: oncall-email
  email_configs:
    - to: "oncall@local.test"
      send_resolved: true
      headers:
        Subject: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ .CommonLabels.severity }})'
```

The SMTP settings live in the `global:` block at the top of `alertmanager.yml`:

```yaml
global:
  smtp_smarthost: "maildev:1025"
  smtp_from: "alertmanager@local.test"
  smtp_require_tls: false
```

MailDev's behaviour:

- Accepts any SMTP delivery on `:1025`. No auth, no TLS, no sender validation.
- Drops every message into an in-memory inbox visible at `http://localhost:1080`.
- Restart of the MailDev container clears the inbox unless you mount a volume.

Fire a critical alert and open the inbox:

```bash
docker compose stop demo-app
# wait ~30s
# → open http://localhost:1080
```

You will see a real RFC-822 email with the subject template rendered. Click it and inspect:

- **Headers tab**: see `From: alertmanager@local.test`, the rendered `Subject:`, the standard Date/Message-ID.
- **HTML tab**: Alertmanager's built-in HTML template renders a basic table of alerts. You can override it with `html:` and `text:` in `email_configs`.
- **Plain text tab**: the text fallback for non-HTML clients.

### Going real — Gmail

To send to a real Gmail address, three things change:

1. The recipient: change `to:` to a real address.
2. The relay: SMTP runs through Gmail itself.
3. Auth: Gmail no longer accepts your regular password from third-party SMTP clients. You need an **App Password** (Google account → Security → 2-Step Verification → App passwords; generate a 16-character password).

```yaml
global:
  smtp_smarthost: "smtp.gmail.com:587"
  smtp_from: "your-address@gmail.com"
  smtp_auth_username: "your-address@gmail.com"
  smtp_auth_password: "xxxxxxxxxxxxxxxx"     # 16-char app password, no spaces
  smtp_require_tls: true
```

In production, do **not** check the app password into git. Use one of:

- `smtp_auth_password_file: /run/secrets/gmail_app_password` (Alertmanager reads it from the file at startup).
- Mount the credential as a Docker secret / Kubernetes Secret and reference it via `_file`.
- Use a configuration management tool to template the file in place at deploy time.

Gmail's send quota is around 500 messages/day for a free account and ~2,000 for Workspace. Production alerting fan-out at any scale wants a real relay (SendGrid, SES, Mailgun, your own Postfix). The Gmail path is a "make it work for a demo" pattern, not a deployment target.

---

## Part 6 — Slack via the mock webhook, and the swap to real Slack

The `platform-slack` and `app-slack` receivers use `slack_configs`. The Slack API URL is set globally:

```yaml
global:
  slack_api_url: "http://webhook-logger:9000/slack"
```

When Alertmanager fires the receiver, it constructs a Slack-shaped JSON payload (the same one Slack accepts on its incoming webhooks endpoint) and POSTs it to that URL. The webhook-logger has no opinion on what it receives — it just prints it. So you can:

```bash
docker compose stop demo-app
# wait ~30s
docker logs --tail 80 webhook-logger
```

You will see the full Slack JSON envelope, including `channel`, `username`, `text`, and `attachments` (Alertmanager wraps the rendered text in a Slack attachment by default).

### Going real — Slack

1. In your Slack workspace, open the channel you want notifications in.
2. Workspace settings → **Apps** → search for and install **Incoming Webhooks**.
3. Click **Add to Slack**, pick the channel, and copy the generated URL — it looks like `https://hooks.slack.com/services/T0000/B0000/abcdef`.
4. Replace `slack_api_url` in `alertmanager.yml`:
   ```yaml
   global:
     slack_api_url: "https://hooks.slack.com/services/T0000/B0000/abcdef"
   ```
5. Reload Alertmanager: `curl -X POST http://localhost:9093/-/reload`.

That is the whole swap. The `channel:` field on the receiver is honoured by Slack only for legacy classic webhooks; modern webhooks deliver to whichever channel the webhook was created for, ignoring `channel:`. If you need to fan out to multiple channels, create one webhook per channel and one receiver per webhook.

Production tip: store the webhook URL in a file, reference it with `slack_api_url_file:`, and treat it as a secret. Anyone with the URL can post to that channel.

---

## Part 7 — Inhibition

The block at the bottom of `alertmanager.yml`:

```yaml
inhibit_rules:
  - source_matchers:
      - alertname = "TargetDown"
    target_matchers:
      - severity =~ "warning|critical"
    equal: ["instance"]
```

Says: **as long as `TargetDown` is firing for an instance, suppress every other warning/critical alert sharing the same `instance` label**.

Why this matters: when a host goes down, every alert that depends on scraping that host (CPU, memory, disk, app metrics) goes stale and starts firing too. Without inhibition, your on-call gets paged ten times for what is one incident.

### Why a "stop the target" demo is unreliable

The intuitive way to demo inhibition is to fire `HighCpuUtilization` on `node-exporter:9100`, then stop node-exporter so `TargetDown` fires for the same `instance`. In practice that doesn't work cleanly: the moment node-exporter stops, Prometheus loses the CPU metric, the rate window goes empty, and `HighCpuUtilization` resolves on its own *before* inhibition can take effect. You end up with `TargetDown` firing alone — no inhibition visible.

The structural lesson: inhibition only suppresses an alert that is *still firing*. If the underlying metric vanishes alongside the target, there is nothing to inhibit.

### Verifying inhibition reliably with `amtool alert add`

The clean approach is to inject two synthetic alerts that share an `instance` label and observe Alertmanager's state directly. This is also a useful production technique — it lets you test routing and inhibition against a running Alertmanager with no real incident.

Inject the warning first:

```bash
docker exec alertmanager amtool alert add \
  --alertmanager.url=http://localhost:9093 \
  alertname=HighCpuUtilization severity=warning team=platform \
  instance=demo-app:8080 \
  --annotation=summary='"synthetic warning"'
```

Now inject the `TargetDown` for the same instance:

```bash
docker exec alertmanager amtool alert add \
  --alertmanager.url=http://localhost:9093 \
  alertname=TargetDown severity=critical team=platform \
  instance=demo-app:8080 \
  --annotation=summary='"synthetic target down"'
```

Inspect the alerts via the API:

```bash
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool
```

You will see two entries: `TargetDown` with `state: "active"`, and `HighCpuUtilization` with `state: "suppressed"` and `inhibitedBy: ["<TargetDown fingerprint>"]`. Same picture in the UI (Alerts tab, tick "Show inhibited").

Synthetic alerts default to a 5-minute lifetime (their `endsAt` is `now + 5m`). They auto-expire; no cleanup required. If you want to send them earlier, you can `POST` to `/api/v2/alerts` with an `endsAt` in the past, which Alertmanager will treat as resolved.

The same `amtool alert add` pattern is invaluable for testing routes against a live Alertmanager during a config change — far safer than waiting for an incident to find out you sent paging alerts to the wrong channel.

### Silence vs inhibition

Both suppress notifications. The difference:

| | Silence | Inhibition |
|---|---|---|
| Source | Operator action via UI or `amtool` | Rule in `alertmanager.yml` |
| Trigger | Manual | Another alert firing |
| Lifetime | Time-boxed (you set start/end) | As long as the source alert is firing |
| Use case | Planned maintenance, known noisy alert | Cascading alerts from a single root cause |
| Auditability | Has `createdBy` and `comment` | Implicit |

Use **silence** when *you* know a window in which alerts are expected (deploy, db migration). Use **inhibition** when *the system* can tell that one alert obsoletes others.

---

## Part 8 — Silencing: UI and `amtool`

### From the UI

1. Open `http://localhost:9093` → **Alerts** tab.
2. Click an alert → **Silence**.
3. Fill in:
   - Matchers — pre-filled from the alert's labels. Tighten or loosen as you wish (e.g., remove `instance` to silence the alert for every host).
   - Duration — pick a short value for the demo (10m).
   - Creator and comment — mandatory. The comment becomes the audit trail; write something like `"Maintenance window 2026-05-22 14:00"`.
4. Submit. The alert disappears from the Alerts view but remains in Prometheus.

### From `amtool` (script-friendly)

```bash
docker exec alertmanager amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --comment="Maintenance window — db migration" \
  --duration=15m \
  alertname=HighCpuUtilization team=platform
```

List active silences:

```bash
docker exec alertmanager amtool silence query --alertmanager.url=http://localhost:9093
```

Expire a silence before its time:

```bash
docker exec alertmanager amtool silence expire <silence-id> --alertmanager.url=http://localhost:9093
```

### Where silences live

Silences are stored in Alertmanager's local data directory (under `--storage.path`, here `/alertmanager`). They survive restarts. In an HA Alertmanager cluster, silences gossip between peers — create on any node, visible from all.

### Common silencing pitfalls

- **Forgetting the matchers.** A silence with no matchers silences *everything*. Alertmanager will warn you in the UI, but `amtool silence add` with an empty matcher list will happily do it. Always pass at least one matcher.
- **Using `=` when you meant `=~`.** `instance=db-` won't match `instance=db-01`. Use `instance=~"db-.*"`.
- **Leaving silences open-ended for "a long time".** Use `15m`/`1h`/`4h`. If a silence is still needed at the end of the window, extending it is a deliberate decision; silently leaving a 30-day silence in place is how alerts get permanently muted.

---

## Cleanup

```bash
docker compose --profile stress down -v
```

The `--profile stress` flag is needed for `docker compose down` to also remove the `cpu-stressor` container (its profile excludes it from the default set). The `-v` removes the `prometheus-data` named volume — drop it if you want to keep Prometheus history between runs.

---

## Discussion questions

1. The critical-severity route has `continue: true`. What would change if you set it to `continue: false`? Walk through what happens to an `AppHighErrorRate` (critical, team=app) alert.
2. The platform team uses `group_by: ["alertname", "instance"]`. Why not `["alertname"]` (which would group every CPU alert across every host into one notification)? When *would* a single-label grouping be the right choice?
3. The inhibition rule has `equal: ["instance"]`. What goes wrong if you change it to `equal: ["instance", "job"]`? What if you remove `equal:` entirely?
4. A teammate says "we should silence `HighCpuUtilization` for the next month because the box is just naturally hot." Why is that the wrong tool? What should they do instead?
5. You set `group_wait: 0s` on the critical route, but `group_wait: 10s` (inherited from root) on every other route. What is the trade-off you are making? What does the user receive in chat?

---

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `docker compose up -d` errors on `cpu-stressor` profile | The `cpu-stressor` service is gated by `profiles: ["stress"]` and the up command doesn't activate that profile | Bring it up with `docker compose --profile stress up -d cpu-stressor`, then control with `start`/`stop`. |
| Alertmanager UI shows alerts but webhook-logger has no output | The route block matched a receiver other than `default-webhook`; check `docker logs alertmanager` for `level=warn` messages about delivery | Confirm with `amtool config routes test severity=... team=...` — the printed receivers are exactly what got notified. |
| MailDev UI is empty after a critical alert fires | Likely `smtp_smarthost` typo or the `oncall-email` receiver was not reached | (a) Run `docker exec alertmanager amtool config routes test severity=critical` and confirm `oncall-email` is listed. (b) `docker logs alertmanager` will show `dial tcp: lookup maildev` or SMTP errors. |
| `amtool: command not found` | The host doesn't have amtool installed | Run it inside the Alertmanager container: `docker exec alertmanager amtool ...`. No host install needed. |
| Reload returns `Lifecycle API is not enabled` | Prometheus was started without `--web.enable-lifecycle` | The compose enables it; if you customized, add the flag back. |
| Inhibition appears to not work | `equal:` labels don't match between source and target alerts | Open both alerts in the Alertmanager UI and confirm every label in `equal:` is identical. The cardinality of `instance` and `job` is the usual culprit. |
| Inhibition demo with real `TargetDown` shows no suppression | The target metric vanishes when its exporter is stopped, so the warning alert resolves on its own before inhibition acts | Use the `amtool alert add` injection pattern (see Part 7) to inject two synthetic alerts with the same `instance` label and observe `state: "suppressed"` directly. |
| `amtool alert add ... --annotation=summary='synthetic ...'` warns about an "incompatible matchers parser" | New Alertmanager UTF-8 matchers parser wants every label value double-quoted | Quote the value: `--annotation=summary='"synthetic warning"'`. The legacy parser falls back automatically, so the command still works; the warning is just a deprecation notice. |
| MailDev container shows `(unhealthy)` in `docker ps` | The 2.x image's bundled healthcheck does not match its actual ready endpoint | Cosmetic — MailDev is fully functional. Confirm by opening `http://localhost:1080` and seeing the inbox. |
| Slack receiver POSTs but the real Slack channel never sees a message | The `slack_api_url` is correct but the channel was archived, or the webhook was revoked | Recreate the incoming webhook in Slack. The URL is a bearer token — old ones stop working when revoked. |
| Email arrives in MailDev but Gmail (production) rejects it | Gmail rejects on SPF/DKIM/DMARC misalignment | Don't use Gmail SMTP for production alerting. Switch to SES/SendGrid/Mailgun with a verified sender domain. |
| Two notifications arrive for the same alert at the same receiver | An ancestor route matched and continued, then a descendant route also matched and routed to the same receiver | Audit your `continue:` flags; only the top-level "always page" routes typically need it. |

---

## References

### Routing and grouping
- [Alertmanager — Configuration](https://prometheus.io/docs/alerting/latest/configuration/) — the authoritative reference for every field in `alertmanager.yml`.
- [Alertmanager — Routing tree editor](https://prometheus.io/webtools/alerting/routing-tree-editor/) — paste your `route:` block and visualise the tree. Invaluable for debugging.
- [Robust Perception — Laying out Alertmanager routes](https://www.robustperception.io/laying-out-alertmanager-routes/) — Brian Brazil on designing a routing tree as an organisation grows from one team to many.

### Receivers and templates
- [Alertmanager — Notification template reference](https://prometheus.io/docs/alerting/latest/notifications/) — every variable available in templates (`.Status`, `.Alerts`, `.CommonLabels`, ...).
- [Alertmanager — Notification template examples](https://prometheus.io/docs/alerting/latest/notification_examples/) — official starting point for Slack/email/PagerDuty templates.
- [Robust Perception — Using Slack with the Alertmanager](https://www.robustperception.io/using-slack-with-the-alertmanager/) — the canonical short walkthrough of `slack_configs`, including title/text customisation.
- [Slack — Sending messages using incoming webhooks](https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks) — how to create the webhook URL and what payload Slack accepts.

### Inhibition, silencing, HA
- [Alertmanager — Configuration (`inhibit_rules`)](https://prometheus.io/docs/alerting/latest/configuration/) — the `source_matchers`, `target_matchers`, `equal` semantics; section `<inhibit_rule>` in the same configuration reference above.

### Real-world / production
- [Prometheus Monitoring Mixins](https://monitoring.mixins.dev/) — production-quality alert rules for common technologies. Read the routing/grouping choices for inspiration.
- [Unit Testing Alertmanager Routing and Inhibition Rules — Frank Rosner](https://dev.to/frosnerd/unit-testing-alertmanager-routing-and-inhibition-rules-1hj4) — using `amtool config routes test` in CI to catch routing regressions before they page the wrong team.
