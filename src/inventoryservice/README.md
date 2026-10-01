# inventoryservice (Week 3 addition)

The plan's **Inventory Service**: it keeps stock levels in DynamoDB and reserves stock for every order, asynchronously.

```
checkout ──OrderCreated──► EventBridge ──rule──► SQS inventory-q ──► inventoryservice
                                                                      │ reserve stock (DynamoDB transaction)
                     EventBridge ◄── InventoryReserved / InventoryFailed
```

## How a reservation works

One DynamoDB transaction does everything or nothing:

1. Create `RESERVATION#<orderId>`, only if it doesn't exist yet. This makes the service **idempotent**: a redelivered message finds the reservation and re-publishes the same result, without touching stock again.
2. For each product, `stock = stock - qty`, only if `stock >= qty`. This means stock **can never go negative**, even with several replicas.

If any product is short, nothing is reserved. The order is recorded as FAILED, and `InventoryFailed` names the products that were short.

The SQS message is deleted **only after** the result event is published. Any error leaves the message in the queue. It's retried, and after 3 tries SQS moves it to `inventory-dlq`.

## API

| Endpoint | Returns |
|---|---|
| `GET /stock` | All stock levels |
| `GET /stock/<productId>` | One product (404 if unknown) |
| `GET /healthz` | Liveness |
| `GET /readyz` | 503 if the consumer loop stopped polling |
| `GET /metrics` | Prometheus: `inventory_reservations_total{result}`, `inventory_message_errors_total{kind}`, `inventory_message_processing_seconds` |

## Event contracts (schema version 1)

**Consumes** `OrderCreated` (source `boutique.checkout`):
```json
{"version": "1", "orderId": "…", "items": [{"productId": "OLJCESPC7Z", "quantity": 1}], "...": "other fields ignored"}
```

**Publishes** (source `boutique.inventory`):
```json
InventoryReserved: {"version": "1", "orderId": "…", "items": [{"productId": "…", "quantity": 1}]}
InventoryFailed:   {"version": "1", "orderId": "…", "reason": "INSUFFICIENT_STOCK", "productIds": ["6E92ZMYYFZ"]}
```

## Configuration

| Env var | Meaning |
|---|---|
| `INVENTORY_TABLE` | DynamoDB table (partition key `pk`, string) |
| `INVENTORY_QUEUE_URL` | SQS `inventory-q` URL |
| `EVENT_BUS_NAME` | EventBridge bus for the result events |
| `SEED_STOCK` / `DEFAULT_STOCK` | Create missing stock rows for the 9 catalog products at startup (never overwrites) |
| `STOCK_OVERRIDES` | e.g. `6E92ZMYYFZ:2`. The Mug starts at 2, so ordering 3 mugs demos `InventoryFailed`. |

**AWS permissions**, through Pod Identity on service account `inventoryservice`:

- DynamoDB `GetItem`, `PutItem`, `UpdateItem`, `Scan`, `ConditionCheckItem` on the table
- SQS `ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility`, `GetQueueAttributes` on `inventory-q`
- EventBridge `PutEvents` on the bus

## Tests

```bash
python -m unittest -v    # 13 tests, in-memory fake of DynamoDB, no AWS needed
```

## Demo ideas

- **Out of stock:** order 3 Mugs. The order ends as FAILED.
- **Consumer failure:** `kubectl scale deploy/inventoryservice --replicas=0`, then place orders and watch `inventory-q` grow. Scale back to 1 and watch it drain.
- **Duplicate delivery:** re-send an OrderCreated. Stock doesn't change, and the log shows `"duplicate": true`.
