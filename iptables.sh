#!/bin/sh
# ==============================================================================
# Script Name: iptables.sh
# Description: iptables 内核级端口转发自动化部署与管理脚本 (兼容 POSIX sh，支持 Alpine/Debian 等)
# Author: Rain-kl & Antigravity
# GitHub: https://github.com/Rain-kl/tunescipt
# ==============================================================================

set -e

# 脚本版本与基础常量
SCRIPT_VERSION="1.0.0"
IPT_CONFIG_DIR="${IPT_CONFIG_DIR:-/etc/iptables-forward}"
RULES_FILE="${IPT_CONFIG_DIR}/rules.conf"
SYSCTL_FILE="/etc/sysctl.d/99-ip-forward.conf"

# 自定义 iptables 专用链名称 (与系统规则完全隔离)
CHAIN_PREROUTING="IPT_FWD_PREROUTING"
CHAIN_POSTROUTING="IPT_FWD_POSTROUTING"
CHAIN_FORWARD="IPT_FWD_FORWARD"

# 终端色彩与样式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()  { printf "%bℹ️  %s%b\n" "$BLUE" "$*" "$NC"; }
log_ok()    { printf "%b✅ %s%b\n" "$GREEN" "$*" "$NC"; }
log_warn()  { printf "%b⚠️  %s%b\n" "$YELLOW" "$*" "$NC"; }
log_error() { printf "%b❌ %s%b\n" "$RED" "$*" "$NC" >&2; }

# 检测并确认 root 权限 (脚本必须由 root 用户直接运行)
require_root() {
    if [ "${TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log_error "本脚本必须使用 root 用户直接运行 (请先执行 'su -' 或登录 root 用户)"
        exit 1
    fi
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu|raspbian)
                echo "debian"
                ;;
            centos|rhel|fedora|rocky|almalinux)
                echo "centos"
                ;;
            alpine)
                echo "alpine"
                ;;
            *)
                echo "${ID:-unknown}"
                ;;
        esac
    else
        uname -s | tr '[:upper:]' '[:lower:]'
    fi
}

# 校验端口范围 (支持单一端口如 8080，或区间如 10000-50000)
validate_port_range() {
    spec="$1"
    [ -z "$spec" ] && return 1

    case "$spec" in
        *-*)
            p_start=$(echo "$spec" | cut -d'-' -f1)
            p_end=$(echo "$spec" | cut -d'-' -f2)
            case "$p_start" in
                ''|*[!0-9]*) return 1 ;;
            esac
            case "$p_end" in
                ''|*[!0-9]*) return 1 ;;
            esac
            [ "$p_start" -ge 1 ] 2>/dev/null || return 1
            [ "$p_start" -le 65535 ] 2>/dev/null || return 1
            [ "$p_end" -ge 1 ] 2>/dev/null || return 1
            [ "$p_end" -le 65535 ] 2>/dev/null || return 1
            [ "$p_start" -le "$p_end" ] 2>/dev/null || return 1
            return 0
            ;;
        *)
            case "$spec" in
                ''|*[!0-9]*) return 1 ;;
            esac
            [ "$spec" -ge 1 ] 2>/dev/null || return 1
            [ "$spec" -le 65535 ] 2>/dev/null || return 1
            return 0
            ;;
    esac
}

# 将端口范围转换为 iptables 格式 (10000-50000 -> 10000:50000)
format_iptables_port() {
    spec="$1"
    case "$spec" in
        *-*)
            echo "$spec" | tr '-' ':'
            ;;
        *)
            echo "$spec"
            ;;
    esac
}

