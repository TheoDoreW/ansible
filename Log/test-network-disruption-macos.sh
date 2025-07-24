#!/bin/bash
# 创建测试脚本

# 设置颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 默认配置
DEPLOYMENT_NAME="nginx-fast-failover"
SERVICE_NAME="nginx-fast-svc"
NAMESPACE="default"

# 显示使用说明
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -n, --node <node-name>      Target node name"
    echo "  -d, --deployment <name>     Deployment name (default: nginx-fast-failover)"
    echo "  -h, --help                  Show this help message"
}

# 解析参数
TARGET_NODE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--node)
            TARGET_NODE="$2"
            shift 2
            ;;
        -d|--deployment)
            DEPLOYMENT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# 日志文件
LOG_FILE="network-disruption-test-$(date +%Y%m%d-%H%M%S).log"

# 日志函数
log() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] ${message}${NC}" | tee -a $LOG_FILE
}

# 自动选择节点
if [ -z "$TARGET_NODE" ]; then
    log "自动选择目标节点..." $CYAN
    TARGET_NODE=$(kubectl get pods -n $NAMESPACE -l app=nginx-fast -o json | jq -r '.items[0].spec.nodeName')
    if [ -z "$TARGET_NODE" ] || [ "$TARGET_NODE" = "null" ]; then
        log "无法自动选择节点" $RED
        exit 1
    fi
fi

log "=== 网络中断详细测试 ===" $BLUE
log "目标节点: $TARGET_NODE"

# 获取初始状态
log "\n=== 初始状态 ===" $BLUE

