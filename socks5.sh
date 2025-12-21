#!/bin/bash
# SOCKS5代理服务器管理脚本(IPv6支持)

# 检测root权限
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用sudo或root用户运行脚本" >&2
    exit 1
fi

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    else
        OS=$(uname -s)
    fi
    echo $OS
}

# 全局变量
OS_TYPE=$(detect_os)

# 获取服务名称和配置文件路径
get_service_name() {
    if [ "$OS_TYPE" = "alpine" ]; then
        echo "sockd"
    else
        echo "danted"
    fi
}

get_config_file() {
    if [ "$OS_TYPE" = "alpine" ]; then
        echo "/etc/sockd.conf"
    else
        echo "/etc/danted.conf"
    fi
}

SERVICE_NAME=$(get_service_name)
CONFIG_FILE=$(get_config_file)

# 获取当前配置的端口
get_current_port() {
    if [ -f "$CONFIG_FILE" ]; then
        grep -m 1 "internal:.*port" "$CONFIG_FILE" | grep -oP 'port = \K\d+'
    fi
}

# 获取SOCKS5用户列表（shell为/bin/false的系统用户）
get_socks5_users() {
    if [ "$OS_TYPE" = "alpine" ]; then
        getent passwd | awk -F: '$7 == "/sbin/nologin" {print $1}' | grep -v "^nobody$" | grep -v "^_"
    else
        getent passwd | awk -F: '$7 == "/bin/false" || $7 == "/usr/sbin/nologin" {print $1}' | grep -v "^nobody$" | grep -v "^_"
    fi
}

# 显示现有用户
show_existing_users() {
    echo ""
    echo "📋 当前系统中的SOCKS5用户:"
    USERS=$(get_socks5_users)
    if [ -z "$USERS" ]; then
        echo "   (暂无用户)"
    else
        echo "$USERS" | while read -r user; do
            echo "   - $user"
        done
    fi
    echo ""
}

# 安装SOCKS5代理
install_socks5() {
    echo "================================"
    echo "   安装 SOCKS5 代理服务器"
    echo "================================"
    
    # 检查是否已安装
    if [ "$OS_TYPE" = "alpine" ]; then
        if rc-service $SERVICE_NAME status &>/dev/null; then
            echo "⚠️  检测到SOCKS5代理已在运行"
            read -p "是否重新安装? (y/n): " REINSTALL
            if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
                echo "取消安装"
                return
            fi
            rc-service $SERVICE_NAME stop
        fi
    else
        if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
            echo "⚠️  检测到SOCKS5代理已在运行"
            read -p "是否重新安装? (y/n): " REINSTALL
            if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
                echo "取消安装"
                return
            fi
            systemctl stop $SERVICE_NAME
        fi
    fi
    
    # 安装依赖
    echo "🔧 安装必要组件..."
    case $OS_TYPE in
        alpine)
            apk update &> /dev/null
            apk add dante-server netcat-openbsd curl openrc &> /dev/null
            ;;
        ubuntu|debian)
            apt update &> /dev/null
            apt install -y dante-server netcat-openbsd curl &> /dev/null
            ;;
        centos|rhel|fedora)
            yum install -y dante-server nc curl &> /dev/null
            ;;
        *)
            echo "❌ 不支持的操作系统: $OS_TYPE"
            return 1
            ;;
    esac
    
    # 配置参数
    read -p "🛡️ 输入代理端口 (默认1080): " PORT
    PORT=${PORT:-1080}
    
    # 交互式输入用户名和密码
    read -p "👤 输入SOCKS5用户名: " USERNAME
    while [ -z "$USERNAME" ]; do
        echo "❌ 用户名不能为空"
        read -p "👤 输入SOCKS5用户名: " USERNAME
    done
    
    read -sp "🔒 输入SOCKS5密码: " PASSWORD
    echo ""
    while [ -z "$PASSWORD" ]; do
        echo "❌ 密码不能为空"
        read -sp "🔒 输入SOCKS5密码: " PASSWORD
        echo ""
    done
    
    # 获取默认接口名称(IPv6优先,失败则用IPv4)
    INTERFACE=$(ip -6 route | awk '/default/ {print $5; exit}')
    [ -z "$INTERFACE" ] && INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
    
    # 创建系统用户用于SOCKS5认证
    echo "👥 创建SOCKS5用户..."
    if id "$USERNAME" &>/dev/null; then
        echo "⚠️  用户 $USERNAME 已存在,将使用现有用户"
    else
        if [ "$OS_TYPE" = "alpine" ]; then
            adduser -D -H -s /sbin/nologin "$USERNAME"
        else
            useradd -r -s /bin/false "$USERNAME"
        fi
    fi
    echo "$USERNAME:$PASSWORD" | chpasswd
    
    # 生成配置文件
    echo "📝 生成Dante配置文件..."
    cat > "$CONFIG_FILE" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
