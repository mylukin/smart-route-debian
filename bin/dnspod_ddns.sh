#!/bin/bash
# DNSPod DDNS 脚本 - 极简高效版
# 参考: https://github.com/kkkgo/dnspod-ddns-with-bashshell

# ==== 配置参数 ====
domain="atmy.work"          # 域名
sub_domain="home"           # 子域名
# ==== 配置结束 ====

# 初始化
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/opt/sbin:$PATH"
echo "$(date +"%Y-%m-%d %H:%M:%S") DNSPod DDNS 开始运行"

# 获取API Token (优先从环境变量获取)
if [ -n "$DNSPOD_TOKEN" ]; then
    login_token="$DNSPOD_TOKEN"
    echo "使用环境变量中的TOKEN"
else
    echo "错误: 环境变量 DNSPOD_TOKEN 未设置"
    exit 1
fi

# 设置完整域名
HOST="$sub_domain.$domain"
if [ "$sub_domain" = "@" ]; then
    HOST="$domain"
fi
echo "域名: $HOST"

# IP正则表达式
IPREX='([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'

# 获取公网IP
echo "获取公网IP..."
DEVIP=""

# 尝试多个公网IP服务
for service in "http://ip.3322.net" "http://ip.cip.cc" "http://ip.sb"; do
    echo "从 $service 获取IP..."
    DEVIP=$(curl -s "$service" 2>/dev/null)

    if echo $DEVIP | grep -qEo "$IPREX"; then
        echo "成功获取IP: $DEVIP"
        break
    fi
done

# 如果前面的服务都失败，尝试ipip.net
if ! echo $DEVIP | grep -qEo "$IPREX"; then
    echo "从 http://myip.ipip.net 获取IP..."
    response=$(curl -s "http://myip.ipip.net" 2>/dev/null)
    DEVIP=$(echo "$response" | grep -Eo "$IPREX" | head -1)
    if echo $DEVIP | grep -qEo "$IPREX"; then
        echo "成功获取IP: $DEVIP"
    fi
fi

if ! echo $DEVIP | grep -qEo "$IPREX"; then
    echo "错误: 无法获取公网IP地址"
    exit 1
fi
echo "[公网IP]: $DEVIP"

# 获取当前DNS记录IP
DNSIP="获取DNS记录失败"
DNSTEST=$(ping -c1 -W1 $HOST 2>&1 | grep -Eo "$IPREX" | head -1)
if echo $DNSTEST | grep -qEo "$IPREX"; then
    DNSIP=$DNSTEST
else
    DNSTEST=$(nslookup $HOST 2>&1 | grep -Eo "$IPREX" | tail -1)
    if echo $DNSTEST | grep -qEo "$IPREX"; then
        DNSIP=$DNSTEST
    else
        DNSTEST=$(curl -ks $HOST -m 1 2>&1 | grep -Eo "$IPREX" | head -1)
        if echo $DNSTEST | grep -qEo "$IPREX"; then
            DNSIP=$DNSTEST
        fi
    fi
fi
echo "[DNS解析IP]: $DNSIP"

# 比较IP是否相同，相同则跳过更新
if [ "$DNSIP" == "$DEVIP" ]; then
    echo "DNS记录IP与公网IP相同，无需更新"
    exit 0
fi

# 准备API参数
token="login_token=${login_token}&format=json&lang=en&error_on_empty=yes&domain=${domain}&sub_domain=${sub_domain}"

# 获取记录信息
echo "获取DNS记录信息..."
Record="$(curl -ks -X POST https://dnsapi.cn/Record.List -d "${token}")"

# 检查API调用是否成功
if echo $Record | grep -qEo "Operation successful"; then
    record_ip=$(echo $Record | grep -Eo "$IPREX" | head -1)
    echo "[API记录IP]: $record_ip"

    # 再次检查API返回的IP是否需要更新
    if [ "$record_ip" = "$DEVIP" ]; then
        echo "API记录IP与公网IP相同，无需更新"
        exit 0
    fi

    # 提取记录ID和线路ID
    record_id=$(echo $Record | grep -Eo '"records"[:\[{" ]+"id"[:" ]+[0-9]+' | grep -Eo '[0-9]+' | head -1)
    record_line_id=$(echo $Record | grep -Eo 'line_id[": ]+[0-9]+' | grep -Eo '[0-9]+' | head -1)

    echo "开始更新DNS记录... (记录ID: $record_id, 线路ID: $record_line_id)"

    # 使用DDNS API更新记录
    ddns="$(curl -ks -X POST https://dnsapi.cn/Record.Ddns -d "${token}&record_id=${record_id}&record_line_id=${record_line_id}&value=$DEVIP")"

    # 检查更新结果
    if echo $ddns | grep -qEo '"code":"1"'; then
        new_ip=$(echo $ddns | grep -Eo "$IPREX" | tail -n1)
        echo "DDNS更新成功: $HOST [$record_ip] -> [$new_ip]"
    else
        error=$(echo $ddns | grep -Eo '"message":"[^"]+"' | grep -Eo '"[^"]+"' | tr -d '"')
        echo "DDNS更新失败: $error"
        exit 1
    fi
else
    error=$(echo $Record | grep -Eo '"message":"[^"]+"' | grep -Eo '"[^"]+"' | tr -d '"')
    echo "获取记录失败: $error"
    exit 1
fi