#!/bin/bash

#############################################################
# 智能TPROXY模式透明代理路由器脚本 (优化版)
#############################################################
# 功能：
# 1. 路由器功能：支持其他设备连接此设备作为代理网关
# 2. 透明代理：使用TPROXY模式，自动转发流量无需客户端配置
# 3. TCP流量处理：所有TCP流量通过代理服务器 
# 4. UDP流量处理：多种模式可选，DNS始终优先通过代理
# 5. DNS保护：DNS查询强制走代理保证隐私
# 6. IPv6支持：自动检测并配置IPv6透明代理
# 7. 直连域名：可配置特定域名直接连接而不经过代理
# 8. 性能优化：批量添加IP规则，缓存IP列表，启动优化
# 9. 启动可靠性：增强的启动序列和自动修复机制
#############################################################

#############################################################
# 配置选项（修改这些值以自定义行为）
#############################################################

# UDP代理模式
# 0 = 全部代理（所有UDP流量走代理）
# 1 = 智能分流（中国IP直连，国外IP走代理）
# 2 = 直连模式（除DNS外所有UDP直连不走代理）
# 注意：无论选择哪种模式，DNS查询始终通过代理以保护隐私
UDP_PROXY_MODE=2

# V2Ray透明代理端口
V2RAY_PORT=1080

# 流量标记
DIRECT_MARK=255         # 直连流量标记
PROXY_MARK=0x07         # 代理流量标记

# 策略路由表号
PROXY_ROUTE_TABLE=310

# 中国IP地址段的ipset名称
CHINA_IPSET_NAME="chnroute"

# 直连域名列表 - 这些域名将直接连接而不经过代理
DIRECT_DOMAINS=("hk.example.com" "us.example.com")

#############################################################
# 初始化
#############################################################

echo "[INFO] 开始配置透明代理路由器..."

# 检查是否以root运行
if [ "$(id -u)" != "0" ]; then
   echo "[错误] 此脚本必须以root权限运行" 
   exit 1
fi

# 检查并安装必要的工具
command -v ipset &>/dev/null || {
    echo "[INFO] 安装 ipset..."
    apt update &>/dev/null && apt install -y ipset &>/dev/null || {
        echo "[错误] 无法安装 ipset，请手动安装后重试"
        exit 1
    }
}

command -v curl &>/dev/null || {
    echo "[INFO] 安装 curl..."
    apt update &>/dev/null && apt install -y curl &>/dev/null || {
        echo "[错误] 无法安装 curl，请手动安装后重试"
        exit 1
    }
}

# 创建持久化目录
IPLIST_DIR="/etc/v2ray/iplist"
mkdir -p "$IPLIST_DIR"

#############################################################
# 网络接口检测
#############################################################

# 获取主网络接口
MAIN_INTERFACE=$(ip route | grep default | head -n1 | awk '{print $5}')
if [ -z "$MAIN_INTERFACE" ]; then
    echo "[警告] 无法检测到默认网络接口"
    echo -n "请输入外网接口名称 (例如: eth0): "
    read MAIN_INTERFACE
fi
echo "[INFO] 使用网络接口: $MAIN_INTERFACE"

# 获取本机IP地址
LOCAL_IP=$(ip addr show $MAIN_INTERFACE | grep -w inet | awk '{print $2}' | cut -d/ -f1)
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$LOCAL_IP" ]; then
        echo -n "[警告] 无法获取本机IP地址，请手动输入: "
        read LOCAL_IP
    fi
fi
echo "[INFO] 本机IP地址: $LOCAL_IP"

