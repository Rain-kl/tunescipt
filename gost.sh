#!/bin/bash
# ==============================================================================
# Script Name: gost.sh
# Description: GOST v3 端口转发自动化部署与管理脚本 (支持 Alpine / Debian 系)
# Author: Rain-kl & Antigravity
# GitHub: https://github.com/Rain-kl/tunescipt
# ==============================================================================

set -eo pipefail

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

log_info()  { echo -e "${BLUE}ℹ️  $*${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error() { echo -e "${RED}❌ $*${NC}" >&2; }

# 检测并确认 root 权限
require_root() {
    if [ "${TEST_MODE:-0}" = "1" ]; then
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 用户或 sudo 执行此脚本"
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
    local arch
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
    local spec="$1"
    if [ -z "$spec" ]; then
        return 1
    fi

    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        if [ "$start" -ge 1 ] && [ "$start" -le 65535 ] && \
           [ "$end" -ge 1 ] && [ "$end" -le 65535 ] && \
           [ "$start" -le "$end" ]; then
            return 0
        fi
        return 1
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        if [ "$spec" -ge 1 ] && [ "$spec" -le 65535 ]; then
            return 0
        fi
        return 1
    fi
    return 1
}

# 校验目标地址 (支持 IPv4, IPv6, 域名)
validate_target() {
    local target="$1"
    if [ -z "$target" ]; then
        return 1
    fi

    # IPv4 正则校验
    local ipv4_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
    if [[ "$target" =~ $ipv4_regex ]]; then
        return 0
    fi

    # IPv6 简单结构校验 (含至少一个冒号，仅含十六进制与冒号)
    if [[ "$target" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$target" == *:* ]]; then
        return 0
    fi

    # 域名/主机名正则校验
    local domain_regex="^([a-zA-Z0-9](([a-zA-Z0-9-]){0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    local hostname_regex="^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"
    if [[ "$target" =~ $domain_regex ]] || [[ "$target" =~ $hostname_regex ]]; then
        # 排除连续点等异常域名
        if [[ "$target" =~ \.\. ]]; then
            return 1
        fi
        return 0
    fi

    return 1
}

# 显示帮助信息
show_help() {
    echo -e "${BOLD}GOST 端口转发自动化部署脚本 (v${SCRIPT_VERSION})${NC}

${BOLD}用法:${NC}
  bash gost.sh [选项]
  curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/gost.sh | sudo bash -s -- [选项]

${BOLD}CLI 快速选项:${NC}
  -d, --destination <ip/domain>   目标转发地址 (必填，支持域名或 IPv4/IPv6)
  -p, --port <port/range>         转发端口或端口范围 (必填，如 8080 或 10000-50000)
  -m, --mode <proto>              转发协议: all (默认 TCP+UDP), tcp, udp
  -b, --bind <ip>                 本地监听绑定地址 (默认 0.0.0.0)
  -h, --help                      显示帮助信息

${BOLD}示例:${NC}
  # 转发本地 10000-50000 的所有 TCP/UDP 流量至 1.2.3.4
  sudo bash gost.sh -d 1.2.3.4 -p 10000-50000

  # 仅转发 TCP 端口 8443 至目标域名
  sudo bash gost.sh -d hk.example.com -p 8443 -m tcp

  # 不带任何参数运行，将进入交互式 TUI 管理面板:
  sudo bash gost.sh"
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
                # 供测试脚本引用环境，不执行主逻辑
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

# 解析端口范围为起始与结束数字
get_port_bounds() {
    local spec="$1"
    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        echo "$spec $spec"
    else
        echo "0 0"
    fi
}

# 检测端口是否与已有启用规则重叠
check_port_overlap() {
    local new_spec="$1"
    local exclude_id="${2:-}"
    ensure_config_dir

    local new_bounds
    new_bounds=$(get_port_bounds "$new_spec")
    read -r new_start new_end <<< "$new_bounds"

    if [ "$new_start" -eq 0 ]; then
        return 1
    fi

    if [ ! -f "$RULES_FILE" ]; then
        return 1
    fi

    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        # 跳过注释行、空行与指定排除 ID
        [[ "$r_id" =~ ^#.*$ ]] && continue
        [ -z "$r_id" ] && continue
        [ "$r_id" = "$exclude_id" ] && continue
        [ "${r_status:-enabled}" != "enabled" ] && continue

        local exist_bounds
        exist_bounds=$(get_port_bounds "$r_port")
        read -r exist_start exist_end <<< "$exist_bounds"

        # 判断区间重叠: max(start1, start2) <= min(end1, end2)
        local max_start=$(( new_start > exist_start ? new_start : exist_start ))
        local min_end=$(( new_end < exist_end ? new_end : exist_end ))

        if [ "$max_start" -le "$min_end" ]; then
            # 重叠
            return 0
        fi
    done < "$RULES_FILE"

    return 1
}

# 获取下一个自增 Rule ID
get_next_rule_id() {
    ensure_config_dir
    local max_id=0
    while IFS='|' read -r r_id rest || [ -n "$r_id" ]; do
        [[ "$r_id" =~ ^#.*$ ]] && continue
        [ -z "$r_id" ] && continue
        if [[ "$r_id" =~ ^[0-9]+$ ]]; then
            if [ "$r_id" -gt "$max_id" ]; then
                max_id="$r_id"
            fi
        fi
    done < "$RULES_FILE"
    echo $(( max_id + 1 ))
}

# 添加新转发规则
add_rule() {
    local target="$1"
    local port_spec="$2"
    local proto="${3:-all}"
    local bind_ip="${4:-0.0.0.0}"
    local status="${5:-enabled}"

    ensure_config_dir

    local next_id
    next_id=$(get_next_rule_id)

    echo "${next_id}|${target}|${port_spec}|${proto}|${bind_ip}|${status}" >> "$RULES_FILE"
    log_ok "已添加规则 [ID: ${next_id}] ${port_spec} -> ${target}:${port_spec} (${proto})"
    return 0
}

# 删除转发规则
delete_rule() {
    local id="$1"
    ensure_config_dir

    if ! grep -q "^${id}|" "$RULES_FILE" 2>/dev/null; then
        log_warn "未找到 ID 为 ${id} 的规则"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${GOST_CONFIG_DIR}/rules.tmp.XXXXXX")
    grep -v "^${id}|" "$RULES_FILE" > "$tmp_file" || true
    mv "$tmp_file" "$RULES_FILE"
    log_ok "已删除规则 [ID: ${id}]"
    return 0
}

# 格式化展示规则列表
list_rules() {
    ensure_config_dir
    echo -e "${BOLD}当前转发规则列表:${NC}"
    printf "%-5s | %-18s | %-24s | %-6s | %-10s | %-8s\n" "ID" "监听端口" "转发目标" "协议" "绑定地址" "状态"
    echo "----------------------------------------------------------------------------------------"
    local count=0
    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        [[ "$r_id" =~ ^#.*$ ]] && continue
        [ -z "$r_id" ] && continue
        count=$((count + 1))
        local status_display
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
    local tmp_yaml
    tmp_yaml=$(mktemp "${GOST_CONFIG_DIR}/config.yaml.tmp.XXXXXX")

    cat << 'EOF' > "$tmp_yaml"
# GOST v3 自动化生成配置文件 (请勿手动修改)
# 由 gost.sh 自动维护
services:
EOF

    local has_services=0
    while IFS='|' read -r r_id r_target r_port r_proto r_bind r_status || [ -n "$r_id" ]; do
        [[ "$r_id" =~ ^#.*$ ]] && continue
        [ -z "$r_id" ] && continue
        [ "${r_status:-enabled}" != "enabled" ] && continue

        has_services=1

        # 处理监听地址
        local listen_addr
        if [ -z "$r_bind" ] || [ "$r_bind" = "0.0.0.0" ]; then
            listen_addr=":${r_port}"
        else
            listen_addr="${r_bind}:${r_port}"
        fi

        # 处理目标地址 (IPv6 包含冒号需加中括号)
        local formatted_target="$r_target"
        if [[ "$formatted_target" == *:* ]] && [[ "$formatted_target" != \[*\]* ]]; then
            formatted_target="[${formatted_target}]"
        fi
        local target_addr="${formatted_target}:${r_port}"

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
    local target_path="$1"
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
    local target_path="$1"
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
    local os
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
        local current_ver
        current_ver="$("$GOST_BIN" -V 2>&1 | head -n 1)"
        log_info "检测到已安装 GOST: ${current_ver}"
        return 0
    fi

    install_dependencies

    local arch
    arch="$(detect_arch)"
    log_info "正在下载 GOST v3 (Linux/${arch})..."

    local gost_version="3.3.0"
    local filename="gost_${gost_version}_linux_${arch}.tar.gz"
    local download_urls=(
        "https://github.com/go-gost/gost/releases/download/v${gost_version}/${filename}"
        "https://ghproxy.net/https://github.com/go-gost/gost/releases/download/v${gost_version}/${filename}"
        "https://mirror.ghproxy.com/https://github.com/go-gost/gost/releases/download/v${gost_version}/${filename}"
    )

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local success=0

    for url in "${download_urls[@]}"; do
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
    local os
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
    local os
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
    local os
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
        local os
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
        local os
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
        local os
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
        local os
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
        local os
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
    local port_spec="$1"
    local action="${2:-allow}" # allow | delete
    local proto="${3:-all}"    # all | tcp | udp

    # 如果有 ufw
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
        local op="--add-port"
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
    echo -e "${BOLD}=== 添加 GOST 端口转发规则 ===${NC}"
    
    # 目标地址输入
    local target=""
    while true; do
        read -r -p "请输入目标转发地址 (域名或 IP): " target
        target="${target// /}"
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
    local port_spec=""
    while true; do
        read -r -p "请输入转发端口或范围 (如 8080 或 10000-50000): " port_spec
        port_spec="${port_spec// /}"
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
            read -r -p "是否仍然强制添加此规则? (y/N): " force_add
            if [[ ! "$force_add" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        break
    done

    # 协议选择
    echo "请选择转发协议:"
    echo "  1) TCP + UDP (默认，推荐)"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    read -r -p "请输入选项 [1-3] (回车默认 1): " proto_choice
    local proto="all"
    case "$proto_choice" in
        2) proto="tcp" ;;
        3) proto="udp" ;;
        *) proto="all" ;;
    esac

    # 本地绑定 IP (可选)
    read -r -p "请输入本地绑定 IP (回车默认 0.0.0.0 全部监听): " bind_ip
    bind_ip="${bind_ip// /}"
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
    echo -e "${BOLD}=== 删除 GOST 端口转发规则 ===${NC}"
    list_rules
    read -r -p "请输入要删除的规则 ID (输入 0 或直接回车取消): " del_id
    del_id="${del_id// /}"
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
    local os
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
    while true; do
        echo ""
        echo -e "${BOLD}=== GOST 服务与自启控制 ===${NC}"
        local cur_status
        cur_status="$(get_service_status)"
        echo -e "当前运行状态: ${cur_status}"
        echo "1. 启动服务"
        echo "2. 停止服务"
        echo "3. 重启服务"
        echo "4. 开启开机自启"
        echo "5. 关闭开机自启"
        echo "6. 查看实时服务日志"
        echo "0. 返回主菜单"
        read -r -p "请选择操作 [0-6]: " s_choice
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
    echo -e "${RED}${BOLD}=== 完全卸载 GOST 服务 ===${NC}"
    read -r -p "⚠️ 确认要停止并彻底卸载 GOST 及所有转发规则配置吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消卸载"
        return 0
    fi

    log_info "正在停止并清理服务..."
    stop_service 2>/dev/null || true
    disable_autostart 2>/dev/null || true

    local os
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
    local os
    os="$(detect_os)"
    local s_status
    s_status="$(get_service_status)"
    local s_display
    case "$s_status" in
        running) s_display="${GREEN}● 运行中${NC}" ;;
        stopped) s_display="${YELLOW}○ 已停止${NC}" ;;
        *) s_display="${RED}未安装/未配置${NC}" ;;
    esac

    local auto_display
    if is_autostart_enabled; then
        auto_display="${GREEN}✅ 已开启${NC}"
    else
        auto_display="${YELLOW}❌ 未开启${NC}"
    fi

    local rule_count=0
    if [ -f "$RULES_FILE" ]; then
        rule_count=$(grep -v '^#' "$RULES_FILE" 2>/dev/null | grep -v '^$' | wc -l || echo 0)
        rule_count="${rule_count// /}"
    fi

    local gost_ver="未安装"
    if [ -x "$GOST_BIN" ]; then
        gost_ver="$("$GOST_BIN" -V 2>&1 | head -n 1 | awk '{print $NF}')"
        [ -z "$gost_ver" ] && gost_ver="已安装"
    fi

    echo -e "${CYAN}================================================================${NC}"
    echo -e "       ${BOLD}GOST 端口转发自动化管理面板 (v${SCRIPT_VERSION})${NC}"
    echo -e "${CYAN}================================================================${NC}"
    printf " 系统发行版: %-12s | GOST 版本: %s\n" "$os" "$gost_ver"
    printf " 服务状态  : %b   | 开机自启: %b\n" "$s_display" "$auto_display"
    printf " 当前规则数: %s 条\n" "$rule_count"
    echo -e "${CYAN}================================================================${NC}"
    echo " 1. ➕ 添加转发规则 (IP/域名, 端口或端口段)"
    echo " 2. 📋 查看所有规则与当前运行状态"
    echo " 3. 🗑️  删除指定转发规则"
    echo " 4. ⚙️  服务管理 (启动 / 停止 / 重启 / 自启)"
    echo " 5. 🧹 完全卸载 GOST 服务及清理配置"
    echo " 0. 🚪 退出脚本"
    echo -e "${CYAN}================================================================${NC}"
}

# TUI 交互主循环
menu_loop() {
    require_root
    ensure_config_dir
    while true; do
        show_menu
        read -r -p "请选择操作 [0-5]: " choice
        case "$choice" in
            1)
                interactive_add_rule
                read -r -p "按回车键继续..."
                ;;
            2)
                echo ""
                list_rules
                read -r -p "按回车键继续..."
                ;;
            3)
                interactive_delete_rule
                read -r -p "按回车键继续..."
                ;;
            4)
                interactive_service_control
                ;;
            5)
                interactive_uninstall
                read -r -p "按回车键继续..."
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
    # 检查是否仅为 source 引入
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
