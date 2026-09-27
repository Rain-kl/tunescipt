# GOST 端口转发自动化脚本 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现一个兼顾 Alpine (OpenRC) 与 Debian/Ubuntu (Systemd) 的自动化 GOST v3 端口转发管理脚本 `gost.sh`，支持一键 CLI 参数快速部署后台与开机自启（`-d <ip/domain> -p <port-or-range>`），以及功能完备的交互式终端 TUI 管理面板。

**Architecture:** 
- 纯 Shell（兼容 POSIX/bash，优先使用系统原生命令 `awk`, `sed`, `grep`, `cat` 等）实现单文件部署脚本 `gost.sh`。
- 本地规则库持久化于 `/etc/gost/rules.conf`，脚本负责将其动态转换为 GOST v3 标准配置 `/etc/gost/config.yaml`。
- 自动适配 Systemd（Debian/Ubuntu/CentOS）与 OpenRC（Alpine），并内置高句柄上限（`LimitNOFILE=1048576`）确保支撑 4 万+ 端口的大区间转发（如 `10000-50000`）。

**Tech Stack:** Bash/POSIX sh, GOST v3, Systemd, OpenRC, UFW/Firewalld/Iptables

## Global Constraints
- 支持 Alpine Linux (musl) 与 Debian/Ubuntu/CentOS 系列 (glibc)
- 零第三方语言/运行时依赖（不使用 `jq`, `yq`, `python` 等）
- 脚本支持非交互式 CLI 直接调用（`-d <target> -p <port> [-m <proto>] [-b <bind>]`）与无参数时的交互式 TUI 菜单
- 遵循仓库现有风格（彩色日志输出、emoji 状态图标提示）

---

### Task 1: 基础工具函数与 CLI 参数解析器

**Files:**
- Create: `gost.sh`
- Test: `tests/test_gost_core.sh`

**Interfaces:**
- Produces: 
  - `log_info()`, `log_ok()`, `log_warn()`, `log_error()`
  - `detect_os()`: 返回 `alpine` | `debian` | `ubuntu` | `centos` 等
  - `detect_arch()`: 返回 `amd64` | `arm64` | `386` | `armv7`
  - `validate_target(target)`: 返回 0（有效域名/IPv4/IPv6）或 1
  - `validate_port_range(port_spec)`: 校验 `8080` 或 `10000-50000`，确保 `1 <= start <= end <= 65535`
  - `parse_args("$@")`: 解析 `-d`, `-p`, `-m`, `-b`, `-h` 并在参数齐全时触发 CLI 自动化流程

- [ ] **Step 1: 编写测试脚本验证参数解析与输入校验**

```bash
mkdir -p tests
cat << 'EOF' > tests/test_gost_core.sh
#!/bin/bash
set -euo pipefail

# 引入函数 (通过 mock 规避 root 检查)
TEST_MODE=1
source ./gost.sh --source-only 2>/dev/null || true

# 测试 1: 端口范围校验
echo "Testing port range validation..."
validate_port_range "8080"
validate_port_range "10000-50000"
! validate_port_range "60000-10000" 2>/dev/null
! validate_port_range "abc" 2>/dev/null
! validate_port_range "0-80" 2>/dev/null
! validate_port_range "80-70000" 2>/dev/null

# 测试 2: 目标地址校验
echo "Testing target validation..."
validate_target "1.1.1.1"
validate_target "example.com"
validate_target "sub.domain.co.uk"
validate_target "2606:4700:4700::1111"
! validate_target "invalid..domain" 2>/dev/null

echo "✅ All core validation tests passed!"
EOF
chmod +x tests/test_gost_core.sh
```

- [ ] **Step 2: 运行测试验证失败（此时 gost.sh 尚未实现对应函数）**

Run: `bash tests/test_gost_core.sh`
Expected: FAIL (函数未定义或文件不存在)

- [ ] **Step 3: 编写 `gost.sh` 中的基础函数与校验逻辑**

实现色彩日志、系统及架构检测、输入验证函数与参数解析。在顶部支持 `--source-only` 模式方便测试。

- [ ] **Step 4: 重新运行测试验证通过**

Run: `bash tests/test_gost_core.sh`
Expected: PASS ("✅ All core validation tests passed!")

- [ ] **Step 5: 提交任务代码**

