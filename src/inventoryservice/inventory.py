"""Inventory logic: stock levels and order reservations in one DynamoDB table.

Table layout (partition key "pk", string):
  PRODUCT#<productId>      -> {"stock": N}
  RESERVATION#<orderId>    -> {"status": RESERVED|FAILED, "items": ..., "reason": ...}

A reservation is ONE DynamoDB transaction:
  - create RESERVATION#<orderId> only if it does not exist yet   (idempotency)
  - for every product: stock = stock - qty only if stock >= qty   (no overselling)
Either everything is applied or nothing is. A redelivered OrderCreated finds the
existing reservation and returns the same result again instead of reserving twice.
"""
import json
import time
from dataclasses import dataclass, field

PRODUCT = "PRODUCT#"
RESERVATION = "RESERVATION#"
EVENT_SOURCE = "boutique.inventory"
SCHEMA_VERSION = "1"


class InvalidEvent(Exception):
    """The message cannot be processed. It is retried, then lands in the dead-letter queue."""


def _error_code(exc):
    return getattr(exc, "response", {}).get("Error", {}).get("Code", "")


@dataclass
class Reservation:
    order_id: str
    status: str  # RESERVED or FAILED
    items: list = field(default_factory=list)
    reason: str = ""
    failed_products: list = field(default_factory=list)
    duplicate: bool = False


