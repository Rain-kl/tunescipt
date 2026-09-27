#!/bin/bash
set -euo pipefail

export TEST_MODE=1
export TEST_DIR="./tmp_service_test"
mkdir -p "$TEST_DIR/system" "$TEST_DIR/init.d"
trap 'rm -rf "$TEST_DIR"' EXIT

source ./gost.sh --source-only

# 测试 1: Systemd 服务模板生成
echo "Testing Systemd service template generation..."
SERVICE_FILE_SYSTEMD="$TEST_DIR/system/gost-forward.service"
generate_systemd_service "$SERVICE_FILE_SYSTEMD"
grep -q "LimitNOFILE=1048576" "$SERVICE_FILE_SYSTEMD"
grep -q "ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml" "$SERVICE_FILE_SYSTEMD"
grep -q "Restart=always" "$SERVICE_FILE_SYSTEMD"

# 测试 2: OpenRC 服务模板生成
echo "Testing OpenRC service template generation..."
SERVICE_FILE_OPENRC="$TEST_DIR/init.d/gost-forward"
generate_openrc_service "$SERVICE_FILE_OPENRC"
grep -q 'rc_ulimit="-n 1048576"' "$SERVICE_FILE_OPENRC"
grep -q 'command="/usr/local/bin/gost"' "$SERVICE_FILE_OPENRC"
grep -q 'command_args="-C /etc/gost/config.yaml"' "$SERVICE_FILE_OPENRC"

echo "✅ Service manager generation tests passed!"
