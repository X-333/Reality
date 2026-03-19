#!/bin/bash

# =============================================================
#  SECTION 0: 公共工具函数库 (Utils)
# =============================================================

# -- 终端颜色定义 --
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"

INFO="${CYAN}[INFO]${PLAIN}"
WARN="${YELLOW}[WARN]${PLAIN}"
ERR="${RED}[ERR] ${PLAIN}"
OK="${GREEN}[OK]  ${PLAIN}"

# 订阅服务端口，集中定义供全局引用
SUB_PORT_HTTPS=48080

# 暂存脚本入参，用于 preflight_guard 提权时透传
_SCRIPT_ARGS=("$@")

# 临时文件注册表，EXIT/INT/TERM 时统一清理
_TEMP_FILES=()
trap 'rm -f "${_TEMP_FILES[@]}" 2>/dev/null' EXIT INT TERM

# -- 统一任务执行封装 --
execute_task() {
    local cmd="$1"
    local desc="$2"
    local on_fail="${3:-error}"
    local err_log spinner_pid
    err_log=$(mktemp)
    _TEMP_FILES+=("$err_log")

    tput civis >/dev/tty
    (
        trap 'exit 0' TERM
        local elapsed=0
        while true; do
            printf "\r${INFO} ${YELLOW}${desc}... %ds${PLAIN}" "$elapsed" >/dev/tty
            sleep 1
            ((elapsed++))
        done
    ) &
    local spinner_pid=$!

    bash -c "$cmd" >/dev/null 2>"$err_log"
    local exit_code=$?

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    tput cnorm >/dev/tty

    if [ $exit_code -eq 0 ]; then
        printf "\r\033[K${OK} ${desc}\n" >/dev/tty
        return 0
    else
        _LAST_ERR_LOG="$err_log"
        if [ "$on_fail" = "warn" ]; then
            printf "\r\033[K${WARN} ${desc} [跳过]\n" >/dev/tty
        else
            printf "\r\033[K${ERR} ${desc} [FAILED]\n" >/dev/tty
            echo -e "${RED}--- 错误详情 ---${PLAIN}"
            cat "$err_log"
            echo -e "${RED}---------------${PLAIN}"
        fi
        return 1
    fi
}

# -- 前置条件校验（权限 / 系统 / 架构）--
preflight_guard() {
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &>/dev/null; then
            echo -e "${YELLOW}检测到非 root 环境，尝试通过 sudo 提权...${PLAIN}"
            exec sudo bash -- "$0" "${_SCRIPT_ARGS[@]}"
        else
            echo -e "${RED}Error: 请使用 root 或 sudo 运行！${PLAIN}"
            exit 1
        fi
    fi

    if [ ! -f /etc/debian_version ]; then
        SYS_WARN="非 Debian/Ubuntu 系统，推荐使用 Debian 12 或 Ubuntu 22.04 及以上版本"
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       ARCH_WARN="不支持的 CPU 架构: ${ARCH}，可能无法正常运行" ;;
    esac
}

# -- 安装前用户确认 --
confirm_installation() {
    echo ""
    echo -e "${INFO} ${RED}安装说明${PLAIN}"

    if [ -n "$SYS_WARN" ]; then
        echo -e "       ${CYAN}系统检测${PLAIN}: ${YELLOW}${SYS_WARN}${PLAIN} ${WARN}"
    elif [ -n "$ARCH_WARN" ]; then
        echo -e "       ${CYAN}系统检测${PLAIN}: Debian/Ubuntu (${ARCH}) ${YELLOW}${ARCH_WARN}${PLAIN} ${WARN}"
    else
        echo -e "       ${CYAN}系统检测${PLAIN}: Debian/Ubuntu (${ARCH}) ${OK}"
    fi

    echo -e "       ${CYAN}安装内容${PLAIN}: Xray 核心服务、防火墙规则、订阅服务、系统优化参数"
    echo -e "       ${CYAN}网络要求${PLAIN}: 服务器需能访问 GitHub（用于拉取 Xray 安装脚本）"
    echo -e "       ${CYAN}预计耗时${PLAIN}: 3 ~ 5 分钟（取决于网络环境）"
    echo -e "       ${CYAN}注意事项${PLAIN}: 重复安装将覆盖现有 Xray 配置文件，请提前备份"
    echo ""

    local key error_msg="" first=1
    while true; do
        if [ -n "$error_msg" ]; then
            printf "\033[1A\r\033[K${RED}%s${PLAIN} 确认继续安装? [y/N]: " "$error_msg"
        elif [ "$first" -eq 0 ]; then
            printf "\033[1A\r\033[K确认继续安装? [y/N]: "
        else
            printf "确认继续安装? [y/N]: "
        fi
        first=0; read -r key
        case "$key" in
            y|Y)
                printf "\033[1A\r\033[K${OK} 执行安装确认\n"
                return ;;
            n|N)
                printf "\033[1A\r\033[K${WARN} 执行安装取消\n"
                exit 1 ;;
            *)
                error_msg="请输入 y 或 n！" ;;
        esac
    done
}

