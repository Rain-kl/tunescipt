#!/bin/sh
set -e

# 引入函数 (规避 root 检查与主入口直接运行)
TEST_MODE=1
. ./gost.sh --source-only 2>/dev/null || true

echo "Testing port range validation..."
validate_port_range "8080"
validate_port_range "10000-50000"
! validate_port_range "60000-10000" 2>/dev/null
! validate_port_range "abc" 2>/dev/null
! validate_port_range "0-80" 2>/dev/null
! validate_port_range "80-70000" 2>/dev/null

echo "Testing target validation..."
validate_target "1.1.1.1"
validate_target "example.com"
validate_target "sub.domain.co.uk"
validate_target "2606:4700:4700::1111"
! validate_target "invalid..domain" 2>/dev/null
! validate_target "" 2>/dev/null

echo "✅ All core validation tests passed!"
