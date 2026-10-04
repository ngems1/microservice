#!/usr/bin/env bash
# Simulated shoppers against the dev shop for a fixed time, then stops by itself.
# Uses the loadgenerator image (Locust, built by every deploy): browse, add to cart,
# change currency, check out. The orders are real: they go through the whole event
# flow and show up on the Grafana dashboard (traffic, latency, orders, queues, CPU).
# Needs kubectl on the cluster and: NS USERS MINUTES; RESTOCK=true + INVENTORY_TABLE
# to reset the stock first (50 per product, the Mug stays at 2 in dev so some orders fail).
set -uo pipefail
: "${NS:?}" "${USERS:?}" "${MINUTES:?}"
JOB=load-test
[[ "$USERS" =~ ^[0-9]+$ && "$USERS" -ge 1 && "$USERS" -le 100 ]] || { echo "USERS must be 1-100"; exit 1; }
[[ "$MINUTES" =~ ^[0-9]+$ && "$MINUTES" -ge 1 && "$MINUTES" -le 60 ]] || { echo "MINUTES must be 1-60"; exit 1; }

if [ "${RESTOCK:-false}" = "true" ]; then
  : "${INVENTORY_TABLE:?}"
  echo "=== Restocking ${INVENTORY_TABLE} ==="
  for pid in 0PUK6V6EV0 1YMWWN1N4O 2ZYFJ3GM2N 66VCHSJNUP 9SIQT8TOJO L9ECAV7KIM LS4PSXUNUM OLJCESPC7Z 6E92ZMYYFZ; do
    qty=50; [ "$pid" = 6E92ZMYYFZ ] && qty=2   # the Mug: keeps the "out of stock" path visible
    aws dynamodb update-item --table-name "$INVENTORY_TABLE" --key "{\"pk\":{\"S\":\"PRODUCT#${pid}\"}}" \
      --update-expression "SET stock = :q" --expression-attribute-values "{\":q\":{\"N\":\"${qty}\"}}" \
      && echo "  ${pid} -> ${qty}"
  done
fi

# Same version as the running shop: the frontend image with the loadgenerator name.
image=$(kubectl -n "$NS" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}')
image=${image/\/frontend:/\/loadgenerator:}
echo "=== Load test: ${USERS} users for ${MINUTES} min (${image##*/}) ==="

cleanup() {
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" delete networkpolicy "$JOB" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT
kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1

kubectl -n "$NS" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${JOB}
spec:
  podSelector:
    matchLabels:
      app: ${JOB}
  policyTypes: [Ingress, Egress]
  egress:
  - {}            # the frontend (allowed in by its own policy) and DNS
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $(( MINUTES * 60 + 300 ))
  template:
    metadata:
      labels:
        app: ${JOB}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: locust
        image: ${image}
        command: ["sh", "-c"]
        args:
        - >-
          locust -f /loadgen/locustfile.py --host="http://frontend:80" --headless
          -u ${USERS} -r 2 --run-time ${MINUTES}m --stop-timeout 10 --only-summary 2>&1
        env:
        - name: HOME
          value: /tmp
        resources:
          requests: { cpu: 300m, memory: 256Mi }
          limits: { cpu: "1", memory: 512Mi }
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: tmp
        emptyDir: {}
YAML

kubectl -n "$NS" wait --for=condition=Ready pod -l "job-name=${JOB}" --timeout=180s >/dev/null \
  || { kubectl -n "$NS" describe pod -l "job-name=${JOB}" | tail -20; exit 1; }
echo "Running. Watch Grafana (Boutique: platform overview) while it runs."
if kubectl -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout="$(( MINUTES * 60 + 240 ))s" >/dev/null; then
  echo "=== Locust summary ==="
else
  echo "=== The load test did not finish cleanly; last output ==="
fi
kubectl -n "$NS" logs "job/${JOB}" --tail=60 2>&1
exit 0