# 校验目标地址 (支持 IPv4, 域名)
validate_target() {
    target="$1"
    [ -z "$target" ] && return 1

    # 包含特殊注入字符或连续点则无效
    case "$target" in
        *[\ /\\\'\"\`\$\;\&\|\<\>\(\)\{\}]*) return 1 ;;
        *..*) return 1 ;;
    esac

    echo "$target" | awk '
    function is_byte(x) { return (x ~ /^[0-9]+$/ && x >= 0 && x <= 255) }
    {
        t = $0
        # IPv4 检查
        if (split(t, a, ".") == 4) {
            if (is_byte(a[1]) && is_byte(a[2]) && is_byte(a[3]) && is_byte(a[4])) exit 0
        }
        # 域名或合法主机名检查
        if (t ~ /^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/ || t ~ /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/) exit 0
        exit 1
    }'
}

# 显示帮助信息
show_help() {
    printf "%biptables 内核端口转发自动化部署脚本 (v%s)%b\n\n" "$BOLD" "$SCRIPT_VERSION" "$NC"
    printf "%b用法:%b\n" "$BOLD" "$NC"
    printf "  sh iptables.sh [选项]\n"
    printf "  curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/iptables.sh | sh -s -- [选项]\n\n"
    printf "%bCLI 快速选项:%b\n" "$BOLD" "$NC"
    printf "  -d, --destination <ip/domain>   目标转发地址 (必填，支持域名或 IPv4)\n"
    printf "  -p, --port <port/range>         转发端口或端口范围 (必填，如 8080 或 10000-50000)\n"
    printf "  -m, --mode <proto>              转发协议: all (默认 TCP+UDP), tcp, udp\n"
    printf "  -b, --bind <ip>                 本地监听绑定地址 (默认 0.0.0.0 全部监听)\n"
    printf "  -h, --help                      显示帮助信息\n\n"
    printf "%b示例 (必须以 root 运行):%b\n" "$BOLD" "$NC"
    printf "  # 内核零损耗转发 10000-50000 的所有 TCP/UDP 流量至 163.192.29.228\n"
    printf "  sh iptables.sh -d 163.192.29.228 -p 10000-50000\n\n"
    printf "  # 仅转发 TCP 端口 40000 至目标 IP\n"
    printf "  sh iptables.sh -d 163.192.29.228 -p 40000 -m tcp\n\n"
    printf "  # 不带任何参数运行，将进入交互式 TUI 管理面板:\n"
    printf "  sh iptables.sh\n"
}

# 解析 CLI 命令行参数
CLI_DEST=""
CLI_PORT=""
CLI_MODE="all"
CLI_BIND="0.0.0.0"
IS_CLI=0

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--destination)
                CLI_DEST="$2"
                IS_CLI=1
                shift 2
                ;;
            -p|--port)
                CLI_PORT="$2"
                IS_CLI=1
                shift 2
                ;;
            -m|--mode)
                CLI_MODE="$2"
                IS_CLI=1
                shift 2
                ;;
            -b|--bind)
                CLI_BIND="$2"
                IS_CLI=1
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --source-only)
                return 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [ "$IS_CLI" -eq 1 ]; then
        if [ -z "$CLI_DEST" ] || [ -z "$CLI_PORT" ]; then
            log_error "CLI 模式下必须同时提供 -d <目标地址> 与 -p <端口或端口段>"
            exit 1
        fi
        if ! validate_target "$CLI_DEST"; then
            log_error "目标地址格式无效: $CLI_DEST"
            exit 1
        fi
        if ! validate_port_range "$CLI_PORT"; then
            log_error "端口或端口范围格式无效 (1-65535): $CLI_PORT"
            exit 1
        fi
        CLI_MODE="$(echo "$CLI_MODE" | tr '[:upper:]' '[:lower:]')"
        case "$CLI_MODE" in
            all|tcp|udp) ;;
            *)
                log_error "协议类型无效: $CLI_MODE (可选: all, tcp, udp)"
                exit 1
                ;;
        esac
    fi
}

