#!/usr/bin/env bash
set -euo pipefail

# =========================
# 颜色和日志函数
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}ℹ️  $*${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error() { echo -e "${RED}❌ $*${NC}"; }

# =========================
# 输入验证函数
# =========================
# 验证 Y/N 输入，返回标准化结果
validate_yn() {
  local input="$1"
  local default="${2:-Y}"
  input="${input:-$default}"
  input="$(echo "$input" | tr '[:lower:]' '[:upper:]')"
  case "$input" in
    Y|YES) echo "Y" ;;
    N|NO)  echo "N" ;;
    *)     echo "$default" ;;
  esac
}

# 验证数字范围
validate_number() {
  local input="$1"
  local min="$2"
  local max="$3"
  local default="$4"
  
  # 去除空白
  input="${input//[[:space:]]/}"
  
  # 如果为空，使用默认值
  [[ -z "$input" ]] && { echo "$default"; return 0; }
  
  # 检查是否为数字
  if ! [[ "$input" =~ ^[0-9]+$ ]]; then
    echo "$default"
    return 0
  fi
  
  # 范围检查
  if (( input < min )); then
    echo "$min"
  elif (( input > max )); then
    echo "$max"
  else
    echo "$input"
  fi
}

# 验证压缩算法
validate_algo() {
  local input="$1"
  input="$(echo "$input" | tr '[:upper:]' '[:lower:]')"
  case "$input" in
    lz4|zstd|lzo) echo "$input" ;;
    *) echo "lz4" ;;  # 默认使用 lz4
  esac
}

# 验证 swap 大小格式（如 1G, 2G, 1024M）
validate_swap_size() {
  local input="$1"
  local default="$2"
  
  input="${input//[[:space:]]/}"
  [[ -z "$input" ]] && { echo "$default"; return 0; }
  
  # 支持 G 和 M 后缀
  if [[ "$input" =~ ^[0-9]+[GgMm]$ ]]; then
    echo "$input" | tr '[:lower:]' '[:upper:]'
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    # 纯数字默认为 MB
    echo "${input}M"
  else
    echo "$default"
  fi
}

# 将 swap 大小转换为 MB
swap_size_to_mb() {
  local size="$1"
  local num="${size%[GgMm]}"
  local suffix="${size: -1}"
  suffix="$(echo "$suffix" | tr '[:lower:]' '[:upper:]')"
  
  case "$suffix" in
    G) echo $(( num * 1024 )) ;;
    M) echo "$num" ;;
    *) echo "$num" ;;
  esac
}

# =========================
# 基础检查
# =========================
if ! grep -qiE 'debian|ubuntu' /etc/os-release; then
  log_error "此脚本仅支持 Debian / Ubuntu 系"
  exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  log_error "请使用 root 或 sudo 运行"
  exit 1
fi

RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CORES=$(nproc 2>/dev/null || echo 1)

DISK_SWAPS="$(swapon --noheadings --raw --output=NAME 2>/dev/null | grep -vE '^/dev/zram[0-9]+$' || true)"
HAS_DISK_SWAP=0
[[ -n "${DISK_SWAPS}" ]] && HAS_DISK_SWAP=1

# =========================
# 函数区
# =========================
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  log_info "已备份: ${f}.bak.*"
}

# 找到根分区底层物理磁盘（尽量）
root_base_disk() {
  local src base pk
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$src" ]] || { echo ""; return 0; }

  # 例：/dev/sda2, /dev/nvme0n1p2, /dev/mapper/xxx, UUID=..., overlay...
  if [[ "$src" =~ ^/dev/ ]]; then
    base="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
    if [[ -n "$base" ]]; then
      echo "$base"
      return 0
    fi
    # 有些场景 PKNAME 为空，退化为 KNAME
    base="$(lsblk -no KNAME "$src" 2>/dev/null | head -n1 || true)"
    echo "$base"
    return 0
  fi

  # 处理 UUID=... 或其他：用 findmnt -> SOURCE 再喂给 lsblk 可能无效，直接返回空
  echo ""
}

disk_is_rotational() {
  local disk="$1"
  [[ -n "$disk" ]] || { echo "unknown"; return 0; }
  local p="/sys/block/${disk}/queue/rotational"
  [[ -f "$p" ]] || { echo "unknown"; return 0; }
  if [[ "$(cat "$p")" == "1" ]]; then
    echo "hdd"
  else
    echo "ssd"
  fi
}

