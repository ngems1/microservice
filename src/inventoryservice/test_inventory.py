"""Unit tests for the inventory logic. Run: python -m unittest -v

Uses an in-memory fake of the DynamoDB calls, so no AWS account or boto3 is needed.
"""
import json
import unittest

import inventory as inv


class FakeAwsError(Exception):
    def __init__(self, code, **extra):
        super().__init__(code)
        self.response = {"Error": {"Code": code}, **extra}


class FakeDynamo:
    """Implements just the calls and condition expressions inventory.py uses."""

    def __init__(self):
        self.items = {}

    def put_item(self, TableName, Item, ConditionExpression=None):
        pk = Item["pk"]["S"]
        if ConditionExpression == "attribute_not_exists(pk)" and pk in self.items:
            raise FakeAwsError("ConditionalCheckFailedException")
        self.items[pk] = dict(Item)

    def get_item(self, TableName, Key, ConsistentRead=False):
        item = self.items.get(Key["pk"]["S"])
        return {"Item": dict(item)} if item else {}

    def scan(self, TableName, FilterExpression, ExpressionAttributeValues, **_):
        prefix = ExpressionAttributeValues[":p"]["S"]
        return {"Items": [dict(v) for k, v in self.items.items() if k.startswith(prefix)]}

    def transact_write_items(self, TransactItems):
        codes = []
        for action in TransactItems:
            if "Put" in action:
                pk = action["Put"]["Item"]["pk"]["S"]
                codes.append("ConditionalCheckFailed" if pk in self.items else "None")
            else:
                upd = action["Update"]
                pk = upd["Key"]["pk"]["S"]
                qty = int(upd["ExpressionAttributeValues"][":q"]["N"])
                ok = pk in self.items and int(self.items[pk]["stock"]["N"]) >= qty
                codes.append("None" if ok else "ConditionalCheckFailed")
        if any(c != "None" for c in codes):
            raise FakeAwsError("TransactionCanceledException", CancellationReasons=[{"Code": c} for c in codes])
        for action in TransactItems:  # all conditions passed: apply everything
            if "Put" in action:
                self.items[action["Put"]["Item"]["pk"]["S"]] = dict(action["Put"]["Item"])
            else:
                upd = action["Update"]
                row = self.items[upd["Key"]["pk"]["S"]]
                row["stock"] = {"N": str(int(row["stock"]["N"]) - int(upd["ExpressionAttributeValues"][":q"]["N"]))}


class FakeEvents:
    def __init__(self, fail=False):
        self.sent, self.fail = [], fail

    def put_events(self, Entries):
        if self.fail:
            return {"FailedEntryCount": 1, "Entries": [{"ErrorCode": "InternalFailure"}]}
        self.sent.extend(Entries)
        return {"FailedEntryCount": 0}


def order_created(order_id, items, version="1"):
    return json.dumps({"detail-type": "OrderCreated", "source": "boutique.checkout",
                       "detail": {"version": version, "orderId": order_id, "items": items}})


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.ddb = FakeDynamo()
        self.store = inv.InventoryStore(self.ddb, "t")
        self.store.seed({"A": 5, "B": 1})

    def test_seed_never_overwrites_existing_stock(self):
        self.store.reserve("o1", [{"productId": "A", "quantity": 2}])
        self.assertEqual(self.store.seed({"A": 50, "C": 7}), 1)  # only C is new
        self.assertEqual(self.store.get_stock("A"), 3)
        self.assertEqual(self.store.list_stock(), {"A": 3, "B": 1, "C": 7})

    def test_reserve_decrements_all_products(self):
        res = self.store.reserve("o1", [{"productId": "A", "quantity": 2}, {"productId": "B", "quantity": 1}])
        self.assertEqual(res.status, "RESERVED")
        self.assertEqual((self.store.get_stock("A"), self.store.get_stock("B")), (3, 0))

    def test_same_product_twice_is_merged(self):
        res = self.store.reserve("o1", [{"productId": "A", "quantity": 2}, {"productId": "A", "quantity": 3}])
        self.assertEqual(res.items, [{"productId": "A", "quantity": 5}])
        self.assertEqual(self.store.get_stock("A"), 0)

    def test_insufficient_stock_reserves_nothing(self):
        res = self.store.reserve("o1", [{"productId": "A", "quantity": 1}, {"productId": "B", "quantity": 2}])
        self.assertEqual((res.status, res.failed_products), ("FAILED", ["B"]))
        self.assertEqual((self.store.get_stock("A"), self.store.get_stock("B")), (5, 1))  # A untouched

    def test_unknown_product_fails(self):
        res = self.store.reserve("o1", [{"productId": "NOPE", "quantity": 1}])
        self.assertEqual((res.status, res.failed_products), ("FAILED", ["NOPE"]))

    def test_redelivery_does_not_reserve_twice(self):
        first = self.store.reserve("o1", [{"productId": "A", "quantity": 2}])
        again = self.store.reserve("o1", [{"productId": "A", "quantity": 2}])
        self.assertEqual((first.status, again.status, again.duplicate), ("RESERVED", "RESERVED", True))
        self.assertEqual(self.store.get_stock("A"), 3)

    def test_redelivery_of_failed_order_returns_same_failure(self):
        self.store.reserve("o1", [{"productId": "B", "quantity": 9}])
        self.store.seed({"Z": 1})
        again = self.store.reserve("o1", [{"productId": "B", "quantity": 9}])
        self.assertEqual((again.status, again.duplicate, again.failed_products), ("FAILED", True, ["B"]))

    def test_bad_items_are_rejected(self):
        for items in ([], [{"productId": "A", "quantity": 0}], [{"quantity": 1}]):
            with self.assertRaises(inv.InvalidEvent):
                self.store.reserve("o1", items)


class EventTests(unittest.TestCase):
    def test_parse_order_created(self):
        oid, items = inv.parse_order_created(order_created("o9", [{"productId": "A", "quantity": 1}]))
        self.assertEqual((oid, items), ("o9", [{"productId": "A", "quantity": 1}]))

    def test_parse_rejects_bad_messages(self):
        for body in ("not json", json.dumps({"detail-type": "Other"}), order_created("o1", [], version="2"),
                     json.dumps({"detail-type": "OrderCreated", "detail": {"version": "1"}})):
            with self.assertRaises(inv.InvalidEvent):
                inv.parse_order_created(body)

    def test_result_events(self):
        ok = inv.result_event(inv.Reservation("o1", "RESERVED", [{"productId": "A", "quantity": 1}]))
        bad = inv.result_event(inv.Reservation("o2", "FAILED", [], "INSUFFICIENT_STOCK", ["B"]))
        self.assertEqual(ok[0], "InventoryReserved")
        self.assertEqual(bad, ("InventoryFailed", {"version": "1", "orderId": "o2",
                                                   "reason": "INSUFFICIENT_STOCK", "productIds": ["B"]}))

    def test_publish(self):
        ev = FakeEvents()
        inv.publish(ev, "bus", "InventoryReserved", {"orderId": "o1"})
        self.assertEqual(ev.sent[0]["Source"], "boutique.inventory")
        self.assertEqual(ev.sent[0]["EventBusName"], "bus")
        with self.assertRaises(RuntimeError):
            inv.publish(FakeEvents(fail=True), "bus", "InventoryReserved", {})

    def test_stock_overrides(self):
        self.assertEqual(inv.parse_stock_overrides("X:2, Y:5,"), {"X": 2, "Y": 5})
        self.assertEqual(inv.parse_stock_overrides(""), {})


if __name__ == "__main__":
    unittest.main()