# 初始化配置目录与规则库
ensure_config_dir() {
    mkdir -p "$IPT_CONFIG_DIR"
    if [ ! -f "$RULES_FILE" ]; then
        cat << 'EOF' > "$RULES_FILE"
# ==============================================================================
# iptables 端口转发规则库 (rules.conf)
# 格式: id|target|port_spec|protocol|bind_ip|status
# ==============================================================================
EOF
    fi
}

# 解析端口范围为起始与结束数字 (返回: "start end")
get_port_bounds() {
    spec="$1"
    case "$spec" in
        *-*)
            s=$(echo "$spec" | cut -d'-' -f1)
            e=$(echo "$spec" | cut -d'-' -f2)
            echo "$s $e"
            ;;
        *)
            echo "$spec $spec"
            ;;
    esac
}

# 检测端口是否与已有启用规则重叠
check_port_overlap() {
    new_spec="$1"
    exclude_id="${2:-}"
    ensure_config_dir

    new_bounds=$(get_port_bounds "$new_spec")
    new_start=$(echo "$new_bounds" | awk '{print $1}')
    new_end=$(echo "$new_bounds" | awk '{print $2}')

    if [ "$new_start" -eq 0 ] 2>/dev/null; then
        return 1
    fi

    if [ ! -f "$RULES_FILE" ]; then
        return 1
    fi

    overlap_found=0
    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        case "$r_id" in
            '#'*|'') continue ;;
        esac
        [ "$r_id" = "$exclude_id" ] && continue
        [ "${r_status:-enabled}" != "enabled" ] && continue

        exist_bounds=$(get_port_bounds "$r_port")
        exist_start=$(echo "$exist_bounds" | awk '{print $1}')
        exist_end=$(echo "$exist_bounds" | awk '{print $2}')

        # 区间重叠判断: max(start1, start2) <= min(end1, end2)
        max_start=$(( new_start > exist_start ? new_start : exist_start ))
        min_end=$(( new_end < exist_end ? new_end : exist_end ))

        if [ "$max_start" -le "$min_end" ]; then
            overlap_found=1
            break
        fi
    done < "$RULES_FILE"

    if [ "$overlap_found" -eq 1 ]; then
        return 0
    else
        return 1
    fi
}

# 获取下一个自增 Rule ID
get_next_rule_id() {
    ensure_config_dir
    max_id=0
    while IFS='|' read -r r_id rest || [ -n "$r_id" ]; do
        case "$r_id" in
            '#'*|'') continue ;;
            *[!0-9]*) continue ;;
            *)
                if [ "$r_id" -gt "$max_id" ] 2>/dev/null; then
                    max_id="$r_id"
                fi
                ;;
        esac
    done < "$RULES_FILE"
    echo $(( max_id + 1 ))
}

# 添加新转发规则
add_rule() {
    target="$1"
    port_spec="$2"
    proto="${3:-all}"
    bind_ip="${4:-0.0.0.0}"
    status="${5:-enabled}"

    ensure_config_dir

    next_id=$(get_next_rule_id)

    echo "${next_id}|${target}|${port_spec}|${proto}|${bind_ip}|${status}" >> "$RULES_FILE"
    log_ok "已添加规则 [ID: ${next_id}] ${port_spec} -> ${target}:${port_spec} (${proto})"
    return 0
}

# 删除转发规则
delete_rule() {
    id="$1"
    ensure_config_dir

    if ! grep -q "^${id}|" "$RULES_FILE" 2>/dev/null; then
        log_warn "未找到 ID 为 ${id} 的规则"
        return 1
    fi

    tmp_file=$(mktemp "${IPT_CONFIG_DIR}/rules.tmp.XXXXXX")
    grep -v "^${id}|" "$RULES_FILE" > "$tmp_file" || true
    mv "$tmp_file" "$RULES_FILE"
    log_ok "已删除规则 [ID: ${id}]"
    return 0
}