# 选择 swapfile 放置的挂载点（/ /var /home）里可用空间最大的那个
best_swap_mountpoint() {
  local best_mp="/" best_free=-1
  local mp free
  for mp in / /var /home; do
    if mountpoint -q "$mp" 2>/dev/null || [[ "$mp" == "/" ]]; then
      free="$(df -BM "$mp" 2>/dev/null | awk 'NR==2{gsub(/M/,"",$4); print int($4)}' || echo 0)"
      if (( free > best_free )); then
        best_free=$free
        best_mp=$mp
      fi
    fi
  done
  echo "$best_mp"
}

root_free_mb() {
  df -BM / | awk 'NR==2{gsub(/M/,"",$4); print int($4)}'
}

# 获取根分区所在磁盘的总大小（MB）
root_disk_size_mb() {
  local disk="$1"
  local size_bytes size_mb
  
  # 如果磁盘名为空，尝试从根分区获取
  if [[ -z "$disk" ]]; then
    disk="$(root_base_disk)"
  fi
  
  [[ -z "$disk" ]] && { echo "0"; return 0; }
  
  # 尝试从 /sys/block 获取大小（以 512 字节扇区为单位）
  local size_file="/sys/block/${disk}/size"
  if [[ -f "$size_file" ]]; then
    local sectors
    sectors=$(cat "$size_file" 2>/dev/null || echo 0)
    size_mb=$(( sectors * 512 / 1024 / 1024 ))
    echo "$size_mb"
    return 0
  fi
  
  # 备用方案：使用 lsblk
  size_bytes=$(lsblk -bno SIZE "/dev/${disk}" 2>/dev/null | head -n1 || echo 0)
  if [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]; then
    size_mb=$(( size_bytes / 1024 / 1024 ))
    echo "$size_mb"
    return 0
  fi
  
  echo "0"
}

# 获取根分区所在磁盘的总大小（GB）
root_disk_size_gb() {
  local mb
  mb=$(root_disk_size_mb "$1")
  echo $(( mb / 1024 ))
}

update_fstab_swap_pri_all() {
  local pri="$1"
  local fstab="/etc/fstab"
  backup_file "$fstab"

  awk -v pri="$pri" '
    BEGIN{OFS="\t"}
    /^[[:space:]]*#/ {print; next}
    NF<4 {print; next}
    $3=="swap" {
      opts=$4
      if (opts ~ /(^|,)pri=[0-9]+(,|$)/) {
        gsub(/(^|,)pri=[0-9]+(,|$)/, "\\1pri=" pri "\\2", opts)
        gsub(/,,+/, ",", opts)
        sub(/^,/, "", opts); sub(/,$/, "", opts)
      } else {
        if (opts=="" || opts=="-") opts="sw"
        opts=opts ",pri=" pri
      }
      $4=opts
      print; next
    }
    {print}
  ' "$fstab" > "${fstab}.tmp"

  mv "${fstab}.tmp" "$fstab"
}

ensure_fstab_swapfile() {
  local path="$1"
  local pri="$2"
  local fstab="/etc/fstab"
  backup_file "$fstab"

  awk -v p="$path" '
    BEGIN{OFS="\t"}
    /^[[:space:]]*#/ {print; next}
    $1==p && $3=="swap" {next}
    {print}
  ' "$fstab" > "${fstab}.tmp"

  echo -e "${path}\tnone\tswap\tsw,pri=${pri}\t0\t0" >> "${fstab}.tmp"
  mv "${fstab}.tmp" "$fstab"
}

create_swapfile() {
  local path="$1"
  local size="$2"

  if [[ -e "$path" ]]; then
    if file -b "$path" 2>/dev/null | grep -qi 'swap file'; then
      log_info "已存在 swapfile: $path（将直接复用）"
      return 0
    fi
    log_error "路径已存在但不是 swapfile: $path"
    log_error "为安全起见，不会覆盖。请换个路径，或手动处理后重试。"
    exit 1
  fi

  log_info "创建 swapfile: $path (大小: $size)"
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "$size" "$path"
  else
    log_warn "系统无 fallocate，使用 dd 创建..."
    dd if=/dev/zero of="$path" bs=1M count=0 seek="$size" status=none
  fi

  chmod 600 "$path"
  mkswap "$path" >/dev/null
}

