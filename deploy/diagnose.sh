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
for pod in $(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 != "Completed" {split($2, r, "/")} $3 != "Completed" && (r[1] != r[2] || $3 != "Running") {print $1}'); do
  echo
  echo "=== ${pod}: describe (end) ==="
  kubectl -n "$ns" describe pod "$pod" 2>&1 | tail -25
  echo "=== ${pod}: logs ==="
  kubectl -n "$ns" logs "$pod" --all-containers --tail=40 2>&1
  echo "=== ${pod}: logs before the last restart ==="
  kubectl -n "$ns" logs "$pod" --all-containers --previous --tail=40 2>/dev/null || echo "(none)"
done
# Grafana runs even when a plugin fails to load, so its pod looks healthy:
# show its plugin messages and the container setup (read-only disk, mounted folders).
if [ "$ns" = monitoring ]; then
  gpod=$(kubectl -n "$ns" get pods -l app.kubernetes.io/name=grafana -o name 2>/dev/null | head -1)
  if [ -n "$gpod" ]; then
    echo
    echo "=== ${gpod}: grafana container (security context, mounts) ==="
    kubectl -n "$ns" get "$gpod" -o jsonpath='{range .spec.containers[?(@.name=="grafana")]}securityContext: {.securityContext}{"\n"}{range .volumeMounts[*]}mount: {.mountPath}{" ro="}{.readOnly}{"\n"}{end}{end}' 2>&1
    echo "=== ${gpod}: plugin / error messages ==="
    kubectl -n "$ns" logs "$gpod" -c grafana 2>&1 | grep -iE 'plugin|prometheus|level=(error|warn)' | grep -v 'level=debug' | head -60
  fi
fi
exit 0
