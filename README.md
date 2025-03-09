# Smart-Route 智能路由方案

一个功能完整的智能路由解决方案，提供透明代理、智能分流、DNS保护和WireGuard VPN服务。该项目专为需要高级网络控制和智能分流的用户设计。

## 项目概述

Smart-Route 提供以下核心功能：

1. **透明代理**：使用TPROXY模式，无需客户端配置即可自动代理所有TCP流量
2. **智能分流**：支持中国IP直连，海外流量走代理的模式
3. **多协议支持**：TCP全局代理，UDP支持多种代理模式
4. **DNS保护**：DNS查询强制走代理以保护隐私
5. **IPv6支持**：自动检测并配置IPv6透明代理
6. **WireGuard VPN**：提供安全的VPN接入功能
7. **多出站支持**：不同类型流量走不同出站（如AI相关域名走美国节点）

## 项目组件

### 核心组件

1. **V2Ray/Xray**：作为主要代理引擎，处理透明代理流量
2. **iptables/ip6tables**：配置透明代理规则和路由功能
3. **WireGuard**：提供VPN接入功能
4. **dnsmasq**：提供本地DNS解析服务

### 脚本说明

1. **bin/setup-tproxy.sh**：配置透明代理的主要脚本
   - 自动设置iptables规则
   - 配置策略路由
   - 支持多种UDP代理模式
   - 处理IPv4/IPv6流量

2. **bin/test-proxy.sh**：测试代理连接质量的工具
   - 测试国内外网站连接
   - 测试ChatGPT、Claude等AI服务的CDN连接
   - 支持HTTP/1.1、HTTP/2和HTTP/3测试

3. **bin/clean-rule.sh**：清理iptables规则的工具
   - 删除重复的iptables规则
   - 保持规则文件结构完整性
   - 包含安全备份功能

### 配置文件

1. **usr/local/etc/v2ray/config.json**：V2Ray配置
   - 多出站配置：香港、美国节点分流
   - 特定域名和地区智能分流
   - 内置DNS服务器配置

2. **etc/dnsmasq.conf**：DNS服务配置
   - 使用本地V2Ray的DNS服务作为上游
   - 缓存设置优化
   - 安全配置防止DNS泄漏

3. **etc/wireguard/wg0.conf**：WireGuard VPN配置
   - 服务器接口配置
   - 对等节点配置
   - 网络和IP分配配置

## 部署指南

### 系统要求

- Debian/Ubuntu系统
- root权限
- 已安装V2Ray/Xray
- 已安装WireGuard（可选）

### 安装步骤

1. **准备工作**
   ```bash
   apt update
   apt install -y curl iptables ipset dnsmasq wireguard
   ```

2. **设置V2Ray/Xray**
   ```bash
   # 创建配置目录
   mkdir -p /usr/local/etc/v2ray
   
   # 编辑配置文件，替换敏感信息
   nano /usr/local/etc/v2ray/config.json
   ```

3. **设置透明代理**
   ```bash
   # 给脚本执行权限
   chmod +x bin/setup-tproxy.sh
   
   # 运行脚本
   ./bin/setup-tproxy.sh
   ```

4. **设置WireGuard（可选）**
   ```bash
   # 创建配置目录
   mkdir -p /etc/wireguard
   
   # 编辑配置文件，替换密钥信息
   nano /etc/wireguard/wg0.conf
   
   # 启用WireGuard
   wg-quick up wg0
   systemctl enable wg-quick@wg0
   ```

5. **设置DNS服务**
   ```bash
   # 编辑配置文件
   nano /etc/dnsmasq.conf
   
   # 重启服务
   systemctl restart dnsmasq
   systemctl enable dnsmasq
   ```

### 测试配置

运行测试脚本检查代理是否正常工作：
```bash
chmod +x bin/test-proxy.sh
./bin/test-proxy.sh
```

### 清理规则

如果iptables规则变得混乱，可以使用清理脚本：
```bash
chmod +x bin/clean-rule.sh
./bin/clean-rule.sh
```

## 客户端使用说明

### 透明代理模式（局域网设备）

要让局域网中的设备使用智能路由的透明代理功能，只需按以下步骤配置网络：

1. **自动获取IP（推荐）**
   - 将设备的网络设置为DHCP自动获取IP地址
   - 确保设备连接到智能路由所在的局域网

2. **手动配置**
   - IP地址：设置为局域网中的可用IP地址
   - 子网掩码：255.255.255.0
   - 默认网关：设置为智能路由服务器的IP地址
   - DNS服务器：设置为智能路由服务器的IP地址

3. **验证连接**
   - 尝试访问国内外网站测试连接
   - 使用`curl ipinfo.io`或访问IP查询网站确认出口IP

### WireGuard VPN模式（远程设备）

对于需要在外部网络使用智能路由功能的设备：

1. **获取WireGuard配置**
   - 从WireGuard UI管理界面下载客户端配置文件
   - 或手动从服务器复制客户端配置

2. **安装WireGuard客户端**
   - Windows/macOS：从[官方网站](https://www.wireguard.com/install/)下载安装
   - iOS：从App Store安装WireGuard客户端
   - Android：从Google Play商店安装WireGuard客户端

3. **导入配置**
   - 将配置文件导入客户端
   - 或扫描WireGuard UI生成的二维码

4. **连接VPN**
   - 激活WireGuard连接
   - 连接成功后，流量将通过智能路由分流

## WireGuard UI 管理工具

推荐使用[WireGuard UI](https://github.com/ngoduykhanh/wireguard-ui)来简化WireGuard客户端管理。

### 安装和使用

1. **安装方法**
   ```bash
   # 使用Docker安装
   docker pull ngoduykhanh/wireguard-ui
   docker run -d --name wg-ui -p 5000:5000 -v /etc/wireguard:/etc/wireguard --cap-add=NET_ADMIN --restart unless-stopped ngoduykhanh/wireguard-ui
   ```

2. **使用方法**
   - 访问 `http://[服务器IP]:5000` (默认用户名/密码: admin/admin)
   - 配置服务器，添加客户端，并生成配置文件或二维码

## 自定义配置

### 修改UDP代理模式

编辑 `bin/setup-tproxy.sh` 文件，修改 `UDP_PROXY_MODE` 变量：
- `0` = 全部代理（所有UDP流量走代理）
- `1` = 智能分流（中国IP直连，国外IP走代理）
- `2` = 直连模式（除DNS外所有UDP直连不走代理）

### 修改直连域名列表

编辑 `bin/setup-tproxy.sh` 文件，修改 `DIRECT_DOMAINS` 数组。

### 修改V2Ray出站配置

编辑 `usr/local/etc/v2ray/config.json` 文件，修改或添加出站配置和路由规则。

## 安全提醒

使用前，请确保替换所有配置文件中的敏感信息：
- V2Ray配置中的密码
- WireGuard配置中的私钥、公钥和预共享密钥

## 故障排除

1. **网络连接问题**
   - 检查iptables规则是否正确加载
   - 验证V2Ray服务是否正常运行
   - 使用 `bin/test-proxy.sh` 检查代理可用性

2. **DNS泄漏问题**
   - 确保dnsmasq配置正确
   - 检查V2Ray DNS配置

3. **规则重置**
   - 重启后规则未加载：确认透明代理服务已启用
   - 使用 `bin/clean-rule.sh` 清理并重新应用规则 