# 检查IPv6支持
IPV6_SUPPORTED=1
if ! test -f /proc/sys/net/ipv6/conf/all/disable_ipv6 || [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
    echo "[INFO] IPv6已被禁用或不受支持，将只配置IPv4"
    IPV6_SUPPORTED=0
fi

# 检查ip6tables是否可用
if [ $IPV6_SUPPORTED -eq 1 ] && ! command -v ip6tables &>/dev/null; then
    echo "[INFO] 未找到ip6tables命令，将只配置IPv4"
    IPV6_SUPPORTED=0
fi

# 检查TPROXY模块
if ! lsmod | grep -q "xt_TPROXY"; then
    echo "[INFO] 加载TPROXY模块..."
    modprobe xt_TPROXY || echo "[警告] TPROXY模块加载失败，功能可能受限"
fi

#############################################################
# 清理现有规则
#############################################################

echo "[INFO] 清理现有网络规则..."

# 清理IPv4规则
iptables -t nat -D PREROUTING -j V2RAY 2>/dev/null
iptables -t nat -D OUTPUT -j V2RAY_MARK 2>/dev/null
iptables -t nat -F V2RAY 2>/dev/null
iptables -t nat -F V2RAY_MARK 2>/dev/null
iptables -t nat -X V2RAY 2>/dev/null
iptables -t nat -X V2RAY_MARK 2>/dev/null

iptables -t mangle -D PREROUTING -j V2RAY_TPROXY 2>/dev/null
iptables -t mangle -D OUTPUT -j V2RAY_TPROXY_MARK 2>/dev/null
iptables -t mangle -F V2RAY_TPROXY 2>/dev/null
iptables -t mangle -F V2RAY_TPROXY_MARK 2>/dev/null
iptables -t mangle -X V2RAY_TPROXY 2>/dev/null
iptables -t mangle -X V2RAY_TPROXY_MARK 2>/dev/null

# 清理IPv6规则（如果支持）
if [ $IPV6_SUPPORTED -eq 1 ]; then
    ip6tables -t nat -D PREROUTING -j V2RAY6 2>/dev/null
    ip6tables -t nat -D OUTPUT -j V2RAY_MARK6 2>/dev/null
    ip6tables -t nat -F V2RAY6 2>/dev/null
    ip6tables -t nat -F V2RAY_MARK6 2>/dev/null
    ip6tables -t nat -X V2RAY6 2>/dev/null
    ip6tables -t nat -X V2RAY_MARK6 2>/dev/null
    
    ip6tables -t mangle -D PREROUTING -j V2RAY_TPROXY6 2>/dev/null
    ip6tables -t mangle -D OUTPUT -j V2RAY_TPROXY_MARK6 2>/dev/null
    ip6tables -t mangle -F V2RAY_TPROXY6 2>/dev/null
    ip6tables -t mangle -F V2RAY_TPROXY_MARK6 2>/dev/null
    ip6tables -t mangle -X V2RAY_TPROXY6 2>/dev/null
    ip6tables -t mangle -X V2RAY_TPROXY_MARK6 2>/dev/null
fi

# 清理ipset
ipset destroy $CHINA_IPSET_NAME 2>/dev/null

# 清理策略路由
ip rule del fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE 2>/dev/null
ip route del local 0.0.0.0/0 dev lo table $PROXY_ROUTE_TABLE 2>/dev/null

if [ $IPV6_SUPPORTED -eq 1 ]; then
    ip -6 rule del fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE 2>/dev/null
    ip -6 route del local ::/0 dev lo table $PROXY_ROUTE_TABLE 2>/dev/null
fi

#############################################################
# 解析直连域名
#############################################################

echo "[INFO] 解析直连域名..."
declare -A DIRECT_IPS
declare -A DIRECT_IP6S

for domain in "${DIRECT_DOMAINS[@]}"; do
    # 获取IPv4地址
    IP=$(host $domain 2>/dev/null | grep "has address" | awk '{print $4}')
    if [ -z "$IP" ]; then
        IP=$(dig +short $domain 2>/dev/null)
        if [ -z "$IP" ]; then
            IP=$(nslookup $domain 2>/dev/null | grep Address | tail -n1 | awk '{print $2}')
        fi
    fi

    if [ -n "$IP" ]; then
        DIRECT_IPS[$domain]=$IP
        echo "[INFO] $domain -> IPv4: ${DIRECT_IPS[$domain]} (直连)"
    fi

    # 获取IPv6地址(如果支持)
    if [ $IPV6_SUPPORTED -eq 1 ]; then
        IP6=$(host -t AAAA $domain 2>/dev/null | grep "IPv6 address" | awk '{print $5}')
        if [ -z "$IP6" ]; then
            IP6=$(dig +short AAAA $domain 2>/dev/null)
        fi
        
        if [ -n "$IP6" ]; then
            DIRECT_IP6S[$domain]=$IP6
            echo "[INFO] $domain -> IPv6: ${DIRECT_IP6S[$domain]} (直连)"
        fi
    fi
done

#############################################################
# 配置路由器功能
#############################################################

echo "[INFO] 配置路由器功能..."

# 启用IP转发
echo 1 > /proc/sys/net/ipv4/ip_forward

if [ $IPV6_SUPPORTED -eq 1 ]; then
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
fi

# 配置NAT
iptables -t nat -C POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE 2>/dev/null || 
    iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

if [ $IPV6_SUPPORTED -eq 1 ]; then
    if ip6tables -t nat -L 2>/dev/null; then
        ip6tables -t nat -C POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE 2>/dev/null || 
            ip6tables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
    fi
fi

#############################################################
# 下载并加载中国IP列表
#############################################################

if [ $UDP_PROXY_MODE -eq 1 ]; then
    echo "[INFO] 配置中国IP智能分流..."
    
    # 创建ipset
    ipset create $CHINA_IPSET_NAME hash:net family inet hashsize 1024 maxelem 65536
    
    # 检查是否需要下载中国IP列表
    CHNROUTE_FILE="$IPLIST_DIR/chnroute.txt"
    CHNROUTE_TIMESTAMP="$IPLIST_DIR/chnroute.timestamp"
    
    DOWNLOAD_REQUIRED=0
    if [ ! -f "$CHNROUTE_FILE" ]; then
        DOWNLOAD_REQUIRED=1
    elif [ -f "$CHNROUTE_TIMESTAMP" ]; then
        LAST_UPDATE=$(cat "$CHNROUTE_TIMESTAMP")
        CURRENT_TIME=$(date +%s)
        TIME_DIFF=$((CURRENT_TIME - LAST_UPDATE))
        if [ $TIME_DIFF -gt 86400 ]; then
            DOWNLOAD_REQUIRED=1
        fi
    else
        DOWNLOAD_REQUIRED=1
    fi
    
    # 下载中国IP列表
    if [ $DOWNLOAD_REQUIRED -eq 1 ]; then
        echo "[INFO] 下载中国IP列表..."
        if curl -s --connect-timeout 10 -o "$CHNROUTE_FILE.new" https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt || \
           curl -s --connect-timeout 10 -o "$CHNROUTE_FILE.new" https://ispip.clang.cn/all_cn.txt || \
           curl -s --connect-timeout 10 -o "$CHNROUTE_FILE.new" https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt; then
            
            if [ -s "$CHNROUTE_FILE.new" ]; then
                mv "$CHNROUTE_FILE.new" "$CHNROUTE_FILE"
                date +%s > "$CHNROUTE_TIMESTAMP"
            else
                rm -f "$CHNROUTE_FILE.new"
                if [ ! -f "$CHNROUTE_FILE" ]; then
                    touch "$CHNROUTE_FILE"
                fi
            fi
        else
            if [ ! -f "$CHNROUTE_FILE" ]; then
                touch "$CHNROUTE_FILE"
            fi
        fi
    fi
    
    # 批量添加IP到ipset
    if [ -s "$CHNROUTE_FILE" ]; then
        echo "[INFO] 加载中国IP列表到ipset..."
        TEMP_RESTORE_FILE=$(mktemp)
        echo "create $CHINA_IPSET_NAME-temp hash:net family inet hashsize 1024 maxelem 65536" > "$TEMP_RESTORE_FILE"
        sed -e "s/^/add $CHINA_IPSET_NAME-temp /" "$CHNROUTE_FILE" >> "$TEMP_RESTORE_FILE"
        echo "swap $CHINA_IPSET_NAME-temp $CHINA_IPSET_NAME" >> "$TEMP_RESTORE_FILE"
        echo "destroy $CHINA_IPSET_NAME-temp" >> "$TEMP_RESTORE_FILE"
        
        ipset restore -f "$TEMP_RESTORE_FILE"
        rm -f "$TEMP_RESTORE_FILE"
        
        IP_COUNT=$(ipset list $CHINA_IPSET_NAME | grep -c "^[0-9]")
        echo "[INFO] 已加载 $IP_COUNT 个中国IP段"
    fi
else
    case $UDP_PROXY_MODE in
        0)
            echo "[INFO] UDP代理模式：全部代理"
            ;;
        2)
            echo "[INFO] UDP代理模式：除DNS外直连"
            ;;
    esac
