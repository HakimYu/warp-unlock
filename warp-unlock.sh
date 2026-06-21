#!/bin/bash

# WARP 一键脚本 - 使用 WireGuard 系统级路由
# 让 Google 等流量自动走 WARP，解锁受限服务
# 特别优化 RackNerd 等纯 IPv4 / 无 TUN 基础环境

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

WARP_IFACE="warp"
WARP_CONF="/etc/wireguard/${WARP_IFACE}.conf"
WGCF_LICENSE="/etc/wgcf-license"
WGCF_PROFILE="/etc/wgcf-profile.conf"
MODE_FILE="/etc/warp-unlock-mode"
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
    echo "║     WireGuard 系统级分流 · 解锁 Google      ║"
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

read_cache_or_fallback() {
    local name="$1" cache_file="$2" fallback="$3"
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
        read_cache_or_fallback "Google" "$cache_file" "$FALLBACK_GOOGLE_IPS"
    fi
}

# ─── 模式相关的 IP 列表 ─────────────────────────────────────────

# YouTube IP 段（Google Video）
YOUTUBE_IPS="
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
104.132.0.0/14
"

# Netflix IP 段
NETFLIX_IPS="
23.246.0.0/18
37.77.184.0/21
45.57.0.0/17
64.120.128.0/17
66.197.128.0/17
108.175.32.0/20
192.173.64.0/18
198.38.96.0/19
198.45.48.0/20
"

# OpenAI IP 段
OPENAI_IPS="
23.98.142.160/27
104.18.0.0/16
172.64.0.0/13
"

# Disney+ IP 段
DISNEY_IPS="
104.64.0.0/10
"

get_mode_ips() {
    local mode="$1"
    case "$mode" in
        1) get_google_ips ;;
        2)
            get_google_ips
            echo "$YOUTUBE_IPS"
            ;;
        3)
            get_google_ips
            echo "$YOUTUBE_IPS"
            echo "$NETFLIX_IPS"
            echo "$OPENAI_IPS"
            echo "$DISNEY_IPS"
            ;;
    esac | grep -v '^[[:space:]]*$' | sort -u
}

# ─── 安装 WireGuard + wgcf ──────────────────────────────────────

install_warp() {
    echo -e "\n${CYAN}[1/4] 安装 WireGuard 工具...${NC}"

    case $OS in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y wireguard-tools curl wget >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y wireguard-tools curl wget >/dev/null 2>&1
            else
                yum install -y wireguard-tools curl wget >/dev/null 2>&1
            fi
            ;;
        *)
            echo -e "${RED}不支持的系统: $OS${NC}"
            echo -e "${YELLOW}支持的系统: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora${NC}"
            exit 1
            ;;
    esac

    if ! command -v wg &>/dev/null; then
        print_error "WireGuard 工具安装失败"
        exit 1
    fi
    print_success "WireGuard 工具已安装"

    echo -e "\n${CYAN}[2/4] 安装 wgcf...${NC}"
    if ! command -v wgcf &>/dev/null; then
        local wgcf_arch
        case "$ARCH" in
            amd64|x86_64) wgcf_arch="amd64" ;;
            arm64|aarch64) wgcf_arch="arm64" ;;
            arm*) wgcf_arch="arm" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
        esac
        local wgcf_url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${wgcf_arch}"
        if ! curl -fsSL -o /usr/local/bin/wgcf "$wgcf_url"; then
            print_error "wgcf 下载失败"
            exit 1
        fi
        chmod +x /usr/local/bin/wgcf
    fi

    if ! command -v wgcf &>/dev/null; then
        print_error "wgcf 安装失败"
        exit 1
    fi
    print_success "wgcf 已安装"
}

# ─── 注册 + 生成 WireGuard 配置 ─────────────────────────────────

