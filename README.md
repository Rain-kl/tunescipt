# TUNE Script 系列脚本

欢迎使用 TUNE Script 系列脚本！本系列脚本旨在帮助用户优化系统性能，提升资源利用率。当前版本包含以下脚本：

## RAM-Tune 内存优化


### 🚀 快速开始

**curl安装:**
```bash
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/ram-tune.sh -o /tmp/ram-tune.sh && sudo bash /tmp/ram-tune.sh
```

### 配置参数说明

| 参数             | 说明                | 自动计算           |
| ---------------- | ------------------- | ------------------ |
| `zram_size`      | zRAM 大小（MB）     | ✅ 默认总内存 50%   |
| `zram_algorithm` | 压缩算法            | ✅ 自动选择最优     |
| `swap_size`      | Swap 文件大小（MB） | ✅ 根据磁盘大小计算 |
| `swappiness`     | 内存交换倾向        | ✅ 根据磁盘类型计算 |

### 推荐值计算逻辑

**Swap 大小计算：**

```
磁盘大小 ≤ 10G:  Swap ≤ 1G
磁盘大小 > 10G:  Swap = RAM（根据磁盘类型调整）
```

**Swappiness 优先级：**
```
SSD 磁盘: 优先级较低（10-20），优先使用 zRAM
HDD 磁盘: 优先级较高（30-50），均衡使用两者
```

## Socks5 搭建脚本


### 🚀 快速开始

**curl安装:**
```bash
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/socks5.sh -o /tmp/socks5.sh && sudo bash /tmp/ram-tune.sh
```