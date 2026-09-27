#!/bin/sh
set -eu

export TEST_MODE=1
export IPT_CONFIG_DIR="./tmp_test_iptables_gen"
mkdir -p "$IPT_CONFIG_DIR"
trap 'rm -rf "$IPT_CONFIG_DIR"' EXIT

# shellcheck disable=SC1091
. ./iptables.sh --source-only

# 添加测试规则
add_rule "163.192.29.228" "10000-50000" "all" "0.0.0.0" "enabled"
add_rule "1.1.1.1" "8443" "tcp" "10.0.0.2" "enabled"
add_rule "2.2.2.2" "9000" "udp" "0.0.0.0" "disabled"

# 测试生成与命令执行捕获
echo "Testing iptables rule application in test mode..."
MOCK_LOG="${IPT_CONFIG_DIR}/mock_iptables.log"
export MOCK_IPTABLES_LOG="$MOCK_LOG"

apply_iptables_rules

# 验证生成的 iptables 指令
[ -f "$MOCK_LOG" ]

# 检查 DNAT 规则
grep -q "iptables -t nat -A IPT_FWD_PREROUTING -p tcp --dport 10000:50000 -j DNAT --to-destination 163.192.29.228:10000:50000" "$MOCK_LOG"
grep -q "iptables -t nat -A IPT_FWD_PREROUTING -p udp --dport 10000:50000 -j DNAT --to-destination 163.192.29.228:10000:50000" "$MOCK_LOG"
grep -q "iptables -t nat -A IPT_FWD_PREROUTING -d 10.0.0.2 -p tcp --dport 8443 -j DNAT --to-destination 1.1.1.1:8443" "$MOCK_LOG"

# 检查 disabled 规则未被生成
! grep -q "9000" "$MOCK_LOG"

# 检查 MASQUERADE 规则
grep -q "iptables -t nat -A IPT_FWD_POSTROUTING -d 163.192.29.228 -p tcp --dport 10000:50000 -j MASQUERADE" "$MOCK_LOG"
grep -q "iptables -t nat -A IPT_FWD_POSTROUTING -d 163.192.29.228 -p udp --dport 10000:50000 -j MASQUERADE" "$MOCK_LOG"

# 检查 FORWARD 规则
grep -q "iptables -t filter -A IPT_FWD_FORWARD -d 163.192.29.228 -p tcp --dport 10000:50000 -j ACCEPT" "$MOCK_LOG"

echo "✅ iptables generator tests passed!"
