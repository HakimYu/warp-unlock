#!/bin/bash

# WARP 一键脚本 - 使用 Cloudflare 官方客户端
# 让 Google 流量自动走 WARP，解锁受限服务

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 备份已存在的系统文件，避免重复运行时无提示覆盖用户配置
backup_file() {
    local file="$1"
    [ -e "$file" ] || return 0

    local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    [ -e "$backup" ] && backup="${backup}.$$"

    cp -a "$file" "$backup" || { echo -e "${RED}备份失败: $file${NC}"; exit 1; }
    echo -e "${YELLOW}已备份: $file -> $backup${NC}"
}

# 写入脚本托管文件：内容相同则不动，内容不同则先备份再覆盖
write_managed_file() {
    local target="$1"
    local mode="${2:-0644}"
    local tmp

    tmp=$(mktemp) || { echo -e "${RED}创建临时文件失败${NC}"; exit 1; }
    cat > "$tmp"

    if [ -e "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        chmod "$mode" "$target" 2>/dev/null || true
        return 0
    fi

    [ -e "$target" ] && backup_file "$target"
    mkdir -p "$(dirname "$target")"
    install -m "$mode" "$tmp" "$target" || { rm -f "$tmp"; echo -e "${RED}写入失败: $target${NC}"; exit 1; }
    rm -f "$tmp"
}

# 移除本脚本添加的 IPv4 优先规则
remove_gai_precedence() {
    [ -f /etc/gai.conf ] || return 0
    local tmp
    tmp=$(mktemp) || return 1
    grep -v -F "precedence ::ffff:0:0/96  100" /etc/gai.conf > "$tmp" || true
    cp "$tmp" /etc/gai.conf
    rm -f "$tmp"
}


# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║     🌐 WARP 一键脚本 - Google 自动解锁 🌐           ║"
    echo "║         使用 Cloudflare 官方客户端                  ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 安装 Cloudflare WARP 官方客户端
install_warp() {
    echo -e "\n${CYAN}[1/3] 安装 Cloudflare WARP 官方客户端...${NC}"
    
    case $OS in
        ubuntu|debian)
            # 先安装必要依赖
            apt-get update -y >/dev/null 2>&1
            apt-get install -y gnupg curl wget lsb-release >/dev/null 2>&1

            if [ -z "$CODENAME" ]; then
                CODENAME=$(lsb_release -cs 2>/dev/null || true)
            fi
            if [ -z "$CODENAME" ]; then
                echo -e "${RED}无法检测 Debian/Ubuntu 发行版代号，无法添加 Cloudflare 源${NC}"
                exit 1
            fi
            
            # 添加 Cloudflare GPG 密钥
            KEYRING=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            TMP_KEY=$(mktemp) || { echo -e "${RED}创建临时文件失败${NC}"; exit 1; }
            if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output "$TMP_KEY"; then
                rm -f "$TMP_KEY"
                echo -e "${RED}下载 Cloudflare GPG 密钥失败${NC}"
                exit 1
            fi
            if [ ! -e "$KEYRING" ] || ! cmp -s "$TMP_KEY" "$KEYRING"; then
                [ -e "$KEYRING" ] && backup_file "$KEYRING"
                install -m 0644 "$TMP_KEY" "$KEYRING" || { rm -f "$TMP_KEY"; echo -e "${RED}安装 Cloudflare GPG 密钥失败${NC}"; exit 1; }
            fi
            rm -f "$TMP_KEY"
            
            # 添加仓库
            write_managed_file /etc/apt/sources.list.d/cloudflare-client.list 0644 << EOF
# Managed by warp-unlock
deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main
EOF
            
            # 安装
            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            # 添加仓库
            write_managed_file /etc/yum.repos.d/cloudflare-warp.repo 0644 << 'EOF'
# Managed by warp-unlock
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
            if command -v dnf &>/dev/null; then
                dnf install -y cloudflare-warp
            else
                yum install -y cloudflare-warp
            fi
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            echo -e "${YELLOW}支持的系统: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora${NC}"
            exit 1
            ;;
    esac
    
    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}WARP 安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ WARP 客户端已安装${NC}"
}