# -- 交互式安装配置（SNI / 端口）--
prompt_install_config() {
    local default_vision=443
    local default_xhttp=8443

    _port_status() {
        local port=$1
        if lsof -i:"$port" -P -n -sTCP:LISTEN >/dev/null 2>&1; then
            local proc
            proc=$(lsof -i:"$port" -P -n -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | head -n1)
            if [[ "$proc" == "xray" ]]; then
                echo -e "${GREEN}[Xray占用]${PLAIN}"
            else
                echo -e "${RED}[占用]${PLAIN}"
            fi
        else
            echo -e "${GREEN}[空闲]${PLAIN}"
        fi
    }

    _is_xray_port() {
        local port=$1
        if lsof -i:"$port" -P -n -sTCP:LISTEN >/dev/null 2>&1; then
            local proc
            proc=$(lsof -i:"$port" -P -n -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | head -n1)
            [[ "$proc" == "xray" ]] && return 0
        fi
        return 1
    }

    _input_sni() {
        local error_msg="" first=1
        while true; do
            if [ -n "$error_msg" ]; then
                printf "\033[1A\r\033[K${RED}%s${PLAIN} 请输入 SNI 域名[默认 www.mellotextile.com ]: " "$error_msg"
            elif [ "$first" -eq 0 ]; then
                printf "\033[1A\r\033[K请输入 SNI 域名[默认 www.mellotextile.com ]: "
            else
                printf "请输入 SNI 域名[默认 www.mellotextile.com ]: "
            fi
            first=0; read -r input
            if [ -z "$input" ]; then
                SNI_HOST="www.mellotextile.com"
                printf "\033[1A\r\033[K${OK} %-7s 域名: ${GREEN}%s${PLAIN}\n" "SNI" "$SNI_HOST"
                return
            fi
            if [[ "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
                SNI_HOST="$input"
                printf "\033[1A\r\033[K${OK} %-7s 域名: ${GREEN}%s${PLAIN}\n" "SNI" "$SNI_HOST"
                return
            else
                error_msg="域名格式无效!"
            fi
        done
    }

    _input_port() {
        local name="$1" default="$2" exclude="${3:-}" error_msg="" first=1
        while true; do
            local status; status=$(_port_status "$default")
            if [ -n "$error_msg" ]; then
                printf "\033[1A\r\033[K${RED}%s${PLAIN} 请输入 %s 端口[默认 %s %b]: " \
                    "$error_msg" "$name" "$default" "$status"
            elif [ "$first" -eq 0 ]; then
                printf "\033[1A\r\033[K请输入 %s 端口[默认 %s %b]: " "$name" "$default" "$status"
            else
                printf "请输入 %s 端口[默认 %s %b]: " "$name" "$default" "$status"
            fi
            first=0; read -r input

            if [ -z "$input" ]; then
                if lsof -i:"$default" -P -n -sTCP:LISTEN >/dev/null 2>&1 && ! _is_xray_port "$default"; then
                    error_msg="端口 ${default} 已被其他服务占用！"
                    continue
                fi
                if [ -n "$exclude" ] && [ "$default" == "$exclude" ]; then
                    error_msg="与 Vision 端口 (${exclude}) 冲突！"
                    continue
                fi
                REPLY_PORT="$default"
                printf "\033[1A\r\033[K${OK} %-7s 端口: ${GREEN}%s${PLAIN}\n" "$name" "$REPLY_PORT"
                return
            fi

            if [[ ! "$input" =~ ^[0-9]+$ ]]; then
                error_msg="请重新输入 [1-65535]"; continue
            fi
            input=$((10#$input))
            if [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
                error_msg="请重新输入 [1-65535]"; continue
            fi
            if lsof -i:"$input" -P -n -sTCP:LISTEN >/dev/null 2>&1 && ! _is_xray_port "$input"; then
                error_msg="端口 ${input} 已被其他服务占用！"
                continue
            fi
            if [ -n "$exclude" ] && [ "$input" == "$exclude" ]; then
                error_msg="与 Vision 端口 (${exclude}) 冲突！"; continue
            fi

            REPLY_PORT="$input"
            printf "\033[1A\r\033[K${OK} %-7s 端口: ${GREEN}%s${PLAIN}\n" "$name" "$REPLY_PORT"
            return
        done
    }

    # -- 订阅服务域名询问（可选；跳过则回退至 IP + 自签证书方案）--
    # Certbot 使用 HTTP-01 验证，仅需 80 端口，与 Vision(443) 无冲突
    _input_sub_domain() {
        local key error_msg="" first=1

        while true; do
            if [ -n "$error_msg" ]; then
                printf "\033[1A\r\033[K${RED}%s${PLAIN} 是否为订阅服务绑定自定义域名? [y/N]: " "$error_msg"
            elif [ "$first" -eq 0 ]; then
                printf "\033[1A\r\033[K是否为订阅服务绑定自定义域名? [y/N]: "
            else
                printf "是否为订阅服务绑定自定义域名? [y/N]: "
            fi
            first=0; read -r key
            case "$key" in
                y|Y) break ;;
                n|N|"")
                    SUB_DOMAIN=""
                    printf "\033[1A\r\033[K${OK} %-7s 域名: 无 (IP + 自签证书方案)\n" "sub"
                    return ;;
                *) error_msg="请输入 y 或 n！" ;;
            esac
        done
        # 清除 [y/N] 提示行，等待域名输入完成后统一输出最终结果
        printf "\033[1A\r\033[K"

        local domain_error="" domain_first=1
        while true; do
            if [ -n "$domain_error" ]; then
                printf "\033[1A\r\033[K${RED}%s${PLAIN} 请输入订阅服务域名 (例: sub.example.com): " "$domain_error"
            elif [ "$domain_first" -eq 0 ]; then
                printf "\033[1A\r\033[K请输入订阅服务域名 (例: sub.example.com): "
            else
                printf "请输入订阅服务域名 (例: sub.example.com): "
            fi
            domain_first=0; read -r input

            if [ -z "$input" ]; then
                domain_error="域名不能为空！"; continue
            fi
            if [[ ! "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
                domain_error="域名格式无效！"; continue
            fi

            printf "\033[1A\r\033[K${INFO} 检查域名 DNS 解析..." >/dev/tty
            local resolved
            resolved=$(getent hosts "$input" 2>/dev/null | awk '{print $1}' | head -n1)
            if [ -z "$resolved" ]; then
                printf "\r\033[K${WARN} 域名 %s 当前无法解析，请确认 DNS A/AAAA 记录已指向本机 IP\n" \
                    "$input" >/dev/tty
                printf "       ${GRAY}DNS 未生效将导致 Certbot 证书申请失败。确认继续? [y/N]: ${PLAIN}"
                read -r confirm
                case "$confirm" in
                    y|Y)
                        SUB_DOMAIN="$input"
                        printf "\033[1A\r\033[K${OK} %-7s 域名: ${GREEN}%s${PLAIN} (Let's Encrypt / DNS 待生效)\n" \
                            "sub" "$SUB_DOMAIN"
                        return ;;
                    *) domain_error="请重新输入域名"; continue ;;
                esac
            else
                SUB_DOMAIN="$input"
                printf "\r\033[K${OK} %-7s 域名: ${GREEN}%s${PLAIN} → %s (Let's Encrypt)\n" \
                    "sub" "$SUB_DOMAIN" "$resolved" >/dev/tty
                return
            fi
        done
    }

    echo -e "\n${CYAN}>>> 0. 安装前配置${PLAIN}"

    _input_sni

    _input_port "Vision" "$default_vision"
    PORT_VISION="$REPLY_PORT"

    _input_port "XHTTP" "$default_xhttp" "$PORT_VISION"
    PORT_XHTTP="$REPLY_PORT"

    _input_sub_domain
}


# =============================================================
#  SECTION 1: 环境准备与检测 (Environment)
# =============================================================

# 基础网络工具安装
preflight_check() {
    if ! command -v curl >/dev/null 2>&1 || ! dpkg -s ca-certificates >/dev/null 2>&1; then
        execute_task \
            "apt-get -o DPkg::Lock::Timeout=120 update -qq && \
             apt-get -o DPkg::Lock::Timeout=120 install -y -qq curl wget ca-certificates" \
            "安装基础网络工具 (curl, ca-certificates)" || exit 1
    fi

    printf "${INFO} 环境预检..." >/dev/tty
    printf "\r\033[K${OK} 环境预检完成\n" >/dev/tty
}

# -- 检测 IPv4 / IPv6 网络连通性 --
check_net_stack() {
    HAS_V4=false; HAS_V6=false
    if curl -s4 -m 3 https://cloudflare.com >/dev/null 2>&1; then HAS_V4=true; fi
    if curl -s6 -m 3 https://cloudflare.com >/dev/null 2>&1; then HAS_V6=true; fi
}

# -- 基础环境初始化（时间同步）--
setup_base_env() {
    if ! command -v chronyc >/dev/null 2>&1; then
        execute_task "apt-get -o DPkg::Lock::Timeout=120 install -y chrony" \
        "安装时间同步组件: chrony" "warn" || return 1
    fi

    execute_task \
        "systemctl enable chrony >/dev/null 2>&1 \
         && systemctl restart chrony >/dev/null 2>&1 \
         && chronyc makestep >/dev/null 2>&1" \
        "启用时间同步: chrony — $(date '+%Y-%m-%d %H:%M:%S')" "warn"

    local current_tz
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    printf "${INFO} 当前时区确认..." >/dev/tty
    printf "\r\033[K${OK} 当前时区确认: %s\n" "${current_tz:-UTC (Default)}" >/dev/tty
}


# =============================================================
#  SECTION 2: 核心组件安装 (Core Install)
# =============================================================

# -- Xray 核心安装（通过官方安装脚本）--
install_xray_robust() {
    local bin_path="/usr/local/bin/xray"
    local err_log spinner_pid
    err_log=$(mktemp)
    _TEMP_FILES+=("$err_log")

    tput civis >/dev/tty
    (
        trap 'exit 0' TERM
        local elapsed=0
        while true; do
            printf "\r${INFO} ${YELLOW}安装 Xray Core... %ds${PLAIN}" "$elapsed" >/dev/tty
            sleep 1
            ((elapsed++))
        done
    ) &
    spinner_pid=$!

    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ install >/dev/null 2>"$err_log"
    local exit_code=$?

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    tput cnorm >/dev/tty

    if [ ! -x "$bin_path" ] || [ $exit_code -ne 0 ]; then
        printf "\r\033[K${ERR} Xray 安装失败，请检查网络或手动安装\n" >/dev/tty
        cat "$err_log"
        return 1
    fi

    local ver
    ver=$("$bin_path" version 2>/dev/null | head -n 1 | awk '{print $2}')
    printf "\r\033[K${OK} 安装 Xray Core: v%s\n" "${ver:-未知版本}" >/dev/tty
}

# -- 核心组件安装入口 --
core_install() {
    echo -e "\n${CYAN}>>> 2. 核心组件 (Core)${PLAIN}"

    export DEBIAN_FRONTEND=noninteractive

    local os_name kernel_ver
    os_name=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
    kernel_ver=$(uname -r)

    execute_task \
        "apt-get -o DPkg::Lock::Timeout=120 update -qq && \
         apt-get -o DPkg::Lock::Timeout=120 -y \
         -o Dpkg::Options::='--force-confdef' \
         -o Dpkg::Options::='--force-confold' upgrade" \
        "检查系统更新: ${os_name} / 内核 ${kernel_ver}" "warn"

    local DEPENDENCIES=(tar unzip fail2ban iptables iptables-persistent qrencode jq python3 python3-systemd lsof)

    local pkg_log
    pkg_log=$(mktemp)
    _TEMP_FILES+=("$pkg_log")

    for pkg in "${DEPENDENCIES[@]}"; do
        printf "${INFO} 安装依赖组件: %s..." "$pkg" >/dev/tty
        apt-get -o DPkg::Lock::Timeout=120 install -y \
            -o Dpkg::Options::='--force-confdef' \
            -o Dpkg::Options::='--force-confold' \
            "$pkg" >/dev/null 2>"$pkg_log"
        local pkg_exit=$?

        if [ $pkg_exit -eq 0 ]; then
            printf "\r\033[K${OK} 安装依赖组件: %s\n" "$pkg" >/dev/tty
        else
            printf "\r\033[K${ERR} 安装依赖组件: %s [FAILED]\n" "$pkg" >/dev/tty
            echo -e "${RED}--- 错误详情 ---${PLAIN}"
            cat "$pkg_log"
            echo -e "${RED}---------------${PLAIN}"
            echo -e "${WARN} 依赖组件 '$pkg' 安装失败，建议重新执行安装脚本。"
            exit 1
        fi
    done

    printf "${OK} ${GREEN}系统依赖安装完成${PLAIN}\n" >/dev/tty

    install_xray_robust || exit 1
}


# =============================================================
#  SECTION 3: 安全与防火墙配置 (Security)
# =============================================================

# 依赖外部变量：HAS_V4、HAS_V6（由 check_net_stack 提供）

# -- 添加单条 iptables 放行规则（IPv4 / IPv6）--
_add_fw_rule() {
    local port=$1 v4=$2 v6=$3
    local failed=false

    if ! command -v iptables >/dev/null 2>&1; then
        printf "${WARN} 未检测到 iptables，跳过端口 %s 的防火墙规则配置。\n" "$port" >/dev/tty
        return 1
    fi
    if [ "$v4" = true ]; then
        iptables  -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || { iptables  -A INPUT -p tcp --dport "$port" -j ACCEPT || failed=true; }
        iptables  -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
            || { iptables  -A INPUT -p udp --dport "$port" -j ACCEPT || failed=true; }
    fi
    if [ "$v6" = true ] && [ -f /proc/net/if_inet6 ]; then
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || { ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT || failed=true; }
        ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
            || { ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT || failed=true; }
    fi

    if [ "$failed" = true ]; then
        printf "${WARN} 端口 %s 部分防火墙规则写入失败，请手动检查 iptables 状态\n" "$port" >/dev/tty
        return 1
    fi
}

# -- Swap 创建（按内存大小自动计算，上限 2048MB）--
_setup_swap() {
    local SWAP_FILE="/swapfile"
    local SWAP_MB DISK_AVAIL_MB MEM_KB

    MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    SWAP_MB=$(( MEM_KB / 1024 / 2 ))
    SWAP_MB=$(( SWAP_MB < 1024 ? 1024 : (SWAP_MB > 2048 ? 2048 : SWAP_MB) ))

    if swapon --show | grep -q .; then
        local existing
        existing=$(swapon --show --noheadings --bytes | awk '{sum += $3} END {printf "%.0f", sum/1024/1024}')
        printf "${OK} 检测到已有 Swap (%sMB)，跳过创建\n" "$existing" >/dev/tty
        return 0
    fi

    DISK_AVAIL_MB=$(df --output=avail -m / | tail -n 1 | tr -d ' ')
    if [ "$DISK_AVAIL_MB" -lt $(( SWAP_MB + 1024 )) ]; then
        printf "${WARN} 磁盘可用空间 (%sMB) 不足，跳过创建\n" "$DISK_AVAIL_MB" >/dev/tty
        return 0
    fi

    local swap_err_log
    swap_err_log=$(mktemp)
    _TEMP_FILES+=("$swap_err_log")

    printf "${INFO} 创建并挂载 Swap (%s, %sMB)..." "$SWAP_FILE" "$SWAP_MB" >/dev/tty
    {
        fallocate -l "${SWAP_MB}M" "$SWAP_FILE" 2>/dev/null \
            || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=none
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null 2>&1
        swapon "$SWAP_FILE"
        grep -q "$SWAP_FILE" /etc/fstab \
            || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    } 2>"$swap_err_log"

    if [ $? -ne 0 ]; then
        printf "\r\033[K${ERR} 创建并挂载 Swap [FAILED]\n" >/dev/tty
        cat "$swap_err_log"; exit 1
    fi
    printf "\r\033[K${OK} 创建并挂载 Swap (%s, %sMB)\n" "$SWAP_FILE" "$SWAP_MB" >/dev/tty
}

# -- 防火墙、Fail2ban、Swap 及内核参数配置入口 --
setup_firewall_and_security() {
    echo -e "\n${CYAN}>>> 3. 端口与安全 (Security)${PLAIN}"

    # 确保默认链策略为 ACCEPT
    iptables  -P INPUT ACCEPT; iptables  -P FORWARD ACCEPT; iptables  -P OUTPUT ACCEPT
    if [ -f /proc/net/if_inet6 ]; then
        ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
    fi
    printf "${OK} 防火墙默认链策略 ACCEPT\n" >/dev/tty

    # Fail2ban 配置（递增封禁策略）
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime           = 86400
findtime          = 86400
maxretry          = 3
bantime.increment = true
bantime.factor    = 1
bantime.maxtime   = 2592000
allowipv6         = auto
ignoreip          = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ssh
mode    = normal
backend = systemd
EOF

    execute_task \
        "systemctl unmask fail2ban >/dev/null 2>&1
         systemctl enable fail2ban >/dev/null 2>&1
         systemctl restart fail2ban" \
        "配置并启动 Fail2ban" || exit 1

    printf "${INFO} 验证 Fail2ban 启动状态..." >/dev/tty
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        printf "\r\033[K${OK} 验证 Fail2ban 启动状态\n" >/dev/tty
    else
        printf "\r\033[K${WARN} Fail2ban 未正常启动，请检查 python3-systemd 是否安装成功\n" >/dev/tty
    fi

    # 防火墙规则写入与持久化
    _add_fw_rule "$PORT_VISION"    "$HAS_V4" "$HAS_V6"
    _add_fw_rule "$PORT_XHTTP"     "$HAS_V4" "$HAS_V6"
    _add_fw_rule "$SUB_PORT_HTTPS" "$HAS_V4" "$HAS_V6"

    execute_task "netfilter-persistent save" "持久化防火墙规则" || exit 1

    _setup_swap

    # 清除其他配置文件中可能存在的 swappiness 覆盖值
    sed -i '/vm.swappiness/d' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null

    cat > /etc/sysctl.d/99-xray-optimize.conf <<EOF
# Swap 亲和度
vm.swappiness = 10

# IP 转发
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF

    execute_task "sysctl --system" "写入并应用内核参数" || exit 1
}


# =============================================================
#  SECTION 4: 生成 Xray 配置文件 (Config)
# =============================================================

core_config() {
    echo -e "\n${CYAN}>>> 4. 生成 Xray 配置文件 (Config)${PLAIN}"

    local err_log
    err_log=$(mktemp)
    _TEMP_FILES+=("$err_log")

    # UUID 生成
    printf "${INFO} 生成 UUID..." >/dev/tty
    UUID=$(/usr/local/bin/xray uuid 2>"$err_log" | tr -d ' \r\n')
    if [ -z "$UUID" ]; then
        printf "\r\033[K${ERR} 生成 UUID [FAILED]\n" >/dev/tty
        cat "$err_log"; exit 1
    fi
    printf "\r\033[K${OK} 生成 UUID\n" >/dev/tty

    # x25519 密钥对生成
    printf "${INFO} 生成 x25519 密钥对..." >/dev/tty
    local keys_raw
    keys_raw=$(/usr/local/bin/xray x25519 2>"$err_log")
    PRIVATE_KEY=$(echo "$keys_raw" | grep -iE "^PrivateKey:"           | head -n 1 | awk -F':' '{print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo  "$keys_raw" | grep -iE "^(PublicKey|Password):" | head -n 1 | awk -F':' '{print $2}' | tr -d ' \r\n')
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        printf "\r\033[K${ERR} 生成 x25519 密钥对 [FAILED]\n" >/dev/tty
        echo -e "${ERR} 密钥对解析失败，Xray 输出格式可能已变更"; exit 1
    fi
    printf "\r\033[K${OK} 生成 x25519 密钥对\n" >/dev/tty

    # Short ID 与 XHTTP Path 生成
    printf "${INFO} 生成 Short ID / Path..." >/dev/tty
    SHORT_ID_VISION=$(openssl rand -hex 8)
    SHORT_ID_XHTTP=$(openssl rand -hex 8)
    XHTTP_PATH="/$(openssl rand -hex 8)"
    printf "\r\033[K${OK} 生成 Short ID / Path\n" >/dev/tty

    # 写入 config.json
    printf "${INFO} 写入 Xray 配置文件..." >/dev/tty
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [ "localhost", "1.1.1.1", "8.8.8.8" ]
  },
  "inbounds": [
    {
      "tag": "vision",
      "port": ${PORT_VISION},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI_HOST}:443",
          "serverNames": [ "${SNI_HOST}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID_VISION}" ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    },
    {
      "tag": "xhttp",
      "port": ${PORT_XHTTP},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": { "path": "${XHTTP_PATH}" },
        "realitySettings": {
          "show": false,
          "target": "${SNI_HOST}:443",
          "serverNames": [ "${SNI_HOST}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID_XHTTP}" ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",   "tag": "direct" },
    { "protocol": "blackhole", "tag": "block"  }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip":       [ "geoip:private" ],  "outboundTag": "block" },
      { "type": "field", "ip":       [ "geoip:cn" ],       "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ],     "outboundTag": "block" }
    ]
  }
}
EOF
    printf "\r\033[K${OK} 写入 Xray 配置文件\n" >/dev/tty

    # Systemd 服务覆写配置
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/override.conf <<EOF
[Service]
LimitNOFILE=infinity
LimitNPROC=65535
TasksMax=infinity
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray/"
EOF

    execute_task "systemctl daemon-reload" "重载 Systemd 配置" || exit 1

    execute_task \
        "/usr/local/bin/xray run -test -confdir /usr/local/etc/xray" \
        "验证 Xray 配置文件语法" || exit 1

    # 生成订阅路径
    printf "${INFO} 生成订阅路径..." >/dev/tty
    SUB_PATH="/$(openssl rand -hex 8)"
    echo "$SUB_PATH" > /usr/local/etc/xray/sub_path
    chmod 600 /usr/local/etc/xray/sub_path
    printf "\r\033[K${OK} 订阅路径已生成\n" >/dev/tty
}


# =============================================================
#  SECTION 5: 部署管理工具 (Tools)
# =============================================================

deploy_tools() {
    echo -e "\n${CYAN}>>> 5. 部署管理脚本${PLAIN}"

    local BIN_DIR="/usr/local/bin"

    # 持久化 SUB_DOMAIN 供 info 脚本运行时读取
    echo "${SUB_DOMAIN}" > /usr/local/etc/xray/sub_domain
    chmod 600 /usr/local/etc/xray/sub_domain

    # =========================================================
    # 工具: info — 显示节点配置信息与订阅地址
    # =========================================================
    cat > "$BIN_DIR/info" <<'INFO_EOF'
#!/bin/bash

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# 解析 Xray 配置
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
SNI_HOST=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
PORT_VISION=$(jq -r '.inbounds[] | select(.tag=="vision") | .port' "$CONFIG_FILE")
PORT_XHTTP=$(jq -r '.inbounds[]  | select(.tag=="xhttp")  | .port' "$CONFIG_FILE")
XHTTP_PATH=$(jq -r '.inbounds[]  | select(.tag=="xhttp")  | .streamSettings.xhttpSettings.path' "$CONFIG_FILE")
SHORT_ID_VISION=$(jq -r '.inbounds[] | select(.tag=="vision") | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
SHORT_ID_XHTTP=$(jq -r  '.inbounds[] | select(.tag=="xhttp")  | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")

# 从私钥计算公钥
RAW_OUTPUT=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY")
PUBLIC_KEY=$(echo "$RAW_OUTPUT" | grep -iE "Public|Password" | head -n 1 | awk -F':' '{print $2}' | tr -d ' \r\n')
[ -z "$PUBLIC_KEY" ] && echo -e "${RED}严重错误：公钥计算失败！${PLAIN}" && exit 1

# 获取公网 IP
IPV4=$(curl -s4 -m 3 https://api.ipify.org 2>/dev/null || echo "N/A")
IPV6=$(curl -s6 -m 3 https://api64.ipify.org 2>/dev/null || echo "N/A")

# 读取订阅域名（空值表示使用 IP 方案）
SUB_DOMAIN=""
[ -f /usr/local/etc/xray/sub_domain ] && SUB_DOMAIN=$(cat /usr/local/etc/xray/sub_domain)

# 配置信息展示
clear
echo -e ""
echo -e "${CYAN}配置信息${PLAIN}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "IPv4"          "${IPV4}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "IPv6"          "${IPV6}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "SNI"           "${SNI_HOST}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "UUID"          "${UUID}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "Short ID (V)"  "${SHORT_ID_VISION}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "Short ID (X)"  "${SHORT_ID_XHTTP}"
printf " ${CYAN}%-14s${PLAIN} : %s\n"  "Public Key"    "${PUBLIC_KEY}"
echo -e ""
printf " ${CYAN}%-14s${PLAIN} : ${CYAN}端口:${PLAIN} %-6s ${CYAN}流控:${PLAIN} %s\n" \
  "Vision" "${PORT_VISION}" "xtls-rprx-vision"
printf " ${CYAN}%-14s${PLAIN} : ${CYAN}端口:${PLAIN} %-6s ${CYAN}协议:${PLAIN} %-16s ${CYAN}Path:${PLAIN} %s\n" \
  "xhttp" "${PORT_XHTTP}" "xhttp" "${XHTTP_PATH}"
echo -e ""

# 订阅地址与二维码
SUB_PORT_HTTPS=48080
SUB_PATH_FILE="/usr/local/etc/xray/sub_path"

if [ ! -f "$SUB_PATH_FILE" ]; then
    echo -e "${RED}Error: 订阅路径文件不存在。${PLAIN}"
else
    SUB_PATH=$(cat "$SUB_PATH_FILE")

    if systemctl is-active --quiet xray-sub; then
        SUB_STATUS="${GREEN}运行中${PLAIN}"
    else
        SUB_STATUS="${RED}未运行${PLAIN}"
    fi
    echo -e "${GRAY}订阅服务状态: ${SUB_STATUS}${PLAIN}\n"

    if [ -n "$SUB_DOMAIN" ]; then
        # ---- Certbot 方案：受信域名证书 ----
        SUB_URL="https://${SUB_DOMAIN}:${SUB_PORT_HTTPS}${SUB_PATH}"
        echo -e "${CYAN}订阅地址 (HTTPS / Let's Encrypt)${PLAIN}:"
        echo -e "${YELLOW}${SUB_URL}${PLAIN}\n"
        qrencode -t ANSIUTF8 "${SUB_URL}"
        echo -e "${GRAY}证书由 Let's Encrypt 签发，无需跳过证书验证${PLAIN}\n"
    else
        # ---- 原始方案：IP + 自签证书 ----
        if [[ "$IPV4" != "N/A" ]]; then
            SUB_HOST="$IPV4"
        elif [[ "$IPV6" != "N/A" ]]; then
            SUB_HOST="[$IPV6]"
        else
            echo -e "${RED}Error: 无法获取公网 IP，订阅地址无法生成。${PLAIN}"
            SUB_HOST=""
        fi

        if [ -n "$SUB_HOST" ]; then
            SUB_URL_HTTPS="https://${SUB_HOST}:${SUB_PORT_HTTPS}${SUB_PATH}"

            echo -e "${CYAN}订阅地址 (HTTPS / 自签证书)${PLAIN}:"
            echo -e "${YELLOW}${SUB_URL_HTTPS}${PLAIN}\n"
            qrencode -t ANSIUTF8 "${SUB_URL_HTTPS}"
            echo -e "${GRAY}客户端需开启 跳过证书验证/AllowInsecure${PLAIN}\n"
        fi
    fi
fi

# 常用指令
echo -e "${CYAN}常用指令${PLAIN}"
echo -e " ${CYAN}[ Xray ]${PLAIN}"
echo -e "   状态      : systemctl status xray"
echo -e "   重启      : systemctl restart xray"
echo -e "   实时日志  : journalctl -u xray -f"
echo -e "   配置预览  : jq . /usr/local/etc/xray/config.json"
echo -e "   配置验证  : xray run -test -confdir /usr/local/etc/xray"
echo -e " ${CYAN}[ 订阅服务 ]${PLAIN}"
echo -e "   状态      : systemctl status xray-sub"
echo -e "   重启      : systemctl restart xray-sub"
echo -e "   日志      : journalctl -u xray-sub -n 20 --no-pager"
if [ -n "$SUB_DOMAIN" ]; then
echo -e " ${CYAN}[ Certbot ]${PLAIN}"
echo -e "   证书状态  : certbot certificates"
echo -e "   手动续期  : certbot renew"
echo -e "   证书路径  : /etc/letsencrypt/live/${SUB_DOMAIN}/"
fi
echo -e " ${CYAN}[ Fail2ban ]${PLAIN}"
echo -e "   运行状态  : systemctl status fail2ban"
echo -e "   封禁列表  : fail2ban-client status sshd"
echo -e " ${CYAN}[ Swap ]${PLAIN}"
echo -e "   Swap      : free -h && swapon --show"
echo -e "   Swappiness: sysctl vm.swappiness"
echo -e " ${CYAN}[ 自定义 ]${PLAIN}"
echo -e "   配置信息  : ${YELLOW}info${PLAIN}"
echo -e "   工具箱    : ${YELLOW}tools${PLAIN}"
echo -e ""

INFO_EOF

    chmod +x "$BIN_DIR/info"
    echo -e "${OK} 部署命令: ${GREEN}info${PLAIN}"

    # =========================================================
    # 工具: tools - 工具箱
    # =========================================================
    cat > "$BIN_DIR/tools" <<'TOOLS_EOF'

#!/bin/bash

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"

[ "$EUID" -ne 0 ] && exec sudo bash -- "$0" "$@"

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
GAI_CONF="/etc/gai.conf"
SYSCTL_CONF="/etc/sysctl.conf"
SYSCTL_BBR_CONF="/etc/sysctl.d/99-xray-bbr.conf"
BBR_BACKUP="/etc/sysctl.d/.bbr_backup_state"
WARP_PORT=40000
WARP_DIRECT_FILE="/usr/local/etc/xray/warp_direct_domains"
SUB_PORT_HTTPS=48080
SUB_PORT_HTTP=48081
PORT_VISION=$(jq -r '.inbounds[] | select(.tag=="vision") | .port' "$CONFIG_FILE" 2>/dev/null)
PORT_XHTTP=$(jq -r  '.inbounds[] | select(.tag=="xhttp")  | .port' "$CONFIG_FILE" 2>/dev/null)
UI_MESSAGE=""
NEED_CLEAR=0

KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)
BBR_OK=0
{ [ "$KERNEL_MAJOR" -gt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]; }; } \
    && BBR_OK=1

# =============================================================
#  1. Xray Core Update
# =============================================================
do_update_core() {
    local log spinner_pid
    log=$(mktemp)

    tput civis
    (
        trap 'exit 0' TERM
        local elapsed=0
        while true; do
            printf "\r\033[K  ${YELLOW}正在更新 Xray Core，请稍候... %ds${PLAIN}" "$elapsed"
            sleep 1
            ((elapsed++))
        done
    ) &
    local spinner_pid=$!

    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ install --without-geodata >"$log" 2>&1
    local exit_code=$?

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    tput cnorm
    printf "\r\033[K"
    rm -f "$log"

    if [ $exit_code -eq 0 ]; then
        systemctl restart xray 2>/dev/null
        local ver; ver=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')
        UI_MESSAGE="${GREEN}Core 更新成功！当前版本: v${ver}${PLAIN}"
    else
        UI_MESSAGE="${RED}Core 更新失败，请检查网络连接。${PLAIN}"
    fi
}

# =============================================================
#  2. SNI
# =============================================================
do_change_sni() {
    local cur; cur=$(jq -r \
        '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "未知"' \
        "$CONFIG_FILE" 2>/dev/null)
    echo ""
    local err=""
    while true; do
        [ -n "$err" ] \
            && printf "\r\033[K${RED}%s${PLAIN} 请输入新 SNI 域名 (0 取消): " "$err" \
            || printf "\r\033[K当前: ${YELLOW}%s${PLAIN}  请输入新 SNI 域名 (0 取消): " "$cur"
        read -r input
        [ "$input" == "0" ] && UI_MESSAGE="${GRAY}操作已取消。${PLAIN}" && return
        [ -z "$input" ]     && err="输入不能为空！" && echo -ne "\033[1A" && continue
        if [[ "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
            jq --arg d "$input" '
                (.inbounds[].streamSettings.realitySettings | select(. != null)) |=
                (.serverNames = [$d] | .target = ($d + ":443"))
            ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
                && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            if systemctl restart xray 2>/dev/null; then
                UI_MESSAGE="${GREEN}SNI 已更新为 ${input}，请同步更新客户端配置。${PLAIN}"
            else
                mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
                systemctl restart xray 2>/dev/null
                UI_MESSAGE="${RED}Xray 重启失败，已自动还原旧配置。${PLAIN}"
            fi
            return
        else
            err="域名格式无效！"; echo -ne "\033[1A"
        fi
    done
}

# =============================================================
#  3-6. Network Stack
# =============================================================
_net_check_ssh() {
    local info="${SUDO_SSH_CLIENT:-$SSH_CLIENT}"
    [ -z "$info" ] && info=$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()')
    [[ "$info" =~ : ]] && echo "v6" || echo "v4"
}

_net_toggle_ipv6() {
    if [ "$1" == "off" ]; then
        if [ "$(_net_check_ssh)" == "v6" ]; then
            UI_MESSAGE="${RED}危险：当前通过 IPv6 SSH 连接，禁止关闭系统 IPv6！${PLAIN}"
            return 1
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=1     >/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
        sed -i '/net.ipv6.conf.all.disable_ipv6/d' "$SYSCTL_CONF"
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> "$SYSCTL_CONF"
    else
        sysctl -w net.ipv6.conf.all.disable_ipv6=0     >/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
        sed -i '/net.ipv6.conf.all.disable_ipv6/d' "$SYSCTL_CONF"
    fi
}

_net_set_prio() {
    [ ! -f "$GAI_CONF" ] && touch "$GAI_CONF"
    sed -i '/^precedence ::ffff:0:0\/96  100/d' "$GAI_CONF"
    [ "$1" == "v4" ] && echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
}

_net_check_v4() {
    curl -s4 -m 3 https://cloudflare.com >/dev/null 2>&1 || \
    curl -s4 -m 3 https://dns.google     >/dev/null 2>&1
}

_net_apply() {
    jq --arg s "$1" '.routing.domainStrategy = $s' "$CONFIG_FILE" \
        > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart xray >/dev/null 2>&1
}

do_net() {
    case "$1" in
        v4_prio)
            _net_toggle_ipv6 "on"; _net_set_prio "v4"
            _net_apply "IPIfNonMatch"
            UI_MESSAGE="${GREEN}已切换至 IPv4 优先模式。${PLAIN}" ;;
        v6_prio)
            _net_toggle_ipv6 "on"; _net_set_prio "v6"
            _net_apply "IPIfNonMatch"
            UI_MESSAGE="${GREEN}已切换至 IPv6 优先模式。${PLAIN}" ;;
        v4_only)
            _net_toggle_ipv6 "off" || return
            _net_set_prio "v4"
            if ! _net_check_v4; then
                _net_toggle_ipv6 "on"
                UI_MESSAGE="${RED}本机无法连接 IPv4 网络，操作已中止。${PLAIN}"; return
            fi
            _net_apply "UseIPv4"
            UI_MESSAGE="${GREEN}已切换至仅 IPv4 模式。${PLAIN}" ;;
        v6_only)
            _net_toggle_ipv6 "on"; _net_set_prio "v6"
            _net_apply "UseIPv6"
            UI_MESSAGE="${GREEN}已切换至仅 IPv6 模式。${PLAIN}" ;;
    esac
}

# =============================================================
#  7-9. WARP
# =============================================================
_warp_check_socket() {
    (echo > /dev/tcp/127.0.0.1/$WARP_PORT) >/dev/null 2>&1
}

_warp_check_outbound() {
    jq -e '.outbounds[] | select(.tag=="warp")' \
        "$CONFIG_FILE" >/dev/null 2>&1
}

_warp_check_global() {
    jq -e '.routing.rules[] | select(.outboundTag=="warp" and .network=="tcp,udp")' \
        "$CONFIG_FILE" >/dev/null 2>&1
}

_warp_check_direct() {
    [ -f "$WARP_DIRECT_FILE" ] && [ -s "$WARP_DIRECT_FILE" ]
}

_warp_wait_port() {
    for i in {1..15}; do _warp_check_socket && return 0; sleep 1; done; return 1
}

_warp_ensure_outbound() {
    _warp_check_outbound && return
    local obj
    obj='{"tag":"warp","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":'$WARP_PORT'}]}}'
    jq --argjson o "$obj" '.outbounds += [$o]' "$CONFIG_FILE" \
        > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

_warp_remove_outbound() {
    jq 'del(.outbounds[] | select(.tag=="warp"))' "$CONFIG_FILE" \
        > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp" and .network=="tcp,udp"))' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    rm -f "$WARP_DIRECT_FILE"
    _warp_sync_direct
}

_warp_sync_direct() {
    jq 'del(.routing.rules[] | select(.outboundTag=="direct" and has("domain")))' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    _warp_check_direct || return
    local domains; domains=$(grep -v '^$' "$WARP_DIRECT_FILE" \
        | jq -Rsc 'split("\n") | map(select(length > 0))')
    local rule; rule=$(jq -n --argjson d "$domains" \
        '{"type":"field","domain":$d,"outboundTag":"direct"}')
    jq --argjson r "$rule" '.routing.rules = [$r] + .routing.rules' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

_validate_domain() {
    local input="$1"
    [ -z "$input" ]               && echo "输入不能为空"   && return 1
    [[ "$input" =~ [[:space:]] ]] && echo "不能含空格"     && return 1
    [[ "$input" =~ ^geoip: ]]     && echo "不支持 geoip:" && return 1

    # 带前缀规则直接放行，由 Xray 自身校验内容合法性
    [[ "$input" =~ ^(geosite:|domain:|full:|regexp:) ]] && return 0

    # 裸域名：允许以 . 开头（Xray 泛匹配子域名语法），剥离后再校验
    local domain="$input"
    [[ "$domain" =~ ^\. ]] && domain="${domain#.}"

    # 必须包含至少一个点，TLD 不少于两个字符，每段首尾不得为连字符
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]] \
        && return 0

    echo "格式不合法"; return 1
}

do_warp_toggle() {
    if _warp_check_socket; then
        local err=""
        while true; do
            [ -n "$err" ] \
                && printf "\r\033[K${RED}%s${PLAIN} 确认卸载 WARP？(y/n): " "$err" \
                || printf "\r\033[K确认卸载 WARP？(y/n): "
            read -r c
            case "$c" in
                [yY])
                    clear; echo -e "\n${RED}正在卸载 WARP...${PLAIN}"
                    if command -v warp &>/dev/null; then (warp u)
                    else (wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh \
                            && bash menu.sh u); fi
                    _warp_remove_outbound
                    systemctl restart xray >/dev/null 2>&1
                    UI_MESSAGE="${GREEN}WARP 已卸载，规则已清理。${PLAIN}"
                    NEED_CLEAR=1; return ;;
                [nN]) UI_MESSAGE="${GRAY}操作已取消。${PLAIN}"; return ;;
                *)    err="请输入 y 或 n！"; echo -ne "\033[1A" ;;
            esac
        done
    else
        clear; echo -e "\n${CYAN}正在安装 WARP (Socks5 模式)...${PLAIN}"
        (wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh c)
        if _warp_wait_port; then
            _warp_ensure_outbound
            systemctl restart xray >/dev/null 2>&1
            UI_MESSAGE="${GREEN}WARP 安装成功，Xray 已自动对接。${PLAIN}"
        else
            UI_MESSAGE="${RED}WARP 安装超时或失败，请查看上方日志。${PLAIN}"
        fi
        echo ""; read -rn1 -s -p "  按任意键返回..."
        NEED_CLEAR=1
    fi
}

do_warp_global() {
    if ! _warp_check_socket; then
        UI_MESSAGE="${YELLOW}WARP 未运行，请先安装（选项 7）。${PLAIN}"; return
    fi
    _warp_ensure_outbound
    if _warp_check_global; then
        jq 'del(.routing.rules[] | select(.outboundTag=="warp" and .network=="tcp,udp"))' \
            "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        systemctl restart xray >/dev/null 2>&1
        UI_MESSAGE="${YELLOW}全局代理已关闭，恢复默认直连。${PLAIN}"
    else
        local rule='{"type":"field","network":"tcp,udp","outboundTag":"warp"}'
        jq --argjson r "$rule" '.routing.rules += [$r]' "$CONFIG_FILE" \
            > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        systemctl restart xray >/dev/null 2>&1
        UI_MESSAGE="${GREEN}全局代理已开启，所有流量经由 WARP。${PLAIN}"
    fi
}

do_warp_direct() {
    if ! _warp_check_global; then
        UI_MESSAGE="${YELLOW}请先开启全局代理（选项 8），直连规则仅在全局模式下有效。${PLAIN}"
        return
    fi

    while true; do
        tput cup 0 0
        echo -e "\033[K"
        echo -e "  ${CYAN}【输入说明】${PLAIN}\033[K"
        echo -e "  以下域名将走直连，绕过 WARP 代理。\033[K"
        echo -e "\033[K"
        echo -e "  ${CYAN}支持格式:${PLAIN}\033[K"
        echo -e "  ${GREEN}geosite:google${PLAIN}          规则库集合，匹配 Google 旗下所有域名\033[K"
        echo -e "  ${GREEN}domain:example.com${PLAIN}      匹配该域名及其所有子域名 [泛匹配: ${GREEN}.example.com${PLAIN}, 裸域名: ${GREEN}example.com${PLAIN}, 同 domain:]\033[K"
        echo -e "  ${GREEN}full:www.example.com${PLAIN}    仅精确匹配该域名，子域名不受影响\033[K"
        echo -e "  ${GREEN}regexp:\.example\.com\$${PLAIN}  正则匹配，需转义特殊字符\033[K"
        echo -e "\033[K"
        echo -e "  ${CYAN}注意事项:${PLAIN}\033[K"
        echo -e "  ${GRAY}· 不支持 geoip: 开头（IP 规则不适用于域名字段）${PLAIN}\033[K"
        echo -e "  ${GRAY}· 支持逗号分隔批量输入，例: geosite:google,gmail.com,paypal.com,wise.com,twitter.com,twimg.com,icloud.com,apple.com,whatsapp.com,whatsapp.net,dmit.io,claude.ai,anthropic.com${PLAIN}\033[K"
        echo -e "  ${GRAY}· 规则生效需重启 Xray，添加后将自动执行${PLAIN}\033[K"
        echo -e "\033[K"
        echo -e "  ${CYAN}当前直连规则:${PLAIN}\033[K"
        local rules; rules=$(grep -v '^$' "$WARP_DIRECT_FILE" 2>/dev/null)
        local total=0
        if [ -z "$rules" ]; then
            echo -e "    ${GRAY}(暂无规则)${PLAIN}\033[K"
        else
            total=$(echo "$rules" | wc -l)
            local i=1
            while IFS= read -r r; do
                printf "    %d. %s\033[K\n" "$i" "$r"; ((i++))
            done <<< "$rules"
        fi
        echo -e "\033[K"
        echo -e "  ${GREEN}a.${PLAIN} 添加  ${RED}d<序号>.${PLAIN} 删除 (例: d1)  ${RED}c.${PLAIN} 清空  ${YELLOW}0.${PLAIN} 返回\033[K"
        echo -e "\033[K"
        tput ed

        local sub_err=""
        while true; do
            [ -n "$sub_err" ] \
                && printf "\r\033[K${RED}%s${PLAIN} 请输入选项: " "$sub_err" \
                || printf "\r\033[K请输入选项: "
            read -r sub
            case "$sub" in
                a|c|0) break ;;
                d[1-9]*)
                    local didx="${sub#d}"
                    if [[ "$didx" =~ ^[0-9]+$ ]] && [ "$didx" -ge 1 ] && [ "$didx" -le "$total" ]
                    then break
                    elif [ "$total" -eq 0 ]; then
                        sub_err="域名池为空！"; echo -ne "\033[1A"
                    else
                        sub_err="序号无效，有效范围 [1-${total}]！"; echo -ne "\033[1A"
                    fi ;;
                *) sub_err="输入无效！"; echo -ne "\033[1A" ;;
            esac
        done

        case "$sub" in
            a)
                while true; do
                    local in_err=""
                    while true; do
                        [ -n "$in_err" ] \
                            && printf "\r\033[K${RED}%s${PLAIN} 请输入域名规则 (0 返回): " "$in_err" \
                            || printf "\r\033[K请输入域名规则，逗号分隔批量输入 (0 返回): "
                        read -r raw
                        [ "$raw" == "0" ] && break 2
                        [ -z "$raw" ] && in_err="输入不能为空！" && echo -ne "\033[1A" && continue
                        local added=0 first_err=""
                        IFS=',' read -ra entries <<< "$raw"
                        for entry in "${entries[@]}"; do
                            entry=$(echo "$entry" | tr -d ' ')
                            [ -z "$entry" ] && continue
                            local emsg; emsg=$(_validate_domain "$entry")
                            if [ $? -ne 0 ]; then
                                first_err="输入不合法或重复，已跳过"
                                continue
                            fi
                            if grep -qx "$entry" "$WARP_DIRECT_FILE" 2>/dev/null; then
                                first_err="输入不合法或重复，已跳过"
                                continue
                            fi
                            echo "$entry" >> "$WARP_DIRECT_FILE"
                            ((added++))
                        done
                        if [ $added -gt 0 ]; then
                            _warp_sync_direct && systemctl restart xray >/dev/null 2>&1
                            echo -ne "\033[1A"
                            printf "\r\033[K${GREEN}%s 已添加${PLAIN}\n" "$raw"
                            in_err=""
                        elif [ -n "$first_err" ]; then
                            in_err="$first_err"
                            echo -ne "\033[1A"
                        fi
                    done
                done ;;

            d[1-9]*)
                local didx="${sub#d}"
                local del_rule; del_rule=$(echo "$rules" | sed -n "${didx}p")
                sed -i "/^$(echo "$del_rule" | sed 's/[[\.*^$()+?{|]/\\&/g')$/d" \
                    "$WARP_DIRECT_FILE"
                _warp_sync_direct; systemctl restart xray >/dev/null 2>&1
                UI_MESSAGE="${GREEN}已删除: ${del_rule}${PLAIN} ${GRAY}(Xray 已重启)${PLAIN}" ;;

            c)
                rm -f "$WARP_DIRECT_FILE"
                _warp_sync_direct
                systemctl restart xray >/dev/null 2>&1
                UI_MESSAGE="${GREEN}已清空所有直连规则。${PLAIN} ${GRAY}(Xray 已重启)${PLAIN}" ;;

            0) NEED_CLEAR=1; return ;;
        esac
    done
}