configure_warp() {
    echo -e "\n${CYAN}[3/4] 注册 WARP 并生成 WireGuard 配置...${NC}"

    # 注册（已注册则跳过）
    if [ ! -f "$WGCF_LICENSE" ]; then
        echo -e "正在注册 WARP 账号..."
        if ! wgcf register --accept-tos 2>/dev/null; then
            print_error "WARP 注册失败"
            exit 1
        fi
        print_success "WARP 账号已注册"
    else
        echo -e "WARP 账号已注册，跳过..."
    fi

    # 生成配置
    echo -e "正在生成 WireGuard 配置..."
    if ! wgcf generate 2>/dev/null; then
        print_error "WireGuard 配置生成失败"
        exit 1
    fi

    # 修复配置：IPv4-only + Endpoint 强制 IPv4 + Keepalive
    echo -e "正在优化配置（IPv4 优先 + 心跳保活）..."
    local tmp_conf
    tmp_conf=$(mktemp) || { echo -e "${RED}创建临时文件失败${NC}"; exit 1; }
    cp "$WGCF_PROFILE" "$tmp_conf"

    # 1. Address 行：移除 IPv6 地址（可能是前面或后面的逗号分隔项）
    sed -i.bak -E '/^Address/ {
        s/,\s*[0-9a-fA-F:]+\/[0-9]+//g
        s/[0-9a-fA-F:]+\/[0-9]+,\s*//g
    }' "$tmp_conf"

    # 2. DNS 行：移除 IPv6 DNS（2606:4700:4700::1111 等）
    sed -i.bak -E '/^DNS/ {
        s/,\s*[0-9a-fA-F:]+//g
        s/[0-9a-fA-F:]+,\s*//g
    }' "$tmp_conf"

    # 3. AllowedIPs 行：移除 IPv6 段（::/0 等）
    sed -i.bak -E '/^AllowedIPs/ {
        s/,\s*[0-9a-fA-F:]+\/[0-9]+//g
        s/[0-9a-fA-F:]+\/[0-9]+,\s*//g
    }' "$tmp_conf"

    # 4. 强制 Endpoint 使用 IPv4（避免 DNS 解析到 IPv6 导致握手失败）
    sed -i.bak 's/^Endpoint\s*=.*/Endpoint = 162.159.192.1:2408/' "$tmp_conf"

    # 5. 添加 PersistentKeepalive（如果不存在）
    if ! grep -q "PersistentKeepalive" "$tmp_conf"; then
        sed -i.bak '/^\[Peer\]/,/^\[/ {
            /^AllowedIPs/ a\
PersistentKeepalive = 25
        }' "$tmp_conf"
    fi
    rm -f "${tmp_conf}.bak"

    write_managed_file "$WARP_CONF" 0600 < "$tmp_conf"
    rm -f "$tmp_conf"

    print_success "WireGuard 配置已生成"
}

# ─── 选择分流模式 ───────────────────────────────────────────────

select_mode() {
    echo -e "\n${CYAN}[4/4] 选择分流模式${NC}\n"
    echo -e "  ${GREEN}1${NC}) 仅代理 Google 搜索/Gemini/商店  ${DIM}(推荐，YouTube 直连无广告)${NC}"
    echo -e "  ${GREEN}2${NC}) 代理 Google 全家桶（含 YouTube）${DIM}(适合 IP 彻底被送中)${NC}"
    echo -e "  ${GREEN}3${NC}) Google + Netflix + OpenAI 等     ${DIM}(解锁全部流媒体)${NC}"
    print_line

    local choice
    read -r -p "请选择模式 [1-3]: " choice
    case "$choice" in
        1|2|3) echo "$choice" > "$MODE_FILE" ;;
        *)
            print_warning "无效选择，默认使用模式 1"
            echo "1" > "$MODE_FILE"
            ;;
    esac
}

# ─── 系统级路由脚本 ─────────────────────────────────────────────

