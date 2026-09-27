#!/bin/sh
set -eu

# 引入函数 (规避 root 检查与主入口直接运行)
export TEST_MODE=1

# 检查当前目录或上层目录中的 port-forward-iptables.sh
SCRIPT_PATH="./port-forward-iptables.sh"
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "port-forward-iptables.sh not found yet"
    exit 1
fi

# shellcheck disable=SC1090
. "$SCRIPT_PATH" --source-only 2>/dev/null || true

echo "Testing port range validation..."
validate_port_range "8080"
validate_port_range "10000-50000"
! validate_port_range "60000-10000" 2>/dev/null
! validate_port_range "abc" 2>/dev/null
! validate_port_range "0-80" 2>/dev/null
! validate_port_range "80-70000" 2>/dev/null

echo "Testing iptables port formatting..."
[ "$(format_iptables_port '8080')" = "8080" ]
[ "$(format_iptables_port '10000-50000')" = "10000:50000" ]

echo "Testing target validation..."
validate_target "1.1.1.1"
validate_target "example.com"
validate_target "sub.domain.co.uk"
validate_target "163.192.29.228"
! validate_target "invalid..domain" 2>/dev/null
! validate_target "" 2>/dev/null
! validate_target "1.2.3.256" 2>/dev/null
! validate_target "foo;rm -rf /" 2>/dev/null

echo "Testing argument parsing..."
parse_args -d 1.2.3.4 -p 10000-50000 -m all -b 0.0.0.0
[ "$CLI_DEST" = "1.2.3.4" ]
[ "$CLI_PORT" = "10000-50000" ]
[ "$CLI_MODE" = "all" ]
[ "$CLI_BIND" = "0.0.0.0" ]
[ "$IS_CLI" -eq 1 ]

echo "✅ All core validation tests passed!"
