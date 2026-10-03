# Monitoring: Prometheus + Grafana

| Piece | Where | What it does |
|---|---|---|
| **Prometheus** | namespace `monitoring` (kube-prometheus-stack) | Scrapes pods (CPU, memory, restarts, readiness), nodes, and the services that expose `/metrics`: inventoryservice (orders reserved / failed / duplicate, processing time) and productcatalogservice (cache hits / misses, MySQL and Redis errors). 24 h of history. |
| **Grafana** | same namespace, its own ALB | Dashboards. Data sources: Prometheus, and **CloudWatch** (ALB, SQS, RDS) through a read-only Pod Identity role (`terraform-aws/monitoring.tf`). |
| **Alerts** | CloudWatch alarms → SNS → Slack `#boutique-alerts` | Unchanged (docs/week3/SLACK.md). Alertmanager is not used. |

Installed and updated by the **deploy** workflow (job `monitoring`, after dev), from:
`monitoring/kube-prometheus-stack.values.yaml`, `monitoring/dashboards/*.json`, `monitoring/grafana-ingress.yaml`, `deploy/monitoring.sh`.

## One-time setup (2 GitHub settings)

**Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
|---|---|---|
| Secret | `GRAFANA_ADMIN_PASSWORD` | A strong password for the Grafana `admin` user |
| Variable | `MONITORING_ALLOWED_CIDR` | Your public IP + `/32`, e.g. `203.0.113.7/32` (search "what is my ip"). Several: comma separated. `0.0.0.0/0` is refused. |

Without the secret, the `monitoring` job is skipped. Without the variable, Grafana runs but has no address.
If your IP changes (home / office), update the variable and re-run **deploy** (or the next deploy picks it up).

## Open Grafana

1. The **deploy** run's Summary (job `monitoring`) and the Slack deploy message show `Grafana: http://boutique-monitoring-....elb.amazonaws.com`. A new ALB needs 2-3 minutes before it answers.
2. Log in: `admin` / your `GRAFANA_ADMIN_PASSWORD`.
3. **Dashboards → Browse → Boutique: platform overview**. The chart's own *Kubernetes / Compute Resources* dashboards are there too.

## The Boutique dashboard

| Row | Panels | Source |
|---|---|---|
| **SLIs** | Availability (non-5xx %, SLO 99.5%), p95 latency (SLO 1 s), order success rate, pods not ready, for dev and prod | CloudWatch (ALB), Prometheus |
| **Shop traffic** | Requests/min, 5xx (shop vs ALB), latency p95/p50 | CloudWatch (ALB) |
| **Application** | Catalog cache hit rate, MySQL loads and errors, orders reserved / failed / duplicate, inventory processing p95 and errors | Prometheus |
| **Event flow** | Messages waiting per queue, dead-letter queues | CloudWatch (SQS) |
| **Kubernetes** | CPU and memory per pod, restarts, node CPU and memory | Prometheus |
| **Databases** | RDS CPU, connections, free storage, read/write latency | CloudWatch (RDS) |

## Load test (makes the dashboard move)

**Actions → load-test → Run workflow**: shoppers (5-50), duration (5-30 min), restock (dev stock back to 50, the Mug stays at 2 so some orders fail). It runs Locust (the loadgenerator image) against the **dev** shop and **stops by itself**; the Locust summary (requests, failures, latency) is on the run's Summary page. The orders are real: they go through the whole event flow.

## Cost and capacity

A t3.medium runs at most 17 pods (VPC CNI). Monitoring adds about 8 pods, so the cluster has **4 nodes** (`node_desired_size`). On a running cluster, Terraform does not change the node count of the existing node group: the 4th node arrives with the next `infra → destroy` + `apply`.
Extra cost while running: the 4th node (~$1/day) and Grafana's ALB (~$0.55/day).

## Troubleshooting

| Symptom | Check |
|---|---|
| `monitoring` job skipped | The `GRAFANA_ADMIN_PASSWORD` secret is missing |
| Grafana URL times out | Your IP is not in `MONITORING_ALLOWED_CIDR`, or the ALB is still starting (2-3 min) |
| CloudWatch panels empty | Grafana pod restarted after the Pod Identity link? `kubectl -n monitoring rollout restart deploy/monitoring-grafana` (or re-run deploy). ALB metrics only appear once the shop gets traffic. |
| Application panels empty | Prometheus → Status → Targets: job `kubernetes-pods` should list inventoryservice and productcatalogservice as UP |
| Pods `Pending` | Not enough pod slots: the cluster needs its 4th node (see above) |
