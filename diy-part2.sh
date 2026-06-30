#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Tailored for Intel Atom D525 (No AES-NI, High Temperature) + 32G Kingston U-disk

# =====================================================================
# 1. 基础系统与管理权对齐 (IP / 密码 / 主题)
# =====================================================================
# 修改默认后台管理 IP 为 192.168.2.1
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# 修改默认密码为 password
sed -i 's/root:::0:99999:7:::/root:$1$O9mCis8O$8GPrlP7QpE1mQ79fI2n64\.:18888:0:99999:7:::/g' package/base-files/files/etc/shadow

# 使用安全的 uci-defaults 注入法切换 Argon 主题
mkdir -p files/etc/uci-defaults
cat << 'EOF' > files/etc/uci-defaults/30_luci-theme-argon
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/30_luci-theme-argon


# =====================================================================
# 2. 🛡️ 针对 D525 高温无 AES-NI 核心与 U盘块设备的底层性能调优
# =====================================================================

# 2.1 注入安全 sysctl 内核参数（严格限制脏页刷盘比率，扩展无 AES 状态下的网络队列容错率）
mkdir -p files/etc/sysctl.d
cat << 'EOF' > files/etc/sysctl.d/99-atom-d525-u-disk-optimize.conf
# 开启 BBR 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# D525 缺乏硬件加解密，适度拉高网络接收处理队列大小，防止高并发时系统直接丢包断网
net.core.netdev_max_backlog=5000

# 严格限制内存脏页产生，强迫内核小额高频慢写，防止慢速金士顿 U盘被连续的大文件写操作瞬时阻断 I/O
vm.dirty_background_ratio=3
vm.dirty_ratio=5
vm.vfs_cache_pressure=60
EOF


# 2.2 深度优化 Samba4 传输配置文件 (开启多线程异步，减轻老双核 D525 的串行排队热量)
SMB_CONF="feeds/luci/applications/luci-app-samba4/root/etc/config/samba4"
if [ -f "$SMB_CONF" ]; then
    sed -i "/config samba/a \\\tlist server_multi_channel_support 'yes'" $SMB_CONF
    sed -i "/config samba/a \\\tlist rpc_daemon_smbd 'embedded'" $SMB_CONF
    sed -i "/config samba/a \\\tlist aio_read_size '4096'" $SMB_CONF
    sed -i "/config samba/a \\\tlist aio_write_size '4096'" $SMB_CONF
    sed -i "/config samba/a \\\tlist use_sendfile 'yes'" $SMB_CONF
fi


# 2.3 注入开机自启脚本补丁（精准限制 U盘 块设备预读为稳健的 2MB，并锁死 mq-deadline 调度器）
mkdir -p files/etc/init.d
cat << 'EOF' > files/etc/init.d/media_io_init
#!/bin/sh /etc/rc.common
START=99

start() {
    # 针对慢速金士顿 U盘存储介质，设置温和顺序预读缓冲区 (4096 sectors = 2MB)
    # 强制为 sda 启用 mq-deadline 调度器，确保网络封包分流具有最高 I/O 响应优先级
    for dev in sda sdb; do
        if [ -b "/dev/$dev" ]; then
            echo "mq-deadline" > /sys/block/$dev/queue/scheduler 2>/dev/null || true
            blockdev --setra 4096 /dev/$dev 2>/dev/null || true
        fi
    done
    
    # 确保内核成功加载 tcp_bbr 模块
    modprobe tcp_bbr 2>/dev/null || true
}
EOF
chmod +x files/etc/init.d/media_io_init


# 2.4 注入定时任务 (每天凌晨 04:30 强行释放缓存，防止 AList 挂载网盘时将 4GB 物理内存占满引发系统死机)
mkdir -p files/etc/crontabs
cat << 'EOF' >> files/etc/crontabs/root
30 4 * * * sync && echo 3 > /proc/sys/vm/drop_caches
EOF
