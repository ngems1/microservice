#!/usr/bin/env bash
# Shows the catalog's database/cache path for one environment, and optionally
# changes one product's price in MySQL (to watch the Redis cache at work):
#   1. product prices in RDS MySQL (after the optional price change)
#   2. productcatalogservice logs: catalog source, cache misses (MySQL loads), hit stats
# Needs kubectl on the cluster and these variables:
#   NS, and the Secret "catalog-query" (DB_HOST DB_PORT DB_NAME DB_USER MYSQL_PWD)
#   PRODUCT_ID / NEW_PRICE (optional): e.g. OLJCESPC7Z / 15.00
set -u
: "${NS:?}"
PRODUCT_ID=${PRODUCT_ID:-}
NEW_PRICE=${NEW_PRICE:-}
JOB=catalog-query
UNITS=""; NANOS=""

if [ -n "$NEW_PRICE" ]; then
  # Strict validation: these values end up in an SQL statement.
  [[ "$PRODUCT_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "invalid product id: $PRODUCT_ID"; exit 1; }
  [[ "$NEW_PRICE" =~ ^[0-9]{1,5}(\.[0-9]{1,2})?$ ]] || { echo "invalid price: $NEW_PRICE (use e.g. 15 or 15.00)"; exit 1; }
  UNITS=${NEW_PRICE%%.*}
  cents=0
  if [[ "$NEW_PRICE" == *.* ]]; then
    frac=${NEW_PRICE#*.}; [ ${#frac} -eq 1 ] && frac="${frac}0"
    cents=$((10#$frac))
  fi
  NANOS=$((cents * 10000000))
fi

echo "=== 1. Products in RDS MySQL ==="
[ -n "$NEW_PRICE" ] && echo "Changing ${PRODUCT_ID} to USD ${NEW_PRICE} (units=${UNITS}, nanos=${NANOS})"
# RDS is private: the query runs in a short-lived pod, with the migration's network
# policy (label app=db-migrate) and RDS certificate bundle (configmap db-migrations).
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
          q() { mysql --host="\$DB_HOST" --port="\$DB_PORT" --user="\$DB_USER" --ssl-mode=VERIFY_IDENTITY --ssl-ca=/ca/rds-ca.pem "\$DB_NAME" "\${@:2}" -e "\$1"; }
          if [ -n "\$NEW_UNITS" ]; then
            q "UPDATE products SET price_units=\$NEW_UNITS, price_nanos=\$NEW_NANOS WHERE id='\$PRODUCT_ID'" \
              && echo "Updated \$PRODUCT_ID in MySQL."
          fi
          q "SELECT id, name, CONCAT(price_currency, ' ', price_units, '.', LPAD(FLOOR(price_nanos / 10000000), 2, '0')) AS price
             FROM products ORDER BY id" -t
        envFrom:
        - secretRef:
            name: ${JOB}
        env:
        - name: HOME
          value: /tmp
        - name: PRODUCT_ID
          value: "${PRODUCT_ID}"
        - name: NEW_UNITS
          value: "${UNITS}"
        - name: NEW_NANOS
          value: "${NANOS}"
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
echo "=== 2. productcatalogservice: database/cache path (last 60 minutes) ==="
echo "'cache miss: loaded N products from MySQL' = read from the database, then cached;"
echo "'catalog cache stats' = requests answered from Redis (hits) vs MySQL (misses), per minute."
lines=$(kubectl -n "$NS" logs deploy/productcatalogservice -c server --since=60m 2>&1 \
  | grep -E "catalog (source|cache)|catalog:" | tail -20)
echo "${lines:-(no catalog lines yet: open the shop to send some traffic)}"

if [ -n "$NEW_PRICE" ]; then
  echo
  echo "The shop keeps showing the old price while the cached catalog is valid (up to 5 minutes),"
  echo "then the next request misses the cache, reads MySQL, and shows USD ${NEW_PRICE}."
fi
exit 0