# =============================================================
#  10-12. BBR
# =============================================================
_bbr_record_backup() {
    [ -f "$BBR_BACKUP" ] && return
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    [[ "$cc" != "bbr" ]] && { echo "ORIG_CC=$cc"; echo "ORIG_QD=$qd"; } > "$BBR_BACKUP"
}

_bbr_rollback() {
    rm -f "$SYSCTL_BBR_CONF"
    local cc="cubic" qd="fq_codel"
    if [ -f "$BBR_BACKUP" ]; then
        # shellcheck source=/dev/null
        . "$BBR_BACKUP"
        [ -n "$ORIG_CC" ] && cc="$ORIG_CC"
        [ -n "$ORIG_QD" ] && qd="$ORIG_QD"
    fi
    sysctl -w net.ipv4.tcp_congestion_control="$cc" >/dev/null 2>&1
    sysctl -w net.core.default_qdisc="$qd"         >/dev/null 2>&1
    sysctl --system                                  >/dev/null 2>&1
}

do_bbr_native() {
    [ $BBR_OK -eq 0 ] \
        && UI_MESSAGE="${RED}内核 ${KERNEL_VER} 不支持 BBR（需要 ≥ 4.9）。${PLAIN}" && return
    _bbr_record_backup
    modprobe tcp_bbr 2>/dev/null; modprobe sch_fq 2>/dev/null
    cat > "$SYSCTL_BBR_CONF" << 'BBR_CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR_CONF
    sysctl -p "$SYSCTL_BBR_CONF" >/dev/null 2>&1
    UI_MESSAGE="${GREEN}BBR 原生模式已启用。${PLAIN}"
}

