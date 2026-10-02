"""slack-alerts Lambda: CloudWatch alarm (via SNS) -> Slack message.

Every alarm topic (one per environment) is subscribed to this function. It turns
the alarm into a short Slack message (red for ALARM, green for OK) and posts it to
the incoming webhook stored in Secrets Manager (SLACK_SECRET_ARN). The webhook URL
is written there by the infra workflow, so it never appears in code, Terraform
state or this function's settings.

No webhook stored yet -> the alarm is logged and skipped (nothing fails).
"""
import json
import logging
import os
import time
import urllib.parse
import urllib.request

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

_cache = {"url": None, "at": 0.0}
CACHE_SECONDS = 300

COLORS = {"ALARM": "#d93025", "OK": "#1e8e3e", "INSUFFICIENT_DATA": "#9aa0a6"}
ICONS = {"ALARM": ":red_circle:", "OK": ":large_green_circle:", "INSUFFICIENT_DATA": ":white_circle:"}


def webhook_url():
    """The webhook URL from Secrets Manager (cached for a few minutes), or None."""
    if _cache["url"] and time.time() - _cache["at"] < CACHE_SECONDS:
        return _cache["url"]
    client = boto3.client("secretsmanager")
    try:
        value = client.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])["SecretString"].strip()
    except client.exceptions.ResourceNotFoundException:
        return None  # the secret exists but no value was stored yet
    if not value.startswith("https://hooks.slack.com/"):
        raise ValueError("the stored Slack webhook URL is not a hooks.slack.com URL")
    _cache.update(url=value, at=time.time())
    return value


def console_link(region, alarm_name):
    return (f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}"
            f"#alarmsV2:alarm/{urllib.parse.quote(alarm_name, safe='')}")


def slack_message(alarm):
    """Slack payload for one CloudWatch alarm notification (the SNS message body)."""
    name = alarm.get("AlarmName", "unknown alarm")
    state = alarm.get("NewStateValue", "UNKNOWN")
    old = alarm.get("OldStateValue", "")
    region = (alarm.get("AlarmArn", "").split(":")[3:4] or [os.environ.get("AWS_REGION", "us-east-1")])[0]
    env = "prod" if "-prod-" in name else "dev" if "-dev-" in name else "-"
    lines = [alarm.get("AlarmDescription") or "",
             f"*Environment:* {env}    *State:* {old} -> {state}",
             f"*Reason:* {alarm.get('NewStateReason', '')}",
             f"<{console_link(region, name)}|Open the alarm in CloudWatch>"]
    return {
        "text": f"{ICONS.get(state, '')} {state}: {name}",
        "attachments": [{"color": COLORS.get(state, "#9aa0a6"),
                         "text": "\n".join(line for line in lines if line),
                         "footer": alarm.get("StateChangeTime", "")}],
    }


def post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310 (fixed https host, checked above)
        return resp.status


def handler(event, context, get_url=webhook_url, send=post):
    url = get_url()
    for record in event.get("Records", []):
        raw = record.get("Sns", {}).get("Message", "{}")
        try:
            alarm = json.loads(raw)
        except json.JSONDecodeError:
            alarm = {"AlarmName": "SNS message", "NewStateValue": "INSUFFICIENT_DATA", "NewStateReason": raw}
        payload = slack_message(alarm)
        if not url:
            log.warning(json.dumps({"msg": "no Slack webhook stored, alarm not sent", "alarm": payload["text"]}))
            continue
        send(url, payload)  # an error here makes SNS retry the delivery
        log.info(json.dumps({"msg": "alarm sent to Slack", "alarm": payload["text"]}))