# 配置 WARP
configure_warp() {
    echo -e "\n${CYAN}[2/3] 配置 WARP...${NC}"
    
    # 注册设备：重复运行时已注册可能返回失败，此时只在状态不可用时中断
    echo -e "正在注册设备..."
    if ! warp-cli --accept-tos registration new 2>/dev/null && ! warp-cli --accept-tos register 2>/dev/null; then
        STATUS=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true)
        if echo "$STATUS" | grep -qiE "registration.*missing|not registered|未注册|error|failed"; then
            echo -e "${RED}WARP 设备注册失败${NC}"
            echo -e "$STATUS"
            exit 1
        fi
        echo -e "${YELLOW}设备可能已注册，继续配置...${NC}"
    fi
    
    # 设置为代理模式 (不会接管全部流量，只通过 SOCKS5 代理)
    if ! warp-cli --accept-tos mode proxy 2>/dev/null && ! warp-cli mode proxy 2>/dev/null; then
        echo -e "${RED}设置 WARP 代理模式失败${NC}"
        exit 1
    fi
    
    # 设置代理端口
    if ! warp-cli --accept-tos proxy port 40000 2>/dev/null && ! warp-cli proxy port 40000 2>/dev/null; then
        echo -e "${RED}设置 WARP SOCKS5 端口失败${NC}"
        exit 1
    fi
    
    # 连接
    echo -e "正在连接 WARP..."
    if ! warp-cli --accept-tos connect 2>/dev/null && ! warp-cli connect 2>/dev/null; then
        echo -e "${RED}连接 WARP 失败${NC}"
        exit 1
    fi
    
    sleep 3
    
    # 显示状态
    STATUS=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true)
    echo -e "状态: ${GREEN}$STATUS${NC}"
    
    echo -e "${GREEN}✓ WARP 配置完成${NC}"
}

# 配置透明代理 (让 Google 流量自动走 WARP)
setup_transparent_proxy() {
    echo -e "\n${CYAN}[3/3] 配置透明代理规则...${NC}"

    local enable_cloudflare_proxy=0
    read -p "是否同时代理 Cloudflare IP 段？可能影响大量使用 Cloudflare CDN 的网站 [y/N]: " cf_choice
    case "$cf_choice" in
        y|Y|yes|YES) enable_cloudflare_proxy=1 ;;
    esac
    
    # 禁用 IPv6 访问 Google（避免 IPv4/IPv6 不匹配导致被检测）
    echo -e "配置 IPv6 规则..."
    
    # 方法1: 添加 IPv6 黑洞路由到 Google IPv6 地址
    # Google IPv6 范围: 2607:f8b0::/32
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
    
    # 方法2: 设置系统优先使用 IPv4。首次修改前备份，重复运行不重复追加。
    if ! grep -qF "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        [ -e /etc/gai.conf ] && backup_file /etc/gai.conf
        {
            echo ""
            echo "# Added by warp-unlock: prefer IPv4 for Google/WARP routing"
            echo "precedence ::ffff:0:0/96  100"
        } >> /etc/gai.conf
    fi
    
    # 安装 redsocks (透明代理工具)
    case $OS in
        ubuntu|debian)
            apt-get install -y redsocks iptables >/dev/null 2>&1 || {
                echo -e "${RED}安装 redsocks/iptables 失败${NC}"
                exit 1
            }
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables >/dev/null 2>&1 || {
                    echo -e "${RED}安装 redsocks/iptables 失败${NC}"
                    exit 1
                }
            else
                yum install -y redsocks iptables >/dev/null 2>&1 || {
                    echo -e "${RED}安装 redsocks/iptables 失败${NC}"
                    exit 1
                }
            fi
            ;;
    esac
    
    # 创建 redsocks 配置
    write_managed_file /etc/redsocks.conf 0644 << 'EOF'
