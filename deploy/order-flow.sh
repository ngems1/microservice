#!/usr/bin/env bash
# Follows orders through the event-driven flow of one environment (read-only):
#   1. orders in RDS MySQL      PENDING -> CONFIRMED / FAILED (+ count per status)
#   2. reservations in DynamoDB written by inventoryservice, and current stock
#   3. SQS queues and dead-letter queues (messages waiting / in flight)
#   4. the order-status Lambda's recent logs
# Needs kubectl on the cluster and AWS credentials, plus (from the Terraform outputs):
#   NS INVENTORY_TABLE QUEUES_JSON LAMBDA_NAME, and the Secret "order-flow-query"
#   (DB_HOST, DB_PORT, DB_NAME, DB_USER, MYSQL_PWD) in the namespace
set -u
: "${NS:?}" "${INVENTORY_TABLE:?}" "${QUEUES_JSON:?}" "${LAMBDA_NAME:?}"
JOB=order-flow-query


echo "=== 1. Orders (RDS MySQL, ${DB_NAME}) ==="
# RDS is private: the query runs in a short-lived pod inside the cluster. It reuses
# the migration's network policy (label app=db-migrate) and RDS certificate bundle.
# The database credentials are in the Secret "order-flow-query", created (and
# deleted afterwards) by the workflow, so no password ever passes through this output.
kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: db-migrate
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: query
        image: public.ecr.aws/docker/library/mysql:8.4
        command: ["/bin/bash", "-c"]
        args:
        - |
          q() { mysql --host="\$DB_HOST" --port="\$DB_PORT" --user="\$DB_USER" --ssl-mode=VERIFY_IDENTITY --ssl-ca=/ca/rds-ca.pem -t "\$DB_NAME" -e "\$1"; }
          q "SELECT status, COUNT(*) AS orders FROM orders GROUP BY status"
          q "SELECT order_id, status, status_reason AS reason,
                    CONCAT(currency, ' ', total_units, '.', LPAD(FLOOR(total_nanos / 10000000), 2, '0')) AS total,
                    created_at, updated_at
             FROM orders ORDER BY created_at DESC LIMIT 10"
        envFrom:
        - secretRef:
            name: ${JOB}
        env:
        - name: HOME
          value: /tmp
        volumeMounts:
        - name: ca
          mountPath: /ca
          readOnly: true
        - name: tmp
          mountPath: /tmp
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: ca
        configMap:
          name: db-migrations
      - name: tmp
        emptyDir: {}
YAML
kubectl -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout=120s >/dev/null 2>&1 \
  || echo "(query did not complete, details below)"
kubectl -n "$NS" logs "job/${JOB}" 2>&1

echo
echo "=== 2. Inventory (DynamoDB ${INVENTORY_TABLE}) ==="
echo "Reservations (one per order):"
aws dynamodb scan --table-name "$INVENTORY_TABLE" \
  --filter-expression "begins_with(pk, :p)" --expression-attribute-values '{":p":{"S":"RESERVATION#"}}' \
  --query 'Items[].[pk.S, status.S, reason.S]' --output table 2>&1 | head -40
echo "Stock:"
aws dynamodb scan --table-name "$INVENTORY_TABLE" \
  --filter-expression "begins_with(pk, :p)" --expression-attribute-values '{":p":{"S":"PRODUCT#"}}' \
  --query 'Items[].[pk.S, stock.N]' --output table 2>&1

echo
echo "=== 3. Queues (waiting / being processed) ==="
printf '%-60s %8s %8s\n' QUEUE WAITING IN-FLIGHT
for url in $(jq -r '.[]' <<<"$QUEUES_JSON"); do
  read -r waiting inflight < <(aws sqs get-queue-attributes --queue-url "$url" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible]' --output text)
  printf '%-60s %8s %8s\n' "${url##*/}" "$waiting" "$inflight"
done
echo "(a dead-letter queue (-dlq) above 0 means messages failed 3 times: see the CloudWatch alarm)"

echo
echo "=== 4. order-status Lambda, last 30 minutes ==="
aws logs tail "/aws/lambda/${LAMBDA_NAME}" --since 30m --format short 2>&1 | tail -30
exit 0