# 格式化展示规则列表
list_rules() {
    ensure_config_dir
    printf "%b当前 iptables 端口转发规则列表:%b\n" "$BOLD" "$NC"
    printf "%-5s | %-18s | %-24s | %-6s | %-10s | %-8s\n" "ID" "监听端口" "转发目标" "协议" "绑定地址" "状态"
    echo "----------------------------------------------------------------------------------------"
    count=0
    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        case "$r_id" in
            '#'*|'') continue ;;
        esac
        count=$((count + 1))
        if [ "${r_status:-enabled}" = "enabled" ]; then
            status_display="${GREEN}启用${NC}"
        else
            status_display="${YELLOW}禁用${NC}"
        fi
        printf "%-5s | %-18s | %-24s | %-6s | %-10s | %b\n" "$r_id" "$r_port" "$r_target" "$r_proto" "$r_bind" "$status_display"
    done < "$RULES_FILE"

    if [ "$count" -eq 0 ]; then
        echo "   (暂无转发规则)"
    fi
    echo ""
}

# 执行 iptables 命令 (支持 TEST_MODE mock)
run_iptables() {
    if [ "${TEST_MODE:-0}" = "1" ]; then
        if [ -n "${MOCK_IPTABLES_LOG:-}" ]; then
            echo "iptables $*" >> "$MOCK_IPTABLES_LOG"
        fi
        return 0
    fi
    iptables "$@"
}

# 目标地址域名解析 (若是纯 IP 直接返回)
resolve_target() {
    target="$1"
    # 如果是纯 IPv4，直接输出
    if echo "$target" | awk '{ split($0, a, "."); if (length(a) == 4) exit 0; exit 1 }'; then
        echo "$target"
        return 0
    fi

    # 域名解析尝试 getent hosts 或 nslookup 或 ping
    ip=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$target" | awk '{print $1}' | head -n 1)
    fi
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup "$target" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n 1)
    fi
    if [ -z "$ip" ] && command -v ping >/dev/null 2>&1; then
        ip=$(ping -c 1 "$target" 2>/dev/null | head -n 1 | sed -n 's/.*(\([0-9.]*\)).*/\1/p')
    fi

    if [ -n "$ip" ]; then
        echo "$ip"
    else
        echo "$target"
    fi
}

# 初始化自定义 iptables 专用链
init_custom_chains() {
    # 1. NAT PREROUTING 专用链
    run_iptables -t nat -N "$CHAIN_PREROUTING" 2>/dev/null || true
    if [ "${TEST_MODE:-0}" != "1" ]; then
        if ! iptables -t nat -C PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null; then
            iptables -t nat -I PREROUTING 1 -j "$CHAIN_PREROUTING"
        fi
    else
        run_iptables -t nat -I PREROUTING 1 -j "$CHAIN_PREROUTING"
    fi

    # 2. NAT POSTROUTING 专用链
    run_iptables -t nat -N "$CHAIN_POSTROUTING" 2>/dev/null || true
    if [ "${TEST_MODE:-0}" != "1" ]; then
        if ! iptables -t nat -C POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null; then
            iptables -t nat -I POSTROUTING 1 -j "$CHAIN_POSTROUTING"
        fi
    else
        run_iptables -t nat -I POSTROUTING 1 -j "$CHAIN_POSTROUTING"
    fi

    # 3. FILTER FORWARD 专用链
    run_iptables -t filter -N "$CHAIN_FORWARD" 2>/dev/null || true
    if [ "${TEST_MODE:-0}" != "1" ]; then
        if ! iptables -t filter -C FORWARD -j "$CHAIN_FORWARD" 2>/dev/null; then
            iptables -t filter -I FORWARD 1 -j "$CHAIN_FORWARD"
        fi
    else
        run_iptables -t filter -I FORWARD 1 -j "$CHAIN_FORWARD"
    fi
}

