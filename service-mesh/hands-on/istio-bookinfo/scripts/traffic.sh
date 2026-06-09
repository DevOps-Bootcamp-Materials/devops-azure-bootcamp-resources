#!/usr/bin/env bash
# Generate steady traffic to Bookinfo so the Kiali graph lights up.
# Usage:
#   ./traffic.sh                 # auto: uses the gateway public IP if there is
#                                # one (AKS), otherwise port-forwards (kind)
#   URL=http://1.2.3.4 ./traffic.sh   # hit an explicit base URL
#   DURATION=300 ./traffic.sh         # run for N seconds (default 600)
#
# Leave it running in its own terminal during the demo. Ctrl-C to stop.

set -euo pipefail

DURATION="${DURATION:-600}"
INTERVAL="${INTERVAL:-0.5}"
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [ -z "${URL:-}" ]; then
  IP="$(kubectl -n istio-system get svc istio-ingressgateway \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -n "$IP" ]; then
    URL="http://$IP"
    echo "Using gateway public IP: $URL"
  else
    echo "No LoadBalancer IP (kind). Port-forwarding istio-ingressgateway -> localhost:8080"
    kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 4
    URL="http://localhost:8080"
  fi
fi

echo "Sending requests to $URL/productpage for ${DURATION}s (every ${INTERVAL}s). Ctrl-C to stop."
end=$((SECONDS + DURATION))
n=0
while [ $SECONDS -lt $end ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$URL/productpage" || echo ERR)"
  n=$((n + 1))
  printf '\r  request %-6d last status: %s' "$n" "$code"
  sleep "$INTERVAL"
done
echo
echo "Done after $n requests."