# Managed by warp-unlock
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    pidfile = "/run/warp-google-redsocks.pid";
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}
EOF

    # 保存 Cloudflare 分流开关
    write_managed_file /etc/default/warp-google 0644 << EOF
# Managed by warp-unlock
ENABLE_CLOUDFLARE_PROXY=$enable_cloudflare_proxy
EOF

    # 创建 iptables 规则脚本
    write_managed_file /usr/local/bin/warp-google 0755 << 'SCRIPT'
#!/bin/bash

REDSOCKS_PID_FILE="/run/warp-google-redsocks.pid"
IP_CACHE_DIR="/var/cache/warp-unlock"
IP_CACHE_MAX_AGE=86400
ENABLE_CLOUDFLARE_PROXY=0
[ -f /etc/default/warp-google ] && . /etc/default/warp-google

# Google / Cloudflare 官方 IPv4 段 API。优先动态获取，失败时使用缓存，再失败才使用 fallback。
GOOGLE_IP_API_URL="https://www.gstatic.com/ipranges/goog.json"
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"

FALLBACK_GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

FALLBACK_CLOUDFLARE_IPS="
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
"

cache_is_fresh() {
    local cache_file="$1"
    [ -s "$cache_file" ] || return 1

    local now mtime age
    now=$(date +%s)
    mtime=$(date -r "$cache_file" +%s 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -lt "$IP_CACHE_MAX_AGE" ]
}

read_cache_or_fallback() {
    local name="$1"
    local cache_file="$2"
    local fallback="$3"

    if [ -s "$cache_file" ]; then
        echo "警告：动态获取 $name IP 段失败，使用缓存 $cache_file" >&2
        cat "$cache_file"
    else
        echo "警告：动态获取 $name IP 段失败，使用内置 fallback" >&2
        echo "$fallback"
    fi
}