# 全量应用 rules.conf 中的所有启用规则到 iptables
apply_iptables_rules() {
    ensure_config_dir
    init_custom_chains

    # 清空专用链内部规则 (保留链本身与外部跳转规则)
    run_iptables -t nat -F "$CHAIN_PREROUTING"
    run_iptables -t nat -F "$CHAIN_POSTROUTING"
    run_iptables -t filter -F "$CHAIN_FORWARD"

    # 放行已有连接
    run_iptables -t filter -A "$CHAIN_FORWARD" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    run_iptables -t filter -A "$CHAIN_FORWARD" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        case "$r_id" in
            '#'*|'') continue ;;
        esac
        [ "${r_status:-enabled}" != "enabled" ] && continue

        resolved_target=$(resolve_target "$r_target")
        fmt_port=$(format_iptables_port "$r_port")

        # 绑定本地 IP 限制 (若非 0.0.0.0 且非空则加上 -d)
        bind_arg=""
        if [ -n "$r_bind" ] && [ "$r_bind" != "0.0.0.0" ]; then
            bind_arg="-d $r_bind"
        fi

        # 处理协议
        protocols=""
        case "$r_proto" in
            tcp) protocols="tcp" ;;
            udp) protocols="udp" ;;
            all|*) protocols="tcp udp" ;;
        esac

        for p in $protocols; do
            # 1. DNAT 规则 (PREROUTING)
            if [ -n "$bind_arg" ]; then
                run_iptables -t nat -A "$CHAIN_PREROUTING" $bind_arg -p "$p" --dport "$fmt_port" -j DNAT --to-destination "${resolved_target}:${fmt_port}"
            else
                run_iptables -t nat -A "$CHAIN_PREROUTING" -p "$p" --dport "$fmt_port" -j DNAT --to-destination "${resolved_target}:${fmt_port}"
            fi

            # 2. SNAT (MASQUERADE) 规则 (POSTROUTING)
            run_iptables -t nat -A "$CHAIN_POSTROUTING" -d "$resolved_target" -p "$p" --dport "$fmt_port" -j MASQUERADE

            # 3. FORWARD 规则 (放行目标端口)
            run_iptables -t filter -A "$CHAIN_FORWARD" -d "$resolved_target" -p "$p" --dport "$fmt_port" -j ACCEPT
        done
    done < "$RULES_FILE"

    log_ok "iptables 端口转发规则已同步生效"
}

# 自动配置系统环境 (内核转发 + 持久化服务)
setup_environment() {
    require_root
    log_info "正在检测并配置系统内核网络转发环境..."

    # 1. 开启内核转发 net.ipv4.ip_forward=1
    if [ "${TEST_MODE:-0}" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        mkdir -p "$(dirname "$SYSCTL_FILE")"
        echo "net.ipv4.ip_forward = 1" > "$SYSCTL_FILE"
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
    log_ok "已开启并固化内核参数 net.ipv4.ip_forward = 1"

    # 2. 安装与适配持久化包
    os="$(detect_os)"
    log_info "正在配置 iptables 持久化服务 (发行版: ${os})..."
    case "$os" in
        alpine)
            if [ "${TEST_MODE:-0}" != "1" ]; then
                apk update >/dev/null 2>&1 || true
                apk add --no-cache iptables iptables-openrc >/dev/null 2>&1 || true
                rc-update add iptables default >/dev/null 2>&1 || true
            fi
            log_ok "已适配 Alpine iptables-openrc 服务"
            ;;
        debian|ubuntu|raspbian)
            if [ "${TEST_MODE:-0}" != "1" ]; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -y >/dev/null 2>&1 || true
                echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections >/dev/null 2>&1 || true
                echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections >/dev/null 2>&1 || true
                apt-get install -y iptables iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
                systemctl enable netfilter-persistent >/dev/null 2>&1 || true
            fi
            log_ok "已适配 Debian/Ubuntu netfilter-persistent 服务"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if [ "${TEST_MODE:-0}" != "1" ]; then
                if command -v dnf >/dev/null 2>&1; then
                    dnf install -y iptables iptables-services >/dev/null 2>&1 || true
                else
                    yum install -y iptables iptables-services >/dev/null 2>&1 || true
                fi
                systemctl enable iptables >/dev/null 2>&1 || true
            fi
            log_ok "已适配 RHEL/CentOS iptables-services 服务"
            ;;
        *)
            log_warn "未识别的 Linux 发行版 (${os})，请确保已安装 iptables 且开启开机自启"
            ;;
    esac
}

