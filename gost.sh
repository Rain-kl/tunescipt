#!/bin/sh
# ==============================================================================
# Script Name: gost.sh
# Description: GOST v3 端口转发自动化部署与管理脚本 (兼容 POSIX sh，支持 Alpine/Debian 等)
# Author: Rain-kl & Antigravity
# GitHub: https://github.com/Rain-kl/tunescipt
# ==============================================================================

set -e

# 脚本版本与基础常量
SCRIPT_VERSION="1.0.0"
GOST_CONFIG_DIR="${GOST_CONFIG_DIR:-/etc/gost}"
RULES_FILE="${GOST_CONFIG_DIR}/rules.conf"
CONFIG_FILE="${GOST_CONFIG_DIR}/config.yaml"
GOST_BIN="${GOST_BIN:-/usr/local/bin/gost}"
SYSTEMD_SERVICE_DIR="${SYSTEMD_SERVICE_DIR:-/etc/systemd/system}"
OPENRC_SERVICE_DIR="${OPENRC_SERVICE_DIR:-/etc/init.d}"

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

# 检测系统架构 (对应 GOST release 架构命名)
detect_arch() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7*|armhf)
            echo "armv7"
            ;;
        i386|i686)
            echo "386"
            ;;
        *)
            echo "$arch"
            ;;
    esac
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

# 校验目标地址 (支持 IPv4, IPv6, 域名)
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
        # IPv6 检查 (包含冒号且十六进制字符)
        if (index(t, ":") > 0 && t ~ /^[0-9a-fA-F:]+$/) exit 0
        # 域名或合法主机名检查
        if (t ~ /^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/ || t ~ /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/) exit 0
        exit 1
    }'
}

# 显示帮助信息
show_help() {
    printf "%bGOST 端口转发自动化部署脚本 (v%s)%b\n\n" "$BOLD" "$SCRIPT_VERSION" "$NC"
    printf "%b用法:%b\n" "$BOLD" "$NC"
    printf "  sh gost.sh [选项]\n"
    printf "  curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/gost.sh | sh -s -- [选项]\n\n"
    printf "%bCLI 快速选项:%b\n" "$BOLD" "$NC"
    printf "  -d, --destination <ip/domain>   目标转发地址 (必填，支持域名或 IPv4/IPv6)\n"
    printf "  -p, --port <port/range>         转发端口或端口范围 (必填，如 8080 或 10000-50000)\n"
    printf "  -m, --mode <proto>              转发协议: all (默认 TCP+UDP), tcp, udp\n"
    printf "  -b, --bind <ip>                 本地监听绑定地址 (默认 0.0.0.0)\n"
    printf "  -h, --help                      显示帮助信息\n\n"
    printf "%b示例 (必须以 root 运行):%b\n" "$BOLD" "$NC"
    printf "  # 转发本地 10000-50000 的所有 TCP/UDP 流量至 1.2.3.4\n"
    printf "  sh gost.sh -d 1.2.3.4 -p 10000-50000\n\n"
    printf "  # 仅转发 TCP 端口 8443 至目标域名\n"
    printf "  sh gost.sh -d hk.example.com -p 8443 -m tcp\n\n"
    printf "  # 不带任何参数运行，将进入交互式 TUI 管理面板:\n"
    printf "  sh gost.sh\n"
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
    mkdir -p "$GOST_CONFIG_DIR"
    if [ ! -f "$RULES_FILE" ]; then
        cat << 'EOF' > "$RULES_FILE"
# ==============================================================================
# GOST 端口转发规则库 (rules.conf)
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

    tmp_file=$(mktemp "${GOST_CONFIG_DIR}/rules.tmp.XXXXXX")
    grep -v "^${id}|" "$RULES_FILE" > "$tmp_file" || true
    mv "$tmp_file" "$RULES_FILE"
    log_ok "已删除规则 [ID: ${id}]"
    return 0
}

