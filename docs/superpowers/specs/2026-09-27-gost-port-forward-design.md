# GOST 端口转发自动化部署脚本设计文档

## 1. 概述与设计目标

为满足在 Linux 环境（尤其是 Debian/Ubuntu 与 Alpine Linux）下快速部署与管理高并发端口段转发的需求，设计并实现自动化部署管理脚本 `gost.sh`。

### 核心目标
1. **轻量与高兼容**：底层使用 GOST v3 二进制，单静态文件，零环境运行时依赖，完美兼容 Alpine (musl) 与 Debian/Ubuntu/CentOS (glibc)。
2. **多模式支持**：
   - **CLI 模式**：通过 `-d <目标地址> -p <端口或端口段> [-m <协议>]` 一键自动化配置与后台常驻。
   - **TUI 交互模式**：无参数运行时进入美观的终端交互菜单，支持增删查改转发规则、启停服务及自启控制。
3. **高并发端口段适配**：优化系统文件句柄限制（`LimitNOFILE=1048576`），稳定承载如 `10000-50000` 达数万端口的并发监听转发。
4. **纯原生 Unix 工具链**：脚本逻辑使用 `sh/bash`、`awk`、`sed`、`grep`、`tar`、`curl/wget`，不依赖 `jq`、`yq` 或 `python`。

---

## 2. 命令行接口 (CLI) 设计

### 2.1 参数定义
| 参数 | 长参数 | 说明 | 默认值 | 示例 |
|---|---|---|---|---|
| `-d` | `--destination` | 目标转发地址（IP 或域名） | 无（CLI 必填） | `-d 1.1.1.1` 或 `-d target.example.com` |
| `-p` | `--port` | 转发端口或端口范围（起始-结束） | 无（CLI 必填） | `-p 8080` 或 `-p 10000-50000` |
| `-m` | `--mode` | 协议类型（`all`, `tcp`, `udp`） | `all` | `-m all` |
| `-b` | `--bind` | 本地监听绑定地址 | `0.0.0.0` | `-b 0.0.0.0` |
| `-h` | `--help` | 显示使用帮助与示例 | - | `-h` |

### 2.2 CLI 快速调用示例
```bash
# 转发 10000-50000 的所有 TCP 与 UDP 流量至 1.2.3.4
curl -fsSL https://raw.githubusercontent.com/Rain-kl/tunescipt/main/gost.sh -o /tmp/gost.sh && sudo bash /tmp/gost.sh -d 1.2.3.4 -p 10000-50000

# 本地执行示例
sudo bash gost.sh -d example.com -p 8080 -m tcp
```

---

## 3. 系统服务与后台自启架构

根据检测到的操作系统类型自动适配后台守护机制：

### 3.1 Debian / Ubuntu / CentOS / RHEL (Systemd)
- 配置文件：`/etc/systemd/system/gost-forward.service`
- 配置详情：
  ```ini
  [Unit]
  Description=GOST Port Forward Service
  After=network.target network-online.target
  Wants=network-online.target

  [Service]
  Type=simple
  ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
  Restart=always
  RestartSec=3
  LimitNOFILE=1048576
  LimitNPROC=512000

  [Install]
  WantedBy=multi-user.target
  ```
- 自启命令：`systemctl daemon-reload && systemctl enable --now gost-forward`

### 3.2 Alpine Linux (OpenRC)
- 服务文件：`/etc/init.d/gost-forward`
- 配置包含：
  - `command="/usr/local/bin/gost"`
  - `command_args="-C /etc/gost/config.yaml"`
  - `command_background="yes"`
  - `pidfile="/run/gost-forward.pid"`
  - `rc_ulimit="-n 1048576"`
- 自启命令：`rc-update add gost-forward default && rc-service gost-forward restart`

---

## 4. 规则存储与配置生成

### 4.1 规则库存储 (`/etc/gost/rules.conf`)
采用纯文本管道符分隔格式：
```text
# id|target|port_spec|protocol|bind_ip|status
1|1.2.3.4|10000-50000|all|0.0.0.0|enabled
2|hk.node.com|8443|tcp|0.0.0.0|enabled
```

### 4.2 编译为 GOST 配置文件 (`/etc/gost/config.yaml`)
脚本读取所有状态为 `enabled` 的规则，逐项生成 YAML 配置：
```yaml
services:
  - name: fwd-tcp-1
    addr: "0.0.0.0:10000-50000"
    handler:
      type: tcp
    listener:
      type: tcp
    forwarder:
      nodes:
        - name: target-1
          addr: "1.2.3.4:10000-50000"
  - name: fwd-udp-1
    addr: "0.0.0.0:10000-50000"
    handler:
      type: udp
    listener:
      type: udp
    forwarder:
      nodes:
        - name: target-1
          addr: "1.2.3.4:10000-50000"
```

---

## 5. TUI 交互菜单设计

终端菜单保持与仓库中现有脚本一致的风格：
1. **主菜单界面**：
   - 顶部显示系统类型、GOST 版本、服务运行状态、开机自启状态、规则统计。
   - 菜单选项：
     - `1. 添加转发规则`
     - `2. 查看转发规则与状态`
     - `3. 删除转发规则`
     - `4. 启停服务与开机自启管理`
     - `5. 卸载 GOST 及全部配置`
     - `0. 退出`
2. **输入校验与容错**：
   - 目标地址合法性校验（IPv4 / IPv6 / Domain）
   - 端口合法性校验（1-65535，起始 <= 结束）
   - 端口重叠冲突检测（如已监听 10000-50000，提示是否覆盖或调整）
3. **防火墙联动**：
   - 自动检测并提示/执行放行规则（支持 `ufw`, `firewalld`, `iptables`）。