get_google_ips() {
    local cache_file="$IP_CACHE_DIR/google-ips-v4.txt"
    local ips

    if cache_is_fresh "$cache_file"; then
        cat "$cache_file"
        return
    fi

    ips=$(curl -fsSL --max-time 10 "$GOOGLE_IP_API_URL" 2>/dev/null \
        | grep -oE '"ipv4Prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"ipv4Prefix"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | sort -u)

    if [ -n "$ips" ]; then
        mkdir -p "$IP_CACHE_DIR"
        echo "$ips" > "$cache_file"
        echo "$ips"
    else
        read_cache_or_fallback "Google" "$cache_file" "$FALLBACK_GOOGLE_IPS"
    fi
}

get_cloudflare_ips() {
    local cache_file="$IP_CACHE_DIR/cloudflare-ips-v4.txt"
    local ips

    if [ "$ENABLE_CLOUDFLARE_PROXY" != "1" ]; then
        return
    fi

    if cache_is_fresh "$cache_file"; then
        cat "$cache_file"
        return
    fi

    ips=$(curl -fsSL --max-time 10 "$CLOUDFLARE_IPV4_URL" 2>/dev/null \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' \
        | sort -u)

    if [ -n "$ips" ]; then
        mkdir -p "$IP_CACHE_DIR"
        echo "$ips" > "$cache_file"
        echo "$ips"
    else
        read_cache_or_fallback "Cloudflare" "$cache_file" "$FALLBACK_CLOUDFLARE_IPS"
    fi
}

get_proxy_ips() {
    {
        get_google_ips
        get_cloudflare_ips
    } | grep -v '^[[:space:]]*$' | sort -u
}

stop_redsocks() {
    if [ -f "$REDSOCKS_PID_FILE" ]; then
        pid=$(cat "$REDSOCKS_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$REDSOCKS_PID_FILE"
    fi
}

start_redsocks() {
    stop_redsocks
    redsocks -c /etc/redsocks.conf
    sleep 1

    if [ -f "$REDSOCKS_PID_FILE" ] && kill -0 "$(cat "$REDSOCKS_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        return
    fi

    # 兼容少数 redsocks 版本不写 pidfile 的情况。
    pid=$(pgrep -f "redsocks.*-c /etc/redsocks.conf" | head -n 1)
    if [ -z "$pid" ]; then
        echo "redsocks 启动失败，请检查 /etc/redsocks.conf"
        exit 1
    fi
    echo "$pid" > "$REDSOCKS_PID_FILE"
}

start() {
    echo "启动 Google/Cloudflare 透明代理..."
    
    # 启动本脚本管理的 redsocks，避免杀掉系统里其他 redsocks 实例
    start_redsocks
    
    # 创建新的 iptables 链
    iptables -t nat -N WARP_UNLOCK 2>/dev/null || iptables -t nat -F WARP_UNLOCK
    
    # 添加 Google / Cloudflare IP 规则
    for ip in $(get_proxy_ips); do
        iptables -t nat -A WARP_UNLOCK -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    
    # 应用到 OUTPUT 链
    iptables -t nat -C OUTPUT -j WARP_UNLOCK 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_UNLOCK
    
    echo "Google/Cloudflare 透明代理已启动"
}

stop() {
    echo "停止 Google/Cloudflare 透明代理..."
    stop_redsocks
    iptables -t nat -D OUTPUT -j WARP_UNLOCK 2>/dev/null
    iptables -t nat -F WARP_UNLOCK 2>/dev/null
    iptables -t nat -X WARP_UNLOCK 2>/dev/null
    # 兼容清理旧版本链名
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    echo "Google/Cloudflare 透明代理已停止"
}

status() {
    echo "=== WARP 状态 ==="
    warp-cli status 2>/dev/null || echo "WARP 未运行"
    echo ""
    echo "=== Redsocks 状态 ==="
    if [ -f "$REDSOCKS_PID_FILE" ] && kill -0 "$(cat "$REDSOCKS_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
    echo ""
    echo "=== iptables 规则 ==="
    iptables -t nat -L WARP_UNLOCK -n 2>/dev/null | head -5 || echo "无规则"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    *) echo "用法: $0 {start|stop|restart|status}" ;;
esac
SCRIPT

    # 启动透明代理
    /usr/local/bin/warp-google start
    
    # 创建 systemd 服务
    write_managed_file /etc/systemd/system/warp-google.service 0644 << 'EOF'
# Managed by warp-unlock
[Unit]
Description=WARP Google/Cloudflare Transparent Proxy
After=network.target warp-svc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-google 2>/dev/null
    
    echo -e "${GREEN}✓ 透明代理配置完成${NC}"
}

# 测试连接
test_connection() {
    echo -e "\n${CYAN}测试连接...${NC}"
    
    sleep 2
    
    # 测试 Google
    GOOGLE_TEST=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$GOOGLE_TEST" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！${NC}"
    else
        echo -e "${YELLOW}Google 测试返回: $GOOGLE_TEST${NC}"
    fi
    
    # 显示 WARP IP
    WARP_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 10 ip.sb 2>/dev/null)
    if [ -n "$WARP_IP" ]; then
        WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
        echo -e "\nWARP IP: ${GREEN}$WARP_IP${NC}"
        echo -e "WARP 位置: ${GREEN}$(echo $WARP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $WARP_INFO | grep -oP '"city":"\K[^"]+')${NC}"
    fi
}

# 创建管理脚本
create_management() {
    write_managed_file /usr/local/bin/warp 0755 << 'EOF'
#!/bin/bash

remove_gai_precedence() {
    [ -f /etc/gai.conf ] || return 0
    tmp=$(mktemp) || return 1
    grep -v -F "precedence ::ffff:0:0/96  100" /etc/gai.conf > "$tmp" || true
    cp "$tmp" /etc/gai.conf
    rm -f "$tmp"
}

case "$1" in
    status)
        warp-cli status 2>/dev/null
        echo ""
        /usr/local/bin/warp-google status 2>/dev/null
        ;;
    start)
        warp-cli connect 2>/dev/null
        /usr/local/bin/warp-google start
        ;;
    stop)
        /usr/local/bin/warp-google stop
        warp-cli disconnect 2>/dev/null
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    test)
        echo "测试 Google 连接..."
        curl -s --max-time 10 -o /dev/null -w "状态码: %{http_code}\n" https://www.google.com
        ;;
    ip)
        echo "直连 IP:"
        curl -4 -s ip.sb
        echo ""
        echo "WARP IP:"
        curl -x socks5://127.0.0.1:40000 -s ip.sb
        echo ""
        ;;
    uninstall)
        echo "正在卸载..."
        /usr/local/bin/warp-google stop 2>/dev/null
        warp-cli disconnect 2>/dev/null
        systemctl disable warp-google 2>/dev/null
        systemctl stop warp-google 2>/dev/null
        systemctl stop warp-svc 2>/dev/null
        ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null
        remove_gai_precedence
        rm -f /etc/systemd/system/warp-google.service
        rm -f /usr/local/bin/warp-google
        rm -f /etc/redsocks.conf
        rm -f /etc/default/warp-google
        rm -f /run/warp-google-redsocks.pid
        rm -rf /var/cache/warp-unlock
        rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
        systemctl daemon-reload 2>/dev/null
        apt-get remove -y cloudflare-warp redsocks 2>/dev/null || yum remove -y cloudflare-warp redsocks 2>/dev/null || dnf remove -y cloudflare-warp redsocks 2>/dev/null
        rm -f /usr/local/bin/warp
        echo "WARP 已卸载"
        ;;
    *)
        echo "WARP 管理工具"
        echo ""
        echo "用法: warp <命令>"
        echo ""
        echo "命令:"
        echo "  status    查看状态"
        echo "  start     启动 WARP"
        echo "  stop      停止 WARP"
        echo "  restart   重启 WARP"
        echo "  test      测试 Google"
        echo "  ip        查看 IP"
        echo "  uninstall 卸载 WARP"
        ;;