# 格式化展示规则列表
list_rules() {
    ensure_config_dir
    printf "%b当前转发规则列表:%b\n" "$BOLD" "$NC"
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

# 编译生成 GOST v3 config.yaml
generate_gost_config() {
    ensure_config_dir
    tmp_yaml=$(mktemp "${GOST_CONFIG_DIR}/config.yaml.tmp.XXXXXX")

    cat << 'EOF' > "$tmp_yaml"
# GOST v3 自动化生成配置文件 (请勿手动修改)
# 由 gost.sh 自动维护
services:
EOF

    has_services=0
    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        case "$r_id" in
            '#'*|'') continue ;;
        esac
        [ "${r_status:-enabled}" != "enabled" ] && continue

        has_services=1

        # 处理监听地址
        if [ -z "$r_bind" ] || [ "$r_bind" = "0.0.0.0" ]; then
            listen_addr=":${r_port}"
        else
            listen_addr="${r_bind}:${r_port}"
        fi

        # 处理目标地址 (IPv6 包含冒号需加中括号)
        formatted_target="$r_target"
        case "$formatted_target" in
            *:*)
                case "$formatted_target" in
                    \[*\]*) ;;
                    *) formatted_target="[${formatted_target}]" ;;
                esac
                ;;
        esac
        target_addr="${formatted_target}:${r_port}"

        # 根据协议生成 TCP / UDP 配置
        if [ "$r_proto" = "all" ] || [ "$r_proto" = "tcp" ]; then
            cat << EOF >> "$tmp_yaml"
  - name: fwd-tcp-${r_id}
    addr: "${listen_addr}"
    handler:
      type: tcp
    listener:
      type: tcp
    forwarder:
      nodes:
        - name: target-${r_id}
          addr: "${target_addr}"
EOF
        fi

        if [ "$r_proto" = "all" ] || [ "$r_proto" = "udp" ]; then
            cat << EOF >> "$tmp_yaml"
  - name: fwd-udp-${r_id}
    addr: "${listen_addr}"
    handler:
      type: udp
    listener:
      type: udp
    forwarder:
      nodes:
        - name: target-${r_id}
          addr: "${target_addr}"
EOF
        fi
    done < "$RULES_FILE"

    if [ "$has_services" -eq 0 ]; then
        echo "# 暂无启用的转发规则" >> "$tmp_yaml"
    fi

    mv "$tmp_yaml" "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    return 0
}

# 服务名称
SERVICE_NAME="gost-forward"

# 生成 Systemd 服务配置
generate_systemd_service() {
    target_path="$1"
    mkdir -p "$(dirname "$target_path")"
    cat << EOF > "$target_path"
[Unit]
Description=GOST Port Forward Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=512000

[Install]
WantedBy=multi-user.target
EOF
}

# 生成 OpenRC 服务配置
generate_openrc_service() {
    target_path="$1"
    mkdir -p "$(dirname "$target_path")"
    cat << EOF > "$target_path"
#!/sbin/openrc-run
description="GOST Port Forward Service"

command="${GOST_BIN}"
command_args="-C ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
rc_ulimit="-n 1048576"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$target_path"
}

# 安装基础依赖
install_dependencies() {
    os="$(detect_os)"
    log_info "检查并安装必要系统组件..."
    case "$os" in
        alpine)
            apk update >/dev/null 2>&1 || true
            apk add --no-cache curl tar ca-certificates openrc >/dev/null 2>&1 || true
            ;;
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y curl tar ca-certificates >/dev/null 2>&1 || true
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl tar ca-certificates >/dev/null 2>&1 || true
            else
                yum install -y curl tar ca-certificates >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# 下载并安装 GOST 二进制
install_gost_binary() {
    if [ -x "$GOST_BIN" ]; then
        current_ver="$("$GOST_BIN" -V 2>&1 | head -n 1)"
        log_info "检测到已安装 GOST: ${current_ver}"
        return 0
    fi

    install_dependencies

    arch="$(detect_arch)"
    log_info "正在下载 GOST v3 (Linux/${arch})..."

    gost_version="3.3.0"
    filename="gost_${gost_version}_linux_${arch}.tar.gz"

    tmp_dir="$(mktemp -d)"
    success=0

    for url in \
        "https://github.com/go-gost/gost/releases/download/v${gost_version}/${filename}" \
        "https://ghproxy.net/https://github.com/go-gost/gost/releases/download/v${gost_version}/${filename}" \
        "https://mirror.ghproxy.com/https://github.com/go-gost/gost/releases/download/v${gost_version}/${filename}"
    do
        log_info "尝试下载源: ${url}"
        if curl -fsSL --connect-timeout 10 -m 60 "$url" -o "${tmp_dir}/${filename}"; then
            success=1
            break
        fi
    done

    if [ "$success" -ne 1 ]; then
        rm -rf "$tmp_dir"
        log_error "下载 GOST 二进制失败，请检查网络连接或手动安装至 ${GOST_BIN}"
        return 1
    fi

    mkdir -p "$(dirname "$GOST_BIN")"
    tar -zxvf "${tmp_dir}/${filename}" -C "$tmp_dir" >/dev/null
    if [ -f "${tmp_dir}/gost" ]; then
        mv "${tmp_dir}/gost" "$GOST_BIN"
        chmod +x "$GOST_BIN"
        rm -rf "$tmp_dir"
        log_ok "GOST 已成功安装至 ${GOST_BIN} ($("$GOST_BIN" -V 2>&1 | head -n 1))"
        return 0
    else
        rm -rf "$tmp_dir"
        log_error "解压安装 GOST 失败"
        return 1
    fi
}