internal: :: port = $PORT
external: $INTERFACE
clientmethod: none
socksmethod: username
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
client pass {
    from: ::/0 to: ::/0
    log: connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect disconnect error
    socksmethod: username
}
socks pass {
    from: ::/0 to: ::/0
    command: bind connect udpassociate
    log: connect disconnect error
    socksmethod: username
}
EOF
    
    # 防火墙配置
    echo "🔥 配置防火墙..."
    if command -v ufw &> /dev/null; then
        ufw allow $PORT/tcp &> /dev/null
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp &> /dev/null
        firewall-cmd --reload &> /dev/null
    fi
    
    # 启动服务
    echo "🚀 启动Dante服务..."
    if [ "$OS_TYPE" = "alpine" ]; then
        # 为 Alpine 创建 init.d 脚本
        cat > /etc/init.d/$SERVICE_NAME <<'INITSCRIPT'
#!/sbin/openrc-run

name="sockd"
description="Dante SOCKS server"
command="/usr/sbin/sockd"
command_args="-f /etc/sockd.conf"
pidfile="/var/run/sockd.pid"

depend() {
    need net
    after firewall
}
INITSCRIPT
        chmod +x /etc/init.d/$SERVICE_NAME
        rc-update add $SERVICE_NAME default &> /dev/null
        rc-service $SERVICE_NAME restart
    else
        systemctl restart $SERVICE_NAME
        systemctl enable $SERVICE_NAME &> /dev/null
    fi
    
    # 验证安装
    echo "✅ 安装完成，测试连接..."
    sleep 2
    if nc -zv localhost $PORT &> /dev/null; then
        IPV4=$(curl -s4 ifconfig.me)
        IPV6=$(curl -s6 ifconfig.me)
        echo "================================"
        echo "SOCKS5代理服务器已就绪"
        echo "IPv4地址: $IPV4"
        echo "IPv6地址: $IPV6"
        echo "端口: $PORT"
        echo "用户名: $USERNAME"
        echo "密码: $PASSWORD"
        echo "认证方式: 用户名/密码"
        echo "================================"
    else
        echo "❌ 服务启动失败，请检查配置" >&2
    fi
}

# 增加/修改用户
manage_user() {
    echo "================================"
    echo "   用户和端口管理"
    echo "================================"
    
    # 检查服务是否安装
    if [ "$OS_TYPE" = "alpine" ]; then
        if ! command -v sockd &> /dev/null; then
            echo "❌ SOCKS5代理未安装，请先执行安装"
            return
        fi
    else
        if ! command -v danted &> /dev/null; then
            echo "❌ SOCKS5代理未安装，请先执行安装"
            return
        fi
    fi
    
    # 显示现有用户
    show_existing_users
    
    echo "1. 添加新用户"
    echo "2. 修改现有用户密码"
    echo "3. 修改监听端口"
    echo "4. 返回主菜单"
    read -p "请选择操作 (1-4): " USER_CHOICE
    
    case $USER_CHOICE in
        1)
            read -p "👤 输入新用户名: " NEW_USERNAME
            while [ -z "$NEW_USERNAME" ]; do
                echo "❌ 用户名不能为空"
                read -p "👤 输入新用户名: " NEW_USERNAME
            done
            
            if id "$NEW_USERNAME" &>/dev/null; then
                echo "⚠️  用户 $NEW_USERNAME 已存在"
                return
            fi
            
            read -sp "🔒 输入密码: " NEW_PASSWORD
            echo ""
            while [ -z "$NEW_PASSWORD" ]; do
                echo "❌ 密码不能为空"
                read -sp "🔒 输入密码: " NEW_PASSWORD
                echo ""
            done
            
            if [ "$OS_TYPE" = "alpine" ]; then
                adduser -D -H -s /sbin/nologin "$NEW_USERNAME"
            else
                useradd -r -s /bin/false "$NEW_USERNAME"
            fi
            echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
            echo "✅ 用户 $NEW_USERNAME 已创建"
            ;;
        2)
            show_existing_users
            read -p "👤 输入要修改的用户名: " EXIST_USERNAME
            if ! id "$EXIST_USERNAME" &>/dev/null; then
                echo "❌ 用户 $EXIST_USERNAME 不存在"
                return
            fi
            
            read -sp "🔒 输入新密码: " NEW_PASSWORD
            echo ""
            while [ -z "$NEW_PASSWORD" ]; do
                echo "❌ 密码不能为空"
                read -sp "🔒 输入新密码: " NEW_PASSWORD
                echo ""
            done
            
            echo "$EXIST_USERNAME:$NEW_PASSWORD" | chpasswd
            echo "✅ 用户 $EXIST_USERNAME 的密码已更新"
            ;;
        3)
            CURRENT_PORT=$(get_current_port)
            if [ -n "$CURRENT_PORT" ]; then
                echo "当前端口: $CURRENT_PORT"
            fi
            
            read -p "🛡️ 输入新的代理端口: " NEW_PORT
            while ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; do
                echo "❌ 请输入有效的端口号 (1-65535)"
                read -p "🛡️ 输入新的代理端口: " NEW_PORT
            done
            
            # 修改配置文件中的端口
            if [ -f "$CONFIG_FILE" ]; then
                # 获取网络接口
                INTERFACE=$(ip -6 route | awk '/default/ {print $5; exit}')
                [ -z "$INTERFACE" ] && INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
                
                sed -i "s/internal: 0.0.0.0 port = [0-9]*/internal: 0.0.0.0 port = $NEW_PORT/" "$CONFIG_FILE"
                sed -i "s/internal: :: port = [0-9]*/internal: :: port = $NEW_PORT/" "$CONFIG_FILE"
                
                # 更新防火墙规则
                if command -v ufw &> /dev/null; then
                    if [ -n "$CURRENT_PORT" ]; then
                        ufw delete allow $CURRENT_PORT/tcp &> /dev/null
                    fi
                    ufw allow $NEW_PORT/tcp &> /dev/null
                elif command -v firewall-cmd &> /dev/null; then
                    if [ -n "$CURRENT_PORT" ]; then
                        firewall-cmd --permanent --remove-port=$CURRENT_PORT/tcp &> /dev/null
                    fi
                    firewall-cmd --permanent --add-port=$NEW_PORT/tcp &> /dev/null
                    firewall-cmd --reload &> /dev/null
                fi
                
                # 重启服务
                if [ "$OS_TYPE" = "alpine" ]; then
                    rc-service $SERVICE_NAME restart
                else
                    systemctl restart $SERVICE_NAME
                fi
                echo "✅ 端口已更新为 $NEW_PORT,服务已重启"
            else
                echo "❌ 配置文件不存在"
            fi
            ;;
        4)
            return
            ;;
        *)
            echo "❌ 无效选项"
            ;;
    esac
}