do_bbr_hardened() {
    [ $BBR_OK -eq 0 ] \
        && UI_MESSAGE="${RED}内核 ${KERNEL_VER} 不支持 BBR（需要 ≥ 4.9）。${PLAIN}" && return
    _bbr_record_backup
    modprobe tcp_bbr 2>/dev/null; modprobe sch_fq 2>/dev/null
    cat > "$SYSCTL_BBR_CONF" << 'BBR_CONF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 1000000
net.ipv4.ip_local_port_range = 32768 60999
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
BBR_CONF
    sysctl -p "$SYSCTL_BBR_CONF" >/dev/null 2>&1
    UI_MESSAGE="${GREEN}BBR 加固模式已启用。${PLAIN}"
}

do_bbr_disable() {
    _bbr_rollback
    UI_MESSAGE="${YELLOW}BBR 已关闭，已恢复系统默认。${PLAIN}"
}

# =============================================================
#  13. SSH
# =============================================================
SSH_CONFIG="/etc/ssh/sshd_config"

_ssh_get_port() {
    local port; port=$(grep -E "^Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | head -n1)
    echo "${port:-22}"
}

_ssh_restart() {
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
}

_ssh_verify_port() {
    local port=$1
    sleep 1
    ss -tlnp | grep -q ":${port} " 2>/dev/null
}

_ssh_apply() {
    local desc="$1"
    if ! sshd -t 2>/dev/null; then
        cp "${SSH_CONFIG}.bak" "$SSH_CONFIG"
        UI_MESSAGE="${RED}配置文件语法校验失败，已自动还原，未作任何变更。${PLAIN}"
        return 1
    fi
    if ! _ssh_restart; then
        cp "${SSH_CONFIG}.bak" "$SSH_CONFIG"
        _ssh_restart
        UI_MESSAGE="${RED}SSH 重启失败，已自动还原。${PLAIN}"
        return 1
    fi
    UI_MESSAGE="${GREEN}${desc}${PLAIN}"
    return 0
}

do_ssh_port() {
    local cur_port; cur_port=$(_ssh_get_port)
    local err=""
    while true; do
        [ -n "$err" ] \
            && printf "\r\033[K${RED}%s${PLAIN} 请输入新 SSH 端口 (0 取消): " "$err" \
            || printf "\r\033[K当前端口: ${YELLOW}%s${PLAIN}  请输入新 SSH 端口 (0 取消): " "$cur_port"
        read -r input
        [ "$input" == "0" ] && UI_MESSAGE="${GRAY}操作已取消。${PLAIN}" && return

        if [[ ! "$input" =~ ^[0-9]+$ ]] || \
           { [ "$input" -ne 22 ] && [ "$input" -lt 1024 ]; } || \
           [ "$input" -gt 65535 ]; then
            err="端口范围无效，请输入 22 或 1024-65535！"; echo -ne "\033[1A"; continue
        fi
        if [ "$input" == "$cur_port" ]; then
            err="与当前端口相同！"; echo -ne "\033[1A"; continue
        fi
        if [ "$input" == "$PORT_VISION" ]    || \
           [ "$input" == "$PORT_XHTTP" ]     || \
           [ "$input" == "$SUB_PORT_HTTPS" ] || \
           [ "$input" == "$SUB_PORT_HTTP" ]; then
            err="该端口已被 Xray 服务占用！"; echo -ne "\033[1A"; continue
        fi
        if lsof -i:"$input" -P -n >/dev/null 2>&1; then
            err="端口 ${input} 已被其他服务占用！"; echo -ne "\033[1A"; continue
        fi
        break
    done

    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"

    if grep -qE "^Port " "$SSH_CONFIG" 2>/dev/null; then
        sed -i "s/^Port .*/Port $input/" "$SSH_CONFIG"
    else
        echo "Port $input" >> "$SSH_CONFIG"
    fi

    _ssh_apply "SSH 端口已更改为 ${input}。" || return

    if ! _ssh_verify_port "$input"; then
        cp "${SSH_CONFIG}.bak" "$SSH_CONFIG"
        _ssh_restart
        UI_MESSAGE="${RED}SSH 未能在新端口监听，已自动还原端口 ${cur_port}。${PLAIN}"
        return
    fi

    iptables  -A INPUT -p tcp --dport "$input"    -j ACCEPT 2>/dev/null
    ip6tables -A INPUT -p tcp --dport "$input"    -j ACCEPT 2>/dev/null
    iptables  -D INPUT -p tcp --dport "$cur_port" -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p tcp --dport "$cur_port" -j ACCEPT 2>/dev/null
    netfilter-persistent save >/dev/null 2>&1

    UI_MESSAGE="${GREEN}SSH 端口已更改为 ${input}，防火墙规则已同步。${PLAIN}"
}

# =============================================================
#  Status Collection
# =============================================================
collect_status() {
    # Xray version
    local ver; ver=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')
    ST_XRAY="${GREEN}● v${ver:-未知}${PLAIN}"

    # SNI
    local sni; sni=$(jq -r \
        '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "未知"' \
        "$CONFIG_FILE" 2>/dev/null)
    ST_SNI="${GREEN}● ${sni}${PLAIN}"

    # Network mode
    local ds; ds=$(jq -r '.routing.domainStrategy // "IPIfNonMatch"' "$CONFIG_FILE" 2>/dev/null)
    local v4_prio=false
    grep -q "^precedence ::ffff:0:0/96  100" "$GAI_CONF" 2>/dev/null && v4_prio=true
    ST_NET3="${GRAY}○ 未启用${PLAIN}"; ST_NET4="${GRAY}○ 未启用${PLAIN}"
    ST_NET5="${GRAY}○ 未启用${PLAIN}"; ST_NET6="${GRAY}○ 未启用${PLAIN}"
    if   [ "$ds" == "UseIPv4" ]; then ST_NET5="${GREEN}● 已启用${PLAIN}"
    elif [ "$ds" == "UseIPv6" ]; then ST_NET6="${GREEN}● 已启用${PLAIN}"
    elif [ "$v4_prio" = true ];  then ST_NET3="${GREEN}● 已启用${PLAIN}"
    else                              ST_NET4="${GREEN}● 已启用${PLAIN}"
    fi

    # WARP
    _warp_check_socket \
        && ST_WARP7="${GREEN}● 运行中${PLAIN}" \
        || ST_WARP7="${GRAY}○ 未运行${PLAIN}"
    _warp_check_global \
        && ST_WARP8="${GREEN}● 已开启${PLAIN}" \
        || ST_WARP8="${GRAY}○ 已关闭${PLAIN}"
    if ! _warp_check_global; then
        ST_WARP9="${GRAY}○ 仅全局模式有效${PLAIN}"
    elif _warp_check_direct; then
        local cnt; cnt=$(grep -c . "$WARP_DIRECT_FILE" 2>/dev/null || echo 0)
        ST_WARP9="${GREEN}● 已启用 (${cnt} 条)${PLAIN}"
    else
        ST_WARP9="${GRAY}○ 未启用${PLAIN}"
    fi

    # BBR
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    ST_BBR10="${GRAY}○ 未启用${PLAIN}"; ST_BBR11="${GRAY}○ 未启用${PLAIN}"; ST_BBR12="${GREEN}● 已启用${PLAIN}"
    if [ "$cc" == "bbr" ]; then
        ST_BBR12="${GRAY}○ 未启用${PLAIN}"
        if [ -f "$SYSCTL_BBR_CONF" ] && grep -q "tcp_keepalive_time" "$SYSCTL_BBR_CONF" 2>/dev/null
        then ST_BBR11="${GREEN}● 已启用${PLAIN}"
        else ST_BBR10="${GREEN}● 已启用${PLAIN}"
        fi
    fi

    # SSH
    local ssh_port; ssh_port=$(_ssh_get_port)
    ST_SSH13="${GREEN}● ${ssh_port}${PLAIN}"
}

# =============================================================
#  Main Menu
# =============================================================
_menu_line() {
    local label="$1" status="$2" target=25
    local cjc; cjc=$(printf '%s' "$label" | grep -oP '[\x{4e00}-\x{9fa5}]' | wc -l)
    local pad=$(( target - ${#label} - cjc ))
    [ $pad -lt 1 ] && pad=1
    printf "  %s%*s%b\033[K\n" "$label" "$pad" "" "$status"
}

show_menu() {
    [ "$NEED_CLEAR" -eq 1 ] && clear && NEED_CLEAR=0
    tput cup 0 0
    printf '\033[1J'
    echo -e "  ${CYAN}[ Xray ]${PLAIN}\033[K"
    _menu_line "1. 更新 Xray Core"  "$ST_XRAY"
    _menu_line "2. 修改 SNI"        "$ST_SNI"
    echo -e "\033[K"
    echo -e "  ${CYAN}[ 网络 ]${PLAIN}\033[K"
    _menu_line "3. IPv4 优先"       "$ST_NET3"
    _menu_line "4. IPv6 优先"       "$ST_NET4"
    _menu_line "5. IPv4 only"       "$ST_NET5"
    _menu_line "6. IPv6 only"       "$ST_NET6"
    echo -e "\033[K"
    echo -e "  ${CYAN}[ WARP ]${PLAIN}\033[K"
    _menu_line "7. 安装 / 卸载"     "$ST_WARP7"
    _menu_line "8. 全局代理开关"    "$ST_WARP8"
    _menu_line "9. 直连规则管理"    "$ST_WARP9"
    echo -e "\033[K"
    echo -e "  ${CYAN}[ 优化 ]${PLAIN}\033[K"
    _menu_line "10. BBR 原生"       "$ST_BBR10"
    _menu_line "11. BBR 加固"       "$ST_BBR11"
    _menu_line "12. 关闭 BBR"       "$ST_BBR12"
    echo -e "\033[K"
    echo -e "  ${CYAN}[ SSH ]${PLAIN}\033[K"
    _menu_line "13. 修改端口"       "$ST_SSH13"
    echo -e "\033[K"
    echo -e "  0. 退出\033[K"
    echo -e "\033[K"
    if [ -n "$UI_MESSAGE" ]; then
        echo -e "  当前操作: ${UI_MESSAGE}\033[K"; UI_MESSAGE=""
    else
        echo -e "  当前操作: ${GRAY}等待输入...${PLAIN}\033[K"
    fi
    echo -e "\033[K"
    tput ed
}

# =============================================================
#  Main Loop
# =============================================================
clear
while true; do
    collect_status
    show_menu
    err=""
    while true; do
        [ -n "$err" ] \
            && echo -ne "\r\033[K${RED}${err}${PLAIN} 请输入选项 [0-13]: " \
            || echo -ne "\r\033[K请输入选项 [0-13]: "
        read -r choice
        case "$choice" in
            [0-9]|10|11|12|13) break ;;
            *) err="输入无效！"; echo -ne "\033[1A" ;;
        esac
    done
    case "$choice" in
        1)  do_update_core ;;
        2)  do_change_sni ;;
        3)  do_net v4_prio ;;
        4)  do_net v6_prio ;;
        5)  do_net v4_only ;;
        6)  do_net v6_only ;;
        7)  do_warp_toggle ;;
        8)  do_warp_global ;;
        9)  do_warp_direct ;;
        10) do_bbr_native ;;
        11) do_bbr_hardened ;;
        12) do_bbr_disable ;;
        13) do_ssh_port ;;
        0)  clear; exit 0 ;;
    esac