```bash
git add gost.sh tests/test_gost_core.sh
git commit -m "feat: add core validation, os detection, and arg parsing"
```

---

### Task 2: 规则存储与 GOST v3 YAML 配置生成引擎

**Files:**
- Modify: `gost.sh`
- Test: `tests/test_rules_engine.sh`

**Interfaces:**
- Consumes: Task 1 的验证函数与配置常量
- Produces:
  - `add_rule(target, port_spec, proto, bind_ip)`: 追加/更新规则到 `/etc/gost/rules.conf`
  - `delete_rule(id)`: 删除指定规则
  - `list_rules()`: 格式化列出当前所有规则
  - `check_port_overlap(port_spec)`: 检测新端口段是否与已有规则冲突
  - `generate_gost_config()`: 纯原生脚本解析 `rules.conf` 并生成标准 `/etc/gost/config.yaml`

- [ ] **Step 1: 编写规则管理与 YAML 编译单元测试**

```bash
cat << 'EOF' > tests/test_rules_engine.sh
#!/bin/bash
set -euo pipefail

export GOST_CONFIG_DIR="./tmp_test_gost"
mkdir -p "$GOST_CONFIG_DIR"
trap 'rm -rf "$GOST_CONFIG_DIR"' EXIT

source ./gost.sh --source-only

# 测试 1: 添加规则并生成 YAML
add_rule "1.2.3.4" "10000-50000" "all" "0.0.0.0"
add_rule "hk.example.com" "8443" "tcp" "0.0.0.0"

# 检查 rules.conf 行数
[ "$(grep -v '^#' "$GOST_CONFIG_DIR/rules.conf" | wc -l)" -eq 2 ]

# 测试 2: 编译 YAML 配置文件
generate_gost_config

# 验证 YAML 内容结构
grep -q "addr: \":10000-50000\"" "$GOST_CONFIG_DIR/config.yaml"
grep -q "addr: \"1.2.3.4:10000-50000\"" "$GOST_CONFIG_DIR/config.yaml"
grep -q "addr: \":8443\"" "$GOST_CONFIG_DIR/config.yaml"
grep -q "addr: \"hk.example.com:8443\"" "$GOST_CONFIG_DIR/config.yaml"

# 测试 3: 删除规则
delete_rule 1
generate_gost_config
! grep -q "10000-50000" "$GOST_CONFIG_DIR/config.yaml"

echo "✅ Rules engine tests passed!"
EOF
chmod +x tests/test_rules_engine.sh
```

- [ ] **Step 2: 运行测试验证失败**

Run: `bash tests/test_rules_engine.sh`
Expected: FAIL

- [ ] **Step 3: 在 `gost.sh` 中实现规则管理和 YAML 生成**

支持通过环境变量指定配置文件目录（默认为 `/etc/gost`），编写纯 awk/cat/sed 的 YAML 转换逻辑。

- [ ] **Step 4: 运行测试验证通过**

Run: `bash tests/test_rules_engine.sh`
Expected: PASS ("✅ Rules engine tests passed!")

- [ ] **Step 5: 提交任务代码**

```bash
git add gost.sh tests/test_rules_engine.sh
git commit -m "feat: implement rule persistence and YAML generator"
```

---

### Task 3: GOST 安装器与 Systemd / OpenRC 服务管理器

**Files:**
- Modify: `gost.sh`
- Test: `tests/test_service_manager.sh`

**Interfaces:**
- Consumes: Task 1 和 Task 2
- Produces:
  - `install_gost_binary()`: 根据平台与架构从 GitHub Releases 获取稳定版二进制（支持镜像加速 fallback），解压至 `/usr/local/bin/gost`
  - `setup_system_service()`: 生成 `/etc/systemd/system/gost-forward.service` 或 `/etc/init.d/gost-forward`，设置 `LimitNOFILE=1048576`
  - `start_service()`, `stop_service()`, `restart_service()`, `get_service_status()`
  - `enable_autostart()`, `disable_autostart()`
  - `manage_firewall(port_spec, action)`: 放行/删除端口段防火墙规则（UFW/firewalld/iptables）

- [ ] **Step 1: 编写服务文件模板生成的模拟测试**