# 保存规则以确保重启不丢失
save_iptables_rules() {
    if [ "${TEST_MODE:-0}" = "1" ]; then
        log_ok "规则已成功持久化保存 (Mock)"
        return 0
    fi
    os="$(detect_os)"
    case "$os" in
        alpine)
            if [ -x "/etc/init.d/iptables" ]; then
                /etc/init.d/iptables save >/dev/null 2>&1 || true
            fi
            ;;
        debian|ubuntu|raspbian)
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1 || true
            else
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v service >/dev/null 2>&1; then
                service iptables save >/dev/null 2>&1 || true
            else
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            fi
            ;;
        *)
            if command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            ;;
    esac
    log_ok "规则已成功持久化保存至系统"
}

# 清理并卸载自定义链
cleanup_iptables_chains() {
    if [ "${TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    # 移除跳转规则
    iptables -t nat -D PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t filter -D FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || true

    # 清空并删除专用链
    iptables -t nat -F "$CHAIN_PREROUTING" 2>/dev/null || true
    iptables -t nat -X "$CHAIN_PREROUTING" 2>/dev/null || true

    iptables -t nat -F "$CHAIN_POSTROUTING" 2>/dev/null || true
    iptables -t nat -X "$CHAIN_POSTROUTING" 2>/dev/null || true

    iptables -t filter -F "$CHAIN_FORWARD" 2>/dev/null || true
    iptables -t filter -X "$CHAIN_FORWARD" 2>/dev/null || true
}

# CLI 自动化非交互部署
cli_deploy() {
    require_root
    log_info "=========================================================="
    log_info " 开始通过 CLI 参数自动化部署 iptables 端口转发"
    log_info "=========================================================="
    log_info "目标地址: ${CLI_DEST}"
    log_info "转发端口: ${CLI_PORT}"
    log_info "转发协议: ${CLI_MODE}"
    log_info "绑定地址: ${CLI_BIND}"

    setup_environment

    if check_port_overlap "$CLI_PORT"; then
        log_warn "检测到端口段 ${CLI_PORT} 与现有规则重叠，将追加并更新配置"
    fi

    add_rule "$CLI_DEST" "$CLI_PORT" "$CLI_MODE" "$CLI_BIND" "enabled"
    apply_iptables_rules
    save_iptables_rules

    echo ""
    log_ok "=========================================================="
    log_ok "🎉 iptables 端口转发自动部署成功！"
    log_ok " 本地监听: ${CLI_BIND}:${CLI_PORT}"
    log_ok " 目标转发: ${CLI_DEST}:${CLI_PORT}"
    log_ok " 传输协议: ${CLI_MODE} (TCP/UDP 一一对应)"
    log_ok " 内核模式: Zero-Memory DNAT/SNAT (零内存损耗)"
    log_ok " 规则持久: 已配置开机自动加载"
    log_ok "=========================================================="
}

# 交互式添加规则
interactive_add_rule() {
    echo ""
    printf "%b=== 添加 iptables 端口转发规则 ===%b\n" "$BOLD" "$NC"

    # 目标地址输入
    target=""
    while :; do
        printf "请输入目标转发地址 (域名或 IP): "
        read -r target
        target=$(echo "$target" | tr -d '[:space:]')
        if [ -z "$target" ]; then
            log_error "目标地址不能为空"
            continue
        fi
        if ! validate_target "$target"; then
            log_error "目标地址格式无效，请输入正确的 IPv4 或域名 (例如: 1.1.1.1 或 example.com)"
            continue
        fi
        break
    done

    # 端口段输入
    port_spec=""
    while :; do
        printf "请输入转发端口或范围 (如 8080 或 10000-50000): "
        read -r port_spec
        port_spec=$(echo "$port_spec" | tr -d '[:space:]')
        if [ -z "$port_spec" ]; then
            log_error "端口不能为空"
            continue
        fi
        if ! validate_port_range "$port_spec"; then
            log_error "端口范围格式错误 (1-65535，起始端口 <= 结束端口)"
            continue
        fi
        if check_port_overlap "$port_spec"; then
            log_warn "检测到端口段 ${port_spec} 与已有规则存在重叠！"
            printf "是否仍然强制添加此规则? (y/N): "
            read -r force_add
            case "$force_add" in
                [Yy]*) ;;
                *) continue ;;
            esac
        fi
        break
    done

    # 协议选择
    echo "请选择转发协议:"
    echo "  1) TCP + UDP (默认，推荐)"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    printf "请输入选项 [1-3] (回车默认 1): "
    read -r proto_choice
    proto="all"
    case "$proto_choice" in
        2) proto="tcp" ;;
        3) proto="udp" ;;
        *) proto="all" ;;
    esac

    # 本地绑定 IP (可选)
    printf "请输入本地绑定 IP (回车默认 0.0.0.0 全部监听): "
    read -r bind_ip
    bind_ip=$(echo "$bind_ip" | tr -d '[:space:]')
    bind_ip="${bind_ip:-0.0.0.0}"

    setup_environment
    add_rule "$target" "$port_spec" "$proto" "$bind_ip" "enabled"
    apply_iptables_rules
    save_iptables_rules

    echo ""
    log_ok "规则添加成功并已实时生效！"
}

