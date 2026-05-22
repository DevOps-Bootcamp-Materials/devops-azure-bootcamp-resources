# Monitoring — Grafana-managed alerts: contact points, notification policies, Slack + email

This is the deep-dive companion to [`week-14/monitoring/hands-on/08_grafana_managed_alerts.md`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp/blob/main/week-14/monitoring/hands-on/08_grafana_managed_alerts.md) in the bootcamp repo. The bootcamp hands-on walks the demo end-to-end and explains what the reader needs to teach (or learn) the topic in one sitting. This README is what you open when you want to understand *why* each piece is shaped the way it is — the architecture decisions, the misconceptions, the alternatives, and the troubleshooting.

The whole hands-on is the natural sequel to [`alertmanager-deep-dive`](../alertmanager-deep-dive/). The two solve the same problem (turn fired alerts into useful notifications) with opposite architectures. The bootcamp hands-on draws the contrast at the end; this README returns to it throughout.

## What this folder contains

- `README.md` — this file, the full walkthrough with every detail.
- `docker-compose.yml` — Grafana, Prometheus, node-exporter, the demo app, MailDev, the webhook-logger, an on-demand `cpu-stressor`.
- `prometheus.yml` — scrape config only. No `rule_files`, no `alerting:` block — Prometheus is reduced to "the datasource Grafana queries".
- `grafana/provisioning/datasources/prometheus.yml` — the Prometheus datasource, with a fixed `uid: prometheus-main` that the alert rules reference.
- `grafana/provisioning/alerting/rules.yaml` — the four alert rules (TargetDown, HighCpuUtilization, AppHighErrorRate, AppHighRequestLatency) as Grafana data graphs.
- `grafana/provisioning/alerting/contact-points.yaml` — three contact points: `oncall-email` (SMTP via MailDev), `platform-slack`, `app-slack` (both via the webhook-logger).
- `grafana/provisioning/alerting/notification-policies.yaml` — the root notification policy and three child routes.
- `grafana/provisioning/alerting/mute-timings.yaml` — a `weekend-nights` mute timing referenced from the policy file.

## Prerequisites

- Docker and Docker Compose installed (`docker --version`, `docker compose version`).
- Lessons 01–06 of week 14 already covered.
- Hands-on 02 (`full-stack`), 04 (`promql-alerting`), 06 (`grafana-dashboards`), and 07 (`alertmanager-deep-dive`) all done. The "is this Grafana or Prometheus' responsibility now?" question only makes sense if you have done 07 first — this README assumes you have.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/monitoring/hands-on/grafana-managed-alerts
docker compose up -d
```

The first time Grafana starts it will read every file under `grafana/provisioning/` and create the corresponding objects: datasources, alert rules (in the `monitoring` folder), contact points, notification policies, and mute timings. From that moment on, the alerts are *live*: Grafana queries Prometheus on schedule, evaluates the threshold expressions, fires on `for: 30s`, and dispatches to whichever contact points the notification policy matches.

This README mirrors the flow of the bootcamp hands-on but expands every "What this means" section into the full treatment.

---

## Part 1 — Architecture: Grafana Unified Alerting in one diagram

Unified Alerting (the default since Grafana 9.0) collapses what used to be two separate worlds — the old Grafana Legacy Alerting and the standalone Prometheus + Alertmanager stack — into a single in-Grafana evaluation engine and dispatcher.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Grafana                                                                 │
│                                                                         │
│  ┌──────────────┐   ┌─────────────────────┐   ┌────────────────────┐    │
│  │ Alert Rules  │──>│ Evaluator (runs on  │──>│ Alertmanager       │    │
│  │ (folder/UID) │   │ each interval)      │   │ (built-in)         │    │
│  └──────────────┘   └─────────────────────┘   └────────────────────┘    │
│         │                     ▲                         │               │
│         │ provisioning        │ datasource query        │               │
│         ▼                     │                         ▼               │
│  ┌──────────────┐   ┌─────────────────────┐   ┌────────────────────┐    │
│  │ Files /      │   │ Prometheus / Loki / │   │ Contact points     │    │
│  │ UI / API     │   │ Mimir / Mysql / ... │   │ Notification pols. │    │
│  └──────────────┘   └─────────────────────┘   │ Silences / mutes   │    │
│                                               └────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
                                                          │
                                                          ▼
                                              ┌────────────────────┐
                                              │ Email / Slack /    │
                                              │ PagerDuty / ...    │
                                              └────────────────────┘
```

