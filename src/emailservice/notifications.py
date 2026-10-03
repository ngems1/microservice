"""Week 3: order notifications from the event flow (step 4).

  order-status Lambda --OrderStatusUpdated--> EventBridge --> notification-q --> here

For every final order status (CONFIRMED or FAILED) the customer gets exactly one
email, and every email is logged in the DynamoDB notifications table:

  notificationId = <orderId>#<status>   (one notification per order and status)

Never twice: the log row is written FIRST, with a condition "only if it does not
exist yet". If the same event arrives twice (SQS delivers at least once), the
condition fails, the duplicate is skipped and the message deleted.

Delivery is "log" mode: the email is rendered and written to the service log
instead of being sent. A real provider (Amazon SES) would plug in at send(); the
row would then be written as PENDING and marked SENT after the provider accepts it,
so a failed send can be retried.

Failures: an invalid event or an AWS error leaves the message in the queue; it is
retried and, after 3 tries, moved to the dead-letter queue (CloudWatch alarm -> Slack).
This module has no boto3 import, so the tests run without AWS.
"""
import json
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

SCHEMA_VERSION = "1"
EVENT_TYPE = "OrderStatusUpdated"
STATUSES = ("CONFIRMED", "FAILED")
DELIVERY_MODE = "log"


class InvalidEvent(Exception):
    """The message can't be processed. Retried, then moved to the dead-letter queue."""


@dataclass
class OrderStatus:
    order_id: str
    status: str
    reason: str = ""
    email: str = ""
    product_ids: list = field(default_factory=list)
    event_id: str = ""

    @property
    def notification_id(self):
        return f"{self.order_id}#{self.status}"


def parse_message(body):
    """SQS message body (an EventBridge event) -> OrderStatus."""
    try:
        event = json.loads(body)
    except (TypeError, ValueError) as exc:
        raise InvalidEvent(f"not JSON: {exc}") from exc
    if not isinstance(event, dict):
        raise InvalidEvent("event is not a JSON object")
    if event.get("detail-type") != EVENT_TYPE:
        raise InvalidEvent(f"unexpected event type {event.get('detail-type')!r}")
    detail = event.get("detail") or {}
    if str(detail.get("version", "")) != SCHEMA_VERSION:
        raise InvalidEvent(f"unsupported {EVENT_TYPE} version {detail.get('version')!r}")
    order_id = str(detail.get("orderId") or "")
    status = str(detail.get("status") or "")
    if not order_id:
        raise InvalidEvent(f"{EVENT_TYPE} without orderId")
    if status not in STATUSES:
        raise InvalidEvent(f"unexpected order status {status!r}")
    return OrderStatus(
        order_id=order_id,
        status=status,
        reason=str(detail.get("reason") or ""),
        email=str(detail.get("email") or ""),
        product_ids=[str(p) for p in detail.get("productIds") or []],
        event_id=str(event.get("id") or ""),
    )


def mask_email(address):
    """someone@example.com -> s*****e@example.com (the log never holds full addresses)."""
    if "@" not in address:
        return ""
    user, domain = address.split("@", 1)
    if len(user) <= 2:
        return f"{user[:1]}*@{domain}"
    return f"{user[0]}{'*' * (len(user) - 2)}{user[-1]}@{domain}"


def render_email(order):
    """(subject, body) for one order status."""
    short = order.order_id.split("-")[0]
    if order.status == "CONFIRMED":
        subject = f"Your order {short} is confirmed"
        body = ("Thank you for your order!\n\n"
                "All your items are reserved and your order is being prepared for shipping.\n\n"
                f"Order ID: {order.order_id}\n")
    else:
        products = ", ".join(order.product_ids) or "some items"
        reason = "out of stock" if order.reason == "INSUFFICIENT_STOCK" else (order.reason or "not available")
        subject = f"We couldn't complete your order {short}"
        body = ("We're sorry, we couldn't complete your order.\n\n"
                f"Reason: {reason} ({products}).\n"
                "Any payment for this order will be refunded.\n\n"
                f"Order ID: {order.order_id}\n")
    return subject, body


