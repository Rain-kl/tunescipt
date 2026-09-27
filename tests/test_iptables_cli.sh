#!/bin/sh
set -eu

export TEST_MODE=1
export IPT_CONFIG_DIR="./tmp_test_iptables_cli"
MOCK_LOG="${IPT_CONFIG_DIR}/mock_iptables.log"
export MOCK_IPTABLES_LOG="$MOCK_LOG"
mkdir -p "$IPT_CONFIG_DIR"
trap 'rm -rf "$IPT_CONFIG_DIR"' EXIT

echo "=== Testing CLI Mode: Single rule with range 10000-50000 ==="
sh ./port-forward-iptables.sh -d 163.192.29.228 -p 10000-50000 -m all

# 验证 rules.conf 记录
grep -q "1|163.192.29.228|10000-50000|all|0.0.0.0|enabled" "$IPT_CONFIG_DIR/rules.conf"

# 验证 mock iptables 输出
grep -q "iptables -t nat -A IPT_FWD_PREROUTING -p tcp --dport 10000:50000 -j DNAT --to-destination 163.192.29.228:10000-50000" "$MOCK_LOG"
grep -q "iptables -t nat -A IPT_FWD_PREROUTING -p udp --dport 10000:50000 -j DNAT --to-destination 163.192.29.228:10000-50000" "$MOCK_LOG"

echo "=== Testing CLI Mode: Additional rule with domain & custom bind ==="
sh ./port-forward-iptables.sh -d 1.1.1.1 -p 8443 -m tcp -b 127.0.0.1
grep -q "2|1.1.1.1|8443|tcp|127.0.0.1|enabled" "$IPT_CONFIG_DIR/rules.conf"
grep -q "iptables -t nat -A IPT_FWD_PREROUTING -d 127.0.0.1 -p tcp --dport 8443 -j DNAT --to-destination 1.1.1.1:8443" "$MOCK_LOG"

echo "=== Testing CLI Argument Error Handling ==="
# 缺少目标
! sh ./port-forward-iptables.sh -p 8080 2>/dev/null
# 端口无效
! sh ./port-forward-iptables.sh -d 1.1.1.1 -p abc 2>/dev/null
# 协议无效
! sh ./port-forward-iptables.sh -d 1.1.1.1 -p 8080 -m invalid 2>/dev/null

echo "✅ All E2E CLI tests passed successfully with /bin/sh!"
