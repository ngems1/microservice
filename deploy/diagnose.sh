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
echo
echo "=== ${ns}: autoscalers (current/target CPU, replicas) ==="
kubectl -n "$ns" get hpa 2>&1
# A pod can be Ready again after a restart, so the loop above skips it: show why each
# container last stopped (OOMKilled = memory limit, Error/exit 137 + probe events = liveness).
echo
echo "=== ${ns}: containers that restarted (last exit) ==="
kubectl -n "$ns" get pods -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LAST_REASON:.status.containerStatuses[*].lastState.terminated.reason,EXIT_CODE:.status.containerStatuses[*].lastState.terminated.exitCode,STOPPED_AT:.status.containerStatuses[*].lastState.terminated.finishedAt' 2>&1 | awk 'NR==1 || $2 ~ /[1-9]/'
kubectl -n "$ns" get events --field-selector reason=Unhealthy 2>/dev/null | grep -i liveness | tail -10
# HPAs at <unknown>: is the metrics API answering, and on which port do its pods listen?
if [ "$ns" = kube-system ]; then
  echo
  echo "=== metrics API (used by the HPAs) ==="
  kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1
  kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server -o jsonpath='{range .items[*]}{.metadata.name}{" ports="}{.spec.containers[*].ports[*].containerPort}{"\n"}{end}' 2>&1
  kubectl top nodes 2>&1 | head -6
fi
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
    # CloudWatch panels empty? Grafana's CloudWatch plugin logs why (last 40 lines).
    echo "=== ${gpod}: CloudWatch plugin messages (latest) ==="
    kubectl -n "$ns" logs "$gpod" -c grafana 2>&1 | grep -iE 'cloudwatch|tsdb\.|aws' | tail -40
  fi
fi
exit 0