class InventoryStore:
    def __init__(self, dynamodb_client, table_name):
        self.ddb = dynamodb_client
        self.table = table_name

    # ------------------------------------------------------------------ stock
    def seed(self, stock_by_product):
        """Create stock rows that do not exist yet. Never overwrites existing stock."""
        created = 0
        for product_id, qty in stock_by_product.items():
            try:
                self.ddb.put_item(
                    TableName=self.table,
                    Item={"pk": {"S": PRODUCT + product_id}, "stock": {"N": str(int(qty))}},
                    ConditionExpression="attribute_not_exists(pk)",
                )
                created += 1
            except Exception as exc:  # noqa: BLE001
                if _error_code(exc) != "ConditionalCheckFailedException":
                    raise
        return created

    def get_stock(self, product_id):
        resp = self.ddb.get_item(
            TableName=self.table, Key={"pk": {"S": PRODUCT + product_id}}, ConsistentRead=True
        )
        item = resp.get("Item")
        return int(item["stock"]["N"]) if item else None

    def list_stock(self):
        result, kwargs = {}, {
            "TableName": self.table,
            "FilterExpression": "begins_with(pk, :p)",
            "ExpressionAttributeValues": {":p": {"S": PRODUCT}},
        }
        while True:
            resp = self.ddb.scan(**kwargs)
            for item in resp.get("Items", []):
                result[item["pk"]["S"][len(PRODUCT):]] = int(item["stock"]["N"])
            if "LastEvaluatedKey" not in resp:
                return result
            kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    # ------------------------------------------------------------ reservation
    def get_reservation(self, order_id):
        resp = self.ddb.get_item(
            TableName=self.table, Key={"pk": {"S": RESERVATION + order_id}}, ConsistentRead=True
        )
        item = resp.get("Item")
        if not item:
            return None
        return Reservation(
            order_id=order_id,
            status=item["status"]["S"],
            items=json.loads(item.get("items", {}).get("S", "[]")),
            reason=item.get("reason", {}).get("S", ""),
            failed_products=json.loads(item.get("failedProducts", {}).get("S", "[]")),
            duplicate=True,
        )

    def reserve(self, order_id, items):
        """Reserve all items of an order, or none of them."""
        merged = {}
        for it in items:
            pid, qty = str(it.get("productId", "")), int(it.get("quantity", 0))
            if not pid or qty <= 0:
                raise InvalidEvent(f"bad item in order {order_id}: {it}")
            merged[pid] = merged.get(pid, 0) + qty
        if not merged:
            raise InvalidEvent(f"order {order_id} has no items")
        if len(merged) > 99:
            raise InvalidEvent(f"order {order_id} has too many distinct products")

        lines = [{"productId": p, "quantity": q} for p, q in merged.items()]
        now = str(int(time.time()))
        actions = [{
            "Put": {
                "TableName": self.table,
                "Item": {
                    "pk": {"S": RESERVATION + order_id},
                    "status": {"S": "RESERVED"},
                    "items": {"S": json.dumps(lines)},
                    "createdAt": {"N": now},
                },
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        }]
        for pid, qty in merged.items():
            actions.append({
                "Update": {
                    "TableName": self.table,
                    "Key": {"pk": {"S": PRODUCT + pid}},
                    "UpdateExpression": "SET stock = stock - :q",
                    "ConditionExpression": "attribute_exists(pk) AND stock >= :q",
                    "ExpressionAttributeValues": {":q": {"N": str(qty)}},
                }
            })

        try:
            self.ddb.transact_write_items(TransactItems=actions)
            return Reservation(order_id, "RESERVED", lines)
        except Exception as exc:  # noqa: BLE001
            if _error_code(exc) != "TransactionCanceledException":
                raise
            reasons = getattr(exc, "response", {}).get("CancellationReasons", [])
            codes = [r.get("Code", "None") for r in reasons]

        # 1) The reservation row already exists: this event was processed before.
        if codes and codes[0] == "ConditionalCheckFailed":
            existing = self.get_reservation(order_id)
            if existing:
                return existing
        # 2) One or more products are unknown or do not have enough stock.
        failed = [lines[i - 1]["productId"] for i, c in enumerate(codes) if i > 0 and c == "ConditionalCheckFailed"]
        if not failed:
            raise RuntimeError(f"reservation for {order_id} cancelled for another reason: {codes}")
        return self._record_failure(order_id, lines, failed)

    def _record_failure(self, order_id, lines, failed):
        try:
            self.ddb.put_item(
                TableName=self.table,
                Item={
                    "pk": {"S": RESERVATION + order_id},
                    "status": {"S": "FAILED"},
                    "reason": {"S": "INSUFFICIENT_STOCK"},
                    "items": {"S": json.dumps(lines)},
                    "failedProducts": {"S": json.dumps(failed)},
                    "createdAt": {"N": str(int(time.time()))},
                },
                ConditionExpression="attribute_not_exists(pk)",
            )
        except Exception as exc:  # noqa: BLE001
            if _error_code(exc) != "ConditionalCheckFailedException":
                raise
            return self.get_reservation(order_id)  # another worker recorded it first
        return Reservation(order_id, "FAILED", lines, "INSUFFICIENT_STOCK", failed)


# ---------------------------------------------------------------------- events
def parse_order_created(sqs_body):
    """SQS body = the EventBridge event. Returns (order_id, items)."""
    try:
        event = json.loads(sqs_body)
    except (TypeError, ValueError) as exc:
        raise InvalidEvent(f"message is not JSON: {exc}") from exc
    if event.get("detail-type") != "OrderCreated":
        raise InvalidEvent(f"unexpected event type: {event.get('detail-type')}")
    detail = event.get("detail") or {}
    if str(detail.get("version", "")) != SCHEMA_VERSION:
        raise InvalidEvent(f"unsupported OrderCreated version: {detail.get('version')}")
    order_id = detail.get("orderId")
    if not order_id:
        raise InvalidEvent("OrderCreated without orderId")
    return str(order_id), detail.get("items") or []


def result_event(res):
    """Build the event to publish for a reservation result: (detail-type, detail)."""
    if res.status == "RESERVED":
        return "InventoryReserved", {"version": SCHEMA_VERSION, "orderId": res.order_id, "items": res.items}
    return "InventoryFailed", {
        "version": SCHEMA_VERSION,
        "orderId": res.order_id,
        "reason": res.reason or "INSUFFICIENT_STOCK",
        "productIds": res.failed_products,
    }


def publish(events_client, bus_name, detail_type, detail):
    resp = events_client.put_events(Entries=[{
        "Source": EVENT_SOURCE,
        "DetailType": detail_type,
        "Detail": json.dumps(detail),
        "EventBusName": bus_name,
    }])
    if resp.get("FailedEntryCount", 0):
        raise RuntimeError(f"PutEvents failed: {resp.get('Entries')}")


def parse_stock_overrides(text):
    """'6E92ZMYYFZ:2,OLJCESPC7Z:5' -> {'6E92ZMYYFZ': 2, 'OLJCESPC7Z': 5}"""
    out = {}
    for part in filter(None, (p.strip() for p in (text or "").split(","))):
        pid, _, qty = part.partition(":")
        out[pid.strip()] = int(qty)
    return out


# The 9 products in src/productcatalogservice/products.json
CATALOG_PRODUCT_IDS = [
    "OLJCESPC7Z", "66VCHSJNUP", "1YMWWN1N4O", "L9ECAV7KIM", "2ZYFJ3GM2N",
    "0PUK6V6EV0", "LS4PSXUNUM", "9SIQT8TOJO", "6E92ZMYYFZ",
]
