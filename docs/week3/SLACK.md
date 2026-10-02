# Slack notifications

Two kinds of messages go to Slack:

| What | From | How |
|---|---|---|
| **Pipeline:** prod waiting for approval, deploy result (build, dev, prod, isolation test, shop links), infra apply/destroy result | GitHub Actions | Incoming webhook, called by `deploy/notify-slack.sh` |
| **AWS alarms:** a dead-letter queue has messages, a queue is backing up, the order-status Lambda fails (dev and prod) | CloudWatch → SNS topic per environment → `slack-alerts` Lambda → Slack | Same incoming webhook, read from Secrets Manager, `terraform-aws/slack.tf` |

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

## 2. AWS alarms (nothing more to set up)

Once `SLACK_WEBHOOK_URL` is set (section 1), alarms use the same webhook:

```
CloudWatch alarm -> SNS topic (dev / prod) -> week3-boutique-slack-alerts Lambda -> Slack
```

- Terraform creates the Lambda, an **empty** Secrets Manager secret `week3-boutique/slack-webhook-url`, and subscribes the Lambda to both environments' alarm topics.
- After every `infra` apply, the workflow step **Store the Slack webhook for alarms** copies the GitHub secret into that Secrets Manager secret (only when it changed). The URL is never in the code, the Terraform state or the Lambda's settings.
- So: set the GitHub secret, run **infra → apply** once. It keeps working after every destroy / apply.

Messages: :red_circle: **ALARM** when an alarm fires, :large_green_circle: **OK** when it recovers, with the environment, the reason and a link to the alarm in CloudWatch.

| Alarm | Fires when |
|---|---|
| `week3-boutique-<env>-<flow>-dlq-not-empty` | A message failed 3 times and is in a dead-letter queue |
| `week3-boutique-<env>-<flow>-backlog` | A queue is backing up |
| `week3-boutique-<env>-order-status-lambda-errors` | The order-status Lambda throws errors |

Why not Amazon Q Developer in chat applications (AWS Chatbot)? Its one-time Slack authorization needs `chatbot:*` permissions in the console, which this account's IAM user doesn't have. The Lambda route needs only what the pipeline already has.

### Test an alarm (console only)

Send an order that doesn't exist: **EventBridge → Event buses → Send events**, bus `week3-boutique-dev-events`, source `boutique.checkout`, detail type `OrderCreated`, detail:

```json
{"version":"1","orderId":"console-test-001","email":"someone@example.com","items":[{"productId":"OLJCESPC7Z","quantity":1}]}
```

inventoryservice reserves it, the order-status Lambda can't find it in MySQL and fails 3 times, the message lands in `week3-boutique-dev-order-status-dlq`. Within about 5 minutes Slack shows **ALARM** for `...-order-status-lambda-errors` and `...-order-status-dlq-not-empty`.

Clean up: **SQS → order-status-dlq → Purge** (the alarm goes back to OK and Slack shows it), then in DynamoDB set `PRODUCT#OLJCESPC7Z` stock back and delete `RESERVATION#console-test-001`.

If nothing arrives: **Lambda → week3-boutique-slack-alerts → Monitor → View CloudWatch logs**. `no Slack webhook stored` means the GitHub secret is missing or infra wasn't applied after adding it.

## Security notes

- The webhook URL is stored as a GitHub **secret**, never in the code.
- The `slack-alerts` Lambda's role can only write its own logs and read that one secret. The webhook URL is copied into Secrets Manager by the workflow, so it is never in the Terraform state.
- A Slack failure never fails a deployment (`notify-slack.sh` always exits 0).
