### ⚠️ 免责与风险声明 (Disclaimer & Risk Warning)

1. **环境差异**：本调优参数基于特定硬件环境（如 1GB 内存配置）草拟。不同服务器的硬件配置、网络架构及业务负载各不相同。**吾之蜜糖，汝之砒霜**，切勿盲目照搬。
2. **潜在风险**：修改系统内核网络参数（sysctl）属于高风险操作。激进的参数调整（尤其是内存限制相关的 `rmem` 和 `wmem`）可能导致服务器内存溢出（OOM）、网络连接中断或系统内核崩溃。
3. **责任自负**：本示例仅供学习和参考。作者不对使用上述配置所产生的任何直接或间接后果（包括但不限于服务器宕机、服务中断、数据丢失）承担任何责任。
4. **强烈建议**：在生产环境应用任何更改之前，请务必：
   - 充分理解每一行参数的实际含义。
   - 备份当前的系统配置。
   - 先在测试环境中进行压力测试和全面验证。

### eg0
```bash
cat > /etc/sysctl.d/99-custom-network.conf <<EOF
# 启用 BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 优化内存限制
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432

# 全局 TCP 内存限制 (针对 1GB 内存系统安全线) (最高约 256MB)
net.ipv4.tcp_mem = 32768 49152 65536

# 规模队列
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 4096
EOF

# 立即应用配置
sysctl -p /etc/sysctl.d/99-custom-network.conf

```

### eg1: 单用户
```bash
cat > /etc/sysctl.d/99-custom-network.conf <<EOF
# 启用 BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 优化内存限制：追求单线程极限速度 (约 25MB 缓冲区)
net.core.rmem_max = 25000000
net.core.wmem_max = 25000000
net.ipv4.tcp_rmem = 4096 131072 25000000
net.ipv4.tcp_wmem = 4096 131072 25000000

# 全局 TCP 内存限制 (针对 1GB 内存系统安全线) (最高约 256MB)
net.ipv4.tcp_mem = 32768 49152 65536

# 保持中等规模队列，适合单用户环境
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.core.netdev_max_backlog = 1024
EOF

# 立即应用配置
sysctl -p /etc/sysctl.d/99-custom-network.conf

```

### eg2: 多用户
```bash
cat > /etc/sysctl.d/99-custom-network.conf <<EOF
# 启用 BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 严格限制单连接最大使用约 4MB (4194304 bytes) 内存，防止个别连接榨干系统
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 16384 4194304

# 全局 TCP 内存保持在 1GB 系统的安全线 (最高约 256MB)
net.ipv4.tcp_mem = 32768 49152 65536

# 适度增加队列以应对多用户的突发连接请求
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 2048
net.core.netdev_max_backlog = 2048
EOF

# 立即应用配置
sysctl -p /etc/sysctl.d/99-custom-network.conf

```
