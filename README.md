# TUNE Script 系列脚本

欢迎使用 TUNE Script 系列脚本！本系列脚本旨在帮助用户优化系统性能，提升资源利用率。当前版本包含以下脚本：

## RAM-Tune 内存优化


### 🚀 快速开始

**curl安装:**
```bash
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/ram-tune.sh -o /tmp/ram-tune.sh && bash /tmp/ram-tune.sh
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
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/socks5.sh -o /tmp/socks5.sh && bash /tmp/socks5.sh
```

## GOST 端口转发脚本 (支持 Alpine / Debian 系)

基于高性能 **GOST v3** 核心的端口转发自动化部署脚本，支持原生 Unix 命令运行、无第三方语言依赖，深度适配 Alpine Linux (OpenRC) 与 Debian / Ubuntu / CentOS 等发行版 (Systemd)。

> ⚠️ **注意**：本仓库系列脚本必须由 **root** 用户直接运行（Alpine Linux 等精简系统默认不带 `sudo`，请先执行 `su -` 切换至 root），请使用 `sh` 运行。

### 🚀 快速开始

**1. CLI 一键非交互部署 (自动后台常驻与开机自启):**
```bash
# 自动部署并转发 8080 的所有 TCP/UDP 流量至目标 IP 对应端口
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/port-forward-gost.sh -o /tmp/port-forward-gost.sh && sh /tmp/port-forward-gost.sh -d <目标IP或域名> -p 8080
```

**2. 交互式 TUI 管理面板:**
```bash
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/port-forward-gost.sh -o /tmp/port-forward-gost.sh && sh /tmp/port-forward-gost.sh
```

---

## iptables 内核级端口转发脚本 (支持万级超大端口段)

基于 Linux 内核原生 **iptables (NAT/DNAT/SNAT)** 的零内存损耗端口转发自动化管理脚本。由于在内核网络栈直接改包，相比用户态代理程序，转发成千上万个端口（如 `10000-50000`）时系统**内存增加 0 MB**，耗时 0 秒，极速线速转发！

### 🚀 快速开始

**1. CLI 一键非交互部署 (自动开启内核转发并开机持久化):**
```bash
# 零内存损耗转发 10000-50000 大范围所有 TCP/UDP 流量至目标 IP
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/port-forward-iptables.sh -o /tmp/port-forward-iptables.sh && sh /tmp/port-forward-iptables.sh -d <目标IP或域名> -p 10000-50000
```

**2. 交互式 TUI 管理面板:**
```bash
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/port-forward-iptables.sh -o /tmp/port-forward-iptables.sh && sh /tmp/port-forward-iptables.sh
```

### CLI 参数说明

| 参数 | 长参数 | 必须 | 说明 | 示例 |
|---|---|---|---|---|
| `-d` | `--destination` | 是 | 目标转发地址 (支持 IPv4 / 域名) | `-d 1.2.3.4` 或 `-d target.example.com` |
| `-p` | `--port` | 是 | 转发端口或端口范围 (端口一一对应) | `-p 8080` 或 `-p 10000-50000` |
| `-m` | `--mode` | 否 | 转发协议 (`all`, `tcp`, `udp`，默认: `all`) | `-m all` |
| `-b` | `--bind` | 否 | 本地监听绑定地址 (默认: `0.0.0.0`) | `-b 0.0.0.0` |
| `-h` | `--help` | 否 | 查看帮助文档与示例 | `-h` |

### 核心特性
- **专用自定义链隔离**：采用 `IPT_FWD_PREROUTING`, `IPT_FWD_POSTROUTING`, `IPT_FWD_FORWARD` 专用链管理，绝不污染或破坏 Docker / Tailscale / UFW 等系统规则。
- **环境自适应固化**：自动开启并固化 `net.ipv4.ip_forward = 1`，跨发行版自动适配规则持久化服务（Alpine `iptables-openrc`、Debian/Ubuntu `netfilter-persistent`、CentOS `iptables-services`）。
- **零内存消耗**：大端口段在内核仅需 1 条规则，彻底解决应用层代理（GOST 等）在转发几万个端口时内存爆满、启动慢、假死问题。