esac
EOF
}

# 安装主流程
do_install() {
    install_warp
    configure_warp
    setup_transparent_proxy
    create_management
    test_connection
    
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            🎉 安装完成！Google 已解锁 🎉            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${YELLOW}所有 Google 流量现已自动通过 WARP！${NC}"
    echo -e "${YELLOW}无需任何额外配置，直接访问即可。${NC}"
    echo -e "\n管理命令: ${CYAN}warp {status|start|stop|restart|test|ip|uninstall}${NC}\n"
}

# 卸载
do_uninstall() {
    echo -e "\n${YELLOW}正在卸载 WARP...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    warp-cli disconnect 2>/dev/null
    systemctl disable warp-google 2>/dev/null
    systemctl stop warp-google 2>/dev/null
    systemctl stop warp-svc 2>/dev/null
    rm -f /etc/systemd/system/warp-google.service
    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp
    rm -f /etc/redsocks.conf
    rm -f /etc/default/warp-google
    rm -f /run/warp-google-redsocks.pid
    rm -rf /var/cache/warp-unlock
    
    # 清理 iptables 规则
    iptables -t nat -D OUTPUT -j WARP_UNLOCK 2>/dev/null
    iptables -t nat -F WARP_UNLOCK 2>/dev/null
    iptables -t nat -X WARP_UNLOCK 2>/dev/null
    # 兼容清理旧版本链名
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    
    # 删除 IPv6 黑洞路由和 IPv4 优先规则
    ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null
    remove_gai_precedence
    
    # 卸载软件包并清理仓库文件
    case $OS in
        ubuntu|debian)
            apt-get remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum remove -y cloudflare-warp redsocks 2>/dev/null || dnf remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac
    systemctl daemon-reload 2>/dev/null
    
    echo -e "${GREEN}✓ WARP 已完全卸载${NC}\n"
}