enable_swap_target() {
  local target="$1"
  local pri="$2"
  if swapon --noheadings --raw --output=NAME 2>/dev/null | grep -qx "$target"; then
    swapoff "$target"
  fi
  swapon -p "$pri" "$target"
}

# sysctl 写入/更新
write_sysctl_conf() {
  local file="/etc/sysctl.d/99-zram-swap.conf"
  backup_file "$file"
  cat > "$file" <<EOF
# Generated by zram+swap setup script
vm.swappiness = $1
vm.page-cluster = $2
EOF
  sysctl --system >/dev/null || true
  log_ok "已写入并应用 sysctl: $file"
}

# =========================
# 额外信息：磁盘类型和大小
# =========================
BASE_DISK="$(root_base_disk)"
DISK_KIND="$(disk_is_rotational "$BASE_DISK")"  # ssd/hdd/unknown
DISK_SIZE_GB=$(root_disk_size_gb "$BASE_DISK")
DISK_SIZE_MB=$(root_disk_size_mb "$BASE_DISK")

# =========================
# 配置模式选择
# =========================
echo
echo "==================== 配置模式选择 ===================="
echo "  1) 一键配置"
echo "  2) 仅配置 zram"
echo "  3) 仅配置 swap"
echo "======================================================="
echo

# 尝试从 /dev/tty 读取输入（支持 curl | bash 方式运行）
if [ -t 0 ]; then
  # 标准输入是终端
  read -rp "请选择配置模式 [1/2/3，默认 1]: " CONFIG_MODE
else
  # 标准输入不是终端（如 curl | bash），尝试从 /dev/tty 读取
  if [ -r /dev/tty ]; then
    read -rp "请选择配置模式 [1/2/3，默认 1]: " CONFIG_MODE </dev/tty
  else
    # 无法读取输入，使用默认值
    CONFIG_MODE="1"
    log_info "自动使用默认配置模式（无交互式终端）"
  fi
fi

CONFIG_MODE="${CONFIG_MODE:-1}"

# 验证输入
case "$CONFIG_MODE" in
  1|一键|all|ALL|All)     CONFIG_MODE="all" ;;
  2|zram|ZRAM|Zram)       CONFIG_MODE="zram" ;;
  3|swap|SWAP|Swap)       CONFIG_MODE="swap" ;;
  *)
    log_warn "无效选择: ${CONFIG_MODE}，将使用默认模式: 一键优配置"
    CONFIG_MODE="all"
    ;;
esac

case "$CONFIG_MODE" in
  all)  log_info "已选择: 一键优配置（zram + swap）" ;;
  zram) log_info "已选择: 仅配置 zram" ;;
  swap) log_info "已选择: 仅配置 swap" ;;
esac

# =========================
# 1) zram 推荐配置
# =========================
if (( RAM_MB <= 2048 )); then
  REC_SIZE_EXPR="ram * 3 / 2"; REC_NUM=3; REC_DEN=2
elif (( RAM_MB <= 4096 )); then
  REC_SIZE_EXPR="ram"; REC_NUM=1; REC_DEN=1
elif (( RAM_MB <= 8192 )); then
  REC_SIZE_EXPR="ram * 3 / 4"; REC_NUM=3; REC_DEN=4
elif (( RAM_MB <= 16384 )); then
  REC_SIZE_EXPR="ram / 2"; REC_NUM=1; REC_DEN=2
else
  REC_SIZE_EXPR="ram / 4"; REC_NUM=1; REC_DEN=4
fi

if (( CORES <= 2 )); then
  REC_ALGO="lz4"
else
  if (( RAM_MB <= 4096 )); then REC_ALGO="lz4"; else REC_ALGO="zstd"; fi
fi

if (( HAS_DISK_SWAP == 1 )); then
  REC_ZRAM_PRIO=200
else
  REC_ZRAM_PRIO=100
fi

REC_ZRAM_MB=$(( RAM_MB * REC_NUM / REC_DEN ))

echo
echo "==================== 系统信息 ===================="
echo "🧠 物理内存: ${RAM_MB} MB"
echo "🧮 CPU 核心数: ${CORES}"
if [[ -n "$BASE_DISK" ]]; then
  echo "💾 根分区磁盘: ${BASE_DISK}（类型: ${DISK_KIND}，大小: ${DISK_SIZE_GB}G）"
else
  echo "💾 根分区磁盘: 未能确定（类型: unknown）"