setup_routing_script() {
    write_managed_file /usr/local/bin/warp-google 0755 << 'SCRIPT'
#!/bin/bash

WARP_IFACE="warp"
WARP_CONF="/etc/wireguard/${WARP_IFACE}.conf"
MODE_FILE="/etc/warp-unlock-mode"
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

YOUTUBE_IPS="
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
104.132.0.0/14
"

NETFLIX_IPS="
23.246.0.0/18
37.77.184.0/21
45.57.0.0/17
64.120.128.0/17
66.197.128.0/17
108.175.32.0/20
192.173.64.0/18
198.38.96.0/19
198.45.48.0/20
"

OPENAI_IPS="
23.98.142.160/27
104.18.0.0/16
172.64.0.0/13
"

DISNEY_IPS="
104.64.0.0/10
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
    local name="$1" cache_file="$2" fallback="$3"
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
        read_cache_or_fallback "Google" "$cache_file" "$FALLBACK_GOOGLE_IPS"
    fi
}

get_mode_ips() {
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "1")
    case "$mode" in
        1) get_google_ips ;;
        2) get_google_ips; echo "$YOUTUBE_IPS" ;;
        3) get_google_ips; echo "$YOUTUBE_IPS"; echo "$NETFLIX_IPS"; echo "$OPENAI_IPS"; echo "$DISNEY_IPS" ;;
    esac | grep -v '^[[:space:]]*$' | sort -u
}

get_mode_name() {
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "1")
    case "$mode" in
        1) echo "仅 Google (不含 YouTube)" ;;
        2) echo "Google 全家桶 (含 YouTube)" ;;
        3) echo "Google + Netflix + OpenAI" ;;
    esac
}

start() {
    if [ ! -f "$WARP_CONF" ]; then
        echo "错误：WireGuard 配置不存在，请先运行安装"
        exit 1
    fi

    echo "启动 WARP WireGuard 隧道..."
    if ! wg-quick up "$WARP_IFACE" 2>/dev/null; then
        # 可能已连接，先 down 再 up
        wg-quick down "$WARP_IFACE" 2>/dev/null
        wg-quick up "$WARP_IFACE" || { echo "WireGuard 启动失败"; exit 1; }
    fi

    echo "添加路由规则（模式: $(get_mode_name)）..."
    local count=0
    for ip in $(get_mode_ips); do
        ip route add "$ip" dev "$WARP_IFACE" 2>/dev/null && count=$((count + 1))
    done
    echo "已添加 $count 条路由规则"
    echo "WARP 系统级分流已启动"
}

stop() {
    echo "停止 WARP 系统级分流..."
    # 删除通过脚本添加的路由
    if [ -f "$WARP_CONF" ]; then
        for ip in $(get_mode_ips); do
            ip route del "$ip" dev "$WARP_IFACE" 2>/dev/null
        done
    fi
    wg-quick down "$WARP_IFACE" 2>/dev/null
    echo "WARP 已停止"
}

status() {
    echo "=== WireGuard 状态 ==="
    if ip link show "$WARP_IFACE" &>/dev/null; then
        echo "接口: 运行中"
        wg show "$WARP_IFACE" 2>/dev/null | head -5
    else
        echo "接口: 未运行"
    fi
    echo ""
    echo "=== 分流模式 ==="
    get_mode_name
    echo ""
    echo "=== 路由规则 ==="
    local count
    count=$(ip route show dev "$WARP_IFACE" 2>/dev/null | wc -l)
    echo "共 $count 条路由规则"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    *) echo "用法: $0 {start|stop|restart|status}" ;;
esac
SCRIPT
}

# ─── 启动分流 ───────────────────────────────────────────────────

start_warp() {
    /usr/local/bin/warp-google start
}

# ─── systemd 服务 ───────────────────────────────────────────────

setup_systemd() {
    write_managed_file /etc/systemd/system/warp-google.service 0644 << 'EOF'
# Managed by warp-unlock
[Unit]
Description=WARP WireGuard System-Level Routing
After=network.target

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
}

