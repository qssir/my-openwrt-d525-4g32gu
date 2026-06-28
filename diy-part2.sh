#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Optimized for Intel Atom D525 + USB 3.0 U-disk Boot Topology

# =====================================================================
# 1. 基础系统与管理权对齐 (IP / 密码 / 主题)
# =====================================================================
# 修改默认后台管理 IP 为 192.168.2.1
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# 修改默认密码为 password
sed -i 's/root:::0:99999:7:::/root:$1$O9mCis8O$8GPrlP7QpE1mQ79fI2n64\.:18888:0:99999:7:::/g' package/base-files/files/etc/shadow

# 【核心修复】使用安全的 uci-defaults 注入法切换 Argon 主题，绝不破坏 LuCI 编译树
mkdir -p files/etc/uci-defaults
cat << 'EOF' > files/etc/uci-defaults/30_luci-theme-argon
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/30_luci-theme-argon


# =====================================================================
# 2. 🛡️ 慢速 U盘与无 AES-NI 硬件加解密 CPU 的控流与隔离优化
# =====================================================================

# 2.1 注入安全 sysctl 内核参数（降低脏页比率，防慢速 I/O 挂起死机）
mkdir -p files/etc/sysctl.d
cat << 'EOF' > files/etc/sysctl.d/99-u-disk-media-optimize.conf
# 开启 BBR 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 适度扩展网络套接字读写缓冲区（兼顾4G内存，不盲目冲高占用）
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# 核心安全补丁：严格限制内存脏页产生，强制内核频繁小额写入，防止慢速 U盘被大写操作瞬时锁死
vm.dirty_background_ratio=3
vm.dirty_ratio=5
vm.vfs_cache_pressure=60
EOF


# 2.2 深度优化 Samba4 传输配置文件 (开启多线程异步，减轻 D525 核心排队压力)
SMB_CONF="feeds/luci/applications/luci-app-samba4/root/etc/config/samba4"
if [ -f "$SMB_CONF" ]; then
    sed -i "/config samba/a \\\tlist server_multi_channel_support 'yes'" $SMB_CONF
    sed -i "/config samba/a \\\tlist rpc_daemon_smbd 'embedded'" $SMB_CONF
    sed -i "/config samba/a \\\tlist aio_read_size '4096'" $SMB_CONF
    sed -i "/config samba/a \\\tlist aio_write_size '4096'" $SMB_CONF
    sed -i "/config samba/a \\\tlist read_raw 'yes'" $SMB_CONF
    sed -i "/config samba/a \\\tlist write_raw 'yes'" $SMB_CONF
    sed -i "/config samba/a \\\tlist use_sendfile 'yes'" $SMB_CONF
fi


# 2.3 注入开机自启脚本补丁（精准调整 U盘 块设备预读与队列调度器）
mkdir -p files/etc/init.d
cat << 'EOF' > files/etc/init.d/media_io_init
#!/bin/sh /etc/rc.common
START=99

start() {
    # 针对慢速金士顿 U盘/移动硬盘(sda, sdb等)，设置稳健的 2MB 顺序预读 (4096 sectors)
    # 强制启用 mq-deadline 调度器，确保网络代理和路由系统包交换的最高 I/O 优先级
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


# 2.4 注入定时计划任务 (每天凌晨 04:30 强行释放缓存，防止 AList 挂载大文件产生内存泄漏)
mkdir -p files/etc/crontabs
cat << 'EOF' >> files/etc/crontabs/root
30 4 * * * sync && echo 3 > /proc/sys/vm/drop_caches
EOF