# 查看状态
do_status() {
    echo -e "\n${CYAN}══════════════ WARP 运行状态 ══════════════${NC}\n"
    
    # WARP 客户端状态
    echo -e "${YELLOW}【WARP 客户端】${NC}"
    if command -v warp-cli &>/dev/null; then
        warp-cli status 2>/dev/null || echo "未运行"
    else
        echo -e "${RED}未安装${NC}"
    fi
    
    echo ""
    
    # Redsocks 状态
    echo -e "${YELLOW}【透明代理】${NC}"
    if pgrep -x redsocks >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
    
    echo ""
    
    # iptables 规则
    echo -e "${YELLOW}【iptables 规则】${NC}"
    iptables -t nat -L WARP_UNLOCK -n 2>/dev/null | head -3 || echo -e "${RED}无规则${NC}"
    
    echo -e "\n${CYAN}════════════════════════════════════════════${NC}\n"
}

# 查看 IP
do_show_ip() {
    echo -e "\n${CYAN}══════════════ IP 信息 ══════════════${NC}\n"
    
    echo -e "${YELLOW}【直连 IP】${NC}"
    DIRECT_IP=$(curl -4 -s --max-time 5 ip.sb)
    DIRECT_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$DIRECT_IP?lang=zh-CN" 2>/dev/null)
    echo -e "IP: ${GREEN}$DIRECT_IP${NC}"
    echo -e "位置: $(echo $DIRECT_INFO | grep -oP '"country":"\K[^"]+') - $(echo $DIRECT_INFO | grep -oP '"city":"\K[^"]+')\n"
    
    echo -e "${YELLOW}【WARP IP】${NC}"
    WARP_IP=$(curl -x socks5://127.0.0.1:40000 -s --max-time 5 ip.sb 2>/dev/null)
    if [ -n "$WARP_IP" ]; then
        WARP_INFO=$(curl -s --max-time 5 "http://ip-api.com/json/$WARP_IP?lang=zh-CN" 2>/dev/null)
        echo -e "IP: ${GREEN}$WARP_IP${NC}"
        echo -e "位置: $(echo $WARP_INFO | grep -oP '"country":"\K[^"]+') - $(echo $WARP_INFO | grep -oP '"city":"\K[^"]+')\n"
    else
        echo -e "${RED}无法获取 (WARP 可能未运行)${NC}\n"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════${NC}\n"
}

# 测试 Google 连接
do_test_google() {
    echo -e "\n${CYAN}测试 Google 连接...${NC}"
    RESULT=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$RESULT" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！状态码: $RESULT${NC}\n"
    else
        echo -e "${RED}✗ Google 连接失败，状态码: $RESULT${NC}\n"
    fi
}

# 启动服务
do_start() {
    echo -e "\n${CYAN}启动 WARP 服务...${NC}"
    warp-cli connect 2>/dev/null
    /usr/local/bin/warp-google start 2>/dev/null
    echo -e "${GREEN}✓ WARP 已启动${NC}\n"
}

# 停止服务
do_stop() {
    echo -e "\n${CYAN}停止 WARP 服务...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    warp-cli disconnect 2>/dev/null
    echo -e "${GREEN}✓ WARP 已停止${NC}\n"
}

# 显示菜单
show_menu() {
    echo -e "${YELLOW}请选择操作:${NC}\n"
    echo -e "  ${GREEN}1.${NC} 安装 WARP (解锁 Gemini和商店等)"
    echo -e "  ${GREEN}2.${NC} 卸载 WARP"
    echo -e "  ${GREEN}3.${NC} 查看状态"
    echo -e "  ${GREEN}0.${NC} 退出\n"
    
    read -p "请输入选项 [0-3]: " choice
    
    case $choice in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_status; do_show_ip; do_test_google ;;
        0) echo -e "\n${GREEN}再见！${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}无效选项${NC}\n" ;;
    esac
}

# 主入口
main() {
    show_banner
    
    # 检查 root
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }
    
    # 检测系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        CODENAME=${VERSION_CODENAME:-}
    else
        echo -e "${RED}无法检测系统${NC}"; exit 1
    fi
    
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    echo -e "${GREEN}系统: $OS $VERSION ($CODENAME) $ARCH${NC}\n"
    
    show_menu
}

main
