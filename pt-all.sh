#!/bin/bash
# =====================================================
# PT 刷流优化一键脚本 (IO + TCP + Limits + NIC + 加速器 + qBittorrent)
# 自动识别磁盘和网卡设备 + 自动安装 qBittorrent 并开机自启
# 适用: Debian / Ubuntu
# =====================================================

set -e

# 自动识别第一个磁盘（排除 loop/ram）
DEVICE=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1; exit}')
# 自动识别默认网卡（取默认路由的接口）
NETDEV=$(ip route | awk '/default/ {print $5; exit}')

echo "检测到磁盘设备: ${DEVICE}"
echo "检测到网卡设备: ${NETDEV}"

echo ">>> [1/7] 配置 IO 调度器 & 预读..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-io-scheduler.rules <<EOF
ACTION=="add|change", KERNEL=="${DEVICE}", ATTR{queue/scheduler}="none"
EOF
blockdev --setra 4096 /dev/${DEVICE}
echo 2 > /sys/block/${DEVICE}/queue/rq_affinity
echo "✅ IO 优化完成 (设备: ${DEVICE})"

echo ">>> [2/7] 应用 TCP/内核优化参数..."
cat > /etc/sysctl.d/99-pt-opt.conf <<EOF
# --- PT 刷流 TCP 优化 ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.netfilter.nf_conntrack_max = 262144
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 10240 65535
EOF
sysctl --system
echo "✅ TCP 内核参数优化完成"

echo ">>> [3/7] 配置文件句柄数..."
cat > /etc/security/limits.d/99-nofile.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
EOF
echo "✅ 文件句柄数已提升到 1048576"

echo ">>> [4/7] 配置网卡 offload..."
apt-get update -y && apt-get install -y ethtool wget curl ca-certificates
ethtool -K ${NETDEV} tso off gso off gro off

cat > /etc/systemd/system/disable-offload.service <<EOF
[Unit]
Description=Disable NIC Offload
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -K ${NETDEV} tso off gso off gro off

[Install]
WantedBy=multi-user.target
EOF
systemctl enable disable-offload
echo "✅ 网卡 offload 已关闭并开机自启"

echo ">>> [5/7] 选择安装 TCP 加速器 (BBR/BBRv2/锐速-LotServer)"
echo " 1) BBR (原版)"
echo " 2) BBRv2 (推荐)"
echo " 3) 锐速 / LotServer"
echo " 0) 跳过"
read -p "请选择 [0-3]: " choice

install_bbr() {
    echo ">>> 安装原版 BBR..."
    modprobe tcp_bbr || true
    echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
    cat >> /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system
    echo "✅ 已启用 BBR"
}

install_bbr2() {
    echo ">>> 安装 BBRv2..."
    modprobe tcp_bbr || true
    echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
    cat >> /etc/sysctl.d/99-bbr2.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr2
EOF
    sysctl --system
    echo "✅ 已启用 BBRv2"
}

install_lotserver() {
    echo ">>> 安装锐速 LotServer..."
    wget -qO- https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh | bash
}

case $choice in
    1) install_bbr ;;
    2) install_bbr2 ;;
    3) install_lotserver ;;
    0) echo ">>> 跳过加速器安装" ;;
    *) echo "输入无效，跳过" ;;
esac

echo ">>> [6/7] 安装并配置 qBittorrent..."
DOWNLOAD_URL="https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-4.3.9_v1.2.15/x86_64-qbittorrent-nox"
INSTALL_PATH="/root/x86_64-qbittorrent-nox"
SERVICE_FILE="/etc/systemd/system/qbittorrent.service"

cd /root
wget -O x86_64-qbittorrent-nox "$DOWNLOAD_URL"
chmod +x x86_64-qbittorrent-nox

# 运行一次以生成默认配置
./x86_64-qbittorrent-nox <<< "y" &
sleep 2
pkill -f x86_64-qbittorrent-nox || true

# 创建 Systemd 服务文件
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=qBittorrent Daemon Service
After=network.target

[Service]
LimitNOFILE=512000
User=root
ExecStart=$INSTALL_PATH
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 重新加载并启动
systemctl daemon-reload
systemctl enable --now qbittorrent
echo "✅ qBittorrent 已安装并配置开机自启"

echo ">>> [7/7] 优化全部完成 ✅"
echo "建议重启服务器以确保所有配置生效"
echo "----------------------------------------------------"
echo "qBittorrent 已成功安装和配置"
echo "默认 WebUI 访问: http://<服务器公网IP>:8080"
echo "默认用户名: admin"
echo "默认密码: adminadmin"