fi
echo "💽 磁盘 swap: $([[ $HAS_DISK_SWAP -eq 1 ]] && echo '已存在' || echo '不存在')"
echo "=================================================="

# 初始化变量（避免未定义错误）
ZRAM_SIZE=""
COMP_ALGO=""
ZRAM_PRIO=""
SWAP_ACTION="skip"
SWAP_MODE=""
SWAPFILE_PATH=""
SWAPFILE_SIZE=""
DISK_SWAP_PRIO=""
SYSCTL_ACTION="skip"
SYS_SWAPPINESS=""
SYS_PAGE_CLUSTER=""

# =========================
# zram 配置（仅在 all 或 zram 模式下执行）
# =========================
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "zram" ]]; then
  echo
  echo "👉 推荐 zram 配置:"
  echo "   zram-size: ${REC_SIZE_EXPR} (约 ${REC_ZRAM_MB} MB)"
  echo "   compression-algorithm: ${REC_ALGO}"
  echo "   swap-priority: ${REC_ZRAM_PRIO} (自动设置)"
  echo

  if [ -t 0 ]; then
    read -rp "是否使用推荐 zram 配置? [Y/n] " USE_REC
  elif [ -r /dev/tty ]; then
    read -rp "是否使用推荐 zram 配置? [Y/n] " USE_REC </dev/tty
  else
    USE_REC="Y"
    log_info "使用推荐 zram 配置（无交互式终端）"
  fi
  USE_REC=$(validate_yn "$USE_REC" "Y")

  if [[ "$USE_REC" == "Y" ]]; then
    ZRAM_SIZE="$REC_SIZE_EXPR"
    COMP_ALGO="$REC_ALGO"
    ZRAM_PRIO="$REC_ZRAM_PRIO"
  else
    if [ -t 0 ]; then
      read -rp "请输入 zram-size (如: ram / 2 或 1024M) [$REC_SIZE_EXPR]: " ZRAM_SIZE
      read -rp "请选择压缩算法 (lz4/zstd/lzo) [$REC_ALGO]: " COMP_ALGO
    elif [ -r /dev/tty ]; then
      read -rp "请输入 zram-size (如: ram / 2 或 1024M) [$REC_SIZE_EXPR]: " ZRAM_SIZE </dev/tty
      read -rp "请选择压缩算法 (lz4/zstd/lzo) [$REC_ALGO]: " COMP_ALGO </dev/tty
    else
      ZRAM_SIZE="$REC_SIZE_EXPR"
      COMP_ALGO="$REC_ALGO"
    fi
    ZRAM_SIZE=${ZRAM_SIZE:-$REC_SIZE_EXPR}
    COMP_ALGO=$(validate_algo "${COMP_ALGO:-$REC_ALGO}")
    
    # 优先级自动设置，不需要用户输入
    ZRAM_PRIO="$REC_ZRAM_PRIO"
    log_info "zram swap 优先级自动设置为: ${ZRAM_PRIO}"
  fi

  log_ok "压缩算法: $COMP_ALGO"
fi

# =========================
# 2) 磁盘 swap 推荐配置（含 SSD/HDD 智能）
# =========================
# 仅在 all 或 swap 模式下执行
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "swap" ]]; then
  echo
  echo "👉 磁盘 swap 配置（swapfile / 现有 swap 分区/文件）"

  REC_SWAP_ENABLE="Y"
  if (( HAS_DISK_SWAP == 1 )); then
    REC_SWAP_MODE="tune"
  else
    REC_SWAP_MODE="create"
fi

# 推荐 swapfile 大小（保守，zram 负责主要压力；磁盘 swap 做兜底）
# 重要：如果磁盘大小 <= 10G，swap 不能超过 1G
MAX_SWAP_SIZE="8G"
if (( DISK_SIZE_GB <= 10 )); then
  MAX_SWAP_SIZE="1G"
  log_warn "磁盘空间较小（${DISK_SIZE_GB}G），swap 大小限制为最大 1G"
fi

if (( RAM_MB <= 2048 )); then
  REC_SWAP_SIZE="2G"
elif (( RAM_MB <= 4096 )); then
  REC_SWAP_SIZE="2G"
elif (( RAM_MB <= 8192 )); then
  REC_SWAP_SIZE="4G"
elif (( RAM_MB <= 16384 )); then
  REC_SWAP_SIZE="8G"
else
  REC_SWAP_SIZE="8G"
fi

