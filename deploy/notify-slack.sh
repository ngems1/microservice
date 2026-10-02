#!/usr/bin/env bash
# Posts one message to Slack through an incoming webhook.
#   notify-slack.sh <good|warning|danger> "<title>" "<text>"
# Does nothing when SLACK_WEBHOOK_URL is empty, and never fails the pipeline:
# a Slack problem must not block a deployment.
set -u
color="${1:-good}"; title="${2:-}"; text="${3:-}"

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "SLACK_WEBHOOK_URL not set: no Slack message."
  exit 0
fi

case "$color" in
  good)    hex="#2eb67d" ;;
  warning) hex="#ecb22e" ;;
  danger)  hex="#e01e5a" ;;
  *)       hex="$color" ;;
esac

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
payload=$(jq -n \
  --arg color "$hex" --arg title "$title" --arg text "$text" --arg link "$run_url" \
  --arg footer "${GITHUB_REPOSITORY:-} · ${GITHUB_WORKFLOW:-} · by ${GITHUB_ACTOR:-}" '
  { attachments: [ {
      color: $color, title: $title, title_link: $link, text: $text,
      footer: $footer, mrkdwn_in: ["text"]
  } ] }')

curl -sS --max-time 10 -X POST -H 'Content-type: application/json' \
  --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null \
  && echo "Slack message sent." \
  || echo "::warning::Could not post to Slack (continuing)."
exit 0