fi

#############################################################
# 配置TPROXY规则
#############################################################

echo "[INFO] 配置透明代理规则..."

# 配置策略路由 - 确保这些规则正确设置
ip rule add fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE pref 789
ip route add local 0.0.0.0/0 dev lo table $PROXY_ROUTE_TABLE

if [ $IPV6_SUPPORTED -eq 1 ]; then
    ip -6 rule add fwmark $PROXY_MARK table $PROXY_ROUTE_TABLE pref 789
    ip -6 route add local ::/0 dev lo table $PROXY_ROUTE_TABLE
fi

# 创建IPv4规则链
iptables -t mangle -N V2RAY_TPROXY
iptables -t mangle -N V2RAY_TPROXY_MARK

# 配置IPv4直连规则
iptables -t mangle -A V2RAY_TPROXY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 240.0.0.0/4 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d 255.255.255.255/32 -j RETURN
iptables -t mangle -A V2RAY_TPROXY -d $LOCAL_IP/32 -j RETURN

# 添加直连域名IP
for domain in "${!DIRECT_IPS[@]}"; do
    iptables -t mangle -A V2RAY_TPROXY -d ${DIRECT_IPS[$domain]}/32 -j RETURN
done

# DNS流量代理转发
iptables -t mangle -A V2RAY_TPROXY -p udp --dport 53 -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
iptables -t mangle -A V2RAY_TPROXY -p udp --dport 443 -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK

# TCP流量代理
iptables -t mangle -A V2RAY_TPROXY -p tcp -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK

# UDP流量处理
case $UDP_PROXY_MODE in
    0)
        # 模式0：所有UDP走代理
        iptables -t mangle -A V2RAY_TPROXY -p udp -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
        ;;
    1)
        # 模式1：智能模式，中国IP直连，国外IP走代理
        iptables -t mangle -A V2RAY_TPROXY -p udp -m set --match-set $CHINA_IPSET_NAME dst -j RETURN
        iptables -t mangle -A V2RAY_TPROXY -p udp -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
        ;;
    2)
        # 模式2：除DNS外所有UDP直连
        # 注意：DNS流量仍然通过代理（已在前面配置）
        # 这里无需添加规则，默认动作是ACCEPT，会直连
        ;;
esac

# 配置本地IPv4流量输出
iptables -t mangle -A V2RAY_TPROXY_MARK -m mark --mark $DIRECT_MARK -j RETURN
iptables -t mangle -A V2RAY_TPROXY_MARK -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A V2RAY_TPROXY_MARK -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A V2RAY_TPROXY_MARK -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A V2RAY_TPROXY_MARK -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY_TPROXY_MARK -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A V2RAY_TPROXY_MARK -d $LOCAL_IP/32 -j RETURN

# 添加直连域名IP到本地规则
for domain in "${!DIRECT_IPS[@]}"; do
    iptables -t mangle -A V2RAY_TPROXY_MARK -d ${DIRECT_IPS[$domain]}/32 -j RETURN
done

# 本地DNS查询使用代理
iptables -t mangle -A V2RAY_TPROXY_MARK -p udp --dport 53 -j MARK --set-mark $PROXY_MARK
iptables -t mangle -A V2RAY_TPROXY_MARK -p udp --dport 443 -j MARK --set-mark $PROXY_MARK


# 本地TCP流量使用代理
iptables -t mangle -A V2RAY_TPROXY_MARK -p tcp -j MARK --set-mark $PROXY_MARK

# 本地UDP流量处理
case $UDP_PROXY_MODE in
    0)
        # 模式0：所有UDP走代理
        iptables -t mangle -A V2RAY_TPROXY_MARK -p udp -j MARK --set-mark $PROXY_MARK
        ;;
    1)
        # 模式1：智能模式，中国IP直连，国外IP走代理
        iptables -t mangle -A V2RAY_TPROXY_MARK -p udp -m set --match-set $CHINA_IPSET_NAME dst -j RETURN
        iptables -t mangle -A V2RAY_TPROXY_MARK -p udp -j MARK --set-mark $PROXY_MARK
        ;;
    2)
        # 模式2：除DNS外所有UDP直连
        # 这里无需添加规则，默认不会设置MARK，流量会直连
        # DNS已经单独设置标记
        ;;
esac

# 应用IPv4规则
iptables -t mangle -A PREROUTING -j V2RAY_TPROXY
iptables -t mangle -A OUTPUT -j V2RAY_TPROXY_MARK

#############################################################
# IPv6 配置（如果支持）
#############################################################