# 根据磁盘大小限制调整推荐 swap 大小
REC_SWAP_SIZE_MB=$(swap_size_to_mb "$REC_SWAP_SIZE")
MAX_SWAP_SIZE_MB=$(swap_size_to_mb "$MAX_SWAP_SIZE")
if (( REC_SWAP_SIZE_MB > MAX_SWAP_SIZE_MB )); then
  REC_SWAP_SIZE="$MAX_SWAP_SIZE"
  log_info "swap 大小已调整为 ${REC_SWAP_SIZE}（受磁盘大小限制）"
fi

# 推荐磁盘 swap priority（低于 zram；HDD 更低，SSD 可稍高）
# 优先级完全自动计算，无需用户干预
if [[ "$DISK_KIND" == "hdd" ]]; then
  REC_DISK_PRIO=10
elif [[ "$DISK_KIND" == "ssd" ]]; then
  REC_DISK_PRIO=50
else
  REC_DISK_PRIO=30
fi
if (( REC_DISK_PRIO >= ZRAM_PRIO )); then
  REC_DISK_PRIO=$(( ZRAM_PRIO > 20 ? ZRAM_PRIO - 20 : 10 ))
fi

# 推荐 swapfile 路径：放到 / /var /home 中空间最大的挂载点
BEST_MP="$(best_swap_mountpoint)"
REC_SWAPFILE="${BEST_MP%/}/swapfile"
[[ "$REC_SWAPFILE" == "//swapfile" ]] && REC_SWAPFILE="/swapfile"

# 空间太紧时，把推荐 swapfile 降为 1G（仅 create 推荐时）
ROOT_FREE_MB=$(root_free_mb)
if [[ "$REC_SWAP_MODE" == "create" ]]; then
  need_mb=0
  case "$REC_SWAP_SIZE" in
    *G) need_mb=$(( ${REC_SWAP_SIZE%G} * 1024 ));;
    *M) need_mb=$(( ${REC_SWAP_SIZE%M} ));;
    *) need_mb=0;;
  esac
  if (( need_mb > 0 && ROOT_FREE_MB < need_mb + 512 )); then
    log_warn "根分区可用空间约 ${ROOT_FREE_MB}MB，偏紧；推荐 swapfile 大小降为 1G"
    REC_SWAP_SIZE="1G"
  fi
fi

echo "👉 推荐 swap 方案:"
if [[ "$REC_SWAP_MODE" == "create" ]]; then
  echo "   模式: 创建 swapfile"
  echo "   路径: ${REC_SWAPFILE}"
  echo "   大小: ${REC_SWAP_SIZE}"
else
  echo "   模式: 调整已有 swap priority（不新建 swapfile）"
fi
echo "   磁盘类型: ${DISK_KIND}（优先级自动设置）"
echo "   磁盘 swap priority: ${REC_DISK_PRIO}（自动）"
echo

if [ -t 0 ]; then
  read -rp "是否配置磁盘 swap? [Y/n] " DO_SWAP
elif [ -r /dev/tty ]; then
  read -rp "是否配置磁盘 swap? [Y/n] " DO_SWAP </dev/tty
else
  DO_SWAP="Y"
  log_info "自动配置磁盘 swap（无交互式终端）"
fi
DO_SWAP=$(validate_yn "$DO_SWAP" "Y")

SWAP_ACTION="skip"
SWAP_MODE="$REC_SWAP_MODE"
SWAPFILE_PATH="$REC_SWAPFILE"
SWAPFILE_SIZE="$REC_SWAP_SIZE"
DISK_SWAP_PRIO="$REC_DISK_PRIO"