# 交互式删除规则
interactive_delete_rule() {
    echo ""
    printf "%b=== 删除 iptables 端口转发规则 ===%b\n" "$BOLD" "$NC"
    list_rules
    printf "请输入要删除的规则 ID (输入 0 或直接回车取消): "
    read -r del_id
    del_id=$(echo "$del_id" | tr -d '[:space:]')
    if [ -z "$del_id" ] || [ "$del_id" = "0" ]; then
        log_info "已取消删除"
        return 0
    fi

    if delete_rule "$del_id"; then
        apply_iptables_rules
        save_iptables_rules
        log_ok "已同步最新转发规则至系统 iptables"
    fi
}

# 交互式服务控制
interactive_service_control() {
    while :; do
        echo ""
        printf "%b=== iptables 规则与服务控制 ===%b\n" "$BOLD" "$NC"
        echo "1. 重新应用所有启用规则"
        echo "2. 手动保存规则至系统持久化"
        echo "3. 清空所有 iptables 端口转发专用规则"
        echo "4. 查看当前 iptables 实时链状态"
        echo "0. 返回主菜单"
        printf "请选择操作 [0-4]: "
        read -r s_choice
        case "$s_choice" in
            1)
                apply_iptables_rules
                save_iptables_rules
                ;;
            2)
                save_iptables_rules
                ;;
            3)
                cleanup_iptables_chains
                save_iptables_rules
                log_ok "已清空所有 iptables 专用转发链"
                ;;
            4)
                echo ""
                log_info "--- PREROUTING (DNAT) ---"
                iptables -t nat -L "$CHAIN_PREROUTING" -n -v 2>/dev/null || echo "链未创建"
                echo ""
                log_info "--- POSTROUTING (MASQUERADE) ---"
                iptables -t nat -L "$CHAIN_POSTROUTING" -n -v 2>/dev/null || echo "链未创建"
                echo ""
                log_info "--- FORWARD (ACCEPT) ---"
                iptables -t filter -L "$CHAIN_FORWARD" -n -v 2>/dev/null || echo "链未创建"
                ;;
            0) break ;;
            *) log_warn "无效选项，请重新输入" ;;
        esac
    done
}

