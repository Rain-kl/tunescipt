# iptables 端口转发自动化脚本 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现一个体验与功能同 `gost.sh` 完全一致、底层基于 Linux 内核 `iptables` NAT 的端口转发自动化管理脚本 `iptables.sh`，原生支持单端口及万级大端口范围（如 `10000-50000`）零内存损耗转发，自动配置系统环境与开机规则持久化。

**Architecture:** 
- 纯 POSIX `/bin/sh` 实现单文件部署管理脚本 `iptables.sh`。
- 本地规则库维护于 `/etc/iptables-forward/rules.conf`，采用自定义独立 iptables 链（`IPT_FWD_PREROUTING`, `IPT_FWD_POSTROUTING`, `IPT_FWD_FORWARD`）进行安全纳管，与 Docker / UFW / Tailscale 等系统规则完全隔离。
- 自动适配 Alpine (iptables-openrc)、Debian/Ubuntu (netfilter-persistent)、CentOS/RHEL (iptables-services)，并在系统级开启并固化 `net.ipv4.ip_forward=1`。

**Tech Stack:** POSIX /bin/sh, Linux iptables (nat, filter), sysctl, OpenRC, Systemd

## Global Constraints
- 纯 POSIX `/bin/sh` 运行，严禁任何 bashism 语法（如 `[[ ]]`, `source`, `function`, `${var/s/r}` 等）。
- 严格必须由 root 用户直接运行（`id -u -eq 0`），禁止使用 `sudo`。
- 不得在本机执行破坏性网络修改；测试必须采用沙箱目录或隔离环境。
- 遵循仓库现有风格（彩色日志输出、emoji 状态图标提示、双向兼容 CLI 自动化参数与交互式 TUI 菜单）。

---

### Task 1: 核心参数解析与基础函数库

**Files:**
- Create: `iptables.sh`
- Test: `tests/test_iptables_core.sh`

**Interfaces:**
- Produces:
  - `require_root()`: 校验 root 身份，支持 `TEST_MODE=1`
  - `detect_os()`: 返回 `alpine` | `debian` | `ubuntu` | `centos` 等
  - `validate_target(target)`: 返回 0（有效 IPv4/域名）或 1
  - `validate_port_range(port_spec)`: 校验 `8080` 或 `10000-50000`
  - `format_iptables_port(port_spec)`: 将 `10000-50000` 转化为 iptables 识别的 `10000:50000`，单端口返回原样
  - `parse_args("$@")`: 解析 `-d`, `-p`, `-m`, `-b`, `-h`

- [x] **Step 1: 编写测试脚本 `tests/test_iptables_core.sh`**
- [x] **Step 2: 运行测试验证失败 (RED)**
- [x] **Step 3: 在 `iptables.sh` 实现基础校验与参数解析逻辑 (GREEN)**
- [x] **Step 4: 运行测试并验证通过，提交代码**

---

### Task 2: 规则引擎与本地存储管理

**Files:**
- Modify: `iptables.sh`
- Test: `tests/test_iptables_rules.sh`

**Interfaces:**
- Produces:
  - `ensure_config_dir()`: 确保 `/etc/iptables-forward` 存在
  - `get_next_rule_id()`: 获取下一个自增 ID
  - `check_port_overlap(port_spec, [exclude_id])`: 区间重叠校验
  - `add_rule(target, port_spec, proto, bind_ip, status)`: 追加规则
  - `delete_rule(id)`: 移除规则
  - `list_rules()`: 终端格式化输出规则表格

- [x] **Step 1: 编写规则引擎测试 `tests/test_iptables_rules.sh`**
- [x] **Step 2: 在 `iptables.sh` 实现规则存储、查询、重叠检测与增删函数**
- [x] **Step 3: 运行测试验证通过，提交代码**

---

### Task 3: iptables 规则链构建与系统环境自动化配置

**Files:**
- Modify: `iptables.sh`
- Test: `tests/test_iptables_generator.sh`

**Interfaces:**
- Produces:
  - `setup_environment()`: 自动安装依赖包（iptables + 持久化组件），开启并持久化 `net.ipv4.ip_forward = 1`
  - `init_custom_chains()`: 创建并挂载 `IPT_FWD_PREROUTING`, `IPT_FWD_POSTROUTING`, `IPT_FWD_FORWARD`
  - `apply_iptables_rules()`: 根据 `rules.conf` 全量生成并同步应用到 iptables
  - `save_iptables_rules()`: 根据发行版持久化规则并设置开机自启
  - `cleanup_iptables_chains()`: 安全卸载专用链，恢复干净网络状态

- [x] **Step 1: 编写 iptables 命令生成与环境适配测试**
- [x] **Step 2: 实现环境准备与多系统持久化逻辑**
- [x] **Step 3: 实现自定义链与规则全量同步逻辑**
- [x] **Step 4: 运行测试验证通过，提交代码**

---

### Task 4: CLI 部署串联与交互式 TUI 管理面板

**Files:**
- Modify: `iptables.sh`
- Test: `tests/test_iptables_cli.sh`

**Interfaces:**
- Produces:
  - `cli_deploy()`: 非交互式单行命令直接部署
  - `interactive_add_rule()`, `interactive_delete_rule()`, `interactive_service_control()`
  - `show_menu()`, `menu_loop()`: 交互式主控制台

- [x] **Step 1: 编写 CLI 端到端自动化测试**
- [x] **Step 2: 完成 CLI 部署流程与 TUI 交互菜单**
- [x] **Step 3: 运行全量测试套件验证通过**
- [x] **Step 4: 提交并推送到 GitHub 远程仓库**

---

### Task 5: 真实环境验证与部署

**Files:**
- Target: 中转机 `144.225.255.118` (Alpine)
- Verify: 本地 Xray 穿透测试

- [x] **Step 1: 将 `iptables.sh` 部署至中转机 `144.225.255.118`**
- [x] **Step 2: 测试使用 `iptables.sh` 转发 `10000-50000` 大端口范围**
- [x] **Step 3: 本地使用 Xray 测试验证 40000 端口连通性**
- [x] **Step 4: 验证系统内存与负载**
