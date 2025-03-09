#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印标题
print_header() {
    echo -e "\n${BLUE}==== $1 ====${NC}"
}

# 超时设置
TIMEOUT=5

# 检查Docker支持
check_docker_support() {
    if command -v docker &>/dev/null; then
        echo "1"
    else
        echo "0"
    fi
}

# 检查HTTP/3支持
check_http3_support() {
    # 优先检查Docker支持
    if [ "$(check_docker_support)" = "1" ]; then
        echo "docker"
    elif curl --help | grep -q -- --http3; then
        echo "native"
    else
        echo "0"
    fi
}

# 测试代理服务器连接
print_header "代理服务器连接测试"
echo "测试与代理服务器的连接..."
ping -c 3 hk.example.com
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}警告：无法 ping 通代理服务器，这可能是正常的如果服务器禁用了 ICMP${NC}"
fi

# 测试国内网站
print_header "国内网站测试"
echo "测试国内网站连接..."
curl -s -m $TIMEOUT -o /dev/null -w "网易连接: HTTP状态码 %{http_code}\n" https://www.163.com
if [ $? -ne 0 ]; then
    echo -e "${RED}网易连接: 超时 (>$TIMEOUT秒)${NC}"
else
    echo -e "${GREEN}网易连接正常${NC}"
fi

# 测试国外网站
print_header "国外网站测试"
echo "测试国外网站连接..."
curl -s -m $TIMEOUT -o /dev/null -w "Google连接: HTTP状态码 %{http_code}\n" https://www.google.com
if [ $? -ne 0 ]; then
    echo -e "${RED}Google连接: 超时 (>$TIMEOUT秒)${NC}"
else
    echo -e "${GREEN}Google连接正常${NC}"
fi

# CDN测试函数
test_cdn() {
    local name=$1
    local url=$2
    
    print_header "$name CDN测试"
    echo "获取 $name CDN信息..."
    
    # 检测HTTP/3支持
    local http3_support=$(check_http3_support)
    
    # 测试HTTP/1.1
    echo -e "${YELLOW}HTTP/1.1 测试:${NC}"
    local http1_result=$(curl -s --http1.1 -m $TIMEOUT "$url" 2>/dev/null)
    local http1_success=$?
    if [ $http1_success -eq 0 ] && [ -n "$http1_result" ]; then
        echo -e "${GREEN}HTTP/1.1连接成功${NC}"
        echo "$http1_result" | grep -E "^(ip=|http=|loc=)" | sed "s/ip=/IP: /g; s/http=/HTTP: /g; s/loc=/位置: /g"
    else
        echo -e "${RED}HTTP/1.1连接失败${NC}"
    fi
    
    # 测试HTTP/2
    echo -e "\n${YELLOW}HTTP/2 测试:${NC}"
    local http2_result=$(curl -s --http2 -m $TIMEOUT "$url" 2>/dev/null)
    local http2_success=$?
    if [ $http2_success -eq 0 ] && [ -n "$http2_result" ]; then
        echo -e "${GREEN}HTTP/2连接成功${NC}"
        echo "$http2_result" | grep -E "^(ip=|http=|loc=)" | sed "s/ip=/IP: /g; s/http=/HTTP: /g; s/loc=/位置: /g"
    else
        echo -e "${RED}HTTP/2连接失败${NC}"
    fi
    
    # 测试HTTP/3
    local http3_success=1
    local http3_result=""
    
    if [ "$http3_support" = "docker" ]; then
        echo -e "\n${YELLOW}HTTP/3 测试 (通过Docker):${NC}"
        # 通过Docker运行HTTP/3测试
        http3_result=$(docker run --rm ymuski/curl-http3 curl -s --http3 -m $TIMEOUT "$url" 2>/dev/null)
        http3_success=$?
        if [ $http3_success -eq 0 ] && [ -n "$http3_result" ]; then
            echo -e "${GREEN}HTTP/3连接成功 (Docker)${NC}"
            echo "$http3_result" | grep -E "^(ip=|http=|loc=)" | sed "s/ip=/IP: /g; s/http=/HTTP: /g; s/loc=/位置: /g"
        else
            echo -e "${RED}HTTP/3连接失败 (Docker)${NC}"
        fi
    elif [ "$http3_support" = "native" ]; then
        echo -e "\n${YELLOW}HTTP/3 测试:${NC}"
        http3_result=$(curl -s --http3 -m $TIMEOUT "$url" 2>/dev/null)
        http3_success=$?
        if [ $http3_success -eq 0 ] && [ -n "$http3_result" ]; then
            echo -e "${GREEN}HTTP/3连接成功${NC}"
            echo "$http3_result" | grep -E "^(ip=|http=|loc=)" | sed "s/ip=/IP: /g; s/http=/HTTP: /g; s/loc=/位置: /g"
        else
            echo -e "${RED}HTTP/3连接失败${NC}"
        fi
    else
        echo -e "\n${YELLOW}HTTP/3 测试:${NC}"
        echo -e "${RED}当前环境不支持HTTP/3测试 (需要HTTP/3-enabled curl或Docker)${NC}"
    fi
    
    # 显示最优结果
    echo -e "\n${YELLOW}最佳协议总结:${NC}"
    if ([ "$http3_support" = "docker" ] || [ "$http3_support" = "native" ]) && [ $http3_success -eq 0 ] && [ -n "$http3_result" ]; then
        echo -e "推荐协议: ${GREEN}HTTP/3${NC}"
    elif [ $http2_success -eq 0 ] && [ -n "$http2_result" ]; then
        echo -e "推荐协议: ${GREEN}HTTP/2${NC}"
    elif [ $http1_success -eq 0 ] && [ -n "$http1_result" ]; then
        echo -e "推荐协议: ${GREEN}HTTP/1.1${NC}"
    else
        echo -e "${RED}所有协议连接失败${NC}"
    fi
}

# 测试ChatGPT CDN
test_cdn "ChatGPT" "https://chatgpt.com/cdn-cgi/trace"

# 测试Claude CDN
test_cdn "Claude" "https://claude.ai/cdn-cgi/trace"

print_header "测试完成"