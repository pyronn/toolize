#!/bin/bash

# ============================================================
#  sing-box SOCKS5 链式代理配置生成脚本，
#  用法:
#    ./add-socks-chain.sh                        # 交互式输入
#    ./add-socks-chain.sh ip:port:user:pass       # 直接传参
# ============================================================

set -euo pipefail

CONF_DIR="/etc/sing-box/conf"
CONFIG_MAIN="/etc/sing-box/config.json"
OUTPUT_FILE="${CONF_DIR}/socks-chain.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_title()   { echo -e "\n${BOLD}$*${NC}"; }

# ── 权限检查 ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

# ── 依赖检查 ──────────────────────────────────────────────
for cmd in sing-box curl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "未找到命令: $cmd，请先安装"
        exit 1
    fi
done

# ── 解析参数 ──────────────────────────────────────────────
PROXY_HOST=""
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""

parse_inline() {
    local input="$1"
    # 支持格式: ip:port:user:pass 或 ip:port:user:pass (允许密码含冒号)
    IFS=':' read -ra parts <<< "$input"
    if [[ ${#parts[@]} -lt 4 ]]; then
        log_error "格式错误，需要至少 4 段: ip:port:username:password"
        exit 1
    fi
    PROXY_HOST="${parts[0]}"
    PROXY_PORT="${parts[1]}"
    PROXY_USER="${parts[2]}"
    # 密码可能含冒号，把第4段之后都拼回去
    PROXY_PASS=$(echo "$input" | cut -d: -f4-)
}

log_title "=== sing-box SOCKS5 链式代理配置生成 ==="

if [[ $# -ge 1 ]]; then
    log_info "检测到参数，使用直接解析模式"
    parse_inline "$1"
else
    # 交互式输入
    echo ""
    echo -e "  支持两种输入方式:"
    echo -e "  ${YELLOW}1${NC}) 逐项输入 IP、端口、用户名、密码"
    echo -e "  ${YELLOW}2${NC}) 粘贴 ${BOLD}ip:port:username:password${NC} 格式文本"
    echo ""
    read -rp "请选择输入方式 [1/2] (默认 1): " MODE
    MODE="${MODE:-1}"

    if [[ "$MODE" == "2" ]]; then
        read -rp "请粘贴代理信息 (ip:port:user:pass): " INLINE_INPUT
        if [[ -z "$INLINE_INPUT" ]]; then
            log_error "输入不能为空"
            exit 1
        fi
        parse_inline "$INLINE_INPUT"
    else
        echo ""
        read -rp "SOCKS5 服务器地址 (IP 或域名): " PROXY_HOST
        read -rp "端口: " PROXY_PORT
        read -rp "用户名: " PROXY_USER
        read -rsp "密码: " PROXY_PASS
        echo ""
    fi
fi

# ── 基本校验 ──────────────────────────────────────────────
[[ -z "$PROXY_HOST" ]] && { log_error "服务器地址不能为空"; exit 1; }
[[ -z "$PROXY_PORT" ]] && { log_error "端口不能为空"; exit 1; }
[[ -z "$PROXY_USER" ]] && { log_error "用户名不能为空"; exit 1; }
[[ -z "$PROXY_PASS" ]] && { log_error "密码不能为空"; exit 1; }

if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
    log_error "端口号无效: $PROXY_PORT"
    exit 1
fi

# ── 显示确认信息 ───────────────────────────────────────────
echo ""
log_title "── 配置信息确认 ──────────────────────────────"
echo -e "  服务器地址 : ${BOLD}${PROXY_HOST}${NC}"
echo -e "  端口       : ${BOLD}${PROXY_PORT}${NC}"
echo -e "  用户名     : ${BOLD}${PROXY_USER}${NC}"
echo -e "  密码       : ${BOLD}$(echo "$PROXY_PASS" | sed 's/./*/g')${NC}"
echo -e "  输出文件   : ${BOLD}${OUTPUT_FILE}${NC}"
echo ""
read -rp "确认生成配置? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_warn "已取消"
    exit 0
fi

# ── 连通性测试 ─────────────────────────────────────────────
log_title "── 测试 SOCKS5 连通性 ──────────────────────────"
log_info "正在连接 ${PROXY_HOST}:${PROXY_PORT} ..."

TEST_IP=$(curl --socks5 "${PROXY_HOST}:${PROXY_PORT}" \
               --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
               --connect-timeout 10 \
               --max-time 15 \
               -s \
               https://api.ipify.org 2>&1) || true

if echo "$TEST_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    log_ok "连通性测试通过，出口 IP: ${BOLD}${TEST_IP}${NC}"
else
    echo ""
    log_warn "连通性测试失败，curl 返回: $TEST_IP"
    echo ""
    read -rp "仍然继续生成配置? [y/N]: " FORCE
    FORCE="${FORCE:-N}"
    if [[ ! "$FORCE" =~ ^[Yy]$ ]]; then
        log_warn "已取消。请检查代理信息或网络后重试"
        exit 1
    fi
fi

# ── 检查是否已存在旧配置 ──────────────────────────────────
if [[ -f "$OUTPUT_FILE" ]]; then
    BACKUP_FILE="${OUTPUT_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    log_warn "已存在旧配置，备份至: $BACKUP_FILE"
    cp "$OUTPUT_FILE" "$BACKUP_FILE"
fi

# ── 生成 conf JSON ─────────────────────────────────────────
log_title "── 生成配置文件 ────────────────────────────────"

mkdir -p "$CONF_DIR"

python3 - <<PYEOF
import json

conf = {
    "outbounds": [
        {
            "tag": "socks-static-ip",
            "type": "socks",
            "server": "${PROXY_HOST}",
            "server_port": ${PROXY_PORT},
            "version": "5",
            "username": "${PROXY_USER}",
            "password": "${PROXY_PASS}"
        }
    ],
    "route": {
        "rules": [
            {
                "protocol": "dns",
                "outbound": "direct"
            }
        ],
        "final": "socks-static-ip"
    }
}

with open("${OUTPUT_FILE}", "w") as f:
    json.dump(conf, f, indent=2, ensure_ascii=False)

print("  文件写入完成: ${OUTPUT_FILE}")
PYEOF

log_ok "配置文件生成成功"

# ── 校验合并配置 ───────────────────────────────────────────
log_title "── 校验 sing-box 合并配置 ──────────────────────"

CHECK_CMD="sing-box check -c ${CONFIG_MAIN} -C ${CONF_DIR}"
if $CHECK_CMD 2>&1; then
    log_ok "配置语法检查通过"
else
    log_error "配置语法检查失败，请查看上方错误信息"
    log_warn "已生成的配置文件保留在 ${OUTPUT_FILE}，请手动修复后执行:"
    echo "  sing-box check -c ${CONFIG_MAIN} -C ${CONF_DIR}"
    exit 1
fi

# ── 重启 sing-box ──────────────────────────────────────────
log_title "── 重启 sing-box ───────────────────────────────"
read -rp "是否立即重启 sing-box? [Y/n]: " DO_RESTART
DO_RESTART="${DO_RESTART:-Y}"

if [[ "$DO_RESTART" =~ ^[Yy]$ ]]; then
    sing-box restart
    sleep 2

    # 检查服务状态
    if systemctl is-active --quiet sing-box 2>/dev/null || \
       pgrep -x sing-box &>/dev/null; then
        log_ok "sing-box 已成功重启"
    else
        log_error "sing-box 重启后未运行，请查看日志: sing-box log"
        exit 1
    fi
else
    log_warn "已跳过重启，请手动执行: sing-box restart"
fi

# ── 完成 ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ 全部完成！${NC}"
echo ""
echo -e "  链式代理出口: ${BOLD}${PROXY_HOST}:${PROXY_PORT}${NC}"
if echo "$TEST_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "  预期出口 IP : ${BOLD}${TEST_IP}${NC}"
fi
echo ""
echo -e "  验证出口 IP (客户端连上代理后访问):"
echo -e "  ${CYAN}https://api.ipify.org${NC}"
echo ""
echo -e "  查看运行日志: ${YELLOW}sing-box log${NC}"
echo -e "  删除链式代理: ${YELLOW}rm ${OUTPUT_FILE} && sing-box restart${NC}"
echo ""