```bash
cat << 'EOF' > tests/test_service_manager.sh
#!/bin/bash
set -euo pipefail

export TEST_DIR="./tmp_service_test"
mkdir -p "$TEST_DIR/system" "$TEST_DIR/init.d"
trap 'rm -rf "$TEST_DIR"' EXIT

source ./gost.sh --source-only

# 测试 Systemd 服务模板生成
OS_TYPE="debian"
SERVICE_FILE_SYSTEMD="$TEST_DIR/system/gost-forward.service"
generate_systemd_service "$SERVICE_FILE_SYSTEMD"
grep -q "LimitNOFILE=1048576" "$SERVICE_FILE_SYSTEMD"
grep -q "ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml" "$SERVICE_FILE_SYSTEMD"

# 测试 OpenRC 服务模板生成
OS_TYPE="alpine"
SERVICE_FILE_OPENRC="$TEST_DIR/init.d/gost-forward"
generate_openrc_service "$SERVICE_FILE_OPENRC"
grep -q "rc_ulimit=\"-n 1048576\"" "$SERVICE_FILE_OPENRC"
grep -q "command=\"/usr/local/bin/gost\"" "$SERVICE_FILE_OPENRC"

echo "✅ Service manager generation tests passed!"
EOF
chmod +x tests/test_service_manager.sh
```

- [ ] **Step 2: 运行测试验证失败**

Run: `bash tests/test_service_manager.sh`
Expected: FAIL

- [ ] **Step 3: 在 `gost.sh` 中实现服务安装、服务文件生成与启停逻辑**

- [ ] **Step 4: 运行测试验证通过**

Run: `bash tests/test_service_manager.sh`
Expected: PASS ("✅ Service manager generation tests passed!")

- [ ] **Step 5: 提交任务代码**

```bash
git add gost.sh tests/test_service_manager.sh
git commit -m "feat: implement gost installation and system service daemon management"
```

---

### Task 4: 交互式 TUI 菜单界面与 CLI 入口串联

**Files:**
- Modify: `gost.sh`

**Interfaces:**
- Consumes: Task 1 - 3 的全部功能函数
- Produces:
  - `show_menu()`: 动态展示系统状态面板与主功能菜单
  - `interactive_add_rule()`: 引导式输入目标、端口段、协议并完成热部署
  - `interactive_delete_rule()`: 编号选择删除规则
  - `interactive_service_control()`: 启停/自启管理
  - `interactive_uninstall()`: 彻底清理 GOST、服务及配置文件
  - `main()`: 综合分流：参数存在执行非交互 CLI，无参数执行 TUI 循环

- [ ] **Step 1: 完善 `gost.sh` 中的 TUI 菜单及各交互子函数**
- [ ] **Step 2: 在 `main()` 中支持 CLI 与 TUI 分流**
  - 当带 `-d` 等参数时：
    1. 自动执行依赖与 GOST 二进制检查安装
    2. 校验参数并添加规则
    3. 编译配置并注册/启动服务
    4. 放行防火墙端口
    5. 打印配置成功的状态并退出
- [ ] **Step 3: 运行语法检查与全流程模拟测试**

Run: `bash -n gost.sh`
Expected: 语法校验通过，退出码 0

- [ ] **Step 4: 提交任务代码**

```bash
git add gost.sh
git commit -m "feat: complete TUI menu and CLI automation entry"
```

---

### Task 5: 编写综合测试、更新 README.md 与全面验证

**Files:**
- Create: `tests/test_cli_e2e.sh`
- Modify: `README.md`

- [ ] **Step 1: 编写 CLI 全流程 end-to-end 模拟测试**

测试从解析参数、生成规则到编译配置的完整 CLI 闭环：
`bash tests/test_cli_e2e.sh`

- [ ] **Step 2: 更新 `README.md`**

在 README 中新增 "GOST 端口段转发脚本" 章节：
- 一键 curl 运行指令与快速开始
- CLI 参数表格说明（`-d`, `-p`, `-m`, `-b` 等）
- 端口段大范围转发特性说明与 Alpine / Debian 双系统支持说明

- [ ] **Step 3: 运行完整测试套件**

```bash
bash tests/test_gost_core.sh
bash tests/test_rules_engine.sh
bash tests/test_service_manager.sh
bash tests/test_cli_e2e.sh
```
Expected: 所有测试全部通过

- [ ] **Step 4: 提交最终文档与测试代码**

```bash
git add README.md tests/test_cli_e2e.sh
git commit -m "docs: update README with gost port forward script usage and add E2E tests"
```
