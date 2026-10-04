#!/usr/bin/env bash
# Simulated shoppers against the DEV shop for a fixed time; stops by itself.
#
#   MODE=load    steady USERS shoppers (the loadgenerator image's own Locust file,
#                long pauses): makes the Grafana dashboard move.
#   MODE=stress  stepped ramp-up to MAX_USERS busy shoppers (deploy/load/stress_locustfile.py),
#                spread over several Locust pods: finds the shop's breaking point.
#
# The orders are real: they go through the whole event flow.
# Needs kubectl on the cluster and: NS MODE MINUTES, USERS (load) or MAX_USERS (stress),
# RESTOCK=none|normal|unlimited (+ INVENTORY_TABLE): normal = 50 per product and the Mug
# at 2 (some orders fail: realistic); unlimited = 100000 (measures capacity, not stock).
set -uo pipefail
: "${NS:?}" "${MINUTES:?}"
MODE=${MODE:-load}
JOB=load-test
[[ "$MINUTES" =~ ^[0-9]+$ && "$MINUTES" -ge 1 && "$MINUTES" -le 60 ]] || { echo "MINUTES must be 1-60"; exit 1; }

case "$MODE" in
  load)
    : "${USERS:?}"
    [[ "$USERS" =~ ^[0-9]+$ && "$USERS" -ge 1 && "$USERS" -le 100 ]] || { echo "USERS must be 1-100"; exit 1; }
    WORKERS=1 ;;
  stress)
    : "${MAX_USERS:?}"
    [[ "$MAX_USERS" =~ ^[0-9]+$ && "$MAX_USERS" -ge 10 && "$MAX_USERS" -le 800 ]] || { echo "MAX_USERS must be 10-800"; exit 1; }
    WORKERS=$(( (MAX_USERS + 149) / 150 ))           # one Locust pod (1 CPU) per ~150 busy shoppers
    RUN_SECONDS=$(( MINUTES * 60 ))
    STEPS=$(( MINUTES * 60 * 2 / 3 / 60 )); [ "$STEPS" -lt 1 ] && STEPS=1   # reach the top after ~2/3 of the run, then hold
    STEP_USERS=$(( (MAX_USERS + STEPS - 1) / STEPS )) ;;
  *) echo "MODE must be load or stress"; exit 1 ;;
esac

RESTOCK=${RESTOCK:-none}
[ "$RESTOCK" = "true" ] && RESTOCK=normal
[ "$RESTOCK" = "false" ] && RESTOCK=none
if [ "$RESTOCK" != "none" ]; then
  : "${INVENTORY_TABLE:?}"
  echo "=== Restocking ${INVENTORY_TABLE} (${RESTOCK}) ==="
  for pid in 0PUK6V6EV0 1YMWWN1N4O 2ZYFJ3GM2N 66VCHSJNUP 9SIQT8TOJO L9ECAV7KIM LS4PSXUNUM OLJCESPC7Z 6E92ZMYYFZ; do
    if [ "$RESTOCK" = unlimited ]; then qty=100000
    else qty=50; [ "$pid" = 6E92ZMYYFZ ] && qty=2; fi   # normal: the Mug keeps the "out of stock" path visible
    aws dynamodb update-item --table-name "$INVENTORY_TABLE" --key "{\"pk\":{\"S\":\"PRODUCT#${pid}\"}}" \
      --update-expression "SET stock = :q" --expression-attribute-values "{\":q\":{\"N\":\"${qty}\"}}" \
      && echo "  ${pid} -> ${qty}"
  done
fi

# Same version as the running shop: the frontend image with the loadgenerator name.
image=$(kubectl -n "$NS" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}')
image=${image/\/frontend:/\/loadgenerator:}

cleanup() {
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" delete networkpolicy "$JOB" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NS" delete configmap "$JOB" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT
kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1

if [ "$MODE" = stress ]; then
  echo "=== Stress test: ramp to ${MAX_USERS} shoppers (+${STEP_USERS}/min), ${MINUTES} min, ${WORKERS} Locust pod(s) ==="
  kubectl -n "$NS" create configmap "$JOB" --from-file=locustfile.py=deploy/load/stress_locustfile.py \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  LOCUST_ARGS="locust -f /stress/locustfile.py --host=http://frontend:80 --headless --only-summary 2>&1"
  per_pod_max=$(( (MAX_USERS + WORKERS - 1) / WORKERS ))
  per_pod_step=$(( (STEP_USERS + WORKERS - 1) / WORKERS ))
  EXTRA_ENV="
        - name: MAX_USERS
          value: \"${per_pod_max}\"
        - name: STEP_USERS
          value: \"${per_pod_step}\"
        - name: STEP_SECONDS
          value: \"60\"
        - name: RUN_SECONDS
          value: \"${RUN_SECONDS}\""
  EXTRA_MOUNT="
        - name: script
          mountPath: /stress
          readOnly: true"
  EXTRA_VOLUME="
      - name: script
        configMap:
          name: ${JOB}"
else
  echo "=== Load test: ${USERS} shoppers for ${MINUTES} min ==="
  LOCUST_ARGS="locust -f /loadgen/locustfile.py --host=http://frontend:80 --headless -u ${USERS} -r 2 --run-time ${MINUTES}m --stop-timeout 10 --only-summary 2>&1"
  EXTRA_ENV=""; EXTRA_MOUNT=""; EXTRA_VOLUME=""
fi
echo "image: ${image##*/}"

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
  parallelism: ${WORKERS}
  completions: ${WORKERS}
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
        args: ["${LOCUST_ARGS}"]
        env:
        - name: HOME
          value: /tmp${EXTRA_ENV}
        resources:
          requests: { cpu: 300m, memory: 256Mi }
          limits: { cpu: "1", memory: 768Mi }
        volumeMounts:
        - name: tmp
          mountPath: /tmp${EXTRA_MOUNT}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: tmp
        emptyDir: {}${EXTRA_VOLUME}
YAML

if ! kubectl -n "$NS" wait --for=condition=Ready pod -l "job-name=${JOB}" --timeout=180s >/dev/null; then
  echo "Locust pods did not start:"; kubectl -n "$NS" get pods -l "job-name=${JOB}"
  kubectl -n "$NS" describe pod -l "job-name=${JOB}" | grep -A8 Events | head -30
  exit 1
fi
started=$(date -u +%H:%M)
echo "Running since ${started} UTC. Watch Grafana > Boutique: platform overview (time range: last 30 min)."
if kubectl -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout="$(( MINUTES * 60 + 240 ))s" >/dev/null; then
  echo "=== Finished: Locust summary per pod ==="
else
  echo "=== Did not finish cleanly; last output per pod ==="
fi
for pod in $(kubectl -n "$NS" get pods -l "job-name=${JOB}" -o name); do
  echo "--- ${pod#pod/}"
  kubectl -n "$NS" logs "$pod" --tail=40 2>&1
done
exit 0
