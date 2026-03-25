#!/usr/bin/env bash
# Integration test: boots a Kurtosis devnet with temu, configures xatu to send
# events to an HTTP endpoint, and exits successfully when the first event arrives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

COLLECTOR_PORT=8888
ENCLAVE_NAME="temu-test"
POLL_INTERVAL=5
TIMEOUT=480  # 8 minutes

SENTINEL_FILE=$(mktemp /tmp/temu-sentinel.XXXXXX)
rm -f "$SENTINEL_FILE"  # we only want the path, not the file

COLLECTOR_LOG=$(mktemp /tmp/temu-collector-log.XXXXXX)
KURTOSIS_CONFIG=$(mktemp /tmp/temu-kurtosis.XXXXXX.yaml)

COLLECTOR_PID=""

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    kurtosis enclave rm -f "$ENCLAVE_NAME" 2>/dev/null || true
    if [ -n "$COLLECTOR_PID" ]; then
        kill "$COLLECTOR_PID" 2>/dev/null || true
        wait "$COLLECTOR_PID" 2>/dev/null || true
    fi
    rm -f "$SENTINEL_FILE" "$COLLECTOR_LOG" "$KURTOSIS_CONFIG"
}
trap cleanup EXIT

# --- Detect host IP reachable from Docker containers ---
detect_host_ip() {
    if [[ "$(uname)" == "Linux" ]] && ip link show docker0 &>/dev/null; then
        ip -4 addr show docker0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
    else
        echo "host.docker.internal"
    fi
}

HOST_IP=$(detect_host_ip)
echo "Host IP for Docker containers: ${HOST_IP}"

# --- Start event collector ---
echo "Starting event collector on port ${COLLECTOR_PORT}..."
python3 "$SCRIPT_DIR/event-collector.py" \
    --port "$COLLECTOR_PORT" \
    --sentinel "$SENTINEL_FILE" \
    > "$COLLECTOR_LOG" 2>&1 &
COLLECTOR_PID=$!
sleep 1

if ! kill -0 "$COLLECTOR_PID" 2>/dev/null; then
    echo "ERROR: Event collector failed to start"
    cat "$COLLECTOR_LOG"
    exit 1
fi
echo "Event collector running (PID: ${COLLECTOR_PID})"

# --- Generate Kurtosis config ---
cat > "$KURTOSIS_CONFIG" <<EOF
extra_files:
  xatu-config.yaml: |
    enabled: true
    name: "temu-integration-test"
    outputs:
    - name: http-test
      type: http
      config:
        address: http://${HOST_IP}:${COLLECTOR_PORT}
        batchTimeout: 1s
        maxExportBatchSize: 1
        exportTimeout: 5s
        workers: 1

participants:
  - el_type: nethermind
    cl_type: teku
    cl_image: "consensys/teku:develop"
    cl_extra_env_vars:
      XATU_CONFIG: "/etc/temu/xatu-config.yaml"
    cl_extra_mounts:
      "/etc/temu": "xatu-config.yaml"
    count: 1
  - el_type: nethermind
    cl_type: lighthouse
    count: 1

network_params:
  electra_fork_epoch: 1
  fulu_fork_epoch: 2
  min_validator_withdrawability_delay: 1
  shard_committee_period: 1
  churn_limit_quotient: 16
  genesis_delay: 30

additional_services: []
EOF

echo "Generated Kurtosis config:"
cat "$KURTOSIS_CONFIG"
echo ""

# --- Run Kurtosis ---
echo "=== Starting Kurtosis devnet ==="
kurtosis run github.com/ethpandaops/ethereum-package \
    --args-file "$KURTOSIS_CONFIG" \
    --enclave "$ENCLAVE_NAME"

echo ""
echo "=== Waiting for xatu events (timeout: ${TIMEOUT}s) ==="

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if [ -f "$SENTINEL_FILE" ]; then
        echo ""
        echo "========================================="
        echo "  PASSED: Received xatu event!"
        echo "========================================="
        echo ""
        echo "Event data:"
        cat "$SENTINEL_FILE"
        echo ""
        echo ""
        echo "Collector log:"
        cat "$COLLECTOR_LOG"
        exit 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    if (( elapsed % 30 == 0 )); then
        echo "  Still waiting... (${elapsed}s / ${TIMEOUT}s)"
    fi
done

# --- Timeout: dump debugging info ---
echo ""
echo "========================================="
echo "  FAILED: No xatu events received within ${TIMEOUT}s"
echo "========================================="
echo ""

echo "=== Collector log ==="
cat "$COLLECTOR_LOG"
echo ""

echo "=== Temu service logs (last 200 lines) ==="
kurtosis service logs "$ENCLAVE_NAME" cl-1-teku-nethermind 2>/dev/null | tail -200 || echo "(could not fetch logs)"
echo ""

echo "=== Kurtosis config used ==="
cat "$KURTOSIS_CONFIG"

exit 1