done

TOOLS_EOF

    chmod +x "$BIN_DIR/tools"
    echo -e "${OK} 部署命令: ${GREEN}tools${PLAIN}"

    # =========================================================
    # 订阅服务：Python 订阅服务器
    # 当 SUB_DOMAIN 非空时，加载 Certbot 签发的受信证书；
    # 否则回退至自签证书 + HTTP 双端口方案。
    # =========================================================
    cat > /usr/local/bin/xray-sub-server.py << SUBSERVER_EOF
#!/usr/bin/env python3
import http.server
import json
import base64
import subprocess
import socket
import os
import sys
import ssl
import threading

CONFIG_FILE   = "/usr/local/etc/xray/config.json"
SUB_PATH_FILE = "/usr/local/etc/xray/sub_path"
XRAY_BIN      = "/usr/local/bin/xray"
SUB_PORT      = ${SUB_PORT_HTTPS}
SUB_DOMAIN    = "${SUB_DOMAIN}"

def get_public_key(private_key):
    try:
        raw = subprocess.check_output(
            [XRAY_BIN, "x25519", "-i", private_key], stderr=subprocess.DEVNULL
        ).decode()
        for line in raw.splitlines():
            if "Public" in line or "Password" in line:
                return line.split(":", 1)[1].strip()
    except Exception:
        return ""
    return ""

