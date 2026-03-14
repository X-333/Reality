#!/bin/bash

# --- 1. 系统环境强制检查 ---
if [ ! -f /etc/debian_version ]; then
    echo -e "\033[31mError: 本脚本仅支持 Debian 或 Ubuntu 系统！CentOS/RedHat 请勿运行。\033[0m"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "\033[31mError: This script must be run as root!\033[0m"
    exit 1
fi

clear
echo "开始全自动化部署..."

# --- 1. 系统初始化 ---
timedatectl set-timezone Asia/Shanghai
export DEBIAN_FRONTEND=noninteractive

echo "更新系统并安装依赖 (此过程可能需要几分钟)..."
apt-get update -qq
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

# 安装核心依赖
DEPENDENCIES="curl wget sudo nano git htop tar unzip socat fail2ban rsyslog chrony iptables qrencode"
apt-get install -y $DEPENDENCIES

# Fail2ban 配置
cat > /etc/fail2ban/jail.local << 'FAIL2BAN_EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
findtime  = 86400
maxretry = 3
bantime  = 86400
backend = systemd
banaction = iptables-multiport
bantime.increment = true
[sshd]
enabled = true
port    = ssh
mode    = aggressive
FAIL2BAN_EOF

# 确保服务启动
systemctl restart rsyslog || echo "Rsyslog restart skipped"
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# --- 2. 内核优化 ---
sed -i 's/^#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab > /dev/null
fi
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

# --- 3. 安装 Xray ---
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata
mkdir -p /usr/local/share/xray/
wget -q -O /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
wget -q -O /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

# --- 4. 生成配置 ---
XRAY_BIN="/usr/local/bin/xray"
SNI_HOST="www.icloud.com"

echo "正在生成身份凭证..."
UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $2}')
# 兼容抓取 Public Key 或 Password
PUBLIC_KEY=$(echo "$KEYS" | grep -E "Public|Password" | awk '{print $2}')
SHORT_ID=$(openssl rand -hex 8)

mkdir -p /usr/local/etc/xray/
cat > /usr/local/etc/xray/config.json <<CONFIG_EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": [ "localhost" ] },
  "inbounds": [
    {
      "port": 443,
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
          "shortIds": [ "${SHORT_ID}" ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": [ "geoip:private", "geoip:cn" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
CONFIG_EOF

# --- 5. 部署工具 ---
mkdir -p /etc/systemd/system/xray.service.d
echo -e "[Service]\nLimitNOFILE=infinity\nLimitNPROC=infinity\nTasksMax=infinity\nRestart=on-failure\nRestartSec=5" > /etc/systemd/system/xray.service.d/override.conf
systemctl daemon-reload
sed -i 's/^#SystemMaxUse=/SystemMaxUse=200M/g' /etc/systemd/journald.conf
systemctl restart systemd-journald

echo -e "#!/bin/bash\nwget -q -O /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat\nwget -q -O /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat\nsystemctl restart xray" > /usr/local/bin/update_geoip.sh && chmod +x /usr/local/bin/update_geoip.sh
(crontab -l 2>/dev/null; echo "0 4 * * 2 /usr/local/bin/update_geoip.sh >/dev/null 2>&1") | sort -u | crontab -

iptables -I INPUT -p tcp -m multiport --dports 22,80,443,5555,8008,8443 -j ACCEPT

# --- 6. 结果输出 ---
IPV4=$(curl -s4 ip.sb)
HOST_TAG=$(hostname | tr ' ' '.')
if [ -z "$HOST_TAG" ]; then HOST_TAG="XrayServer"; fi

LINK="vless://${UUID}@${IPV4}:443?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI_HOST}&sid=${SHORT_ID}#${HOST_TAG}"

echo ""
echo -e "\033[32m部署成功 \033[0m"
echo ""
echo " 配置信息:"
echo -e "IPv4       : \033[36m${IPV4}\033[0m"
echo -e "Port       : \033[36m443\033[0m"
echo -e "SNI        : \033[36m${SNI_HOST}\033[0m"
echo -e "ShortId    : \033[36m${SHORT_ID}\033[0m"
echo -e "UUID       : \033[36m${UUID}\033[0m"
echo -e "Public Key : \033[36m${PUBLIC_KEY}\033[0m"
echo ""
echo -e "\033[33m链接:\033[0m"
echo -e "\033[32m${LINK}\033[0m"
echo ""
echo -e "\033[33mQR码:\033[0m"
qrencode -t ANSIUTF8 "${LINK}"
echo ""