if [[ "$DO_SWAP" == "Y" ]]; then
  if [ -t 0 ]; then
    read -rp "是否使用推荐 swap 方案? [Y/n] " USE_SWAP_REC
  elif [ -r /dev/tty ]; then
    read -rp "是否使用推荐 swap 方案? [Y/n] " USE_SWAP_REC </dev/tty
  else
    USE_SWAP_REC="Y"
    log_info "使用推荐 swap 方案（无交互式终端）"
  fi
  USE_SWAP_REC=$(validate_yn "$USE_SWAP_REC" "Y")

  if [[ "$USE_SWAP_REC" == "Y" ]]; then
    SWAP_ACTION="apply"
  else
    echo "自定义 swap 方案："
    echo "  1) create  - 创建/启用 swapfile"
    echo "  2) tune    - 仅调整已有 swap priority（不新建）"
    echo "  3) off     - 关闭所有磁盘 swap（不建议，谨慎使用）"
    if [ -t 0 ]; then
      read -rp "请选择模式 (1/2/3) [${REC_SWAP_MODE}]: " SWAP_MODE
    elif [ -r /dev/tty ]; then
      read -rp "请选择模式 (1/2/3) [${REC_SWAP_MODE}]: " SWAP_MODE </dev/tty
    else
      SWAP_MODE="$REC_SWAP_MODE"
    fi
    SWAP_MODE=${SWAP_MODE:-$REC_SWAP_MODE}

    # 兼容数字输入，增加健壮性
    case "$SWAP_MODE" in
      1|create|CREATE|Create) SWAP_MODE="create" ;;
      2|tune|TUNE|Tune)       SWAP_MODE="tune" ;;
      3|off|OFF|Off)          SWAP_MODE="off" ;;
      *)
        log_warn "无效选择: $SWAP_MODE，将使用推荐模式: ${REC_SWAP_MODE}"
        SWAP_MODE="$REC_SWAP_MODE"
        ;;
    esac

    # 优先级自动设置，不需要用户输入
    DISK_SWAP_PRIO="$REC_DISK_PRIO"
    log_info "磁盘 swap 优先级自动设置为: ${DISK_SWAP_PRIO}"

    # 只要选择 create，就询问路径和大小（回车用默认）
    if [[ "$SWAP_MODE" == "create" ]]; then
      if [ -t 0 ]; then
        read -rp "swapfile 路径 [${REC_SWAPFILE}]: " SWAPFILE_PATH
      elif [ -r /dev/tty ]; then
        read -rp "swapfile 路径 [${REC_SWAPFILE}]: " SWAPFILE_PATH </dev/tty
      else
        SWAPFILE_PATH="$REC_SWAPFILE"
      fi
      SWAPFILE_PATH=${SWAPFILE_PATH:-$REC_SWAPFILE}
      
      # 验证路径格式
      if [[ ! "$SWAPFILE_PATH" =~ ^/ ]]; then
        log_warn "路径必须是绝对路径，使用默认路径: ${REC_SWAPFILE}"
        SWAPFILE_PATH="$REC_SWAPFILE"
      fi

      if [ -t 0 ]; then
        read -rp "swapfile 大小 (如 1G/2G/4096M) [${REC_SWAP_SIZE}]: " SWAPFILE_SIZE
      elif [ -r /dev/tty ]; then
        read -rp "swapfile 大小 (如 1G/2G/4096M) [${REC_SWAP_SIZE}]: " SWAPFILE_SIZE </dev/tty
      else
        SWAPFILE_SIZE="$REC_SWAP_SIZE"
      fi
      SWAPFILE_SIZE=$(validate_swap_size "$SWAPFILE_SIZE" "$REC_SWAP_SIZE")
      
      # 检查用户输入的大小是否超过磁盘限制
      USER_SIZE_MB=$(swap_size_to_mb "$SWAPFILE_SIZE")
      if (( USER_SIZE_MB > MAX_SWAP_SIZE_MB )); then
        log_warn "输入的 swap 大小 (${SWAPFILE_SIZE}) 超过磁盘限制，已调整为 ${MAX_SWAP_SIZE}"
        SWAPFILE_SIZE="$MAX_SWAP_SIZE"
      fi
      
      # 检查可用空间
      SWAPFILE_SIZE_MB=$(swap_size_to_mb "$SWAPFILE_SIZE")
      if (( SWAPFILE_SIZE_MB > ROOT_FREE_MB - 512 )); then
        local safe_size=$(( ROOT_FREE_MB - 512 ))
        if (( safe_size < 512 )); then
          log_error "磁盘可用空间不足，无法创建 swapfile"
          exit 1
        fi
        SWAPFILE_SIZE="${safe_size}M"
        log_warn "可用空间不足，swapfile 大小调整为: ${SWAPFILE_SIZE}"
      fi
    fi

    SWAP_ACTION="apply"
  fi
fi
fi  # 结束 swap 配置条件块

# =========================
# 3) sysctl 调优（推荐/自定义，可选）
# =========================
# sysctl 配置在所有模式下都可用
echo
echo "👉 sysctl 调优（可选，用于配合 zram+swap）"
# 推荐值：zram 场景下 swappiness 通常提高；page-cluster 设 0 减少 swap readahead（对 zram/SSD 更友好）
REC_SWAPPINESS=180
REC_PAGE_CLUSTER=0

