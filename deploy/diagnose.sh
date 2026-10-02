#!/usr/bin/env bash
# Read-only snapshot of a namespace: why pods aren't ready.
#   diagnose.sh <namespace>
# Pods, recent events (image pulls, scheduling, failed probes), and for every pod
# that isn't fully ready: the end of "describe" and its logs (current + previous).
set -u
ns="${1:?namespace}"

echo "=== ${ns}: pods ==="
kubectl -n "$ns" get pods -o wide 2>&1
echo
echo "=== ${ns}: ingress / services ==="
kubectl -n "$ns" get ingress,svc 2>&1
echo
echo "=== ${ns}: recent events ==="
kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -40
for pod in $(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '{split($2, r, "/")} r[1] != r[2] || $3 != "Running" {print $1}'); do
  echo
  echo "=== ${pod}: describe (end) ==="
  kubectl -n "$ns" describe pod "$pod" 2>&1 | tail -25
  echo "=== ${pod}: logs ==="
  kubectl -n "$ns" logs "$pod" --all-containers --tail=40 2>&1
  echo "=== ${pod}: logs before the last restart ==="
  kubectl -n "$ns" logs "$pod" --all-containers --previous --tail=40 2>/dev/null || echo "(none)"
done
exit 0