if [ $IPV6_SUPPORTED -eq 1 ]; then
    echo "[INFO] 配置IPv6透明代理..."
    
    # 创建IPv6规则链
    ip6tables -t mangle -N V2RAY_TPROXY6
    ip6tables -t mangle -N V2RAY_TPROXY_MARK6
    
    # 配置IPv6直连规则
    ip6tables -t mangle -A V2RAY_TPROXY6 -d ::1/128 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY6 -d fc00::/7 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY6 -d fe80::/10 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY6 -d ff00::/8 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY6 -d 2001:db8::/32 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY6 -d 64:ff9b::/96 -j RETURN
    
    # 添加直连域名IPv6
    for domain in "${!DIRECT_IP6S[@]}"; do
        ip6tables -t mangle -A V2RAY_TPROXY6 -d ${DIRECT_IP6S[$domain]}/128 -j RETURN
    done
    
    # DNS流量转发
    ip6tables -t mangle -A V2RAY_TPROXY6 -p udp --dport 53 -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
    ip6tables -t mangle -A V2RAY_TPROXY6 -p udp --dport 443 -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
    
    # TCP流量处理
    ip6tables -t mangle -A V2RAY_TPROXY6 -p tcp -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
    
    # UDP流量处理 - 与IPv4使用相同的模式
    case $UDP_PROXY_MODE in
        0)
            # 模式0：所有UDP走代理
            ip6tables -t mangle -A V2RAY_TPROXY6 -p udp -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
            ;;
        1)
            # 模式1：所有IPv6的UDP都走代理，因为没有IPv6的中国IP列表
            ip6tables -t mangle -A V2RAY_TPROXY6 -p udp -j TPROXY --on-port $V2RAY_PORT --tproxy-mark $PROXY_MARK
            ;;
        2)
            # 模式2：除DNS外所有UDP直连
            # DNS流量已经单独配置过了，这里不需要额外规则
            ;;
    esac
    
    # 配置本地IPv6流量输出
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -m mark --mark $DIRECT_MARK -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d ::1/128 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d fc00::/7 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d fe80::/10 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d ff00::/8 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d 2001:db8::/32 -j RETURN
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d 64:ff9b::/96 -j RETURN
    
    # 添加直连域名IPv6到本地规则
    for domain in "${!DIRECT_IP6S[@]}"; do
        ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -d ${DIRECT_IP6S[$domain]}/128 -j RETURN
    done
    
    # 本地DNS查询使用代理
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -p udp --dport 53 -j MARK --set-mark $PROXY_MARK
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -p udp --dport 443 -j MARK --set-mark $PROXY_MARK
    
    # 本地TCP流量标记
    ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -p tcp -j MARK --set-mark $PROXY_MARK
    
    # 本地UDP流量处理 - 与IPv4使用相同的模式
    case $UDP_PROXY_MODE in
        0)
            # 模式0：所有UDP走代理
            ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -p udp -j MARK --set-mark $PROXY_MARK
            ;;
        1)
            # 模式1：所有IPv6的UDP都走代理
            ip6tables -t mangle -A V2RAY_TPROXY_MARK6 -p udp -j MARK --set-mark $PROXY_MARK
            ;;
        2)
            # 模式2：除DNS外所有UDP直连
            # DNS已经单独设置了标记
            ;;
    esac
    
    # 应用IPv6规则
    ip6tables -t mangle -A PREROUTING -j V2RAY_TPROXY6
    ip6tables -t mangle -A OUTPUT -j V2RAY_TPROXY_MARK6
fi

#############################################################
# 保存规则
#############################################################

echo "[INFO] 保存规则配置..."

# 保存iptables规则
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

if [ $IPV6_SUPPORTED -eq 1 ]; then
    if ip6tables -L &>/dev/null; then
        ip6tables-save > /etc/iptables/rules.v6
    fi
fi

# 保存ipset（如果启用UDP智能分流）
if [ $UDP_PROXY_MODE -eq 1 ]; then
    mkdir -p /etc/ipset
    
    # 保存通用格式
    ipset save > /etc/ipset/ipset.conf
    
    # 创建优化的恢复文件
    if ipset list $CHINA_IPSET_NAME &>/dev/null; then
        IPSET_RESTORE_FILE="/etc/ipset/chnroute.restore"
        echo "create $CHINA_IPSET_NAME hash:net family inet hashsize 1024 maxelem 65536" > "$IPSET_RESTORE_FILE"
        ipset list $CHINA_IPSET_NAME | grep "^[0-9]" | sed -e "s/^/add $CHINA_IPSET_NAME /" >> "$IPSET_RESTORE_FILE"
    fi
fi

# 确保开机启用IP转发
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi

if [ $IPV6_SUPPORTED -eq 1 ]; then
    if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
    fi
fi

#############################################################
# 创建优化的启动服务
#############################################################

echo "[INFO] 创建优化的系统启动服务..."

# 创建启动脚本而不是直接内联所有命令
mkdir -p /usr/local/bin
cat > /usr/local/bin/tproxy-boot.sh << 'EOF'
#!/bin/bash

# 透明代理启动脚本
# 此脚本由透明代理服务调用，用于初始化和恢复网络规则

LOG_FILE="/var/log/transparent-proxy.log"
PROXY_MARK="0x07"
PROXY_ROUTE_TABLE="310"

# 记录日志的函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 初始化日志
init_log() {
    echo "===== 透明代理服务启动 [$(date +'%Y-%m-%d %H:%M:%S')] =====" > "$LOG_FILE"
}

# 启用IP转发
enable_ip_forwarding() {
    echo 1 > /proc/sys/net/ipv4/ip_forward
    log "IPv4转发已启用"
    
    # 如果IPv6可用，也启用IPv6转发
    if test -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && [ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]; then
        echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
        log "IPv6转发已启用"
    fi
}

# 检测网络接口
detect_interface() {
    local iface=""
    local attempt=1
    local max_attempts=10
    
    while [ $attempt -le $max_attempts ]; do
        iface=$(ip route | grep default | head -n1 | awk '{print $5}')
        if [ -n "$iface" ]; then
            log "检测到默认网络接口: $iface"
            echo "$iface"
            return 0
        else
            log "尝试($attempt/$max_attempts)检测默认接口..."
            sleep 2
            attempt=$((attempt + 1))
        fi
    done
    
    # 尝试备用接口
    for backup_iface in eth0 eth1 ens33 ens34 enp0s3 enp0s8 wlan0; do
        if ip link show "$backup_iface" &>/dev/null; then
            log "使用备用网络接口: $backup_iface"
            echo "$backup_iface"
            return 0
        fi
    done
    
    log "错误: 无法检测到任何可用的网络接口"
    return 1
}

# 应用NAT规则
apply_nat_rules() {
    local iface="$1"
    if [ -n "$iface" ]; then
        iptables -t nat -F POSTROUTING
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
        log "NAT规则应用成功 (接口: $iface)"
        
        # 如果IPv6可用，也应用IPv6 NAT规则
        if test -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && [ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]; then
            if ip6tables -t nat -L &>/dev/null; then
                ip6tables -t nat -F POSTROUTING
                ip6tables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
                log "IPv6 NAT规则应用成功"
            fi
        fi
    else
        log "错误: 应用NAT规则失败，无有效接口"
        return 1
    fi
}

# 加载ipset规则
load_ipset_rules() {
    if [ -f /etc/ipset/chnroute.restore ]; then
        ipset restore -f /etc/ipset/chnroute.restore
        log "ipset规则已从chnroute.restore加载"
    elif [ -f /etc/ipset/ipset.conf ]; then
        ipset restore < /etc/ipset/ipset.conf
        log "ipset规则已从ipset.conf加载"
    else
        log "未找到ipset规则文件，跳过"
    fi
}

# 设置IPv4策略路由
setup_ipv4_policy_routing() {
    # 清理已有规则
    ip rule del fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table "$PROXY_ROUTE_TABLE" 2>/dev/null
    
    # 添加新规则
    ip rule add fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" pref 789
    ip route add local 0.0.0.0/0 dev lo table "$PROXY_ROUTE_TABLE"
    
    log "IPv4策略路由已配置: fwmark $PROXY_MARK -> table $PROXY_ROUTE_TABLE"
}

# 设置IPv6策略路由
setup_ipv6_policy_routing() {
    if test -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && [ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]; then
        # 清理已有规则
        ip -6 rule del fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" 2>/dev/null
        ip -6 route del local ::/0 dev lo table "$PROXY_ROUTE_TABLE" 2>/dev/null
        
        # 添加新规则
        ip -6 rule add fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" pref 789
        ip -6 route add local ::/0 dev lo table "$PROXY_ROUTE_TABLE"
        
        log "IPv6策略路由已配置"
    else
        log "IPv6已禁用，跳过IPv6路由配置"
    fi
}