def get_ip(version):
    try:
        flag = "-4" if version == 4 else "-6"
        url  = "https://api.ipify.org" if version == 4 else "https://api64.ipify.org"
        result = subprocess.check_output(
            ["curl", "-s", flag, "-m", "3", url], stderr=subprocess.DEVNULL
        ).decode().strip()
        return result if result else "N/A"
    except Exception:
        return "N/A"

def build_links():
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
    except Exception as e:
        raise RuntimeError(f"配置文件读取失败: {e}")

    inbounds = cfg.get("inbounds", [])
    vision   = next((i for i in inbounds if i.get("tag") == "vision"), None)
    xhttp    = next((i for i in inbounds if i.get("tag") == "xhttp"),  None)

    if not vision:
        return ""

    uuid             = vision["settings"]["clients"][0]["id"]
    private_key      = vision["streamSettings"]["realitySettings"]["privateKey"]
    short_id_vision  = vision["streamSettings"]["realitySettings"]["shortIds"][0]
    short_id_xhttp   = (xhttp["streamSettings"]["realitySettings"].get("shortIds") or [None])[0] if xhttp else None
    sni              = vision["streamSettings"]["realitySettings"]["serverNames"][0]
    port_vision      = vision["port"]
    port_xhttp       = xhttp["port"] if xhttp else None
    xhttp_path       = xhttp["streamSettings"]["xhttpSettings"]["path"] if xhttp else None
    public_key       = get_public_key(private_key)

    if not public_key:
        return ""

    hostname = socket.gethostname()
    ipv4     = get_ip(4)
    ipv6     = get_ip(6)
    links    = []

    for ip, label in [(ipv4, "IPv4"), (ipv6, "IPv6")]:
        if ip == "N/A":
            continue
        host = f"[{ip}]" if ":" in ip else ip
        links.append(
            f"vless://{uuid}@{host}:{port_vision}?security=reality&encryption=none"
            f"&pbk={public_key}&headerType=none&fp=chrome&type=tcp"
            f"&flow=xtls-rprx-vision&sni={sni}&sid={short_id_vision}"
            f"#{hostname}_{label}_Vision"
        )
        if port_xhttp and xhttp_path and short_id_xhttp:
            links.append(
                f"vless://{uuid}@{host}:{port_xhttp}?security=reality&encryption=none"
                f"&pbk={public_key}&headerType=none&fp=chrome&type=xhttp"
                f"&path={xhttp_path}&sni={sni}&sid={short_id_xhttp}"
                f"#{hostname}_{label}_xhttp"
            )

    return base64.b64encode("\n".join(links).encode()).decode()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == SUB_PATH:
            content = get_cached_links().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

