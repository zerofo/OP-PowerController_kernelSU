#!/system/bin/sh

# ==============================================
# 路径与变量定义
# ==============================================
MODDIR=${0%/*}
BYPASS_NODE="/sys/devices/virtual/oplus_chg/battery/mmi_charging_enable"
CAPACITY_NODE="/sys/class/power_supply/battery/capacity"
USB_ONLINE_NODE="/sys/class/power_supply/usb/online"
MAX_LOG_SIZE=1048576  # 1MB

# 文件定义
CONFIG_FILE="$MODDIR/config.txt"
CONTROL_FILE="$MODDIR/control.txt"
STATUS_FILE="$MODDIR/status.txt"
LOG_FILE="$MODDIR/service.log"

# ==============================================
# 初始化配置和状态文件
# ==============================================
initialize_files() {
    if [ ! -f "$CONTROL_FILE" ]; then
        echo "AUTO_ENABLE=1" > "$CONTROL_FILE"
        chmod 644 "$CONTROL_FILE"
        log "CONTROL_FILE 不存在，已创建并设置为默认值 (AUTO_ENABLE=1)"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "UPPER_LIMIT=91" > "$CONFIG_FILE"
        echo "LOWER_LIMIT=78" >> "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        log "CONFIG_FILE 不存在，已创建并设置为默认值 (上/下限=91/78)"
    fi

    if [ ! -f "$STATUS_FILE" ]; then
        touch "$STATUS_FILE"
        chmod 644 "$STATUS_FILE"
        log "STATUS_FILE 已创建"
    fi
}

# ==============================================
# 辅助函数
# ==============================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

update_status() {
    local mode="$1"
    local capacity="$2"
    local usb="$3"
    local auto="$4"
    local upper="$5"
    local lower="$6"
    
    cat > "$STATUS_FILE" << EOF
MODE=$mode
CAPACITY=$capacity
USB_ONLINE=$usb
AUTO_ENABLE=$auto
UPPER=$upper
LOWER=$lower
TIMESTAMP=$(date +%s)
EOF
    chmod 644 "$STATUS_FILE"
}

# 读取配置文件中的数值，如果失败则返回默认值
read_config_value() {
    local key="$1"
    local default="$2"
    local value=$(grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' \t')
    
    if echo "$value" | grep -qE '^[0-9]+$' && [ "$value" -ge 0 ] && [ "$value" -le 100 ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

read_control_state() {
    local value=$(grep -m1 "^AUTO_ENABLE=" "$CONTROL_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' \t')
    if [ "$value" = "1" ] || [ "$value" = "0" ]; then
        echo "$value"
    else
        echo "1"
    fi
}

# 日志轮转：检查日志文件大小，超过 MAX_LOG_SIZE 则清空
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt "$MAX_LOG_SIZE" ]; then
            : > "$LOG_FILE"
            # 清空后写入一条记录，表明日志已被重置
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志超过 1MB，已自动清空" >> "$LOG_FILE"
        fi
    fi
}

# ==============================================
# 主逻辑
# ==============================================
# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 2

initialize_files

if [ ! -f "$BYPASS_NODE" ]; then
    log "严重错误：旁路节点不存在，模块将停止运行"
    exit 1
fi

echo 1 > "$BYPASS_NODE"
log "模块服务已启动，初始化完成"

LAST_STATE=""
while true; do
    AUTO_ENABLE=$(read_control_state)
    UPPER_LIMIT=$(read_config_value "UPPER_LIMIT" 91)
    LOWER_LIMIT=$(read_config_value "LOWER_LIMIT" 78)
    
    if [ "$UPPER_LIMIT" -le "$LOWER_LIMIT" ]; then
        log "警告：配置的上限 (${UPPER_LIMIT}) 不大于下限 (${LOWER_LIMIT})，使用默认值 91/78"
        UPPER_LIMIT=91
        LOWER_LIMIT=78
    fi
    
    CAPACITY=$(cat "$CAPACITY_NODE" 2>/dev/null || echo 0)
    USB_ONLINE=$(cat "$USB_ONLINE_NODE" 2>/dev/null || echo 0)
    
    if [ "$AUTO_ENABLE" = "0" ]; then
        if [ "$LAST_STATE" != "MANUAL_DISABLED" ]; then
            echo 1 > "$BYPASS_NODE"
            log "用户手动禁用了自动控制，已恢复充电"
            LAST_STATE="MANUAL_DISABLED"
        fi
        update_status "🔴 手动禁用" "$CAPACITY" "$USB_ONLINE" "0" "$UPPER_LIMIT" "$LOWER_LIMIT"
        
    elif [ "$USB_ONLINE" -eq 0 ]; then
        if [ "$LAST_STATE" != "UNPLUGGED" ]; then
            echo 1 > "$BYPASS_NODE"
            log "电源已断开，已恢复充电"
            LAST_STATE="UNPLUGGED"
        fi
        update_status "💤 未接电源" "$CAPACITY" "$USB_ONLINE" "1" "$UPPER_LIMIT" "$LOWER_LIMIT"
        
    else
        if [ "$CAPACITY" -ge "$UPPER_LIMIT" ]; then
            if [ "$LAST_STATE" != "BYPASS_ON" ]; then
                echo 0 > "$BYPASS_NODE"
                log "电量已达到 ${CAPACITY}% (≥${UPPER_LIMIT}%)，开启旁路供电"
                LAST_STATE="BYPASS_ON"
            fi
            update_status "⚡ 旁路供电中" "$CAPACITY" "$USB_ONLINE" "1" "$UPPER_LIMIT" "$LOWER_LIMIT"
            
        elif [ "$CAPACITY" -le "$LOWER_LIMIT" ]; then
            if [ "$LAST_STATE" != "CHARGING" ]; then
                echo 1 > "$BYPASS_NODE"
                log "电量已降至 ${CAPACITY}% (≤${LOWER_LIMIT}%)，恢复快速充电"
                LAST_STATE="CHARGING"
            fi
            update_status "🟢 正常充电" "$CAPACITY" "$USB_ONLINE" "1" "$UPPER_LIMIT" "$LOWER_LIMIT"
            
        else
            if [ "$LAST_STATE" = "BYPASS_ON" ]; then
                update_status "⚡ 旁路中(等待降至${LOWER_LIMIT}%)" "$CAPACITY" "$USB_ONLINE" "1" "$UPPER_LIMIT" "$LOWER_LIMIT"
            else
                update_status "🟢 充电中(等待充至${UPPER_LIMIT}%)" "$CAPACITY" "$USB_ONLINE" "1" "$UPPER_LIMIT" "$LOWER_LIMIT"
            fi
        fi
    fi
    
    # 关键：每次循环都检查日志文件大小
    rotate_log
    
    sleep 5
done