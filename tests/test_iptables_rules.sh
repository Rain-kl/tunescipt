#!/bin/sh
set -eu

export TEST_MODE=1
export IPT_CONFIG_DIR="./tmp_test_iptables"
mkdir -p "$IPT_CONFIG_DIR"
trap 'rm -rf "$IPT_CONFIG_DIR"' EXIT

# shellcheck disable=SC1091
. ./port-forward-iptables.sh --source-only

# 测试 1: 添加规则
echo "Testing adding rules..."
add_rule "1.2.3.4" "10000-50000" "all" "0.0.0.0" "enabled"
add_rule "hk.example.com" "8443" "tcp" "0.0.0.0" "enabled"

# 检查 rules.conf 行数
COUNT=$(grep -v '^#' "$IPT_CONFIG_DIR/rules.conf" | grep -v '^$' | wc -l)
COUNT=$(echo "$COUNT" | tr -d '[:space:]')
[ "$COUNT" -eq 2 ]

# 测试 2: 重叠端口检测
echo "Testing port overlap detection..."
# 10000-50000 已被占用，20000-30000 应重叠
if check_port_overlap "20000-30000"; then
    echo "Overlap correctly detected!"
else
    echo "Failed to detect overlap!"
    exit 1
fi

# 80 端口未占用，不应重叠
if check_port_overlap "80"; then
    echo "False positive overlap detected!"
    exit 1
fi

# 测试 3: 删除规则
echo "Testing delete rule..."
delete_rule 1
COUNT=$(grep -v '^#' "$IPT_CONFIG_DIR/rules.conf" | grep -v '^$' | wc -l)
COUNT=$(echo "$COUNT" | tr -d '[:space:]')
[ "$COUNT" -eq 1 ]

echo "✅ Rules engine tests passed!"
