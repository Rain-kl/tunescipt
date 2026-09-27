#!/bin/bash
set -euo pipefail

export TEST_MODE=1
export GOST_CONFIG_DIR="./tmp_test_gost"
mkdir -p "$GOST_CONFIG_DIR"
trap 'rm -rf "$GOST_CONFIG_DIR"' EXIT

source ./gost.sh --source-only

# 测试 1: 添加规则并生成 YAML
echo "Testing adding rules..."
add_rule "1.2.3.4" "10000-50000" "all" "0.0.0.0"
add_rule "hk.example.com" "8443" "tcp" "0.0.0.0"

# 检查 rules.conf 行数
COUNT=$(grep -v '^#' "$GOST_CONFIG_DIR/rules.conf" | grep -v '^$' | wc -l)
[ "$COUNT" -eq 2 ]

# 测试 2: 编译 YAML 配置文件
echo "Testing generating YAML config..."
generate_gost_config

# 验证 YAML 内容结构
grep -q 'addr: ":10000-50000"' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'addr: "1.2.3.4:10000-50000"' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'addr: ":8443"' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'addr: "hk.example.com:8443"' "$GOST_CONFIG_DIR/config.yaml"

# 测试 3: 重叠端口检测
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

# 测试 4: 删除规则
echo "Testing delete rule..."
delete_rule 1
generate_gost_config
! grep -q "10000-50000" "$GOST_CONFIG_DIR/config.yaml"

echo "✅ Rules engine tests passed!"
