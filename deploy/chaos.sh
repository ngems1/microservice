#!/usr/bin/env bash
# Breaks one thing in boutique-dev on purpose, measures the impact and the recovery,
# and always puts it back (trap). Run by .github/workflows/chaos.yml.
#
#   SCENARIO=pod-failure       deletes the pod of SERVICE; Kubernetes starts a new one.
#                              Measures how long until it is Ready, and checks the shop
#                              (through the ALB) every 2 s meanwhile.
#   SCENARIO=consumer-failure  stops inventoryservice (0 replicas) for OUTAGE_MINUTES
#                              while a few simulated shoppers keep ordering: orders stay
#                              PENDING, inventory-q fills up, the "backlog" alarm goes to
#                              Slack. Then the consumer comes back and works off the queue.
#
# Needs kubectl on the cluster, AWS credentials, and: NS, INVENTORY_QUEUE_URL, DLQ_URLS_JSON,
# SCENARIO, SERVICE (pod-failure), OUTAGE_MINUTES (consumer-failure).
set -uo pipefail
: "${NS:?}" "${SCENARIO:?}"
[ "$NS" = boutique-dev ] || { echo "::error::chaos only runs in boutique-dev (got ${NS})"; exit 1; }

shop_url=$(kubectl -n "$NS" get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
ts() { date -u +%H:%M:%S; }
summary() { echo "$*" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# --------------------------------------------------------------------------------------
pod_failure() {
  : "${SERVICE:?}"
  local old new start ready_at ok=0 bad=0 code
  old=$(kubectl -n "$NS" get pods -l "app=${SERVICE}" -o jsonpath='{.items[0].metadata.name}')
  [ -n "$old" ] || { echo "::error::no running pod for ${SERVICE}"; exit 1; }
  replicas=$(kubectl -n "$NS" get deploy "$SERVICE" -o jsonpath='{.status.readyReplicas}')
  summary "### Chaos: pod failure (${SERVICE})"
  summary "- Pods ready before: ${replicas:-0}. Deleting \`${old}\` at $(ts) UTC."

  start=$(date +%s)
  kubectl -n "$NS" delete pod "$old" --wait=false >/dev/null

  # Shop check through the ALB + wait for a new Ready pod (max 3 min).
  ready_at=""
  for _ in $(seq 1 90); do
    if [ -n "$shop_url" ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${shop_url}/" || echo 000)
      if [ "$code" = 200 ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "$(ts) shop answered ${code}"; fi
    fi
    if [ -z "$ready_at" ]; then
      new=$(kubectl -n "$NS" get pods -l "app=${SERVICE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        | awk -v o="$old" '$1!=o && $2=="True"{print $1; exit}')
      [ -n "$new" ] && ready_at=$(date +%s) && echo "$(ts) new pod ${new} is Ready"
    fi
    # After recovery, keep checking the shop for 20 more seconds, then stop.
    if [ -n "$ready_at" ] && [ $(( $(date +%s) - ready_at )) -ge 20 ]; then break; fi
    sleep 2
  done

  if [ -z "$ready_at" ]; then
    summary "- ❌ No new Ready pod after 3 minutes."; kubectl -n "$NS" describe pod -l "app=${SERVICE}" | tail -20; exit 1
  fi
  summary "- ✅ New pod \`${new}\` Ready after **$((ready_at - start)) s** (Kubernetes recreated it, nobody had to act)."
  [ -n "$shop_url" ] && summary "- Shop home page during the test: **${ok} OK, ${bad} errors** (one check every 2 s)."
  if [ "${bad}" -gt 0 ] && [ "${replicas:-1}" -le 1 ]; then
    summary "- With a single replica there is a short gap while the new pod starts: 2+ replicas (minReplicas) would hide it."
  fi
}

# --------------------------------------------------------------------------------------
queue_line() {
  aws sqs get-queue-attributes --queue-url "$1" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible]' --output text
}

TRAFFIC=chaos-traffic
ORIGINAL_REPLICAS=""
restore() {
  # Always: consumer back, simulated shoppers gone.
  if [ -n "$ORIGINAL_REPLICAS" ]; then
    kubectl -n "$NS" scale deploy inventoryservice --replicas="$ORIGINAL_REPLICAS" >/dev/null 2>&1 \
      && echo "$(ts) restore: inventoryservice back to ${ORIGINAL_REPLICAS} replica(s)"
  fi
  kubectl -n "$NS" delete job "$TRAFFIC" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" delete networkpolicy "$TRAFFIC" --ignore-not-found >/dev/null 2>&1
}

consumer_failure() {
  : "${INVENTORY_QUEUE_URL:?}" "${OUTAGE_MINUTES:?}"
  local image waiting inflight start_drain
  trap restore EXIT
  ORIGINAL_REPLICAS=$(kubectl -n "$NS" get deploy inventoryservice -o jsonpath='{.spec.replicas}')
  summary "### Chaos: consumer failure (inventoryservice down ${OUTAGE_MINUTES} min)"

  # A few shoppers who keep placing orders (the shop's own load generator image).
  image=$(kubectl -n "$NS" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}')
  image=${image/\/frontend:/\/loadgenerator:}
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${TRAFFIC}
spec:
  podSelector:
    matchLabels:
      app: ${TRAFFIC}
  policyTypes: [Ingress, Egress]
  egress:
  - {}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${TRAFFIC}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $(( OUTAGE_MINUTES * 60 + 120 ))
  template:
    metadata:
      labels:
        app: ${TRAFFIC}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: locust
        image: ${image}
        command: ["sh", "-c"]
        args: ["locust -f /loadgen/locustfile.py --host=http://frontend:80 --headless -u 4 -r 1 --run-time $(( OUTAGE_MINUTES ))m --only-summary"]
        env:
        - name: HOME
          value: /tmp
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 500m, memory: 512Mi }
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

  echo "$(ts) stopping inventoryservice (was ${ORIGINAL_REPLICAS} replica(s))"
  kubectl -n "$NS" scale deploy inventoryservice --replicas=0 >/dev/null
  summary "- $(ts) UTC: inventoryservice stopped, 4 simulated shoppers keep ordering."
  printf '%-10s %-10s %-10s\n' TIME WAITING IN-FLIGHT
  for _ in $(seq 1 "$OUTAGE_MINUTES"); do
    sleep 60
    read -r waiting inflight < <(queue_line "$INVENTORY_QUEUE_URL")
    printf '%-10s %-10s %-10s\n' "$(ts)" "$waiting" "$inflight"
  done
  summary "- $(ts) UTC: **${waiting} order events waiting** in inventory-q (orders stay PENDING meanwhile)."
  [ "$OUTAGE_MINUTES" -ge 8 ] && summary "- The *inventory-backlog* alarm (oldest message > 5 min, 3 checks) should now be 🔴 in #boutique-alerts."

  echo "$(ts) restarting inventoryservice"
  kubectl -n "$NS" scale deploy inventoryservice --replicas="$ORIGINAL_REPLICAS" >/dev/null
  kubectl -n "$NS" delete job "$TRAFFIC" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" rollout status deploy/inventoryservice --timeout=180s
  start_drain=$(date +%s)
  for _ in $(seq 1 60); do
    read -r waiting inflight < <(queue_line "$INVENTORY_QUEUE_URL")
    printf '%-10s %-10s %-10s\n' "$(ts)" "$waiting" "$inflight"
    [ "$waiting" = 0 ] && [ "$inflight" = 0 ] && break
    sleep 5
  done
  if [ "$waiting" = 0 ] && [ "$inflight" = 0 ]; then
    summary "- ✅ Consumer back: queue empty after **$(( $(date +%s) - start_drain )) s**. No message lost: SQS kept them until a consumer was there."
  else
    summary "- ⚠️ Still ${waiting} waiting / ${inflight} in flight after 5 min: check inventoryservice logs below."
  fi

  echo "--- dead-letter queues (should all be 0)"
  for url in $(jq -r '.[]' <<<"${DLQ_URLS_JSON:-[]}"); do
    read -r waiting inflight < <(queue_line "$url"); printf '%-50s %s\n' "${url##*/}" "$waiting"
  done
  echo "--- inventoryservice, last lines"
  kubectl -n "$NS" logs deploy/inventoryservice --since=5m 2>&1 | tail -15
  summary "- Next: Actions > order-flow > dev shows the orders CONFIRMED and their notifications; the alarm turns 🟢 within a few minutes."
}

case "$SCENARIO" in
  pod-failure)      pod_failure ;;
  consumer-failure) consumer_failure ;;
  *) echo "::error::unknown scenario ${SCENARIO}"; exit 1 ;;
esac