echo "👉 推荐 sysctl:"
echo "   vm.swappiness = ${REC_SWAPPINESS}"
echo "   vm.page-cluster = ${REC_PAGE_CLUSTER}"
echo

if [ -t 0 ]; then
  read -rp "是否应用 sysctl 推荐/自定义配置? [y/N] " DO_SYSCTL
elif [ -r /dev/tty ]; then
  read -rp "是否应用 sysctl 推荐/自定义配置? [y/N] " DO_SYSCTL </dev/tty
else
  DO_SYSCTL="N"
  log_info "跳过 sysctl 配置（无交互式终端）"
fi
DO_SYSCTL=$(validate_yn "$DO_SYSCTL" "N")

SYS_SWAPPINESS="$REC_SWAPPINESS"
SYS_PAGE_CLUSTER="$REC_PAGE_CLUSTER"

if [[ "$DO_SYSCTL" == "Y" ]]; then
  if [ -t 0 ]; then
    read -rp "是否使用推荐 sysctl 配置? [Y/n] " USE_SYSCTL_REC
  elif [ -r /dev/tty ]; then
    read -rp "是否使用推荐 sysctl 配置? [Y/n] " USE_SYSCTL_REC </dev/tty
  else
    USE_SYSCTL_REC="Y"
  fi
  USE_SYSCTL_REC=$(validate_yn "$USE_SYSCTL_REC" "Y")
  if [[ "$USE_SYSCTL_REC" == "Y" ]]; then
    SYSCTL_ACTION="apply"
  else
    if [ -t 0 ]; then
      read -rp "vm.swappiness (0-200) [${REC_SWAPPINESS}]: " SYS_SWAPPINESS
      read -rp "vm.page-cluster (0-9) [${REC_PAGE_CLUSTER}]: " SYS_PAGE_CLUSTER
    elif [ -r /dev/tty ]; then
      read -rp "vm.swappiness (0-200) [${REC_SWAPPINESS}]: " SYS_SWAPPINESS </dev/tty
      read -rp "vm.page-cluster (0-9) [${REC_PAGE_CLUSTER}]: " SYS_PAGE_CLUSTER </dev/tty
    else
      SYS_SWAPPINESS="$REC_SWAPPINESS"
      SYS_PAGE_CLUSTER="$REC_PAGE_CLUSTER"
    fi
    SYS_SWAPPINESS=$(validate_number "$SYS_SWAPPINESS" 0 200 "$REC_SWAPPINESS")
    SYS_PAGE_CLUSTER=$(validate_number "$SYS_PAGE_CLUSTER" 0 9 "$REC_PAGE_CLUSTER")
    SYSCTL_ACTION="apply"
  fi
fi

# =========================
# 最终确认
# =========================
echo
echo "==================== 最终配置 ===================="

# zram 配置显示
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "zram" ]]; then
  echo "----- zram -----"
  cat <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = $COMP_ALGO
swap-priority = $ZRAM_PRIO
EOF
else
  echo "----- zram -----"
  echo "（跳过 zram 配置）"
fi

echo
echo "----- disk swap -----"
if [[ "$CONFIG_MODE" == "zram" ]]; then
  echo "（跳过 swap 配置）"
elif [[ "$SWAP_ACTION" == "skip" ]]; then
  echo "不配置磁盘 swap"
else
  echo "模式: $SWAP_MODE"
  echo "磁盘 swap priority: $DISK_SWAP_PRIO (自动)"
  if [[ "$SWAP_MODE" == "create" ]]; then
    echo "swapfile: $SWAPFILE_PATH"
    echo "swapfile 大小: $SWAPFILE_SIZE"
  fi
fi

echo
echo "----- sysctl -----"
if [[ "$SYSCTL_ACTION" == "skip" ]]; then
  echo "不修改 sysctl"
else
  echo "vm.swappiness = $SYS_SWAPPINESS"
  echo "vm.page-cluster = $SYS_PAGE_CLUSTER"
fi
echo "=================================================="

echo
if [ -t 0 ]; then
  read -rp "确认应用以上配置? [Y/n] " CONFIRM
elif [ -r /dev/tty ]; then
  read -rp "确认应用以上配置? [Y/n] " CONFIRM </dev/tty
else
  CONFIRM="Y"
  log_info "自动确认应用配置（无交互式终端）"