# 安装并配置系统自启服务
setup_system_service() {
    os="$(detect_os)"
    log_info "配置系统服务与开机自启..."

    if [ "$os" = "alpine" ]; then
        generate_openrc_service "${OPENRC_SERVICE_DIR}/${SERVICE_NAME}"
        if [ "${TEST_MODE:-0}" != "1" ]; then
            rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        fi
        log_ok "已注册 OpenRC 自启服务 (${OPENRC_SERVICE_DIR}/${SERVICE_NAME})"
    else
        generate_systemd_service "${SYSTEMD_SERVICE_DIR}/${SERVICE_NAME}.service"
        if [ "${TEST_MODE:-0}" != "1" ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
        log_ok "已注册 Systemd 自启服务 (${SYSTEMD_SERVICE_DIR}/${SERVICE_NAME}.service)"
    fi
}

# 获取服务运行状态 (running / stopped / not_installed)
get_service_status() {
    os="$(detect_os)"
    if [ "$os" = "alpine" ]; then
        if [ ! -f "${OPENRC_SERVICE_DIR}/${SERVICE_NAME}" ]; then
            echo "not_installed"
            return 0
        fi
        if [ "${TEST_MODE:-0}" = "1" ]; then
            echo "running"
            return 0
        fi
        if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        if [ ! -f "${SYSTEMD_SERVICE_DIR}/${SERVICE_NAME}.service" ]; then
            echo "not_installed"
            return 0
        fi
        if [ "${TEST_MODE:-0}" = "1" ]; then
            echo "running"
            return 0
        fi
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
    fi
}

# 判断自启是否开启
is_autostart_enabled() {
    if [ "${TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    os="$(detect_os)"
    if [ "$os" = "alpine" ]; then
        rc-status default 2>/dev/null | grep -q "${SERVICE_NAME}"
    else
        systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null
    fi
}

# 启动服务
start_service() {
    if [ "${TEST_MODE:-0}" != "1" ]; then
        os="$(detect_os)"
        if [ "$os" = "alpine" ]; then
            rc-service "${SERVICE_NAME}" start >/dev/null 2>&1 || true
        else
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl start "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    log_ok "GOST 转发服务已启动"
}

# 停止服务
stop_service() {
    if [ "${TEST_MODE:-0}" != "1" ]; then
        os="$(detect_os)"
        if [ "$os" = "alpine" ]; then
            rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
        else
            systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    log_ok "GOST 转发服务已停止"
}

# 重启服务
restart_service() {
    if [ "${TEST_MODE:-0}" != "1" ]; then
        os="$(detect_os)"
        if [ "$os" = "alpine" ]; then
            rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1 || true
        else
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    log_ok "GOST 转发服务已重启并重载最新配置"
}

# 开启自启
enable_autostart() {
    if [ "${TEST_MODE:-0}" != "1" ]; then
        os="$(detect_os)"
        if [ "$os" = "alpine" ]; then
            rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        else
            systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    log_ok "已开启开机自启"
}

# 关闭自启
disable_autostart() {
    if [ "${TEST_MODE:-0}" != "1" ]; then
        os="$(detect_os)"
        if [ "$os" = "alpine" ]; then
            rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        else
            systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    log_ok "已关闭开机自启"
}

# 管理防火墙端口
manage_firewall() {
    port_spec="$1"
    action="${2:-allow}" # allow | delete
    proto="${3:-all}"    # all | tcp | udp

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [ "$action" = "allow" ]; then
            [ "$proto" = "all" ] || [ "$proto" = "tcp" ] && ufw allow "${port_spec}/tcp" >/dev/null 2>&1 || true
            [ "$proto" = "all" ] || [ "$proto" = "udp" ] && ufw allow "${port_spec}/udp" >/dev/null 2>&1 || true
        else
            [ "$proto" = "all" ] || [ "$proto" = "tcp" ] && ufw delete allow "${port_spec}/tcp" >/dev/null 2>&1 || true
            [ "$proto" = "all" ] || [ "$proto" = "udp" ] && ufw delete allow "${port_spec}/udp" >/dev/null 2>&1 || true
        fi
        log_info "已更新 UFW 防火墙端口放行规则: ${port_spec} (${proto})"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        op="--add-port"
        [ "$action" = "delete" ] && op="--remove-port"
        [ "$proto" = "all" ] || [ "$proto" = "tcp" ] && firewall-cmd --permanent "${op}=${port_spec}/tcp" >/dev/null 2>&1 || true
        [ "$proto" = "all" ] || [ "$proto" = "udp" ] && firewall-cmd --permanent "${op}=${port_spec}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_info "已更新 Firewalld 防火墙端口放行规则: ${port_spec} (${proto})"
    fi
}

# CLI 自动化非交互部署
cli_deploy() {
    require_root
    log_info "=========================================================="
    log_info " 开始通过 CLI 参数自动化部署 GOST 端口转发"
    log_info "=========================================================="
    log_info "目标地址: ${CLI_DEST}"
    log_info "转发端口: ${CLI_PORT}"
    log_info "转发协议: ${CLI_MODE}"
    log_info "绑定地址: ${CLI_BIND}"

    install_gost_binary

    if check_port_overlap "$CLI_PORT"; then
        log_warn "检测到端口段 ${CLI_PORT} 与现有规则重叠，将追加并更新配置"
    fi

    add_rule "$CLI_DEST" "$CLI_PORT" "$CLI_MODE" "$CLI_BIND" "enabled"
    generate_gost_config

    setup_system_service
    restart_service
    enable_autostart

    manage_firewall "$CLI_PORT" "allow" "$CLI_MODE"

    echo ""
    log_ok "=========================================================="
    log_ok "🎉 GOST 端口转发自动部署成功！"
    log_ok " 本地监听: ${CLI_BIND}:${CLI_PORT}"
    log_ok " 目标转发: ${CLI_DEST}:${CLI_PORT}"
    log_ok " 传输协议: ${CLI_MODE} (TCP/UDP 一一对应)"
    log_ok " 后台守护: 已配置自启动 (${SERVICE_NAME})"
    log_ok " 配置文件: ${CONFIG_FILE}"
    log_ok "=========================================================="
}

# 交互式添加规则
interactive_add_rule() {
    echo ""
    printf "%b=== 添加 GOST 端口转发规则 ===%b\n" "$BOLD" "$NC"
    
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
            log_error "目标地址格式无效，请输入正确的 IPv4、IPv6 或域名 (例如: 1.1.1.1 或 example.com)"
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

    install_gost_binary
    add_rule "$target" "$port_spec" "$proto" "$bind_ip" "enabled"
    generate_gost_config
    setup_system_service
    restart_service
    enable_autostart
    manage_firewall "$port_spec" "allow" "$proto"

    echo ""
    log_ok "规则添加成功并已实时生效！"
}

# 交互式删除规则
interactive_delete_rule() {
    echo ""
    printf "%b=== 删除 GOST 端口转发规则 ===%b\n" "$BOLD" "$NC"
    list_rules
    printf "请输入要删除的规则 ID (输入 0 或直接回车取消): "
    read -r del_id
    del_id=$(echo "$del_id" | tr -d '[:space:]')
    if [ -z "$del_id" ] || [ "$del_id" = "0" ]; then
        log_info "已取消删除"
        return 0
    fi

    if delete_rule "$del_id"; then
        generate_gost_config
        restart_service
        log_ok "已重载最新转发配置"
    fi
}

# 查看日志
view_logs() {
    os="$(detect_os)"
    log_info "正在查看服务日志 (按 Ctrl+C 退出)..."
    sleep 1
    if [ "$os" = "alpine" ]; then
        if [ -f "/var/log/messages" ]; then
            tail -n 50 -f /var/log/messages | grep --line-buffered "${SERVICE_NAME}" || true
        else
            log_warn "未找到 Alpine 系统日志文件 /var/log/messages"
        fi
    else
        journalctl -u "${SERVICE_NAME}" -f -n 50 || true
    fi
}

# 交互式服务控制
interactive_service_control() {
    while :; do
        echo ""
        printf "%b=== GOST 服务与自启控制 ===%b\n" "$BOLD" "$NC"
        cur_status="$(get_service_status)"
        printf "当前运行状态: %s\n" "$cur_status"
        echo "1. 启动服务"
        echo "2. 停止服务"
        echo "3. 重启服务"
        echo "4. 开启开机自启"
        echo "5. 关闭开机自启"
        echo "6. 查看实时服务日志"
        echo "0. 返回主菜单"
        printf "请选择操作 [0-6]: "
        read -r s_choice
        case "$s_choice" in
            1) start_service ;;
            2) stop_service ;;
            3) restart_service ;;
            4) enable_autostart ;;
            5) disable_autostart ;;
            6) view_logs ;;
            0) break ;;
            *) log_warn "无效选项，请重新输入" ;;
        esac
    done
}