# 加载iptables规则
load_iptables_rules() {
    if [ -f /etc/iptables/rules.v4 ]; then
        iptables-restore < /etc/iptables/rules.v4
        log "IPv4规则已加载"
    else
        log "未找到IPv4规则文件"
    fi
    
    if [ -f /etc/iptables/rules.v6 ] && test -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && [ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]; then
        ip6tables-restore < /etc/iptables/rules.v6
        log "IPv6规则已加载"
    fi
}

# 验证关键规则
verify_rules() {
    # 验证NAT规则
    if ! iptables -t nat -L POSTROUTING | grep -q MASQUERADE; then
        log "错误: MASQUERADE规则未应用，尝试重新应用"
        local iface=$(ip route | grep default | head -n1 | awk '{print $5}')
        if [ -n "$iface" ]; then
            iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
            log "- NAT规则重新应用成功"
        fi
    else
        log "验证: MASQUERADE规则已存在"
    fi
    
    # 验证策略路由规则
    if ! ip rule | grep -q "fwmark $PROXY_MARK lookup $PROXY_ROUTE_TABLE"; then
        log "错误: 策略路由规则未应用，尝试重新应用"
        ip rule add fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" pref 789
        log "- 策略路由规则重新应用成功"
    else
        log "验证: 策略路由规则已存在"
    fi
}

# 输出最终状态
print_status() {
    log "NAT规则:"
    iptables -t nat -L POSTROUTING -v >> "$LOG_FILE"
    
    log "策略路由规则:"
    ip rule >> "$LOG_FILE"
    
    log "策略路由表 ($PROXY_ROUTE_TABLE):"
    ip route show table "$PROXY_ROUTE_TABLE" >> "$LOG_FILE"
    
    log "===== 透明代理启动完成 [$(date +'%Y-%m-%d %H:%M:%S')] ====="
}

# 主函数
main() {
    init_log
    enable_ip_forwarding
    
    local iface=$(detect_interface)
    if [ -n "$iface" ]; then
        apply_nat_rules "$iface"
        load_ipset_rules
        setup_ipv4_policy_routing
        setup_ipv6_policy_routing
        load_iptables_rules
        verify_rules
        print_status
        return 0
    else
        log "启动失败: 无法获取网络接口"
        return 1
    fi
}

# 执行主函数
main
EOF

# 创建定期检查脚本
cat > /usr/local/bin/tproxy-check.sh << 'EOF'
#!/bin/bash

# 透明代理规则检查脚本
# 此脚本由nat-rule-check.service定期执行，用于确保关键网络规则始终有效

LOG_FILE="/var/log/transparent-proxy.log"
PROXY_MARK="0x07"
PROXY_ROUTE_TABLE="310"

# 记录日志的函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 检查: $1" >> "$LOG_FILE"
}

# 检查并修复NAT规则
check_nat_rules() {
    if ! iptables -t nat -L POSTROUTING | grep -q MASQUERADE; then
        log "未检测到MASQUERADE规则，重新应用..."
        local iface=$(ip route | grep default | head -n1 | awk '{print $5}')
        if [ -n "$iface" ]; then
            iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
            log "- NAT规则已修复"
        else
            log "- 错误: 无法获取网络接口，NAT规则修复失败"
        fi
    fi
}

# 检查并修复IPv4策略路由规则
check_ipv4_policy_routing() {
    # 检查策略路由规则
    if ! ip rule | grep -q "fwmark $PROXY_MARK lookup $PROXY_ROUTE_TABLE"; then
        log "未检测到IPv4策略路由规则，重新应用..."
        ip rule add fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" pref 789
        log "- IPv4策略路由规则已修复"
    fi
    
    # 检查路由表
    if ! ip route show table "$PROXY_ROUTE_TABLE" | grep -q "local 0.0.0.0/0"; then
        log "未检测到本地路由表项，重新应用..."
        ip route add local 0.0.0.0/0 dev lo table "$PROXY_ROUTE_TABLE"
        log "- 本地路由表已修复"
    fi
}

# 检查并修复IPv6策略路由规则
check_ipv6_policy_routing() {
    if test -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && [ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 0 ]; then
        # 检查IPv6策略路由规则
        if ! ip -6 rule | grep -q "fwmark $PROXY_MARK lookup $PROXY_ROUTE_TABLE"; then
            log "未检测到IPv6策略路由规则，重新应用..."
            ip -6 rule add fwmark "$PROXY_MARK" table "$PROXY_ROUTE_TABLE" pref 789
            log "- IPv6策略路由规则已修复"
        fi
        
        # 检查IPv6路由表
        if ! ip -6 route show table "$PROXY_ROUTE_TABLE" | grep -q "local ::/0"; then
            log "未检测到IPv6本地路由表项，重新应用..."
            ip -6 route add local ::/0 dev lo table "$PROXY_ROUTE_TABLE"
            log "- IPv6本地路由表已修复"
        fi
    fi
}