# ─── 管理脚本 ───────────────────────────────────────────────────

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
        echo "=== WireGuard 状态 ==="
        ip link show warp &>/dev/null && { echo "接口: 运行中"; wg show warp 2>/dev/null | head -5; } || echo "接口: 未运行"
        echo ""
        /usr/local/bin/warp-google status 2>/dev/null
        ;;
    start)
        /usr/local/bin/warp-google start
        ;;
    stop)
        /usr/local/bin/warp-google stop
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
        warp_ip=$(curl --interface warp -4 -s --max-time 5 ip.sb 2>/dev/null)
        echo "${warp_ip:-无法获取}"
        echo ""
        ;;
    uninstall)
        echo "正在卸载..."
        /usr/local/bin/warp-google stop 2>/dev/null
        wg-quick down warp 2>/dev/null
        systemctl disable warp-google 2>/dev/null
        systemctl stop warp-google 2>/dev/null
        ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null
        remove_gai_precedence
        rm -f /etc/systemd/system/warp-google.service
        rm -f /usr/local/bin/warp-google
        rm -f /etc/wireguard/warp.conf
        rm -f /etc/wgcf-license
        rm -f /etc/wgcf-profile.conf
        rm -f /etc/warp-unlock-mode
        rm -rf /var/cache/warp-unlock
        systemctl daemon-reload 2>/dev/null
        rm -f /usr/local/bin/warp
        echo "WARP 已卸载"
        ;;
    *)
        echo "warp-unlock 管理工具"
        echo ""
        echo "用法: warp <命令>"
        echo ""
        echo "常用命令:"
        echo "  status     查看 WireGuard 状态和路由"
        echo "  ip         对比直连 IP 和 WARP IP"
        echo "  test       测试 Google 连接"
        echo ""
        echo "服务控制:"
        echo "  start      启动 WARP 系统级分流"
        echo "  stop       停止 WARP 系统级分流"
        echo "  restart    重启服务"
        echo ""
        echo "维护:"
        echo "  uninstall  卸载 WARP 和本脚本配置"
        ;;
esac
EOF
}

# ─── 测试连接 ───────────────────────────────────────────────────

test_connection() {
    echo -e "\n${CYAN}测试连接...${NC}"
    sleep 2

    GOOGLE_TEST=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "$GOOGLE_TEST" = "200" ]; then
        print_success "Google 连接成功"
    else
        echo -e "${YELLOW}Google 测试返回: $GOOGLE_TEST${NC}"
    fi

    local warp_ip
    warp_ip=$(curl --interface warp -4 -s --max-time 10 ip.sb 2>/dev/null)
    if [ -n "$warp_ip" ]; then
        local warp_info
        warp_info=$(curl -s --max-time 5 "http://ip-api.com/json/$warp_ip?lang=zh-CN" 2>/dev/null)
        echo -e "\nWARP IP: ${GREEN}$warp_ip${NC}"
        echo -e "WARP 位置: ${GREEN}$(echo "$warp_info" | grep -oP '"country":"\K[^"]+') - $(echo "$warp_info" | grep -oP '"city":"\K[^"]+')${NC}"
    fi
}

# ─── 安装主流程 ─────────────────────────────────────────────────

do_install() {
    install_warp
    configure_warp
    select_mode
    setup_routing_script
    start_warp
    setup_systemd
    create_management
    test_connection

    local mode_name
    mode_name=$(cat "$MODE_FILE" 2>/dev/null || echo "1")
    case "$mode_name" in
        1) mode_name="仅 Google (不含 YouTube)" ;;
        2) mode_name="Google 全家桶 (含 YouTube)" ;;
        3) mode_name="Google + Netflix + OpenAI" ;;
    esac

    echo -e "\n${GREEN}${BOLD}安装完成，WARP 系统级分流已启用${NC}"
    print_line
    echo -e "${YELLOW}模式:${NC} $mode_name"
    echo -e "${YELLOW}原理:${NC} 内核路由表直接分流，所有代理软件自动生效"
    echo -e "${YELLOW}管理:${NC} ${CYAN}warp {status|ip|test|start|stop|restart|uninstall}${NC}\n"
}

# ─── 卸载 ───────────────────────────────────────────────────────