# 交互式完全卸载
interactive_uninstall() {
    echo ""
    printf "%b%b=== 完全卸载 GOST 服务 ===%b\n" "$RED" "$BOLD" "$NC"
    printf "⚠️ 确认要停止并彻底卸载 GOST 及所有转发规则配置吗？(y/N): "
    read -r confirm
    case "$confirm" in
        [Yy]*) ;;
        *)
            log_info "已取消卸载"
            return 0
            ;;
    esac

    log_info "正在停止并清理服务..."
    stop_service 2>/dev/null || true
    disable_autostart 2>/dev/null || true

    os="$(detect_os)"
    if [ "$os" = "alpine" ]; then
        rm -f "${OPENRC_SERVICE_DIR}/${SERVICE_NAME}" 2>/dev/null || true
    else
        rm -f "${SYSTEMD_SERVICE_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true
        [ "${TEST_MODE:-0}" != "1" ] && systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 清理二进制与配置
    rm -f "$GOST_BIN"
    rm -rf "$GOST_CONFIG_DIR"

    log_ok "GOST 服务及所有配置已彻底卸载清理完毕！"
}

# 展示主菜单面板
show_menu() {
    clear 2>/dev/null || true
    os="$(detect_os)"
    s_status="$(get_service_status)"
    case "$s_status" in
        running) s_display="${GREEN}● 运行中${NC}" ;;
        stopped) s_display="${YELLOW}○ 已停止${NC}" ;;
        *) s_display="${RED}未安装/未配置${NC}" ;;
    esac

    if is_autostart_enabled; then
        auto_display="${GREEN}✅ 已开启${NC}"
    else
        auto_display="${YELLOW}❌ 未开启${NC}"
    fi

    rule_count=0
    if [ -f "$RULES_FILE" ]; then
        rule_count=$(grep -v '^#' "$RULES_FILE" 2>/dev/null | grep -v '^$' | wc -l || echo 0)
        rule_count=$(echo "$rule_count" | tr -d '[:space:]')
    fi

    gost_ver="未安装"
    if [ -x "$GOST_BIN" ]; then
        gost_ver="$("$GOST_BIN" -V 2>&1 | head -n 1 | awk '{print $NF}')"
        [ -z "$gost_ver" ] && gost_ver="已安装"
    fi

    printf "%b================================================================%b\n" "$CYAN" "$NC"
    printf "       %bGOST 端口转发自动化管理面板 (v%s)%b\n" "$BOLD" "$SCRIPT_VERSION" "$NC"
    printf "%b================================================================%b\n" "$CYAN" "$NC"
    printf " 系统发行版: %-12s | GOST 版本: %s\n" "$os" "$gost_ver"
    printf " 服务状态  : %b   | 开机自启: %b\n" "$s_display" "$auto_display"
    printf " 当前规则数: %s 条\n" "$rule_count"
    printf "%b================================================================%b\n" "$CYAN" "$NC"
    echo " 1. ➕ 添加转发规则 (IP/域名, 端口或端口段)"
    echo " 2. 📋 查看所有规则与当前运行状态"
    echo " 3. 🗑️  删除指定转发规则"
    echo " 4. ⚙️  服务管理 (启动 / 停止 / 重启 / 自启)"
    echo " 5. 🧹 完全卸载 GOST 服务及清理配置"
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
