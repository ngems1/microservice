# Slack notifications

Two kinds of messages go to Slack:

| What | From | How |
|---|---|---|
| **Pipeline:** prod waiting for approval, deploy result (build, dev, prod, isolation test, shop links), infra apply/destroy result | GitHub Actions | Incoming webhook, called by `deploy/notify-slack.sh` |
| **AWS alarms:** a dead-letter queue has messages, a queue is backing up, the order-status Lambda fails (dev and prod) | CloudWatch → SNS topic per environment → Slack | Amazon Q Developer in chat applications (formerly AWS Chatbot), `terraform-aws/slack.tf` |

Both are optional. Until they are set up, nothing is sent and nothing fails.

## 1. Pipeline messages (5 minutes)

1. Slack: create a channel, for example `#week3-boutique`.
2. Go to **api.slack.com/apps → Create New App → From scratch**. Name it `week3-pipeline` and pick your workspace.
3. **Incoming Webhooks** → turn it **On** → **Add New Webhook to Workspace** → choose `#week3-boutique` → **Allow**.
4. Copy the webhook URL (`https://hooks.slack.com/services/...`). **It's a secret**: anyone with it can post to your channel.
5. GitHub: **Settings → Secrets and variables → Actions → Secrets tab → New repository secret**
   - Name: `SLACK_WEBHOOK_URL`
   - Value: the URL

The next `deploy` or `infra apply` run posts to the channel.

## 2. AWS alarms (10 minutes)

1. AWS console, switch the region to **US East (Ohio) us-east-2**. This service's console only works there; the alarms themselves stay in us-east-1.
2. Search for **Amazon Q Developer in chat applications** → **Configure new client** → **Slack** → **Configure** → **Allow** (you're the workspace admin).
3. Copy the **Workspace ID** shown for your workspace (starts with `T`).
4. Slack: right-click the channel → **View channel details** → at the bottom, copy the **Channel ID** (starts with `C`). For a private channel, also type `/invite @Amazon Q` in it.
5. GitHub: **Settings → Secrets and variables → Actions → Variables tab**, add two repository variables:
   - `SLACK_TEAM_ID` = the workspace ID
   - `SLACK_CHANNEL_ID` = the channel ID
6. Run **infra → apply**. Terraform creates the Slack channel configuration and subscribes it to the dev and prod alarm topics.

Don't create the channel configuration by hand in the console: Terraform creates it, and a manual one would be a duplicate.

### Test an alarm (CloudShell, us-east-1)

```bash
aws cloudwatch set-alarm-state \
  --alarm-name week3-boutique-dev-inventory-dlq-not-empty \
  --state-value ALARM --state-reason "Slack test"
```

The message arrives in Slack within a minute. The alarm goes back to OK by itself at the next check, and that sends an "OK" message too.

## Security notes

- The webhook URL is stored as a GitHub **secret**, never in the code.
- The Slack integration's AWS role (`week3-boutique-slack-alerts`) and its guardrail only allow **reading** CloudWatch: nobody can change AWS resources from Slack.
- A Slack failure never fails a deployment (`notify-slack.sh` always exits 0).