do_uninstall() {
    echo -e "\n${YELLOW}正在卸载 WARP...${NC}"
    /usr/local/bin/warp-google stop 2>/dev/null
    wg-quick down "$WARP_IFACE" 2>/dev/null
    systemctl disable warp-google 2>/dev/null
    systemctl stop warp-google 2>/dev/null
    rm -f /etc/systemd/system/warp-google.service
    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp
    rm -f "$WARP_CONF"
    rm -f "$WGCF_LICENSE"
    rm -f "$WGCF_PROFILE"
    rm -f "$MODE_FILE"
    rm -rf "$IP_CACHE_DIR"

    # 清理 IPv6 路由和 IPv4 优先规则
    ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null
    remove_gai_precedence

    # 卸载 wgcf
    rm -f /usr/local/bin/wgcf

    systemctl daemon-reload 2>/dev/null

    print_success "WARP 已完全卸载"
    echo ""
}

# ─── 状态查看 ───────────────────────────────────────────────────

do_status() {
    echo -e "\n${CYAN}══════════════ WARP 运行状态 ══════════════${NC}\n"

    echo -e "${YELLOW}【WireGuard 接口】${NC}"
    if ip link show "$WARP_IFACE" &>/dev/null; then
        echo -e "${GREEN}运行中${NC}"
        wg show "$WARP_IFACE" 2>/dev/null | head -5
    else
        echo -e "${RED}未运行${NC}"
    fi

    echo ""
    echo -e "${YELLOW}【分流模式】${NC}"
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "未配置")
    case "$mode" in
        1) echo "模式 1: 仅 Google (不含 YouTube)" ;;
        2) echo "模式 2: Google 全家桶 (含 YouTube)" ;;
        3) echo "模式 3: Google + Netflix + OpenAI" ;;
        *) echo "$mode" ;;
    esac

    echo ""
    echo -e "${YELLOW}【路由规则】${NC}"
    local count
    count=$(ip route show dev "$WARP_IFACE" 2>/dev/null | wc -l)
    echo -e "共 ${GREEN}$count${NC} 条路由规则"

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
    warp_ip=$(curl --interface warp -4 -s --max-time 5 ip.sb 2>/dev/null)
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
    echo -e "\n${CYAN}启动 WARP 系统级分流...${NC}"

    if [ ! -f "$WARP_CONF" ] || [ ! -x /usr/local/bin/warp-google ]; then
        print_error "WARP 尚未安装，请先选择 1 安装 / 更新"
        echo ""
        return 1
    fi

    /usr/local/bin/warp-google start || return 1
    print_success "WARP 已启动"
    echo ""
}

do_stop() {
    echo -e "\n${CYAN}停止 WARP 系统级分流...${NC}"

    if [ ! -x /usr/local/bin/warp-google ]; then
        print_error "WARP 尚未安装"
        echo ""
        return 1
    fi

    /usr/local/bin/warp-google stop
    print_success "WARP 已停止"
    echo ""
}

# ─── 菜单 ──────────────────────────────────────────────────────

show_menu() {
    local choice

    while true; do
        show_banner
        echo -e "${GREEN}系统:${NC} $OS $VERSION ${CODENAME:+($CODENAME) }$ARCH"
        echo -e "${DIM}模式: WireGuard 系统级路由，所有代理软件自动分流${NC}"
        print_line
        echo -e "${BOLD}请选择操作${NC}\n"
        echo -e "  ${GREEN}1${NC}) 安装 / 更新      ${DIM}安装 WireGuard + wgcf，配置系统级分流${NC}"
        echo -e "  ${GREEN}2${NC}) 查看状态         ${DIM}查看 WireGuard 状态和路由规则${NC}"
        echo -e "  ${GREEN}3${NC}) 查看 IP          ${DIM}对比直连 IP 和 WARP IP${NC}"
        echo -e "  ${GREEN}4${NC}) 测试 Google      ${DIM}检查 Google 连接状态${NC}"
        echo -e "  ${GREEN}5${NC}) 启动服务         ${DIM}启动 WARP 系统级分流${NC}"
        echo -e "  ${GREEN}6${NC}) 停止服务         ${DIM}停止 WARP 系统级分流${NC}"
        echo -e "  ${RED}7${NC}) 卸载             ${DIM}移除 WARP、路由和本脚本配置${NC}"
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
                if confirm_action "确认卸载 WARP 和本脚本配置吗？"; then
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