# 获取Service IP
SVC_IP=$(kubectl get svc $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$SVC_IP" ] || [ "$SVC_IP" = "null" ]; then
    SVC_IP=$(kubectl get svc $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    log "使用 ClusterIP: $SVC_IP" $YELLOW
else
    log "Service LoadBalancer IP: $SVC_IP" $GREEN
fi

# 获取目标节点上的Pod
TARGET_POD=$(kubectl get pods -n $NAMESPACE -l app=nginx-fast -o json | jq -r --arg node "$TARGET_NODE" '.items[] | select(.spec.nodeName==$node) | .metadata.name' | head -1)
POD_IP=$(kubectl get pod $TARGET_POD -n $NAMESPACE -o jsonpath='{.status.podIP}')

log "目标Pod: $TARGET_POD"
log "Pod IP: $POD_IP"

# 显示初始状态
kubectl get node $TARGET_NODE -o wide | tee -a $LOG_FILE
kubectl get pods -n $NAMESPACE -l app=nginx-fast -o wide | tee -a $LOG_FILE

# 创建后台监控进程
log "\n开始后台监控进程..." $CYAN

# 1. 监控节点状态（每秒检查）
(
    while true; do
        NODE_STATUS=$(kubectl get node $TARGET_NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$TIMESTAMP,NODE,$NODE_STATUS" >> node-status.csv
        sleep 1
    done
) &
NODE_MONITOR_PID=$!

# 2. 监控Pod状态（每秒检查）
(
    while true; do
        POD_STATUS=$(kubectl get pod $TARGET_POD -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
        POD_READY=$(kubectl get pod $TARGET_POD -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$TIMESTAMP,POD,$POD_STATUS,$POD_READY" >> pod-status.csv
        sleep 1
    done
) &
POD_MONITOR_PID=$!

# 3. 监控Service可达性（每0.5秒检查）
(
    while true; do
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 1 --max-time 1 http://$SVC_IP 2>/dev/null | grep -q "200"; then
            echo "$TIMESTAMP,SERVICE,UP" >> service-status.csv
        else
            echo "$TIMESTAMP,SERVICE,DOWN" >> service-status.csv
        fi
        sleep 0.5
    done
) &
SERVICE_MONITOR_PID=$!

# 4. 监控Pod IP直连（每0.5秒检查）
(
    while true; do
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 1 --max-time 1 http://$POD_IP 2>/dev/null | grep -q "200"; then
            echo "$TIMESTAMP,POD_DIRECT,UP" >> pod-direct-status.csv
        else
            echo "$TIMESTAMP,POD_DIRECT,DOWN" >> pod-direct-status.csv
        fi
        sleep 0.5
    done
) &
POD_DIRECT_MONITOR_PID=$!

# 显示模拟指令
log "\n请在另一个终端运行以下命令模拟节点故障:" $YELLOW
echo "kubectl debug node/$TARGET_NODE -it --image=mcr.microsoft.com/cbl-mariner/busybox:2.0"
echo "# 在容器内执行:"
echo "chroot /host"
echo "ip link set eth0 down"
echo ""
read -p "网络接口禁用后按回车继续..."

# 记录网络中断时间
DISRUPTION_TIME=$(date '+%Y-%m-%d %H:%M:%S')
log "网络接口已禁用: $DISRUPTION_TIME" $RED

# 继续监控60秒
log "监控60秒内的变化..." $CYAN
sleep 60

# 停止所有监控进程
kill $NODE_MONITOR_PID $POD_MONITOR_PID $SERVICE_MONITOR_PID $POD_DIRECT_MONITOR_PID 2>/dev/null

# 分析结果
log "\n=== 分析结果 ===" $BLUE

# 分析节点状态变化
log "\n节点状态变化:"
FIRST_NOT_READY=$(grep ",NODE,False" node-status.csv | head -1 | cut -d',' -f1)
if [ -n "$FIRST_NOT_READY" ]; then
    log "节点首次变为 NotReady: $FIRST_NOT_READY" $RED
fi

# 分析Service中断
log "\nService 可达性:"
FIRST_SERVICE_DOWN=$(grep ",SERVICE,DOWN" service-status.csv | head -1 | cut -d',' -f1)
if [ -n "$FIRST_SERVICE_DOWN" ]; then
    log "Service 首次中断: $FIRST_SERVICE_DOWN" $RED
fi

# 分析Pod直连
log "\nPod 直连状态:"
FIRST_POD_DOWN=$(grep ",POD_DIRECT,DOWN" pod-direct-status.csv | head -1 | cut -d',' -f1)
if [ -n "$FIRST_POD_DOWN" ]; then
    log "Pod 直连首次失败: $FIRST_POD_DOWN" $RED
fi

# 分析Pod状态变化
log "\nPod 状态变化:"
FIRST_POD_NOT_READY=$(grep ",POD,.*,False" pod-status.csv | head -1 | cut -d',' -f1)
if [ -n "$FIRST_POD_NOT_READY" ]; then
    log "Pod 首次变为 NotReady: $FIRST_POD_NOT_READY" $YELLOW
fi

# 生成时间线
log "\n=== 0-60秒时间线 ===" $BLUE
log "网络中断时间: $DISRUPTION_TIME"

# 计算各事件的时间差
if [ -n "$FIRST_POD_DOWN" ] && [ -n "$DISRUPTION_TIME" ]; then
    # macOS 兼容的时间计算
    DISRUPTION_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$DISRUPTION_TIME" +%s 2>/dev/null || date -d "$DISRUPTION_TIME" +%s)
    POD_DOWN_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$FIRST_POD_DOWN" +%s 2>/dev/null || date -d "$FIRST_POD_DOWN" +%s)
    DIFF=$((POD_DOWN_EPOCH - DISRUPTION_EPOCH))
    log "Pod直连中断延迟: ${DIFF}秒"
fi

# 显示当前状态
log "\n=== 当前状态 ===" $BLUE
kubectl get node $TARGET_NODE
kubectl get pod $TARGET_POD -n $NAMESPACE

# 清理临时文件
rm -f node-status.csv pod-status.csv service-status.csv pod-direct-status.csv

log "\n详细日志已保存到: $LOG_FILE" $GREEN