Three things are worth holding in your head:

1. **The evaluator runs *inside* Grafana.** Every rule has an `interval` (1m by default). On each tick, Grafana runs the data graph: it queries the datasource, applies the expressions, and produces a value per series. If the threshold is breached for the `for:` duration, the rule transitions to firing.
2. **The dispatcher is a real Alertmanager embedded in Grafana.** Internally, Grafana ships the Prometheus Alertmanager codebase as a library and feeds it the alerts produced by the evaluator. Your `contact-points.yaml` and `notification-policies.yaml` are translated into the same `receivers:` and `route:` structures Alertmanager has used for years — only the wire format has changed (Grafana's own provisioning YAML instead of `alertmanager.yml`).
3. **Datasources are abstracted.** A rule can query Prometheus, Loki, Mimir, MySQL, CloudWatch, Tempo — anything Grafana has a datasource for — and combine results with expressions. This is the biggest single difference from Prometheus rules: a single rule can join two datasources, which Prometheus' own rule language cannot do.

### The contrast with Prometheus + Alertmanager

| Question | Prometheus + Alertmanager | Grafana Unified Alerting |
|---|---|---|
| Where do rules live? | `rule_files:` in Prometheus | Grafana database + provisioning YAML |
| Who evaluates? | Prometheus | Grafana |
| Where is state stored? | In Prometheus' WAL | In Grafana's database |
| Who routes notifications? | Alertmanager (separate process) | Embedded Alertmanager (same Grafana process) |
| Can a single rule join two datasources? | No | Yes |
| Multi-tenancy / RBAC on rules? | None (it's a flat config file) | Per-folder permissions |
| HA story | Run Alertmanager as a cluster (gossip) | Run Grafana with shared DB; alertmanager state in DB |
| What you write | `alert: ...` YAML | A "data graph" of refIds + expressions |

In production, teams pick one of the two patterns and stick to it. Mixing them — Prometheus rules *plus* Grafana rules — is supported but creates two places to look during an incident, two sets of silences, two routing trees. The bootcamp hands-on ends on a decision table that summarises when to choose which; Part 8 of this README expands it.

---

## Part 2 — The data graph: what a Grafana alert rule actually is

Open `grafana/provisioning/alerting/rules.yaml` and look at the first rule (`HighCpuUtilization`). The shape is:

```yaml
condition: C
data:
  - refId: A      # the query
    datasourceUid: prometheus-main
    model:
      instant: true
      expr: '100 - (avg by(instance) ...)'
  - refId: C      # the threshold
    datasourceUid: __expr__
    model:
      type: threshold
      expression: A
      conditions:
        - evaluator:
            type: gt
            params: [80]
```

The `data:` list is a directed graph. Each entry has a `refId` (a letter, by convention) and a `datasourceUid`. The special `__expr__` datasource is Grafana's built-in expression engine: instead of querying an external system, it computes a value from previous refIds. The `condition:` field at the top names the refId whose result is interpreted as the firing/not-firing boolean.

There are four expression types:

- **Threshold** (`type: threshold`) — the simplest. Takes an input value and a comparator (`gt`, `lt`, `within_range`, ...). One per typical rule.
- **Math** (`type: math`) — a small expression language with `+`, `-`, `*`, `/`, `&&`, `||`, `==`, ternaries, and the special `${refId}` substitution. Used when a threshold isn't expressive enough: `${A} > 80 && ${B} < 100`.
- **Reduce** (`type: reduce`) — collapses a *range* of values into a single number per series. Reducers: `last`, `mean`, `max`, `min`, `sum`, `count`. You need a Reduce node when the upstream query returns a range vector and the threshold needs an instant value.
- **Classic condition** (`type: classic_condition`) — the legacy single-node "this query AND that query" expression carried over from old Grafana alerts. New rules generally avoid this in favour of explicit Reduce + Math + Threshold chains.

### `instant: true` vs range queries — and why our rules use it

Every PromQL query in our `rules.yaml` sets `instant: true`. That means Grafana asks Prometheus for the value *now*, not a series of values over a window. With `instant: true`, Threshold can read the single most recent value directly — no Reduce node needed.

If you drop `instant: true`, Grafana issues a range query (`/api/v1/query_range`). The threshold can't be applied to a range vector, so the rule becomes "broken" until you add a Reduce node between A and C:

```yaml
- refId: A      # range query
  model:
    expr: '100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)'
- refId: B      # collapse the range to a single value per series
  datasourceUid: __expr__
  model:
    type: reduce
    expression: A
    reducer: last
- refId: C      # threshold
  datasourceUid: __expr__
  model:
    type: threshold
    expression: B
    conditions: [...]
```

Both shapes work. The instant-query shape is simpler and is what students will see most often when they create a rule via the UI; the range-query + Reduce shape is what you reach for when you need a mean or max over a window rather than the last value.

### `for:` (pending period) vs `interval:`

Two timing concepts that students confuse:

- **`interval`** is on the *group*, not the rule: how often Grafana evaluates every rule in the group. Default 1m; production groups often use 30s or 1m.
- **`for`** is on the *rule*: how long the threshold must keep being breached before the alert transitions from Pending to Firing. Identical semantics to Prometheus' `for:`.

Set `for: 0s` if you want the rule to fire on the first breach. Set `for: 5m` if you want it to ignore short spikes. The `for:` value is independent of `interval:` — a rule with `interval: 30s, for: 2m` evaluates four times before it can fire.

### `noDataState` and `execErrState`

What the rule should do when something goes wrong. Both fields take one of: `OK`, `Alerting`, `NoData` (or `Error` for `execErrState`).

- `noDataState: NoData` (most rules) — when the query returns no series, raise a synthetic "DatasourceNoData" alert. Useful for "the metric should exist" rules like `TargetDown`.
- `noDataState: OK` — silently ignore empty results. Use for "the metric only exists when there's traffic" rules (our `AppHighErrorRate` does this: if no requests, there is no series, and that's fine).
- `noDataState: Alerting` — treat empty as firing. Use for "the heartbeat must always be present" rules.

The same three for `execErrState` (datasource errors, expression errors). `Error` triggers a synthetic `DatasourceError` alert that you can route the same way as a real alert.

---

## Part 3 — Contact points: where notifications go

A contact point is "a destination plus its credentials and rendering options". In our setup:

- `oncall-email` — type `email`. Recipient list is per-contact-point. The SMTP relay itself is configured at the Grafana *server* level via the `GF_SMTP_*` env vars in `docker-compose.yml`. **There is one SMTP relay per Grafana installation**; multiple email contact points share it.
- `platform-slack` / `app-slack` — type `slack`. Each has its own `url` (the incoming webhook), `recipient` (cosmetic on modern webhooks), `title`, and `text`. Each Slack contact point is independent.

Grafana ships ~25 contact point types out of the box: `email`, `slack`, `pagerduty`, `opsgenie`, `webhook`, `discord`, `teams`, `googlechat`, `telegram`, `sns`, `victorops`, `webex`, `wecom`, `kafka`, `line`, `pushover`, ... The provisioning YAML is the same shape (a `settings:` map per `type:`); the keys inside `settings:` vary per type. The catalogue is documented in [Grafana's Manage contact points docs](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/).

### Templating: `title:`, `text:`, `subject:`, `message:`

Every contact point of a given type exposes a small set of templatable fields. For Slack: `title`, `text`. For email: `subject`, `message`. The template language is Go's `text/template` with the same data model the Alertmanager exposes — `.Status`, `.Alerts`, `.CommonLabels`, `.CommonAnnotations`, `.GroupLabels`. The same templates you may have written in the alertmanager-deep-dive hands-on (`slack.tmpl`) work here with very small adjustments.

Two things to know:

1. **Field-level templating, no separate template file by default.** Our `contact-points.yaml` inlines the `title:` and `text:` directly. If you want to share templates between contact points, define them at the global level in Grafana's "Notification templates" UI (also provisionable) and reference them with `{{ template "name" . }}`.
2. **`.Alerts.SortedPairs`** is the way to iterate label pairs in a stable order. Plain `range .Alerts.Labels` gives you a map with no guaranteed order, which makes templates non-deterministic — annoying when comparing two notifications.

Common variables you will reach for:

| Variable | Meaning |
|---|---|
| `.Status` | `firing` or `resolved` for the whole group |
| `.Alerts` | The list of alerts in this notification group |
| `.Alerts.Firing` / `.Alerts.Resolved` | The two subsets |
| `.CommonLabels` | Labels that are identical across every alert in the group |
| `.CommonAnnotations` | Same, for annotations |
| `.GroupLabels` | The labels Grafana used to group these alerts (your `group_by:`) |
| `.ExternalURL` | The URL of the Grafana that produced the notification |

### Test notifications

In the UI, every contact point has a **Test** button that sends a synthetic notification. Use this every time you change a contact point — it's the fastest way to find a malformed template, a wrong webhook URL, or a missing SMTP credential, *before* a real alert fires.

In our setup:

- Test `oncall-email` → MailDev inbox at `http://localhost:1080` shows the message.
- Test `platform-slack` → `docker logs webhook-logger` shows the Slack-shaped POST.

### Production note: webhook URLs are credentials

The Slack incoming webhook URL is a bearer token — anyone with the URL can post to that channel as that integration. In production:

- Mount the URL as a file (`url_file:` instead of `url:`) and treat the file as a Docker / Kubernetes secret.
- Or use Grafana's secrets handling (`GF_SECURITY_SECRET_KEY` + the encrypted secrets feature) which stores the secret encrypted in the database.

Same story for the Gmail App Password used in the "Going real" section.

---

## Part 4 — Notification policies: the routing tree

Notification policies are Grafana's name for what Alertmanager calls the routing tree. Same semantics: a tree of policies evaluated top-to-bottom, first-match-wins, with optional `continue: true` to keep evaluating siblings after a match.

Open `notification-policies.yaml`. The root policy has:

```yaml
receiver: oncall-email      # catch-all
group_by: ['grafana_folder', 'alertname']
group_wait: 30s
group_interval: 5m
repeat_interval: 4h
```

Children inherit every field they don't redefine. The `severity=critical` child overrides `group_wait: 0s` (page immediately, no buffering) and sets `continue: true` so warning-team-specific routes below also get a copy. The two team routes set their own `group_by:` for fine-grained grouping.

### `object_matchers` vs `matchers` vs the legacy `match` / `match_re`

The provisioning YAML accepts three shapes for the "does this policy match this alert" condition:

```yaml
# Recommended for new content — full PromQL-style matchers including =, !=, =~, !~
object_matchers:
  - ['severity', '=', 'critical']
  - ['team', '=~', 'platform|core']

# String form, identical semantics, harder to template-generate
matchers:
  - severity = "critical"
  - team =~ "platform|core"

# Legacy, restricted to equality
match:
  severity: critical
match_re:
  team: platform|core
```

`object_matchers` (an array of 3-element arrays) is the form used by Grafana's own UI export. New content should use it. The other two forms still work and you will find them in older configs.

### Grouping knobs — exactly the same as Alertmanager

The four knobs from the alertmanager-deep-dive hands-on are unchanged:

| Knob | Controls |
|---|---|
| `group_by` | Which alerts get bundled into the same notification. |
| `group_wait` | How long to buffer the first notification of a new group. |
| `group_interval` | How long to wait before re-notifying when a *new* alert joins an existing group. |
| `repeat_interval` | How often to re-send the same still-firing notification. |

If you read Part 3 of [`alertmanager-deep-dive/README.md`](../alertmanager-deep-dive/README.md), everything you learned there applies verbatim here. The values you would set in production (`repeat_interval: 1h–24h`, `group_wait: 30s–60s` for non-critical, `0s` for critical) are unchanged.

### Inheritance: subtle but important

Children inherit every field they don't redefine, *including* `group_by`. This bites: if you set `group_by: ['grafana_folder', 'alertname']` at the root and a child route only sets `receiver:` and `matchers:`, the child also groups by `(folder, alertname)`. Often what you want is the child to group by something more specific. Always redefine `group_by` on every leaf policy unless you want the parent's grouping.

### `continue: true` and the "critical always pages + team Slack also" pattern

This is the single most common production routing shape:

```yaml
routes:
  - object_matchers: [['severity', '=', 'critical']]
    receiver: oncall-email
    group_wait: 0s
    continue: true               # <-- keep evaluating siblings
  - object_matchers: [['team', '=', 'platform']]
    receiver: platform-slack
  - object_matchers: [['team', '=', 'app']]
    receiver: app-slack
```

A `severity=critical, team=platform` alert hits both `oncall-email` (because the critical rule matched) *and* `platform-slack` (because evaluation continued and the team-platform rule matched). Forgetting `continue: true` is the most common reason "the on-call email arrived but Slack didn't" — the alert matched the critical route, evaluation stopped, the team route never ran.

### Predicting routing without firing anything

Alertmanager has `amtool config routes test`. Grafana doesn't ship an exact equivalent CLI, but you can use the **Alerting → Notification policies → Show matching alerts** view: enter a set of labels and Grafana renders which policy node would match. Use this every time you change `notification-policies.yaml`.

---

## Part 5 — Silences and mute timings: two ways to "be quiet"

Two different shapes of "stop notifying":

- **Silence** — a one-off, manually created mute over a *specific* set of label matchers, with a start and end time. You make one when a runbook says "we're about to do this maintenance, mute these alerts for an hour". It carries `createdBy` and `comment` for audit.
- **Mute timing** — a *recurring* time window referenced from a notification policy. You define it once ("weekend nights", "saturday-overnight-batch") and policies opt in via `mute_time_intervals:`. No human action needed at run time.

The hands-on demonstrates both. Silences come and go; mute timings are part of the configuration.

### Three patterns, three tools

| Situation | Tool |
|---|---|
| "We're going to take the db offline at 14:00 for 30 minutes." | One-off **silence**, label-matched on the deploy target, expires automatically. |
| "Don't page anyone for warnings between Saturday 22:00 and Monday 06:00." | **Mute timing** on the warning policies. |
| "When the host is down, suppress every other alert from that host." | **Inhibition rule** (Grafana 10.x supports them in the unified Alertmanager). |

Inhibition is the only one we don't exercise in this hands-on (it lives in the alertmanager-deep-dive). The provisioning YAML supports it (`inhibitRules:` at the same level as `policies:`); the syntax matches the Alertmanager YAML one-for-one.

### Silence pitfalls

- **Never leave a silence open-ended.** Use short windows (15m, 1h, 4h) and renew if you need more time. The single most common production outage caused by alerting is "an alert was silenced two weeks ago and never expired".
- **Silences match labels exactly.** A silence on `severity=critical` does *not* silence a `severity=warning` alert from the same rule. The matcher is on labels, not on rule identity.
- **Silences gossip in HA.** If you run Grafana with multiple replicas, silences are persisted in the database and replicated; in the legacy standalone-Alertmanager setup, silences gossip between AM peers. Same outcome.

### Mute timing pitfalls

- **Timezones.** Mute timings use the *Grafana server's* time zone unless you specify `location: Europe/Madrid` at the timing level. A common cause of "the mute didn't work" is that the server is in UTC and the timing is in local clock time.
- **Mute does not stop evaluation.** A muted rule still evaluates, still moves to Firing, still appears in the Alerting UI. Only the *notification dispatch* is suppressed. If you want the rule to genuinely pause, mark it `isPaused: true`.
- **Multiple intervals.** A mute timing has a *list* of `time_intervals`; an alert is muted if *any* interval matches. Our `weekend-nights` example has two intervals (Sat/Sun evening + Sat/Sun/Mon early morning) to cover the full overnight window cleanly across the date boundary.

---

## Part 6 — Provisioning: editing as code, locking the UI

Grafana provisioning is the "load this config on startup" mechanism. It applies to datasources, dashboards, plugins, and (since 9.0) alerting objects: rules, contact points, policies, mute timings, notification templates.

### What happens on startup

For each file under `/etc/grafana/provisioning/alerting/`:

1. Grafana parses the YAML.
2. For each object (a rule, a contact point, a policy, ...), it `upserts` into the database, matched by `uid` for rules/templates and by `name` for contact points / policies / mute timings.
3. The object is marked **provisioned** in the database — the UI shows a small lock icon next to it.

A provisioned object cannot be edited from the UI (or via the regular API). The "Edit" button is greyed out, and Grafana shows a message like: "This rule is provisioned. To change it, edit the YAML and reload Grafana, or use the provisioning API."

### What "edit" means in a provisioned world

Three options, in order of how teams usually adopt them:

1. **Edit the YAML, commit it, restart / reload Grafana.** What we do in this hands-on. Simple, git-as-source-of-truth, works for small teams.
2. **Use the provisioning API.** `POST /api/v1/provisioning/alert-rules` with the JSON shape of a rule. This is what tools like Terraform's `grafana_rule_group` resource do under the hood. Useful for higher-ops teams who want infrastructure-as-code in their existing IaC pipeline.
3. **Disable provisioning for a specific object.** Set `disableProvenance: true` on a contact point or rule group to allow UI edits despite the file. Useful for "this rule was set up by ops but the app team owns iteration".

### Round-tripping UI → file

A common workflow:

1. Prototype a rule in the UI until it works.
2. Export it: **Alerting → Alert rules → ⋯ menu → Modify export → YAML**.
3. Paste into `rules.yaml`, commit, restart.

The UI export will include some Grafana-managed fields you don't strictly need (`provenance`, `created`, `updated`, sometimes nested folders). Strip what isn't necessary and keep the file small enough to read.

### Reloading without a restart

Two paths:

```bash
# Full provisioning reload — re-reads every provisioning file
curl -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/alerting/reload
```

This is faster than `docker compose restart grafana` and doesn't kick logged-in users out. The hands-on uses `docker compose restart grafana` because it is the more obvious sequence for a class demo; in your day job, use the reload endpoint.

---

## Part 7 — Going real: Slack incoming webhooks + Gmail SMTP

Same four-line swap as in the alertmanager-deep-dive hands-on, on the Grafana side this time.

### Real Slack

In `contact-points.yaml`, replace the mock URL:

```yaml
- orgId: 1
  name: platform-slack
  receivers:
    - uid: platform-slack-receiver
      type: slack
      settings:
        url: https://hooks.slack.com/services/T00000000/B00000000/abcdefghij
        # recipient: '#platform-alerts'   # cosmetic on modern webhooks
        title: '[{{ .Status | toUpper }}] {{ index .GroupLabels "alertname" }}'
        text: |
          {{ range .Alerts -}}
          *Summary:* {{ .Annotations.summary }}
          {{ end -}}
```

Then reload Grafana (`docker compose restart grafana` or the reload API). The next firing alert routes to the real channel.

Notes:

- The `recipient:` field is cosmetic on modern Slack incoming webhooks — the webhook is bound at creation time to the channel the integration was added to. Setting `recipient:` to a different channel does *not* redirect the message; you would need to create another webhook for the second channel.
- The Slack URL is a bearer token. In production, mount it as a Docker secret and use `url_file:` instead of `url:`.

### Real Gmail (App Password)

The SMTP server lives at the Grafana *server* level — change the env vars in `docker-compose.yml`:

```yaml
- GF_SMTP_ENABLED=true
- GF_SMTP_HOST=smtp.gmail.com:587
- GF_SMTP_USER=your-address@gmail.com
- GF_SMTP_PASSWORD=xxxxxxxxxxxxxxxx        # 16-char App Password
- GF_SMTP_FROM_ADDRESS=your-address@gmail.com
- GF_SMTP_FROM_NAME=Your Service Alerts
- GF_SMTP_STARTTLS_POLICY=MandatoryStartTLS
```

Get the App Password from your Google account → Security → 2-Step Verification → App passwords. Gmail no longer accepts regular account passwords from third-party SMTP clients; an App Password is mandatory.

Restart Grafana (env-var change requires restart, not reload):

```bash
docker compose up -d grafana
```

Then in the email contact point, change `addresses:` to a real recipient. Test from the UI and confirm the email lands in the destination inbox.

### Why this is a demo, not a deployment

Gmail and a single Slack incoming webhook are fine for a class. In production at any scale:

- **Email volume.** Gmail caps free accounts around 500 messages/day, Workspace around 2,000. A noisy week burns through that. Production uses SES, SendGrid, Mailgun, Postmark — services with proper SPF/DKIM/DMARC alignment.
- **Slack at scale.** A single incoming webhook is fine for a small team or a demo. Beyond that, teams use Slack's Bot API with proper auth, or route through PagerDuty / Opsgenie which then notifies Slack as one of many endpoints.
- **Pager integration.** "Wake someone up" is its own contact point type (`pagerduty`, `opsgenie`). Email is *never* the right shape for that.

---

## Part 8 — When to choose Grafana-managed alerts vs Prometheus + Alertmanager

The decision table you reach for when an SRE asks "why did we pick this side?":

| Factor | Grafana-managed | Prometheus + Alertmanager |
|---|---|---|
| Single-datasource (Prometheus only) alerts | Either works. Slight edge to Prometheus because the rules sit *next to* the recording rules and the scrape config. | ✓ Idiomatic. |
| Multi-datasource alerts (Prometheus + Loki, Prometheus + a DB) | ✓ Only Grafana can do this in one rule. | Cannot — you have to write two rules and combine via labels in AM. |
| Alert rule ownership by non-SRE teams (app team self-serves) | ✓ Per-folder permissions in Grafana mean an app team can manage its own folder. | All rules sit in the same Prometheus config; ownership is at the YAML file level. |
| Same evaluator as your dashboards | ✓ "What you see on the dashboard is what fires." | Prometheus evaluates; small subtle differences from Grafana's read path possible. |
| Federation / very large fleets (Mimir, Thanos) | Works, but the eval engine is Grafana, which becomes a scaling axis. | ✓ Mature pattern: Prometheus + Mimir/Thanos + AM. |
| HA on the dispatcher | Grafana with shared DB; AM state in DB. | ✓ Battle-tested AM gossip cluster. |
| Recording rules | Lives in Mimir/Prometheus, *not* in Grafana. | ✓ Idiomatic. |
| What your SREs already know | If they know Grafana well, it's a small step. | If they know Prometheus+AM, the model is familiar. |
| Open-source-only stack? | Yes, Grafana OSS supports everything in this hands-on. | Yes. |

A reasonable default for a small team starting fresh today: **Grafana-managed alerts**, because the UI is friendlier, the per-folder permissions are real, and most small shops only have one or two datasources.

A reasonable default for a large platform team with an existing Prometheus + AM deployment: **keep it**, because you have a working routing tree, your SREs know the model, and the migration cost is non-trivial.

Mixing both is supported but creates the "two places to look" problem. Most teams that try mixing end up consolidating within six months.

---

## Cleanup

```bash
docker compose --profile stress down -v
```

The `--profile stress` flag is what makes `down` also remove the `cpu-stressor` container. `-v` removes the named volumes (`prometheus-data`, `grafana-data`) so the next run starts from a clean Grafana state — important if you've been clicking around the UI and want to start fresh from provisioning.

---

## Discussion questions

1. We set `instant: true` on every PromQL query in `rules.yaml`. What would change if we set `instant: false` instead, and why would Threshold then be wrong without a Reduce node in between?
2. The `severity=critical` route uses `continue: true`. What concrete alert path would fail if we removed it?
3. Why does Grafana have *two* concepts (silences + mute timings) when Alertmanager has only one (silences + `time_intervals`)? In what case would you use one over the other?
4. The Grafana SMTP relay is configured at the *server* level (env vars), but the recipient list is per *contact point*. What is the trade-off behind this split, and what would change if SMTP were configurable per contact point?
5. We deliberately left out inhibition rules. If you had to inhibit `HighCpuUtilization` whenever `TargetDown` fires for the same instance, where in the YAML would you add the rule, and what would the `equal:` clause look like?
6. The `noDataState` for `TargetDown` is `Alerting` and for `AppHighErrorRate` is `OK`. Walk through why each choice is correct *for that specific alert* — what would go wrong if you swapped them?

---

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| Grafana logs `failed to load file ".../alerting/rules.yaml": ...` | YAML structure invalid (most often: missing `model:` on a data entry, or `condition:` referring to a non-existent refId). | Validate the YAML against [Grafana's alert rule provisioning schema](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/). Match a known-good rule's shape exactly. |
| Rule appears in the UI but shows "Error" state with "input data does not match expected type" | Mismatch between `instant: true/false` and the downstream expression. With `instant: true`, the expression sees a scalar per series; without it, it sees a range. | Add `instant: true` to the query model, or insert a `reduce` node between A and the threshold. |
| Email contact point Test succeeds but real alerts never email | Notification policy doesn't actually route to `oncall-email`. Common cause: matcher typo (`Severity` vs `severity`, capital S). | Check **Alerting → Notification policies → Show matching alerts** for the alert's exact label set. Fix the matcher. |
| Slack contact point Test reports success but webhook-logger logs nothing | The compose network resolved `webhook-logger` correctly but the contact point still uses an old URL from a previous edit. | Restart Grafana (`docker compose restart grafana`) after editing `contact-points.yaml`, and check the contact point's URL field in the UI for the actually-loaded value. |
| Provisioned rule can be edited from the UI anyway | The `provenance` field was set to `none` or the rule group has `disableProvenance: true`. | Remove the override and reload. If you actually want UI edits, this is the correct state — just be aware your YAML is no longer the source of truth for that rule. |
| `for: 30s` rules take much longer than 30s to fire | The rule's `interval:` is longer than expected (default 1m). `for:` doesn't *start counting* until the first breached evaluation. So with `interval: 1m, for: 30s`, the rule fires at the second consecutive evaluation that breaches — somewhere between 1m and 2m after the threshold is breached. | Shorten `interval:` to `30s` (or less) if you need sharper alerting. |
| MailDev inbox stays empty when a critical alert fires | The Grafana SMTP env vars are wrong. Most common: `GF_SMTP_ENABLED` not set, or `GF_SMTP_HOST` pointing to `localhost` instead of `maildev` (which only works on the bridge network). | `docker compose exec grafana env | grep GF_SMTP` and confirm; fix in compose and restart. |
| Mute timing seems to never match | Server timezone mismatch. The Grafana container runs in UTC by default. | Add `TZ=Europe/Madrid` to the Grafana service env, or set `location: Europe/Madrid` on the mute timing entry. |
| Slack title or annotation renders as `[no value]` | The PromQL query groups by a label that does not exist on the source metric (e.g. `sum by (handler)` on a metric that only carries `code`/`method`). The alert still fires but `$labels.handler` is empty. | Query the source metric first (`http_requests_total` in the demo app exposes `{code, method}` only — *not* `handler`). Group the rule by a label that exists on that specific metric. |
| `DatasourceNoData` alerts fire during the first minute after `docker compose up` | Expected. The PromQL `rate()` window needs a full `[1m]` of data before returning a value. With `noDataState: NoData`, Grafana raises a synthetic `DatasourceNoData` alert that propagates the rule's labels but rewrites `alertname` to `DatasourceNoData` (the original alertname becomes `rulename`). | Either accept it (production rules are typically `noDataState: OK` for "metric only exists when there's traffic" rules, and `noDataState: NoData` only for "this metric must always be present" rules), or add a dedicated route at the top of the policy tree for `alertname=DatasourceNoData` so these go to a separate, lower-priority channel. |
| After editing a provisioned rule via the API, the file revision is "lost" on next restart | This is by design — provisioning re-applies the file content on startup, overwriting API changes. | Either always edit the file (and `git commit`) or set `disableProvenance: true` on the group to make the file purely seed data. |

## References

- [Grafana — Alerting overview](https://grafana.com/docs/grafana/latest/alerting/) — the entry point to the entire Alerting docs tree. Bookmark.
- [Grafana — Provision alerting resources](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/) — the canonical reference for the YAML shapes used in this folder.
- [Grafana — Manage contact points](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/) — the full catalogue of contact-point types and their per-type `settings:` keys.
- [Grafana — Notification policies](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/create-notification-policy/) — routing tree semantics, inheritance, matchers.
- [Grafana — Mute timings](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/mute-timings/) — recurring suppression windows.
- [Grafana — Templates for notifications](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/template-notifications/) — the Go template data model exposed to `title:` / `text:` / `message:`.
- [Grafana — Migrating from legacy alerting](https://grafana.com/docs/grafana/latest/alerting/set-up/migrating-alerts/) — useful even if you didn't run legacy alerting; the migration docs explain the data-graph model in passing.
