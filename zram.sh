#!/usr/bin/env bash
set -euo pipefail

# --------- 检查发行版 ---------
if ! grep -qiE 'debian|ubuntu' /etc/os-release; then
  echo "❌ 此脚本仅支持 Debian / Ubuntu 系"
  exit 1
fi

# --------- 检查 root ---------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "❌ 请使用 root 或 sudo 运行"
  exit 1
fi

# --------- 获取内存 (MB) / CPU 核心数 ---------
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CORES=$(nproc 2>/dev/null || echo 1)

# --------- 是否存在“非 zram”的磁盘 swap ---------
HAS_DISK_SWAP=0
if swapon --noheadings --raw --output=NAME 2>/dev/null | grep -qvE '^/dev/zram[0-9]+$'; then
  # 这里简单判断：swapon 列表里出现非 /dev/zramX 的 swap（可能是分区/文件）
  if swapon --noheadings --raw --output=NAME 2>/dev/null | grep -qE '^(\/dev\/(sd|vd|nvme|mmcblk)[^ ]+|\/)'; then
    HAS_DISK_SWAP=1
  fi
fi

# --------- 推荐配置（更贴近实际使用的经验值）---------
# zram 大小：小内存更激进，大内存更保守，避免浪费过多不可压缩的元数据/管理开销
# 用整数分数表达，兼容 systemd-zram-generator 的表达式解析
if (( RAM_MB <= 2048 )); then
  # 1.5x
  REC_SIZE_EXPR="ram * 3 / 2"
  REC_NUM=3; REC_DEN=2
elif (( RAM_MB <= 4096 )); then
  # 1.0x
  REC_SIZE_EXPR="ram"
  REC_NUM=1; REC_DEN=1
elif (( RAM_MB <= 8192 )); then
  # 0.75x
  REC_SIZE_EXPR="ram * 3 / 4"
  REC_NUM=3; REC_DEN=4
elif (( RAM_MB <= 16384 )); then
  # 0.5x
  REC_SIZE_EXPR="ram / 2"
  REC_NUM=1; REC_DEN=2
else
  # 0.25x
  REC_SIZE_EXPR="ram / 4"
  REC_NUM=1; REC_DEN=4
fi

# 压缩算法：低核数优先 lz4（更省 CPU / 延迟更低）；否则内存较大时用 zstd（压缩率更好）
if (( CORES <= 2 )); then
  REC_ALGO="lz4"
else
  if (( RAM_MB <= 4096 )); then
    REC_ALGO="lz4"
  else
    REC_ALGO="zstd"
  fi
fi

# swap 优先级：有磁盘 swap 就让 zram 更优先（避免频繁写盘）；没有就用 100
if (( HAS_DISK_SWAP == 1 )); then
  REC_PRIO=200
else
  REC_PRIO=100
fi

# 计算一个“约等于”的推荐 zram MB 方便展示
REC_ZRAM_MB=$(( RAM_MB * REC_NUM / REC_DEN ))

# --------- 显示推荐 ---------
echo "🧠 检测到物理内存: ${RAM_MB} MB"
echo "🧮 CPU 核心数: ${CORES}"
if (( HAS_DISK_SWAP == 1 )); then
  echo "💽 检测到磁盘 swap: 是（将提高 zram 优先级）"
else
  echo "💽 检测到磁盘 swap: 否"
fi
echo
echo "👉 推荐配置:"
echo "   zram-size: ${REC_SIZE_EXPR}   (约 ${REC_ZRAM_MB} MB)"
echo "   compression-algorithm: ${REC_ALGO}"
echo "   swap-priority: ${REC_PRIO}"
echo

# --------- 用户确认 / 自定义 ---------
read -rp "是否使用推荐配置? [Y/n] " USE_REC
USE_REC=${USE_REC:-Y}

if [[ "$USE_REC" =~ ^[Yy]$ ]]; then
  ZRAM_SIZE="$REC_SIZE_EXPR"
  COMP_ALGO="$REC_ALGO"
  SWAP_PRIO="$REC_PRIO"
else
  read -rp "请输入 zram-size (如: ram / 2 或 1024M): " ZRAM_SIZE
  read -rp "请选择压缩算法 (lz4/zstd/lzo): " COMP_ALGO
  read -rp "设置 swap 优先级? (默认 ${REC_PRIO}) [${REC_PRIO}]: " SWAP_PRIO
  SWAP_PRIO=${SWAP_PRIO:-$REC_PRIO}
fi

# 简单校验压缩算法
case "$COMP_ALGO" in
  lz4|zstd|lzo) ;;
  *)
    echo "❌ 不支持的压缩算法: $COMP_ALGO (请用 lz4 / zstd / lzo)"
    exit 1
    ;;
esac

echo
echo "📄 最终配置:"
cat <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = $COMP_ALGO
swap-priority = $SWAP_PRIO
EOF

read -rp "确认应用以上配置? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# --------- 安装 ---------
echo "📦 安装 systemd-zram-generator..."
apt update
apt install -y systemd-zram-generator

# --------- 写入配置（先备份）---------
CONF_FILE="/etc/systemd/zram-generator.conf"
if [[ -f "$CONF_FILE" ]]; then
  cp -a "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  echo "🧷 已备份旧配置为: ${CONF_FILE}.bak.*"
fi

echo "✍️ 写入配置: $CONF_FILE"
cat > "$CONF_FILE" <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = $COMP_ALGO
swap-priority = $SWAP_PRIO
EOF

# --------- 立即生效 ---------
echo "🔄 应用配置..."
systemctl daemon-reload

# 某些机器上服务名可能不存在（首次启用前），这里做容错处理
systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
# 如果没起来，尝试 start
systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true

# --------- 显示结果 ---------
echo
echo "✅ zram 已配置完成:"
swapon --show || true
echo
zramctl || true

echo
echo "🎉 完成！"