# 主函数
main() {
    check_nat_rules
    check_ipv4_policy_routing
    check_ipv6_policy_routing
}

# 执行主函数
main
EOF

# 设置执行权限
chmod +x /usr/local/bin/tproxy-boot.sh
chmod +x /usr/local/bin/tproxy-check.sh

# 创建主服务文件 - 简化版本
cat > /etc/systemd/system/transparent-proxy.service << 'EOF'
[Unit]
Description=透明代理路由器服务
After=network-online.target
Wants=network-online.target
Requires=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tproxy-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 创建检查服务文件 - 简化版本
cat > /etc/systemd/system/nat-rule-check.service << 'EOF'
[Unit]
Description=NAT和策略路由规则定期检查服务
After=transparent-proxy.service
Requires=transparent-proxy.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tproxy-check.sh
EOF

# 创建定时器文件
cat > /etc/systemd/system/nat-rule-check.timer << 'EOF'
[Unit]
Description=定期检查NAT和策略路由规则

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s

[Install]
WantedBy=timers.target
EOF

# 重载systemd配置并启用服务
systemctl daemon-reload
systemctl enable transparent-proxy.service
systemctl enable nat-rule-check.timer

echo "[INFO] 服务已配置，将在系统启动时自动运行"
echo "[INFO] 添加了15秒定时检查服务，确保NAT和策略路由规则始终有效"

#############################################################
# 总结和状态输出
#############################################################

echo ""
echo "========================================"
echo "    透明代理路由器配置完成"
echo "========================================"
echo ""
echo "[功能说明]"
echo "1. 路由器功能：作为透明代理网关供其他设备使用"
echo "2. TCP代理模式：所有TCP流量都通过代理服务器"
echo "3. UDP代理模式："
case $UDP_PROXY_MODE in
    0)
        echo "   - 全部代理：所有UDP流量都通过代理服务器"
        ;;
    1)
        echo "   - 智能分流：中国IP直连，国外IP走代理"
        ;;
    2)
        echo "   - 直连模式：除DNS外所有UDP直连不走代理"
        ;;
esac
echo "4. DNS安全：DNS查询始终通过代理保护隐私"
if [ $IPV6_SUPPORTED -eq 1 ]; then
    echo "5. IPv6支持：已启用IPv6透明代理"
else
    echo "5. IPv6支持：未启用IPv6支持"
fi
echo "6. 启动优化：使用增强的启动序列和自动修复机制"
echo "7. 直连域名：$(echo ${DIRECT_DOMAINS[@]} | tr ' ' ',')"
echo ""

echo "[网络接口信息]"
echo "- 主网络接口: $MAIN_INTERFACE"
echo "- 本机IP地址: $LOCAL_IP"
echo ""

echo "[规则统计]"
echo "- iptables规则数量: $(iptables -t mangle -L | grep -c "Chain\|target")"
if [ $UDP_PROXY_MODE -eq 1 ]; then
    echo "- 中国IP段数量: $(ipset list $CHINA_IPSET_NAME 2>/dev/null | grep -c "^[0-9]")"
fi
echo ""

echo "[启动服务]"
echo "- 主服务: transparent-proxy.service (已启用)"
echo "- 检查服务: nat-rule-check.timer (每15秒运行一次)"
echo "- 启动脚本: /usr/local/bin/tproxy-boot.sh"
echo "- 检查脚本: /usr/local/bin/tproxy-check.sh"
echo "- 日志文件: /var/log/transparent-proxy.log"
echo ""

echo "[客户端设备配置指南]"
echo "要使用此透明代理路由器，客户端设备需按下方配置网络:"
echo "- IP地址: 自动获取或手动设置为局域网地址"
echo "- 子网掩码: 255.255.255.0"
echo "- 默认网关: $LOCAL_IP"
echo "- DNS服务器: $LOCAL_IP"
echo ""

echo "[连接测试]"
echo "设置完成后，可在客户端设备上运行以下命令测试连接:"
echo "- ping google.com"
echo "- curl ipinfo.io"
echo ""

echo "========================================"