# 读取订阅路径
try:
    with open(SUB_PATH_FILE) as f:
        SUB_PATH = f.read().strip()
except FileNotFoundError:
    print(f"[ERROR] 订阅路径文件不存在: {SUB_PATH_FILE}", flush=True)
    sys.exit(1)

# 配置变更时自动刷新缓存
_cached_links = None
_config_mtime = None

def get_cached_links():
    global _cached_links, _config_mtime
    try:
        mtime = os.path.getmtime(CONFIG_FILE)
    except OSError:
        mtime = None
    if _cached_links is None or mtime != _config_mtime:
        try:
            _cached_links = build_links()
            _config_mtime = mtime
        except Exception as e:
            print(f"[ERROR] 订阅链接生成失败: {e}", flush=True)
            if _cached_links is None:
                _cached_links = ""
    return _cached_links

get_cached_links()

# TLS 证书路径选择：Certbot 受信证书 或 自签证书
if SUB_DOMAIN:
    CERT_FILE = f"/etc/letsencrypt/live/{SUB_DOMAIN}/fullchain.pem"
    KEY_FILE  = f"/etc/letsencrypt/live/{SUB_DOMAIN}/privkey.pem"
else:
    CERT_FILE = "/usr/local/etc/xray/sub.crt"
    KEY_FILE  = "/usr/local/etc/xray/sub.key"

try:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
except Exception as e:
    print(f"[ERROR] TLS 证书加载失败: {e}", flush=True)
    sys.exit(1)

https_server = http.server.HTTPServer(("0.0.0.0", SUB_PORT), Handler)
https_server.socket = ctx.wrap_socket(https_server.socket, server_side=True)

if SUB_DOMAIN:
    print(f"[INFO] 域名模式：HTTPS:{SUB_PORT} (Let's Encrypt)", flush=True)
else:
    print(f"[INFO] 独立模式：HTTPS:{SUB_PORT} (自签证书)", flush=True)

https_server.serve_forever()
SUBSERVER_EOF

    # =========================================================
    # 证书申请：Certbot（仅 SUB_DOMAIN 非空时执行）
    # 或回退至自签证书
    # =========================================================

    _input_fallback_confirm() {
        local key error_msg="" first=1
        while true; do
            if [ -n "$error_msg" ]; then
                printf "\033[1A\r\033[K${RED}%s${PLAIN} 回退至自签证书方案继续安装? [y/N]: " "$error_msg"
            elif [ "$first" -eq 0 ]; then
                printf "\033[1A\r\033[K回退至自签证书方案继续安装? [y/N]: "
            else
                printf "回退至自签证书方案继续安装? [y/N]: "
            fi
            first=0; read -r key
            case "$key" in
                y|Y)
                    printf "\033[1A\r\033[K${OK} 回退至自签证书方案\n"
                    return 0 ;;
                n|N|"")
                    printf "\033[1A\r\033[K${WARN} 安装已中止。\n"
                    return 1 ;;
                *) error_msg="请输入 y 或 n！" ;;
            esac
        done
    }

    if [ -n "$SUB_DOMAIN" ]; then
        # 80 端口占用预检
        if lsof -i:80 -P -n -sTCP:LISTEN >/dev/null 2>&1; then
            local proc
            proc=$(lsof -i:80 -P -n -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | head -n1)
            echo -e "${ERR} 80 端口当前被 ${proc} 占用，Certbot 无法完成 HTTP-01 验证。"
            echo -e "       请释放 80 端口后重新执行安装脚本。"
            exit 1
        fi

        _add_fw_rule 80 "$HAS_V4" "$HAS_V6"
        execute_task "netfilter-persistent save" "持久化防火墙规则 (80)" || exit 1

        execute_task \
            "apt-get install -y -qq certbot" \
            "安装 Certbot" || exit 1

        local cert_err
        cert_err=$(mktemp)
        _TEMP_FILES+=("$cert_err")

        printf "${INFO} 申请 Let's Encrypt 证书 (域名: ${SUB_DOMAIN})..." >/dev/tty
        certbot certonly --standalone \
            --non-interactive --agree-tos \
            --register-unsafely-without-email \
            -d "${SUB_DOMAIN}" >/dev/null 2>"$cert_err"
        local cert_exit=$?

        if [ $cert_exit -eq 0 ]; then
            printf "\r\033[K${OK} 申请 Let's Encrypt 证书 (域名: ${SUB_DOMAIN})\n" >/dev/tty
        else
            printf "\r\033[K${ERR} 证书申请失败\n" >/dev/tty
            echo -e "${RED}--- 错误详情 ---${PLAIN}"
            cat "$cert_err"
            echo -e "${RED}---------------${PLAIN}"

            if grep -qi "too many\|rate limit" "$cert_err"; then
                echo -e "${WARN} 原因：该域名申请次数已达 Let's Encrypt 频率限制（每周最多 5 次）。"
                echo -e "       请等待限制解除后重新执行安装脚本，或更换域名。"
            elif grep -qi "dns\|resolve\|NXDOMAIN\|no valid A\|no valid AAAA" "$cert_err"; then
                echo -e "${WARN} 原因：域名 DNS 解析未就绪，Certbot 无法验证域名所有权。"
                echo -e "       请确认 A/AAAA 记录已正确指向本机 IP，等待 DNS 生效后重新执行安装脚本。"
            elif grep -qi "timeout\|connection\|network" "$cert_err"; then
                echo -e "${WARN} 原因：网络连接超时，无法访问 Let's Encrypt 服务器。"
                echo -e "       请检查服务器出站网络后重新执行安装脚本。"
            elif grep -qi "port 80\|bind\|address already" "$cert_err"; then
                echo -e "${WARN} 原因：80 端口在申请过程中被占用，Certbot 无法启动临时验证服务器。"
                echo -e "       请释放 80 端口后重新执行安装脚本。"
            else
                echo -e "${WARN} 原因未能自动识别，请参考上方错误详情排查。"
            fi

            echo ""
            if _input_fallback_confirm; then
                SUB_DOMAIN=""
                echo "" > /usr/local/etc/xray/sub_domain
            else
                exit 1
            fi
        fi

        # 仅在证书申请成功时配置续期后置脚本
        if [ -n "$SUB_DOMAIN" ]; then
            mkdir -p /etc/letsencrypt/renewal-hooks/deploy
            cat > /etc/letsencrypt/renewal-hooks/deploy/restart-xray-sub.sh <<'HOOK_EOF'
#!/bin/bash
systemctl restart xray-sub
HOOK_EOF
            chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-xray-sub.sh
            printf "${OK} 配置证书续期并自动重启订阅服务\n" >/dev/tty
        fi
    fi

    # 回退至自签证书（证书申请失败回退 或 用户未填写域名）
    if [ -z "$SUB_DOMAIN" ]; then
        execute_task \
            "openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
             -keyout /usr/local/etc/xray/sub.key \
             -out /usr/local/etc/xray/sub.crt \
             -subj '/CN=xray-sub' \
             -addext 'subjectAltName=DNS:xray-sub' >/dev/null 2>&1 && \
             chmod 600 /usr/local/etc/xray/sub.key" \
            "生成订阅服务 TLS 证书 (自签名 3650天)" || exit 1
    fi

    # =========================================================
    # 部署并启动订阅服务
    # =========================================================
    cat > /etc/systemd/system/xray-sub.service <<EOF
[Unit]
Description=Xray Subscription Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/xray-sub-server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    execute_task \
        "systemctl daemon-reload
         systemctl enable xray-sub >/dev/null 2>&1
         systemctl restart xray-sub >/dev/null 2>&1" \
        "部署并启动订阅服务 (HTTPS: ${SUB_PORT_HTTPS})" || exit 1

    # =========================================================
    # 初始化 GeoData 规则库及自动更新任务
    # =========================================================
    execute_task \
        "curl -sLo /usr/local/share/xray/geoip.dat \
         https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
         curl -sLo /usr/local/share/xray/geosite.dat \
         https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
        "初始化 GeoData 规则库" || echo -e "${WARN} GeoData 初始化下载失败，将使用官方默认版本"

    execute_task \
        "(crontab -l 2>/dev/null | grep -v 'geoip\.dat\|geosite\.dat'; \
          echo '0 3 * * 1 curl -sLo /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && curl -sLo /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat && systemctl restart xray') | crontab -" \
        "注册 GeoData 每周自动更新任务 (周一 03:00)" || exit 1
}


# =============================================================
#  MAIN: 主流程
# =============================================================

# 权限校验、系统架构检测，不满足条件时提前终止
preflight_guard

# 展示安装说明并等待用户确认，输入 n 时中止安装
confirm_installation

# 交互式收集安装参数：SNI 域名、Vision 端口、XHTTP 端口、订阅域名
prompt_install_config

# 安装基础网络工具、检测 IPv4/IPv6 连通性、初始化时间同步
echo -e "\n${CYAN}>>> 1. 基础环境配置 (Basic Env)${PLAIN}"
preflight_check
check_net_stack
setup_base_env

# 更新系统软件包、安装依赖组件、安装 Xray Core
core_install

# 配置防火墙放行规则、启动 Fail2ban、创建 Swap、写入内核优化参数
setup_firewall_and_security

# 生成 UUID、密钥对、Short ID，写入 Xray 配置文件并验证语法
core_config

# 部署 info 管理脚本、订阅服务及证书、GeoData 规则库与自动更新任务
deploy_tools

# 设置 Xray 开机自启并立即启动服务
echo -e "\n${CYAN}>>> 6. 启动 Xray 服务${PLAIN}"
execute_task \
    "systemctl enable xray >/dev/null 2>&1 && systemctl restart xray >/dev/null 2>&1" \
    "启动 Xray 服务" || exit 1

# 安装完成，输出节点配置信息与订阅地址
bash /usr/local/bin/info