fi
CONFIRM=$(validate_yn "$CONFIRM" "Y")
[[ "$CONFIRM" == "Y" ]] || { log_info "已取消操作"; exit 0; }

# =========================
# 应用 zram 配置
# =========================
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "zram" ]]; then
  log_info "安装 systemd-zram-generator..."
  apt update -qq
  apt install -y systemd-zram-generator

  CONF_FILE="/etc/systemd/zram-generator.conf"
  backup_file "$CONF_FILE"
  log_info "写入配置: $CONF_FILE"
  cat > "$CONF_FILE" <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = $COMP_ALGO
swap-priority = $ZRAM_PRIO
EOF

  log_info "应用 zram 配置..."
  systemctl daemon-reload
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
  systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
fi

# =========================
# 应用磁盘 swap 配置
# =========================
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "swap" ]] && [[ "$SWAP_ACTION" == "apply" ]]; then
  case "$SWAP_MODE" in
    create)
      create_swapfile "$SWAPFILE_PATH" "$SWAPFILE_SIZE"
      ensure_fstab_swapfile "$SWAPFILE_PATH" "$DISK_SWAP_PRIO"
      enable_swap_target "$SWAPFILE_PATH" "$DISK_SWAP_PRIO"
      log_ok "swapfile 已创建并启用: $SWAPFILE_PATH"
      ;;

    tune)
      if (( HAS_DISK_SWAP == 0 )); then
        log_warn "未检测到磁盘 swap，tune 模式无事可做。你可以改用 create 模式创建 swapfile。"
      else
        log_info "调整所有磁盘 swap priority 为: $DISK_SWAP_PRIO（并写入 /etc/fstab 持久化）"
        update_fstab_swap_pri_all "$DISK_SWAP_PRIO"

        while read -r dev; do
          [[ -z "$dev" ]] && continue
          if [[ "$dev" =~ ^/dev/zram[0-9]+$ ]]; then
            continue
          fi
          enable_swap_target "$dev" "$DISK_SWAP_PRIO" || true
        done <<< "$DISK_SWAPS"

        log_ok "已尝试应用 priority（如有 systemd/其他机制管理，重启后会更一致）"
      fi
      ;;

    off)
      if (( HAS_DISK_SWAP == 0 )); then
        log_info "没有磁盘 swap，无需关闭。"
      else
        log_warn "关闭所有磁盘 swap（不会删除文件，但会 swapoff）："
        while read -r dev; do
          [[ -z "$dev" ]] && continue
          if [[ "$dev" =~ ^/dev/zram[0-9]+$ ]]; then
            continue
          fi
          swapoff "$dev" || true
        done <<< "$DISK_SWAPS"
        log_ok "已关闭磁盘 swap（fstab 未自动清理，如需持久化关闭请手动处理 /etc/fstab）"
      fi
      ;;

    *)
      log_error "未知 swap 模式: $SWAP_MODE"
      exit 1
      ;;
  esac
fi

# =========================
# sysctl 应用
# =========================
if [[ "$SYSCTL_ACTION" == "apply" ]]; then
  # 由于前面已经用 validate_number 验证过，这里只是额外保险
  if ! [[ "$SYS_SWAPPINESS" =~ ^[0-9]+$ ]] || (( SYS_SWAPPINESS < 0 || SYS_SWAPPINESS > 200 )); then
    log_error "vm.swappiness 非法: $SYS_SWAPPINESS（应为 0-200）"
    exit 1
  fi
  if ! [[ "$SYS_PAGE_CLUSTER" =~ ^[0-9]+$ ]] || (( SYS_PAGE_CLUSTER < 0 || SYS_PAGE_CLUSTER > 9 )); then
    log_error "vm.page-cluster 非法: $SYS_PAGE_CLUSTER"
    exit 1
  fi
  write_sysctl_conf "$SYS_SWAPPINESS" "$SYS_PAGE_CLUSTER"
fi

# =========================
# 显示结果
# =========================
echo
echo "==================== 执行结果 ===================="
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "zram" ]]; then
  log_ok "当前 zram 状态："
  zramctl || true
  echo
fi
if [[ "$CONFIG_MODE" == "all" || "$CONFIG_MODE" == "swap" ]]; then
  log_ok "当前 swap 状态："
  swapon --show || true
  echo
fi
echo "=================================================="
echo
echo "🎉 配置完成！"