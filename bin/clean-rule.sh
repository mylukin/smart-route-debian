#!/bin/bash

# 改进的iptables无用规则清理脚本
# 保持规则文件结构完整性

echo "=== [$(date)] 开始清理iptables无用规则 ==="

# 检查是否以root运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root权限运行" 
   exit 1
fi

# 备份当前规则
echo ">>> 备份当前iptables规则..."
mkdir -p /etc/iptables/backup
BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
iptables-save > "/etc/iptables/backup/rules.v4.$BACKUP_DATE"
ip6tables-save > "/etc/iptables/backup/rules.v6.$BACKUP_DATE" 2>/dev/null
echo "  - 已备份规则到 /etc/iptables/backup/rules.v4.$BACKUP_DATE"

# 临时文件
IPV4_CURRENT=$(mktemp)
IPV4_CLEAN=$(mktemp)
IPV6_CURRENT=$(mktemp)
IPV6_CLEAN=$(mktemp)

# 保存当前规则到临时文件
iptables-save > "$IPV4_CURRENT"
ip6tables-save > "$IPV6_CURRENT" 2>/dev/null

echo ">>> 开始清理IPv4规则..."

# 处理IPv4规则 - 保持表结构完整性
{
    # 逐行处理IPv4规则文件
    local_table=""
    declare -A seen_rules
    while IFS= read -r line; do
        # 处理表头
        if [[ "$line" =~ ^\*([a-z]+) ]]; then
            local_table="${BASH_REMATCH[1]}"
            echo "$line"
            continue
        fi
        
        # 处理提交行
        if [[ "$line" == "COMMIT" ]]; then
            echo "$line"
            local_table=""
            continue
        fi
        
        # 处理注释和空行
        if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
            echo "$line"
            continue
        fi
        
        # 处理链定义行
        if [[ "$line" =~ ^: ]]; then
            echo "$line"
            continue
        fi
        
        # 处理规则行（-A开头）- 去重
        if [[ "$line" =~ ^-A ]]; then
            rule_key="${local_table}:${line}"
            if [[ -z "${seen_rules[$rule_key]}" ]]; then
                seen_rules[$rule_key]=1
                echo "$line"
            else
                : # 跳过重复规则
            fi
            continue
        fi
        
        # 其他行直接输出
        echo "$line"
    done < "$IPV4_CURRENT"
} > "$IPV4_CLEAN"

# 计算移除的规则数
IPV4_ORIGINAL_LINES=$(grep -E "^-A" "$IPV4_CURRENT" | wc -l)
IPV4_CLEAN_LINES=$(grep -E "^-A" "$IPV4_CLEAN" | wc -l)
IPV4_REMOVED=$((IPV4_ORIGINAL_LINES - IPV4_CLEAN_LINES))
echo "  - 已从IPv4规则中移除 $IPV4_REMOVED 行重复规则"

echo ">>> 开始清理IPv6规则..."

# 处理IPv6规则
if [ -f "$IPV6_CURRENT" ]; then
    {
        # 逐行处理IPv6规则文件
        local_table=""
        declare -A seen_rules
        while IFS= read -r line; do
            # 处理表头
            if [[ "$line" =~ ^\*([a-z]+) ]]; then
                local_table="${BASH_REMATCH[1]}"
                echo "$line"
                continue
            fi
            
            # 处理提交行
            if [[ "$line" == "COMMIT" ]]; then
                echo "$line"
                local_table=""
                continue
            fi
            
            # 处理注释和空行
            if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
                echo "$line"
                continue
            fi
            
            # 处理链定义行
            if [[ "$line" =~ ^: ]]; then
                echo "$line"
                continue
            fi
            
            # 处理规则行（-A开头）- 去重
            if [[ "$line" =~ ^-A ]]; then
                rule_key="${local_table}:${line}"
                if [[ -z "${seen_rules[$rule_key]}" ]]; then
                    seen_rules[$rule_key]=1
                    echo "$line"
                else
                    : # 跳过重复规则
                fi
                continue
            fi
            
            # 其他行直接输出
            echo "$line"
        done < "$IPV6_CURRENT"
    } > "$IPV6_CLEAN"
    
    # 计算移除的规则数
    IPV6_ORIGINAL_LINES=$(grep -E "^-A" "$IPV6_CURRENT" | wc -l)
    IPV6_CLEAN_LINES=$(grep -E "^-A" "$IPV6_CLEAN" | wc -l)
    IPV6_REMOVED=$((IPV6_ORIGINAL_LINES - IPV6_CLEAN_LINES))
    echo "  - 已从IPv6规则中移除 $IPV6_REMOVED 行重复规则"
