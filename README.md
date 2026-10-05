# Week 3: Retail microservices on AWS EKS

An online shop made of **12 microservices** (a fork of Google's Online Boutique, extended with an
inventory service and an event-driven order flow), running on **Amazon EKS** with separate **dev**
and **prod** environments, built and deployed entirely by **GitHub Actions** with no stored AWS keys.

| | |
|---|---|
| Shop (prod) | https://shop.sebngembou-cloud.click |
| Shop (dev) | https://dev.sebngembou-cloud.click |
| Grafana | https://grafana.sebngembou-cloud.click (only from `MONITORING_ALLOWED_CIDR`) |
| Region / account | us-east-1 |

> The addresses only answer while the infrastructure is up (`infra -> apply`, then `deploy`).
> It is destroyed at the end of every day to save cost.

![Architecture](docs/week3/architecture.png)

## What's inside

| Area | Choice | Details |
|---|---|---|
| Services | Go, C#, Java, Node.js, Python; gRPC between services | `src/` |
| Kubernetes | EKS, 4 x t3.medium, VPC CNI prefix delegation (110 pods/node), metrics-server | `terraform-aws/eks.tf` |
| Packaging | One Helm chart, values per environment | `helm-chart/` |
| Data | RDS MySQL 8.4 (orders, catalog; prod Multi-AZ), ElastiCache Redis (cart, catalog cache), DynamoDB (stock, notification log) | `terraform-aws/modules/environment/data.tf` |
| Events | EventBridge bus, one SQS queue + DLQ per consumer, order-status Lambda | `terraform-aws/modules/environment/events.tf` |
| Email | Amazon SES from `orders@<domain>` (DKIM), Slack `#boutique-orders` | `terraform-aws/ses.tf`, `src/emailservice/` |
| Entry point | One ALB per environment, HTTPS with an ACM certificate, Route 53 names | `helm-chart/templates/ingress.yaml`, `terraform-aws/dns.tf` |
| Scaling | HorizontalPodAutoscaler on the 5 busiest services | `helm-chart/templates/hpa.yaml` |
| Observability | Prometheus + Grafana (Prometheus and CloudWatch data sources), Container Insights logs, CloudWatch alarms -> Slack | `monitoring/`, [MONITORING.md](docs/week3/MONITORING.md) |
| Security | GitHub OIDC roles, Pod Identity per service, KMS, private data stores, NetworkPolicies, Checkov, ECR scan gate | [SECURITY.md](docs/week3/SECURITY.md) |

## The order flow

```
checkout ──OrderCreated──────────────► EventBridge ──► inventory-q ──────► inventoryservice (DynamoDB stock)
inventory ─InventoryReserved/Failed──► EventBridge ──► order-status-q ───► order-status Lambda (RDS order row)
order-status ─OrderStatusUpdated─────► EventBridge ──► notification-q ───► emailservice (SES email + Slack)
```

Each queue has a dead-letter queue (after 3 failed tries) and two alarms (DLQ not empty, oldest
message older than 5 minutes) that post to Slack `#boutique-alerts`. Consumers are idempotent:
a message delivered twice reserves stock or sends an email only once.

## Pipelines

| Workflow | When | What |
|---|---|---|
| `ci` | Every pull request | Unit tests, Helm render (must contain the HPAs), Docker build of changed services |
| `infra` | PR (plan, read-only role) / merge to `main` (apply) / manual (`destroy`) | Terraform + Checkov |
| `deploy` | Merge to `main` touching app code, or manual | Build 12 images (tag = commit SHA), ECR scan gate, deploy dev (migrations, Helm, HTTPS smoke test), approval, deploy prod, isolation test, monitoring |
| `cluster-status` | Manual | Pods, events, autoscalers, restarts, Helm history, per namespace |
| `order-flow` | Manual | Follows orders through RDS, DynamoDB, queues, Lambda and SES |
| `load-test` | Manual | Locust `load` (demo) or stepped `stress` test in dev |
| `chaos` | Manual | Deletes a pod, or stops the queue consumer, in dev; restores everything |
| `catalog` | Manual | Changes a price in MySQL to show the Redis cache at work |
| `isolation-test` | After prod, or manual | Proves dev can't reach prod (network and IAM) |
| `bootstrap` | Once | State bucket and the plan/deploy roles |

Git strategy: GitHub Flow, squash merges, `main` always deployable ([GITHUB-FLOW.md](docs/week3/GITHUB-FLOW.md)).

## Quick start

| Goal | Guide |
|---|---|
| Run it on your laptop (Docker Compose) | [LOCAL.md](docs/week3/LOCAL.md) |
| Connect GitHub to AWS (once) | [BOOTSTRAP.md](docs/week3/BOOTSTRAP.md) |
| Create the infrastructure and deploy | [SETUP.md](docs/week3/SETUP.md), [DEPLOY.md](docs/week3/DEPLOY.md) |
| Dashboards, load and stress tests | [MONITORING.md](docs/week3/MONITORING.md) |
| Slack channels | [SLACK.md](docs/week3/SLACK.md) |
| Dev / prod isolation | [ISOLATION.md](docs/week3/ISOLATION.md) |
| Something is broken | [RUNBOOK.md](docs/week3/RUNBOOK.md) |

Daily routine: **infra -> apply** (25-35 min), **deploy**, work, **infra -> destroy**.

## Repository layout

```
src/                  12 services (+ loadgenerator)
helm-chart/           Kubernetes manifests: values.yaml, values-aws.yaml, values-dev/prod.yaml
terraform-bootstrap/  State bucket and GitHub OIDC roles
terraform-aws/        VPC, EKS, ECR, DNS/ACM, SES, Slack, monitoring role, per-environment module
db/migrations/        MySQL schema and seed data
deploy/               Scripts the workflows run (diagnose, smoke/isolation tests, chaos, load test)
monitoring/           kube-prometheus-stack values, Grafana dashboards, ingress
docs/week3/           Guides, runbook, security notes, architecture diagram
docker-compose.yml    Local stack with Redis, MySQL and DynamoDB Local
```

## Proven results

| Test | Result |
|---|---|
| Stress test, before autoscaling | 0 errors, ~130 req/s, p95 ~8 s: frontend pinned at its CPU limit |
| Stress test, with HPA | Home page about 10x faster; next bottleneck found: recommendationservice and sticky gRPC connections |
| Rollback | Redeploying an older commit SHA brought the old version back (footer + Helm history) |
| Chaos: pod failure | checkoutservice pod deleted, new pod Ready in 5 s, 0 failed shop requests |
| Chaos: consumer down 8+ min | Backlog alarm red then green in Slack, queued orders processed after restart, DLQs at 0 |
| Isolation | dev -> prod services BLOCKED, dev role -> prod DynamoDB AccessDenied |
| Order email | SES email "Your order ... is confirmed" from `orders@sebngembou-cloud.click`, plus Slack message |
