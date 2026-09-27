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
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/socks5.sh -o /tmp/socks5.sh && sudo bash /tmp/socks5.sh
```

## GOST 端口段转发脚本 (支持 Alpine / Debian 系)

基于高性能 **GOST v3** 核心的高并发端口段转发自动化部署脚本，支持原生 Unix 命令运行、无第三方语言依赖，深度适配 Alpine Linux (OpenRC) 与 Debian / Ubuntu / CentOS 等发行版 (Systemd)。

### 🚀 快速开始

**1. CLI 一键非交互部署 (自动后台常驻与开机自启):**
```bash
# 自动部署并转发 10000-50000 的所有 TCP/UDP 流量至目标 IP 对应端口
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/gost.sh -o /tmp/gost.sh && sudo bash /tmp/gost.sh -d <目标IP或域名> -p 10000-50000
```

**2. 交互式 TUI 管理面板:**
```bash
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/gost.sh -o /tmp/gost.sh && sudo bash /tmp/gost.sh
```

### CLI 参数说明

| 参数 | 长参数 | 必须 | 说明 | 示例 |
|---|---|---|---|---|
| `-d` | `--destination` | 是 | 目标转发地址 (支持 IPv4 / IPv6 / 域名) | `-d 1.2.3.4` 或 `-d target.example.com` |
| `-p` | `--port` | 是 | 转发端口或端口范围 (端口一一对应) | `-p 8080` 或 `-p 10000-50000` |
| `-m` | `--mode` | 否 | 转发协议 (`all`, `tcp`, `udp`，默认: `all`) | `-m tcp` |
| `-b` | `--bind` | 否 | 本地监听绑定地址 (默认: `0.0.0.0`) | `-b 0.0.0.0` |
| `-h` | `--help` | 否 | 查看帮助文档与示例 | `-h` |

### 核心特性
- **跨平台自适应**：自动识别 Debian/Ubuntu/CentOS (`systemd`) 与 Alpine Linux (`OpenRC`)，自动注册为系统后台服务并开启开机自启。
- **高并发端口段优化**：针对 `10000-50000` 等达数万端口的并发监听，在服务配置中自动注入 `LimitNOFILE=1048576`，杜绝文件句柄耗尽错误。
- **多规则库持久化**：规则持久保存在 `/etc/gost/rules.conf`，动态生成 GOST 官方标准 YAML 配置，可在 TUI 中便捷管理多条规则。
- **防火墙联动**：自动检测并放行 `UFW` 或 `Firewalld` 对应端口。