# 卸载SOCKS5代理
uninstall_socks5() {
    echo "================================"
    echo "   卸载 SOCKS5 代理服务器"
    echo "================================"
    
    echo "🛑 停止Dante服务..."
    if [ "$OS_TYPE" = "alpine" ]; then
        rc-service $SERVICE_NAME stop &> /dev/null
        rc-update del $SERVICE_NAME default &> /dev/null
        rm -f /etc/init.d/$SERVICE_NAME
    else
        systemctl stop $SERVICE_NAME &> /dev/null
        systemctl disable $SERVICE_NAME &> /dev/null
    fi
    
    echo "🗑️  删除软件包..."
    case $OS_TYPE in
        alpine)
            apk del dante-server &> /dev/null
            ;;
        ubuntu|debian)
            apt remove --purge -y dante-server &> /dev/null
            apt autoremove -y &> /dev/null
            ;;
        centos|rhel|fedora)
            yum remove -y dante-server &> /dev/null
            ;;
    esac
    
    echo "📁 删除配置文件..."
    rm -f "$CONFIG_FILE"
    
    # 删除防火墙规则
    CURRENT_PORT=$(get_current_port)
    if [ -n "$CURRENT_PORT" ]; then
        if command -v ufw &> /dev/null; then
            ufw delete allow $CURRENT_PORT/tcp &> /dev/null
        elif command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --remove-port=$CURRENT_PORT/tcp &> /dev/null
            firewall-cmd --reload &> /dev/null
        fi
    fi
    
    echo "✅ SOCKS5代理已完全卸载"
    
    # 显示现有用户
    show_existing_users
    
    read -p "是否删除SOCKS5用户? (y/n): " DELETE_USERS
    if [[ "$DELETE_USERS" =~ ^[Yy]$ ]]; then
        read -p "输入要删除的用户名 (多个用户用空格分隔): " USERS
        for USER in $USERS; do
            if id "$USER" &>/dev/null; then
                userdel "$USER" &> /dev/null
                echo "✅ 已删除用户: $USER"
            else
                echo "⚠️  用户不存在: $USER"
            fi
        done
    fi
}

# 显示主菜单
show_menu() {
    clear
    echo "================================"
    echo "   SOCKS5 代理管理脚本"
    echo "================================"
    echo "1. 安装 SOCKS5 代理"
    echo "2. 增加/修改用户"
    echo "3. 卸载 SOCKS5 代理"
    echo "4. 退出"
    echo "================================"
}

# 主循环
main() {
    while true; do
        show_menu
        read -p "请选择操作 (1-4): " CHOICE
        
        case $CHOICE in
            1)
                install_socks5
                read -p "按回车键继续..."
                ;;
            2)
                manage_user
                read -p "按回车键继续..."
                ;;
            3)
                uninstall_socks5
                read -p "按回车键继续..."
                ;;
            4)
                exit 0
                ;;
            *)
                echo "❌ 无效选项，请重新选择"
                sleep 2
                ;;
        esac
    done
}

# 启动脚本
main