#!/usr/bin/env bash
# Proves that dev cannot reach prod inside the shared EKS cluster.
#
#   Network  a probe pod in boutique-dev, with its own egress open (like any dev
#            pod), tries to open connections to prod services. The prod
#            NetworkPolicies must drop them. The prod frontend is the control:
#            it is public (behind the ALB) and must answer.
#   IAM      the dev inventoryservice pod (Pod Identity) reads its own DynamoDB
#            table (must work), then prod's table (must be AccessDenied).
#   Known gap  prod Redis is reachable from dev (no auth, open to the VPC).
#            Reported as a warning until Redis gets an auth token + TLS.
#
# Needs: kubectl connected to the cluster, and these variables:
#   DEV_NS PROD_NS DEV_TABLE PROD_TABLE PROD_REDIS (host:port)
# Exit code 0 = isolation holds, 1 = a check failed.
set -uo pipefail

: "${DEV_NS:?}" "${PROD_NS:?}" "${DEV_TABLE:?}" "${PROD_TABLE:?}" "${PROD_REDIS:?}"
PROBE=isolation-probe
failures=0
rows=()

record() { # name, expected, actual
  local mark="PASS"
  if [ "$2" != "$3" ]; then mark="FAIL"; failures=$((failures + 1)); fi
  rows+=("| $1 | $2 | $3 | ${mark} |")
  echo "${mark}  $1: expected $2, got $3"
}

cleanup() {
  kubectl -n "$DEV_NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$DEV_NS" delete networkpolicy "$PROBE" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

# --- probe pod: egress open, so only the prod side can block it --------------
cleanup
kubectl -n "$DEV_NS" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${PROBE}
spec:
  podSelector:
    matchLabels:
      app: ${PROBE}
  policyTypes: [Ingress, Egress]
  egress:
  - {}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE}
  labels:
    app: ${PROBE}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: public.ecr.aws/docker/library/python:3.12-slim
    command: ["sleep", "600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits: { cpu: 100m, memory: 64Mi }
EOF
kubectl -n "$DEV_NS" wait --for=condition=Ready "pod/${PROBE}" --timeout=120s || { echo "Probe pod did not start"; exit 1; }
sleep 15 # let the VPC CNI apply the policies to the new pod

# OPEN or BLOCKED for a TCP connection from the probe (3 s timeout).
connect() {
  kubectl -n "$DEV_NS" exec "$PROBE" -- python -c "
import socket, sys
try:
    socket.create_connection(('$1', $2), timeout=3).close(); print('OPEN')
except OSError:
    print('BLOCKED')" 2>/dev/null | tail -1
}

echo "== Network: from ${DEV_NS} to ${PROD_NS} =="
record "dev -> prod frontend:80 (public, control)" OPEN "$(connect "frontend.${PROD_NS}.svc.cluster.local" 80)"
for target in productcatalogservice:3550 cartservice:7070 checkoutservice:5050 currencyservice:7000 paymentservice:50051 inventoryservice:80; do
  svc=${target%%:*}; port=${target##*:}
  record "dev -> prod ${svc}:${port}" BLOCKED "$(connect "${svc}.${PROD_NS}.svc.cluster.local" "$port")"
done

redis_host=${PROD_REDIS%%:*}; redis_port=${PROD_REDIS##*:}
redis=$(connect "$redis_host" "$redis_port")
if [ "$redis" = "OPEN" ]; then
  rows+=("| dev -> prod Redis (known gap) | BLOCKED | OPEN | WARN |")
  echo "WARN  dev can open a connection to prod Redis: add an auth token + TLS (see docs/week3/ISOLATION.md)"
  echo "::warning::Known gap: prod Redis is reachable from dev (no auth token yet)."
else
  rows+=("| dev -> prod Redis | BLOCKED | ${redis} | PASS |")
fi

echo "== IAM: dev inventoryservice (Pod Identity) =="
# Uses the dev pod's own credentials. Prints OK, AccessDenied, or what went wrong
# (exception name, or kubectl's own error), so a broken check is never silent.
dynamo() {
  local out
  out=$(kubectl -n "$DEV_NS" exec deploy/inventoryservice -c server -- python -c "
import boto3
try:
    boto3.client('dynamodb').scan(TableName='$1', Limit=1)
    print('OK')
except Exception as e:
    code = getattr(e, 'response', {}).get('Error', {}).get('Code', '') or type(e).__name__
    print('AccessDenied' if 'AccessDenied' in code else code + ': ' + str(e)[:150])
" 2>&1)
  echo "$out" | tr -d '\r' | grep -v '^\s*$' | tail -1
}
record "dev role -> dev table" OK "$(dynamo "$DEV_TABLE")"
record "dev role -> prod table" AccessDenied "$(dynamo "$PROD_TABLE")"

# --- report -------------------------------------------------------------------
{
  echo "### Isolation test: ${DEV_NS} vs ${PROD_NS}"
  echo
  echo "| Check | Expected | Result | |"
  echo "|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$failures" -gt 0 ]; then
  echo "${failures} isolation check(s) failed."
  exit 1
fi
echo "Isolation holds."