def _error_code(exc):
    return getattr(exc, "response", {}).get("Error", {}).get("Code", "")


class NotificationLog:
    """The DynamoDB notifications table."""

    def __init__(self, dynamodb_client, table_name):
        self.ddb = dynamodb_client
        self.table = table_name

    def claim(self, order, subject):
        """Write the log row if this notification is new. False = already sent (duplicate)."""
        item = {
            "notificationId": {"S": order.notification_id},
            "orderId": {"S": order.order_id},
            "status": {"S": order.status},
            "channel": {"S": "email"},
            "delivery": {"S": DELIVERY_MODE},
            "recipient": {"S": mask_email(order.email)},
            "subject": {"S": subject},
            "sentAt": {"S": datetime.now(timezone.utc).isoformat(timespec="seconds")},
        }
        if order.reason:
            item["reason"] = {"S": order.reason}
        if order.event_id:
            item["eventId"] = {"S": order.event_id}
        try:
            self.ddb.put_item(TableName=self.table, Item=item,
                              ConditionExpression="attribute_not_exists(notificationId)")
            return True
        except Exception as exc:  # noqa: BLE001
            if _error_code(exc) == "ConditionalCheckFailedException":
                return False
            raise


def send(logger, order, subject, body):
    """Log-mode delivery: the rendered email goes to the service log."""
    logger.info("email sent", extra={
        "orderId": order.order_id, "status": order.status, "to": mask_email(order.email),
        "subject": subject, "delivery": DELIVERY_MODE, "body": body})


def handle(body, log_table, logger):
    """Process one message. Returns 'sent', 'duplicate' or 'no-email'. Raises to retry."""
    order = parse_message(body)
    subject, text = render_email(order)
    if not log_table.claim(order, subject):
        logger.info("duplicate event, email already sent",
                    extra={"orderId": order.order_id, "status": order.status})
        return "duplicate"
    if not order.email:
        logger.warning("no email address on the order, nothing sent",
                       extra={"orderId": order.order_id, "status": order.status})
        return "no-email"
    send(logger, order, subject, text)
    return "sent"


class Consumer:
    """Long-polls notification-q; deletes a message only once it is handled."""

    def __init__(self, sqs, queue_url, log_table, logger):
        self.sqs, self.queue_url, self.log_table, self.logger = sqs, queue_url, log_table, logger
        self.last_poll = 0.0
        self.stopping = False

    def healthy(self, max_silence=90):
        return time.time() - self.last_poll < max_silence

    def poll_once(self, wait_seconds=20):
        self.last_poll = time.time()
        resp = self.sqs.receive_message(QueueUrl=self.queue_url, MaxNumberOfMessages=10,
                                        WaitTimeSeconds=wait_seconds,
                                        AttributeNames=["ApproximateReceiveCount"])
        results = []
        for msg in resp.get("Messages", []):
            try:
                results.append(handle(msg["Body"], self.log_table, self.logger))
                self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=msg["ReceiptHandle"])
            except InvalidEvent as exc:
                self.logger.error("invalid message, will retry then go to the DLQ",
                                  extra={"error": str(exc), "messageId": msg.get("MessageId")})
                results.append("invalid")
            except Exception as exc:  # noqa: BLE001 - AWS errors: the message is retried
                self.logger.exception("processing failed, message will be retried",
                                      extra={"error": str(exc), "messageId": msg.get("MessageId")})
                results.append("error")
        return results

    def run(self):
        self.logger.info("notification consumer started", extra={"queue": self.queue_url})
        while not self.stopping:
            try:
                self.poll_once()
            except Exception as exc:  # noqa: BLE001 - keep polling, AWS hiccups are transient
                self.logger.exception("receive_message failed", extra={"error": str(exc)})
                time.sleep(5)
