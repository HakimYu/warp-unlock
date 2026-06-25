#!/bin/bash

# WARP 一键脚本 - 使用 Cloudflare 官方客户端
# 让 Google 流量自动走 WARP，解锁受限服务

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

WARP_PROXY_PORT=40000
REDSOCKS_PORT=12345
REDSOCKS_CONF="/etc/redsocks.conf"
IP_CACHE_DIR="/var/cache/warp-unlock"
IP_CACHE_MAX_AGE=86400
GOOGLE_IP_API_URL="https://www.gstatic.com/ipranges/goog.json"

# ─── 备份与文件管理 ─────────────────────────────────────────────

backup_file() {
    local file="$1"
    [ -e "$file" ] || return 0
    local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    [ -e "$backup" ] && backup="${backup}.$$"
    cp -a "$file" "$backup" || { echo -e "${RED}备份失败: $file${NC}"; exit 1; }
    echo -e "${YELLOW}已备份: $file -> $backup${NC}"
}

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

# ─── 显示工具 ──────────────────────────────────────────────────

print_line() { echo -e "${DIM}──────────────────────────────────────────────${NC}"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

pause_return() {
    echo ""
    read -r -p "按回车键返回菜单..." _
}

confirm_action() {
    local answer
    read -r -p "$1 [y/N]: " answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║              warp-unlock                    ║"
    echo "║      Cloudflare WARP · 解锁 Google          ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

remove_gai_precedence() {
    [ -f /etc/gai.conf ] || return 0
    local tmp
    tmp=$(mktemp) || return 1
    grep -v -F "precedence ::ffff:0:0/96  100" /etc/gai.conf > "$tmp" || true
    cp "$tmp" /etc/gai.conf
    rm -f "$tmp"
}

# ─── IP 段获取（带缓存 + fallback）──────────────────────────────

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

cache_is_fresh() {
    local cache_file="$1"
    [ -s "$cache_file" ] || return 1
    local now mtime age
    now=$(date +%s)
    mtime=$(date -r "$cache_file" +%s 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -lt "$IP_CACHE_MAX_AGE" ]
}

get_google_ips() {
    local cache_file="$IP_CACHE_DIR/google-ips-v4.txt"
    if cache_is_fresh "$cache_file"; then
        cat "$cache_file"
        return
    fi
    local ips
    ips=$(curl -fsSL --max-time 10 "$GOOGLE_IP_API_URL" 2>/dev/null \
        | grep -oE '"ipv4Prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"ipv4Prefix"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | sort -u)
    if [ -n "$ips" ]; then
        mkdir -p "$IP_CACHE_DIR"
        echo "$ips" > "$cache_file"
        echo "$ips"
    else
        if [ -s "$cache_file" ]; then
            echo "警告：动态获取 Google IP 段失败，使用缓存 $cache_file" >&2
            cat "$cache_file"
        else
            echo "警告：动态获取 Google IP 段失败，使用内置 fallback" >&2
            echo "$FALLBACK_GOOGLE_IPS"
        fi
    fi
}

# ─── 显示当前 IP ───────────────────────────────────────────────

show_current_ip() {
    echo -e "\n${YELLOW}当前 IP 信息:${NC}"
    local current_ip ip_info
    current_ip=$(curl -4 -s --max-time 5 ip.sb)
    ip_info=$(curl -s --max-time 5 "http://ip-api.com/json/$current_ip?lang=zh-CN" 2>/dev/null)
    echo -e "IP: ${GREEN}$current_ip${NC}"
    echo -e "位置: ${GREEN}$(echo "$ip_info" | grep -oP '"country":"\K[^"]+') - $(echo "$ip_info" | grep -oP '"city":"\K[^"]+')${NC}"
}

# ─── 安装 Cloudflare WARP 官方客户端 ────────────────────────────

install_warp() {
    echo -e "\n${CYAN}[1/3] 安装 Cloudflare WARP 官方客户端...${NC}"

    case $OS in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y gnupg curl wget lsb-release >/dev/null 2>&1

            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" > /etc/apt/sources.list.d/cloudflare-client.list

            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo << 'EOF'
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
        print_error "WARP 安装失败"
        exit 1
    fi

    print_success "WARP 客户端已安装"
}

# ─── 配置 WARP ─────────────────────────────────────────────────

configure_warp() {
    echo -e "\n${CYAN}[2/3] 配置 WARP...${NC}"

    echo -e "正在注册设备..."
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true

    # 设置为代理模式（不接管全部流量，只通过 SOCKS5 代理）
    warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli mode proxy 2>/dev/null || true

    # 设置代理端口
    warp-cli --accept-tos proxy port "$WARP_PROXY_PORT" 2>/dev/null || warp-cli proxy port "$WARP_PROXY_PORT" 2>/dev/null || true

    echo -e "正在连接 WARP..."
    warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null

    sleep 3

    local status
    status=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null)
    echo -e "状态: ${GREEN}$status${NC}"

    print_success "WARP 配置完成"
}

# ─── 配置透明代理（redsocks + iptables）────────────────────────

setup_transparent_proxy() {
    echo -e "\n${CYAN}[3/3] 配置透明代理规则...${NC}"

    # 禁用 IPv6 访问 Google（避免 IPv4/IPv6 不匹配导致被检测）
    echo -e "配置 IPv6 规则..."
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true

    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    # 安装 redsocks 和 iptables
    case $OS in
        ubuntu|debian)
            apt-get install -y redsocks iptables >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables >/dev/null 2>&1
            else
                yum install -y redsocks iptables >/dev/null 2>&1
            fi
            ;;
    esac

    # 创建 redsocks 配置
    write_managed_file "$REDSOCKS_CONF" 0644 << EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $REDSOCKS_PORT;
    ip = 127.0.0.1;
    port = $WARP_PROXY_PORT;
    type = socks5;
}
EOF

    # 创建 iptables 路由脚本（支持动态获取 Google IP）
    write_managed_file /usr/local/bin/warp-google 0755 << 'SCRIPT'
#!/bin/bash

REDSOCKS_PORT=12345
IP_CACHE_DIR="/var/cache/warp-unlock"
IP_CACHE_MAX_AGE=86400
GOOGLE_IP_API_URL="https://www.gstatic.com/ipranges/goog.json"

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

cache_is_fresh() {
    local cache_file="$1"
    [ -s "$cache_file" ] || return 1
    local now mtime age
    now=$(date +%s)
    mtime=$(date -r "$cache_file" +%s 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -lt "$IP_CACHE_MAX_AGE" ]
}

get_google_ips() {
    local cache_file="$IP_CACHE_DIR/google-ips-v4.txt"
    if cache_is_fresh "$cache_file"; then
        cat "$cache_file"
        return
    fi
    local ips
    ips=$(curl -fsSL --max-time 10 "$GOOGLE_IP_API_URL" 2>/dev/null \
        | grep -oE '"ipv4Prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"ipv4Prefix"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        | sort -u)
    if [ -n "$ips" ]; then
        mkdir -p "$IP_CACHE_DIR"
        echo "$ips" > "$cache_file"
        echo "$ips"
    else
        if [ -s "$cache_file" ]; then
            echo "警告：动态获取 Google IP 段失败，使用缓存" >&2
            cat "$cache_file"
        else
            echo "警告：动态获取 Google IP 段失败，使用内置 fallback" >&2
            echo "$FALLBACK_GOOGLE_IPS"
        fi
    fi
}

start() {
    echo "启动 Google 透明代理..."

    # 启动 redsocks
    pkill redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf

    # 创建新的 iptables 链
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE

    # 动态获取 Google IP 并添加规则
    local count=0
    for ip in $(get_google_ips); do
        [ -z "$ip" ] && continue
        iptables -t nat -A WARP_GOOGLE -d "$ip" -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT" && count=$((count + 1))
    done
    echo "已添加 $count 条 iptables 规则"

    # 应用到 OUTPUT 链
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_GOOGLE

    echo "Google 透明代理已启动"
}

stop() {
    echo "停止 Google 透明代理..."
    pkill redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    echo "Google 透明代理已停止"
}

status() {
    echo "=== WARP 状态 ==="
    warp-cli status 2>/dev/null || echo "WARP 未运行"
    echo ""
    echo "=== Redsocks 状态 ==="
    pgrep -x redsocks >/dev/null && echo "运行中" || echo "未运行"
    echo ""
    echo "=== iptables 规则 ==="
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -5 || echo "无规则"
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
Description=WARP Google Transparent Proxy
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

    print_success "透明代理配置完成"
}

# ─── 测试连接 ───────────────────────────────────────────────────

test_connection() {
    echo -e "\n${CYAN}测试连接...${NC}"
    sleep 2

    local google_test
    google_test=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$google_test" = "200" ]; then
        print_success "Google 连接成功"
    else
        echo -e "${YELLOW}Google 测试返回: $google_test${NC}"
    fi

    local warp_ip warp_info
    warp_ip=$(curl -x "socks5://127.0.0.1:$WARP_PROXY_PORT" -s --max-time 10 ip.sb 2>/dev/null)
    if [ -n "$warp_ip" ]; then
        warp_info=$(curl -s --max-time 5 "http://ip-api.com/json/$warp_ip?lang=zh-CN" 2>/dev/null)
        echo -e "\nWARP IP: ${GREEN}$warp_ip${NC}"
        echo -e "WARP 位置: ${GREEN}$(echo "$warp_info" | grep -oP '"country":"\K[^"]+') - $(echo "$warp_info" | grep -oP '"city":"\K[^"]+')${NC}"
    fi
}

# ─── 管理脚本 ───────────────────────────────────────────────────

create_management() {
    write_managed_file /usr/local/bin/warp 0755 << EOF
#!/bin/bash

remove_gai_precedence() {
    [ -f /etc/gai.conf ] || return 0
    tmp=\$(mktemp) || return 1
    grep -v -F "precedence ::ffff:0:0/96  100" /etc/gai.conf > "\$tmp" || true
    cp "\$tmp" /etc/gai.conf
    rm -f "\$tmp"
}

case "\$1" in
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
        \$0 stop
        sleep 2
        \$0 start
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
        curl -x socks5://127.0.0.1:$WARP_PROXY_PORT -s ip.sb
        echo ""
        ;;
    uninstall)
        echo "正在卸载..."
        /usr/local/bin/warp-google stop 2>/dev/null
        warp-cli disconnect 2>/dev/null
        systemctl disable warp-google 2>/dev/null
        systemctl stop warp-svc 2>/dev/null
        iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
        iptables -t nat -F WARP_GOOGLE 2>/dev/null
        iptables -t nat -X WARP_GOOGLE 2>/dev/null
        ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null
        remove_gai_precedence
        rm -f /etc/systemd/system/warp-google.service
        rm -f /usr/local/bin/warp-google
        rm -f /usr/local/bin/warp
        rm -f /etc/redsocks.conf
        rm -rf /var/cache/warp-unlock
        systemctl daemon-reload 2>/dev/null
        apt-get remove -y cloudflare-warp redsocks 2>/dev/null || yum remove -y cloudflare-warp redsocks 2>/dev/null
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
        echo "WARP 已卸载"
        ;;
    *)
        echo "warp-unlock 管理工具"
        echo ""
        echo "用法: warp <命令>"
        echo ""
        echo "常用命令:"
        echo "  status     查看 WARP 和透明代理状态"
        echo "  ip         对比直连 IP 和 WARP IP"
        echo "  test       测试 Google 连接"
        echo ""
        echo "服务控制:"
        echo "  start      启动 WARP 透明代理"
        echo "  stop       停止 WARP 透明代理"
        echo "  restart    重启服务"
        echo ""
        echo "维护:"
        echo "  uninstall  卸载 WARP 和本脚本配置"
        ;;
esac
EOF
}

# ─── 安装主流程 ─────────────────────────────────────────────────

do_install() {
    install_warp
    configure_warp
    setup_transparent_proxy
    create_management
    test_connection

    echo -e "\n${GREEN}${BOLD}安装完成！Google 已解锁${NC}"
    print_line
    echo -e "${YELLOW}所有 Google 流量现已自动通过 WARP${NC}"
    echo -e "${YELLOW}管理:${NC} ${CYAN}warp {status|ip|test|start|stop|restart|uninstall}${NC}\n"
}

# ─── 卸载 ───────────────────────────────────────────────────────

do_uninstall() {
    echo -e "\n${YELLOW}正在卸载 WARP...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    warp-cli disconnect 2>/dev/null
    systemctl disable warp-google 2>/dev/null
    systemctl stop warp-svc 2>/dev/null

    # 清理 iptables 规则
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null

    # 删除 IPv6 黑洞路由
    ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null

    # 清理配置文件和缓存
    rm -f /etc/systemd/system/warp-google.service
    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp
    rm -f "$REDSOCKS_CONF"
    rm -rf "$IP_CACHE_DIR"

    # 恢复 gai.conf
    remove_gai_precedence

    # 卸载软件包
    case $OS in
        ubuntu|debian)
            apt-get remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum remove -y cloudflare-warp redsocks 2>/dev/null || dnf remove -y cloudflare-warp redsocks 2>/dev/null
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac

    systemctl daemon-reload 2>/dev/null

    print_success "WARP 已完全卸载"
    echo ""
}

# ─── 状态查看 ───────────────────────────────────────────────────

do_status() {
    echo -e "\n${CYAN}══════════════ WARP 运行状态 ══════════════${NC}\n"

    echo -e "${YELLOW}【WARP 客户端】${NC}"
    if command -v warp-cli &>/dev/null; then
        warp-cli status 2>/dev/null || echo -e "${RED}未运行${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi

    echo ""
    echo -e "${YELLOW}【透明代理 (Redsocks)】${NC}"
    if pgrep -x redsocks >/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi

    echo ""
    echo -e "${YELLOW}【iptables 规则】${NC}"
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -3 || echo -e "${RED}无规则${NC}"

    echo -e "\n${CYAN}════════════════════════════════════════════${NC}\n"
}

# ─── IP 查看 ────────────────────────────────────────────────────

do_show_ip() {
    echo -e "\n${CYAN}══════════════ IP 信息 ══════════════${NC}\n"

    echo -e "${YELLOW}【直连 IP】${NC}"
    local direct_ip direct_info
    direct_ip=$(curl -4 -s --max-time 5 ip.sb)
    direct_info=$(curl -s --max-time 5 "http://ip-api.com/json/$direct_ip?lang=zh-CN" 2>/dev/null)
    echo -e "IP: ${GREEN}$direct_ip${NC}"
    echo -e "位置: $(echo "$direct_info" | grep -oP '"country":"\K[^"]+') - $(echo "$direct_info" | grep -oP '"city":"\K[^"]+')"

    echo ""
    echo -e "${YELLOW}【WARP IP】${NC}"
    local warp_ip warp_info
    warp_ip=$(curl -x "socks5://127.0.0.1:$WARP_PROXY_PORT" -s --max-time 5 ip.sb 2>/dev/null)
    if [ -n "$warp_ip" ]; then
        warp_info=$(curl -s --max-time 5 "http://ip-api.com/json/$warp_ip?lang=zh-CN" 2>/dev/null)
        echo -e "IP: ${GREEN}$warp_ip${NC}"
        echo -e "位置: $(echo "$warp_info" | grep -oP '"country":"\K[^"]+') - $(echo "$warp_info" | grep -oP '"city":"\K[^"]+')"
    else
        echo -e "${RED}无法获取 (WARP 可能未运行)${NC}"
    fi

    echo -e "\n${CYAN}══════════════════════════════════════${NC}\n"
}

# ─── 测试 Google ────────────────────────────────────────────────

do_test_google() {
    echo -e "\n${CYAN}测试 Google 连接...${NC}"
    local result
    result=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$result" = "200" ]; then
        echo -e "${GREEN}✓ Google 连接成功！状态码: $result${NC}\n"
    else
        echo -e "${RED}✗ Google 连接失败，状态码: $result${NC}\n"
    fi
}

# ─── 启动/停止 ──────────────────────────────────────────────────

do_start() {
    echo -e "\n${CYAN}启动 WARP 服务...${NC}"

    if ! command -v warp-cli &>/dev/null; then
        print_error "WARP 尚未安装，请先选择 1 安装"
        echo ""
        return 1
    fi

    warp-cli connect 2>/dev/null
    /usr/local/bin/warp-google start 2>/dev/null
    print_success "WARP 已启动"
    echo ""
}

do_stop() {
    echo -e "\n${CYAN}停止 WARP 服务...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    warp-cli disconnect 2>/dev/null
    print_success "WARP 已停止"
    echo ""
}

# ─── 菜单 ──────────────────────────────────────────────────────

show_menu() {
    local choice

    while true; do
        show_banner
        echo -e "${GREEN}系统:${NC} $OS $VERSION ${CODENAME:+($CODENAME) }$ARCH"
        print_line
        echo -e "${BOLD}请选择操作${NC}\n"
        echo -e "  ${GREEN}1${NC}) 安装 / 更新      ${DIM}安装 Cloudflare WARP 并配置透明代理${NC}"
        echo -e "  ${GREEN}2${NC}) 查看状态         ${DIM}查看 WARP、Redsocks 和 iptables 状态${NC}"
        echo -e "  ${GREEN}3${NC}) 查看 IP          ${DIM}对比直连 IP 和 WARP IP${NC}"
        echo -e "  ${GREEN}4${NC}) 测试 Google      ${DIM}检查 Google 连接状态${NC}"
        echo -e "  ${GREEN}5${NC}) 启动服务         ${DIM}启动 WARP 透明代理${NC}"
        echo -e "  ${GREEN}6${NC}) 停止服务         ${DIM}停止 WARP 透明代理${NC}"
        echo -e "  ${RED}7${NC}) 卸载             ${DIM}移除 WARP、透明代理和本脚本配置${NC}"
        echo -e "  ${YELLOW}0${NC}) 退出"
        print_line

        read -r -p "请输入选项 [0-7]: " choice

        case "$choice" in
            1) do_install; pause_return ;;
            2) do_status; pause_return ;;
            3) do_show_ip; pause_return ;;
            4) do_test_google; pause_return ;;
            5) do_start; pause_return ;;
            6) do_stop; pause_return ;;
            7)
                if confirm_action "确认卸载 WARP 和透明代理配置吗？"; then
                    do_uninstall
                else
                    print_warning "已取消卸载"
                fi
                pause_return
                ;;
            0|q|Q)
                echo -e "\n${GREEN}再见！${NC}\n"
                exit 0
                ;;
            *)
                print_error "无效选项：$choice"
                pause_return
                ;;
        esac
    done
}

# ─── 主入口 ─────────────────────────────────────────────────────

main() {
    show_banner

    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行！${NC}"; exit 1; }

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        CODENAME=${VERSION_CODENAME:-}
    else
        echo -e "${RED}无法检测系统${NC}"; exit 1
    fi

    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    show_menu
}

main