else
    echo "  ! IPv6规则文件不存在，跳过IPv6规则清理"
fi

# 特别清理：IPv6 DNS_SPECIAL6链中的重复规则
# 只有在链被引用但为空时才清理
if ip6tables -t nat -L DNS_SPECIAL6 &>/dev/null; then
    RULES_COUNT=$(ip6tables -t nat -L DNS_SPECIAL6 -n --line-numbers | grep -c "^[0-9]")
    if [ "$RULES_COUNT" -eq 0 ]; then
        ip6tables -t nat -F DNS_SPECIAL6 2>/dev/null
        echo "  - 已清空IPv6 DNS_SPECIAL6链（此链是重复引用的）"
    fi
fi

# 应用清理后的规则
echo ">>> 应用清理后的规则..."
cat "$IPV4_CLEAN" | iptables-restore
RESTORE_STATUS=$?
if [ $RESTORE_STATUS -eq 0 ]; then
    echo "  - 已成功应用清理后的IPv4规则"
else
    echo "  ! 应用IPv4规则失败，恢复备份..."
    cat "/etc/iptables/backup/rules.v4.$BACKUP_DATE" | iptables-restore
    echo "  - 已恢复IPv4规则备份"
fi

if [ -f "$IPV6_CLEAN" ]; then
    cat "$IPV6_CLEAN" | ip6tables-restore
    RESTORE_STATUS=$?
    if [ $RESTORE_STATUS -eq 0 ]; then
        echo "  - 已成功应用清理后的IPv6规则"
    else
        echo "  ! 应用IPv6规则失败，恢复备份..."
        cat "/etc/iptables/backup/rules.v6.$BACKUP_DATE" | ip6tables-restore 2>/dev/null
        echo "  - 已恢复IPv6规则备份"
    fi
fi

# 保存清理后的规则
iptables-save > /etc/iptables/rules.v4
echo "  - 已保存清理后的IPv4规则到 /etc/iptables/rules.v4"

if ip6tables -t nat -L &>/dev/null; then
    ip6tables-save > /etc/iptables/rules.v6
    echo "  - 已保存清理后的IPv6规则到 /etc/iptables/rules.v6"
fi

# 删除临时文件
rm -f "$IPV4_CURRENT" "$IPV4_CLEAN" "$IPV6_CURRENT" "$IPV6_CLEAN"

echo ""
echo ">>> 清理结果摘要:"
echo "  - 已从IPv4规则中移除 $IPV4_REMOVED 行重复规则"
if [ -f "$IPV6_CURRENT" ]; then
    echo "  - 已从IPv6规则中移除 $IPV6_REMOVED 行重复规则"
fi
echo "  - 原始规则已备份到: /etc/iptables/backup/rules.v4.$BACKUP_DATE"
echo "  - 清理后的规则已保存到: /etc/iptables/rules.v4"
echo ""
echo "  - 如果有任何问题，可以使用以下命令恢复备份:"
echo "    iptables-restore < /etc/iptables/backup/rules.v4.$BACKUP_DATE"
echo "    ip6tables-restore < /etc/iptables/backup/rules.v6.$BACKUP_DATE"

echo "=== [$(date)] 规则清理完成 ==="