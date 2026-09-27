#!/bin/sh
set -e

export TEST_MODE=1
export GOST_CONFIG_DIR="./tmp_e2e_gost"
export SYSTEMD_SERVICE_DIR="${GOST_CONFIG_DIR}/systemd"
export OPENRC_SERVICE_DIR="${GOST_CONFIG_DIR}/openrc"
mkdir -p "$GOST_CONFIG_DIR" "$SYSTEMD_SERVICE_DIR" "$OPENRC_SERVICE_DIR"
trap 'rm -rf "$GOST_CONFIG_DIR"' EXIT

# 创建 Mock GOST 二进制
export GOST_BIN="${GOST_CONFIG_DIR}/gost"
cat << 'EOF' > "$GOST_BIN"
#!/bin/sh
if [ "$1" = "-V" ]; then
    echo "gost 3.3.0 (mock)"
    exit 0
fi
exit 0
EOF
chmod +x "$GOST_BIN"

echo "=== Testing CLI Mode: Single rule with range 10000-50000 ==="
sh ./port-forward-gost.sh -d 1.2.3.4 -p 10000-50000 -m all

# 验证 rules.conf
grep -q "1|1.2.3.4|10000-50000|all|0.0.0.0|enabled" "$GOST_CONFIG_DIR/rules.conf"

# 验证 config.yaml
grep -q 'addr: ":10000-50000"' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'addr: "1.2.3.4:10000-50000"' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'type: tcp' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'type: udp' "$GOST_CONFIG_DIR/config.yaml"

echo "=== Testing CLI Mode: Additional rule with domain & custom bind ==="
sh ./port-forward-gost.sh -d hk.example.com -p 8443 -m tcp -b 127.0.0.1

grep -q "hk.example.com" "$GOST_CONFIG_DIR/rules.conf"
grep -q 'addr: "127.0.0.1:8443"' "$GOST_CONFIG_DIR/config.yaml"
grep -q 'addr: "hk.example.com:8443"' "$GOST_CONFIG_DIR/config.yaml"

echo "=== Testing CLI Argument Error Handling ==="
# 缺少 -p
! sh ./port-forward-gost.sh -d 1.2.3.4 2>/dev/null
# 缺少 -d
! sh ./port-forward-gost.sh -p 8080 2>/dev/null
# 错误端口
! sh ./port-forward-gost.sh -d 1.2.3.4 -p 70000 2>/dev/null
# 倒序区间
! sh ./port-forward-gost.sh -d 1.2.3.4 -p 50000-10000 2>/dev/null
# 非法域名
! sh ./port-forward-gost.sh -d "bad..domain" -p 8080 2>/dev/null

echo "✅ All E2E CLI tests passed successfully with /bin/sh!"
