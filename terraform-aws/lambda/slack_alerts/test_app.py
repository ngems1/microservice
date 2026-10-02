import json
import unittest

import app

ALARM = {
    "AlarmName": "week3-boutique-dev-order-status-dlq-not-empty",
    "AlarmDescription": "Messages for the order-status consumer are failing",
    "AlarmArn": "arn:aws:cloudwatch:us-east-1:111122223333:alarm:week3-boutique-dev-order-status-dlq-not-empty",
    "NewStateValue": "ALARM",
    "OldStateValue": "OK",
    "NewStateReason": "Threshold Crossed: 1 datapoint [1.0] was greater than 0.0",
    "StateChangeTime": "2026-10-02T16:00:00.000+0000",
}


def sns_event(message):
    return {"Records": [{"Sns": {"Message": message}}]}


class SlackAlertsTest(unittest.TestCase):
    def test_alarm_message(self):
        msg = app.slack_message(ALARM)
        self.assertIn("ALARM: week3-boutique-dev-order-status-dlq-not-empty", msg["text"])
        body = msg["attachments"][0]
        self.assertEqual(body["color"], app.COLORS["ALARM"])
        self.assertIn("*Environment:* dev", body["text"])
        self.assertIn("region=us-east-1#alarmsV2:alarm/week3-boutique-dev-order-status-dlq-not-empty", body["text"])

    def test_ok_is_green(self):
        msg = app.slack_message(dict(ALARM, NewStateValue="OK", OldStateValue="ALARM"))
        self.assertEqual(msg["attachments"][0]["color"], app.COLORS["OK"])

    def test_posts_each_alarm(self):
        sent = []
        app.handler(sns_event(json.dumps(ALARM)), None,
                    get_url=lambda: "https://hooks.slack.com/services/x", send=lambda u, p: sent.append(p))
        self.assertEqual(len(sent), 1)

    def test_no_webhook_skips(self):
        sent = []
        app.handler(sns_event(json.dumps(ALARM)), None, get_url=lambda: None, send=lambda u, p: sent.append(p))
        self.assertEqual(sent, [])

    def test_non_json_message(self):
        sent = []
        app.handler(sns_event("plain text"), None,
                    get_url=lambda: "https://hooks.slack.com/services/x", send=lambda u, p: sent.append(p))
        self.assertIn("plain text", sent[0]["attachments"][0]["text"])


if __name__ == "__main__":
    unittest.main()