# 交互式完全卸载
interactive_uninstall() {
    echo ""
    printf "%b%b=== 完全卸载 iptables 端口转发服务 ===%b\n" "$RED" "$BOLD" "$NC"
    printf "⚠️ 确认要清空转发规则并卸载相关配置吗？(y/N): "
    read -r confirm
    case "$confirm" in
        [Yy]*) ;;
        *)
            log_info "已取消卸载"
            return 0
            ;;
    esac

    log_info "正在清理 iptables 专用链并保存系统状态..."
    cleanup_iptables_chains 2>/dev/null || true
    save_iptables_rules 2>/dev/null || true

    rm -rf "$IPT_CONFIG_DIR"
    log_ok "iptables 转发规则及配置目录已彻底清理完毕！"
}

# 展示主菜单面板
show_menu() {
    clear 2>/dev/null || true
    os="$(detect_os)"

    ip_fwd="未知"
    if [ -f /proc/sys/net/ipv4/ip_forward ]; then
        if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
            ip_fwd="${GREEN}✅ 已开启${NC}"
        else
            ip_fwd="${RED}❌ 未开启${NC}"
        fi
    fi

    rule_count=0
    if [ -f "$RULES_FILE" ]; then
        rule_count=$(grep -v '^#' "$RULES_FILE" 2>/dev/null | grep -v '^$' | wc -l || echo 0)
        rule_count=$(echo "$rule_count" | tr -d '[:space:]')
    fi

    printf "%b================================================================%b\n" "$CYAN" "$NC"
    printf "     %biptables 内核端口转发管理面板 (v%s)%b\n" "$BOLD" "$SCRIPT_VERSION" "$NC"
    printf "%b================================================================%b\n" "$CYAN" "$NC"
    printf " 系统发行版: %-12s | 内核转发: %b\n" "$os" "$ip_fwd"
    printf " 转发引擎  : %-12s | 规则总数: %s 条\n" "Linux iptables" "$rule_count"
    printf "%b================================================================%b\n" "$CYAN" "$NC"
    echo " 1. ➕ 添加转发规则 (IP/域名, 端口或端口段)"
    echo " 2. 📋 查看所有规则与当前运行状态"
    echo " 3. 🗑️  删除指定转发规则"
    echo " 4. ⚙️  规则控制 (重新应用 / 手动保存 / 状态查看)"
    echo " 5. 🧹 完全卸载清理所有转发规则"
    echo " 0. 🚪 退出脚本"
    printf "%b================================================================%b\n" "$CYAN" "$NC"
}

# TUI 交互主循环
menu_loop() {
    require_root
    ensure_config_dir
    while :; do
        show_menu
        printf "请选择操作 [0-5]: "
        read -r choice
        case "$choice" in
            1)
                interactive_add_rule
                printf "按回车键继续..."
                read -r _
                ;;
            2)
                echo ""
                list_rules
                printf "按回车键继续..."
                read -r _
                ;;
            3)
                interactive_delete_rule
                printf "按回车键继续..."
                read -r _
                ;;
            4)
                interactive_service_control
                ;;
            5)
                interactive_uninstall
                printf "按回车键继续..."
                read -r _
                ;;
            0)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                log_warn "无效选项，请重新选择"
                sleep 1
                ;;
        esac
    done
}

# 主入口分流
main() {
    if [ "${SOURCE_ONLY:-0}" = "1" ]; then
        return 0 2>/dev/null || exit 0
    fi

    for arg in "$@"; do
        if [ "$arg" = "--source-only" ]; then
            return 0 2>/dev/null || exit 0
        fi
    done

    parse_args "$@"

    if [ "$IS_CLI" -eq 1 ]; then
        cli_deploy
    else
        menu_loop
    fi
}

main "$@"


