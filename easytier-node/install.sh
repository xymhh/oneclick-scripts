#!/usr/bin/env bash
# =========================================================
# EasyTier 共享 / 中继节点一键管理脚本（支持网络白名单）
#
# 支持：Debian/Ubuntu、RHEL/CentOS/Rocky/Alma、Alpine；x86_64 / aarch64 / armv7
# 改动：装 easytier-core / easytier-cli 到 /usr/local/bin、写 /etc/easytier/node.conf、
#       写 /etc/systemd/system/easytier.service
#
# 用法（交互菜单）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)
# 非交互：
#   bash install.sh --mode 3 --port 11010 --whitelist "P????-MYR00" --yes
#   bash install.sh --mode 4 --network-name mynet --network-secret mypass --yes
# =========================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/easytier"
CONFIG_FILE="${CONFIG_DIR}/node.conf"
SERVICE_FILE="/etc/systemd/system/easytier.service"

# 取不到最新版本号时用这个（与 PCL2 内置 EasyTier 版本对齐，2.6.4）
ET_FALLBACK_TAG="v2.6.4"
ET_REPO="EasyTier/EasyTier"

# ---- 命令行参数（默认全部走交互） ----
OPT_MODE=""; OPT_PORT=""; OPT_WHITELIST=""; OPT_NET_NAME=""; OPT_NET_SECRET=""
OPT_VERSION=""; OPT_MIRROR="auto"; OPT_YES=0

# =========================================================
# 下载加速：直连 + 三个加速前缀，失败依次重试
# =========================================================
MIRROR_ORDER=()

gh_can_direct() {
    # api.github.com 通 ≠ 下载通：国内常见「api 能过，raw / release 资产域名被墙」，
    # 所以两个域名都要通才算直连可用，否则默认走加速源，避免先卡在直连上干等。
    curl -fsS -m 4 -o /dev/null https://api.github.com/ 2>/dev/null || return 1
    curl -fsS -m 4 -o /dev/null https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/README.md 2>/dev/null || return 1
    return 0
}

build_mirror_order() {
    case "${OPT_MIRROR}" in
        direct) MIRROR_ORDER=("") ;;
        proxy)  MIRROR_ORDER=("https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/") ;;
        *)
            if gh_can_direct; then
                MIRROR_ORDER=("" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/")
            else
                MIRROR_ORDER=("https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" "")
            fi
            ;;
    esac
}

gh_fetch() {
    local url="$1" out="$2" timeout="${3:-90}" prefix label t0 cost
    for prefix in "${MIRROR_ORDER[@]}"; do
        if [[ -n "${prefix}" ]]; then label="加速源 ${prefix}"; else label="直连 GitHub"; fi
        echo -e "  ${BLUE}→ 尝试${label}${PLAIN}"
        rm -f "$out"
        t0=$(date +%s)
        # --speed-limit/--speed-time：15 秒内低于 1KB/s 就判定卡死并换源，不用干等 --max-time
        if curl -fL --progress-bar --connect-timeout 5 --speed-limit 1024 --speed-time 15 \
                --max-time "${timeout}" -o "$out" "${prefix}${url}" 2>&1 ; then
            cost=$(( $(date +%s) - t0 ))
            echo -e "  ${GREEN}✓ ${label}成功（${cost}s，$(du -h "$out" | cut -f1)）${PLAIN}"
            return 0
        fi
        cost=$(( $(date +%s) - t0 ))
        echo -e "  ${YELLOW}✗ ${label}失败（${cost}s），换下一个${PLAIN}"
    done
    rm -f "$out"
    return 1
}

gh_latest_tag() {
    local prefix tag
    for prefix in "${MIRROR_ORDER[@]}"; do
        tag=$(curl -fsSL -m 10 "${prefix}https://api.github.com/repos/${ET_REPO}/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -n "$tag" ]] && { echo "$tag"; return 0; }
    done
    echo "${ET_FALLBACK_TAG}"
}

# =========================================================
# 基础
# =========================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)           OPT_MODE="${2:-}"; shift 2 ;;
            --port)           OPT_PORT="${2:-}"; shift 2 ;;
            --whitelist)      OPT_WHITELIST="${2:-}"; shift 2 ;;
            --network-name)   OPT_NET_NAME="${2:-}"; shift 2 ;;
            --network-secret) OPT_NET_SECRET="${2:-}"; shift 2 ;;
            --version)        OPT_VERSION="${2:-}"; shift 2 ;;
            --mirror)         OPT_MIRROR="${2:-auto}"; shift 2 ;;
            --yes|-y)         OPT_YES=1; shift ;;
            --help|-h)
                sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
                exit 0 ;;
            *) echo -e "${RED}未知参数：$1（--help 查看用法）${PLAIN}"; exit 1 ;;
        esac
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}错误：请以 root 权限运行此脚本！${PLAIN}"; exit 1; }
}

check_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   ET_ARCH="x86_64" ;;
        aarch64|arm64)  ET_ARCH="aarch64" ;;
        armv7*|armv8l|armhf) ET_ARCH="armv7" ;;
        riscv64)        ET_ARCH="riscv64" ;;
        loongarch64|loongarch64*) ET_ARCH="loongarch64" ;;
        *) echo -e "${RED}暂不支持当前架构：${arch}（上游未提供对应 EasyTier 安装包）${PLAIN}"; exit 1 ;;
    esac
}

install_dependencies() {
    echo -e "${YELLOW}正在检查基础依赖（curl wget unzip tar）...${PLAIN}"
    local pkgs="curl wget unzip tar"
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y $pkgs >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y $pkgs >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache $pkgs >/dev/null 2>&1
    fi
    local missing=""
    for c in curl unzip tar; do command -v "$c" &>/dev/null || missing="$missing $c"; done
    [[ -n "$missing" ]] && { echo -e "${RED}依赖安装失败，缺少：${missing}${PLAIN}"; exit 1; }
}

get_public_ip() {
    SERVER_IP=$(curl -s4m 5 https://api.ipify.org 2>/dev/null \
        || curl -s4m 5 https://ifconfig.me 2>/dev/null \
        || curl -s4m 5 https://ip.sb 2>/dev/null)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<你的服务器公网IP>"
}

load_config() {
    LISTEN_PORT="11010"; MODE="3"; WHITELIST=""; NET_NAME=""; NET_SECRET=""
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}" 2>/dev/null
    fi
}

# =========================================================
# 服务单元
# =========================================================
create_service() {
    local args=(-l "tcp://0.0.0.0:${LISTEN_PORT}" -l "udp://0.0.0.0:${LISTEN_PORT}")
    case "${MODE}" in
        1) # 只协助打洞：清空白名单（=不转发数据）+ 仍接受对端 RPC
           args+=(--relay-network-whitelist "" --relay-all-peer-rpc) ;;
        2) # 全量中继：显式写 "*"，别依赖上游默认值（默认虽也是 *，但不写出来服务单元看不出意图）
           args+=(--relay-network-whitelist "*") ;;
        3) # 白名单：逗号分隔多个通配符
           args+=(--relay-network-whitelist "${WHITELIST}") ;;
        4) # 私有组网：本机作为该网络的普通节点
           args+=(--network-name "${NET_NAME}" --network-secret "${NET_SECRET}") ;;
    esac

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=EasyTier Shared/Relay Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core ${args[*]}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable easytier.service >/dev/null 2>&1
}

# =========================================================
# 核心安装 / 配置
# =========================================================
install_or_update_core() {
    check_arch
    install_dependencies
    build_mirror_order

    echo -e "${CYAN}正在获取 EasyTier 版本信息...${PLAIN}"
    local tag="${OPT_VERSION}"
    if [[ -z "${tag}" ]]; then
        tag=$(gh_latest_tag)
        [[ "${tag}" == "${ET_FALLBACK_TAG}" ]] && echo -e "${YELLOW}（接口未取到版本号，使用内置 fallback：${tag}）${PLAIN}"
    fi
    echo -e "目标版本：${GREEN}${tag}${PLAIN}（架构：${ET_ARCH}）"

    local zip_name="easytier-linux-${ET_ARCH}-${tag}.zip"
    local tmp_dir="/tmp/easytier_tmp"
    rm -rf "$tmp_dir" && mkdir -p "$tmp_dir"

    echo -e "${YELLOW}正在下载核心文件...${PLAIN}"
    if ! gh_fetch "https://github.com/${ET_REPO}/releases/download/${tag}/${zip_name}" "${tmp_dir}/${zip_name}" 90; then
        echo -e "${RED}下载失败：所有源都没成。可重试：bash install.sh --mirror proxy --mode 3 --yes${PLAIN}"
        echo -e "${YELLOW}或手动下载后放到本机，用 --version ${tag} 跳过联网取版本号。${PLAIN}"
        return 1
    fi

    unzip -q -o "${tmp_dir}/${zip_name}" -d "$tmp_dir" || { echo -e "${RED}解压失败！${PLAIN}"; return 1; }
    local f_core f_cli
    f_core=$(find "$tmp_dir" -type f -name "easytier-core" | head -n 1)
    f_cli=$(find "$tmp_dir" -type f -name "easytier-cli" | head -n 1)

    if [[ -z "${f_core}" ]]; then
        echo -e "${RED}压缩包里没找到 easytier-core！${PLAIN}"
        return 1
    fi

    systemctl stop easytier >/dev/null 2>&1
    install -m 755 "$f_core" "${INSTALL_DIR}/easytier-core"
    [[ -n "${f_cli}" ]] && install -m 755 "$f_cli" "${INSTALL_DIR}/easytier-cli"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}核心部署完成：$(${INSTALL_DIR}/easytier-core --version 2>/dev/null | head -n 1)${PLAIN}"

    if [[ ! -f "${CONFIG_FILE}" || -n "${OPT_MODE}" ]]; then
        configure_node
    else
        systemctl daemon-reload
        systemctl restart easytier.service
        echo -e "${GREEN}检测到已有配置，服务已用新核心重启。${PLAIN}"
        hold_screen
    fi
}

configure_node() {
    if [[ ! -x "${INSTALL_DIR}/easytier-core" ]]; then
        echo -e "${RED}未检测到 EasyTier 核心，请先执行 [1] 安装！${PLAIN}"
        hold_screen; return 1
    fi
    mkdir -p "${CONFIG_DIR}"
    load_config

    echo -e "\n${CYAN}================ 配置 EasyTier 节点 ================${PLAIN}"
    echo -e "  ${GREEN}1)${PLAIN} 公开打洞轻量模式：只协助打洞，不转发数据（最省流量，对称 NAT 玩家容易连不上）"
    echo -e "  ${GREEN}2)${PLAIN} 公开全量中继模式：谁都能用你中转（带宽会被白嫖，慎用）"
    echo -e "  ${GREEN}3)${PLAIN} 网络白名单模式 ${YELLOW}[推荐]${PLAIN}：只给匹配通配符的网络中转"
    echo -e "  ${GREEN}4)${PLAIN} 私有独立组网模式：本机作为指定网络的一个节点"

    MODE="${OPT_MODE}"
    while [[ ! "${MODE}" =~ ^[1-4]$ ]]; do
        read -rp "请选择模式 [1-4, 默认 ${MODE:-3}]: " MODE
        MODE="${MODE:-3}"
    done

    local port="${OPT_PORT}"
    if [[ -z "${port}" && "${OPT_YES}" -eq 1 ]]; then port="${LISTEN_PORT}"; fi
    while [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); do
        [[ "${OPT_YES}" -eq 1 ]] && { port="${LISTEN_PORT}"; break; }
        read -rp "监听端口 [TCP/UDP 同端口, 当前/默认 ${LISTEN_PORT}]: " port
        port="${port:-${LISTEN_PORT}}"
    done
    LISTEN_PORT="$port"

    case "${MODE}" in
        3)
            echo -e "\n${YELLOW}白名单支持 wildmatch 通配符：* 任意多个字符，? 单个字符；逗号分隔多个。${PLAIN}"
            echo -e "  PCL2 联机房间名格式为 P<端口hex4>-<5位后缀>，例如 P63DD-MYR00："
            echo -e "    只放行自己那一组   → ${CYAN}P????-MYR00${PLAIN}"
            echo -e "    放行所有 PCL2 房间 → ${CYAN}P????-*${PLAIN}"
            WHITELIST="${OPT_WHITELIST}"
            if [[ -z "${WHITELIST}" && "${OPT_YES}" -eq 0 ]]; then
                read -rp "允许中继的网络白名单 [默认 P????-*]: " WHITELIST
            fi
            WHITELIST="${WHITELIST:-P????-*}"
            ;;
        4)
            NET_NAME="${OPT_NET_NAME}"; NET_SECRET="${OPT_NET_SECRET}"
            if [[ "${OPT_YES}" -eq 1 ]] && [[ -z "${NET_NAME}" || -z "${NET_SECRET}" ]]; then
                echo -e "${RED}模式 4 需要同时提供 --network-name 与 --network-secret${PLAIN}"
                exit 1
            fi
            while [[ -z "${NET_NAME}" ]]; do read -rp "网络名称 (Network Name): " NET_NAME; done
            while [[ -z "${NET_SECRET}" ]]; do read -rp "网络密钥 (Network Secret): " NET_SECRET; done
            ;;
    esac

    cat > "${CONFIG_FILE}" <<EOF
# 由 easytier-node/install.sh 生成，仅用于本脚本回显与重配；服务单元里已固化启动参数
LISTEN_PORT='${LISTEN_PORT}'
MODE='${MODE}'
WHITELIST='${WHITELIST}'
NET_NAME='${NET_NAME}'
NET_SECRET='${NET_SECRET}'
EOF
    chmod 600 "${CONFIG_FILE}"

    create_service

    echo -e "${YELLOW}正在重启 EasyTier 服务...${PLAIN}"
    systemctl restart easytier.service
    sleep 1

    get_public_ip
    echo -e "\n${GREEN}==================== 配置已生效 ====================${PLAIN}"
    echo -e "模式    : ${CYAN}${MODE}${PLAIN}  端口: ${CYAN}${LISTEN_PORT} (TCP/UDP)${PLAIN}"
    [[ "${MODE}" == "3" ]] && echo -e "白名单  : ${CYAN}${WHITELIST}${PLAIN}"
    [[ "${MODE}" == "4" ]] && echo -e "网络名  : ${CYAN}${NET_NAME}${PLAIN}"
    echo -e "节点地址："
    echo -e "  ${YELLOW}tcp://${SERVER_IP}:${LISTEN_PORT}${PLAIN}"
    echo -e "  ${YELLOW}udp://${SERVER_IP}:${LISTEN_PORT}${PLAIN}"
    echo -e "放行防火墙（如启用）："
    echo -e "  ${CYAN}ufw allow ${LISTEN_PORT}/tcp; ufw allow ${LISTEN_PORT}/udp${PLAIN}"
    echo -e "  ${CYAN}firewall-cmd --add-port=${LISTEN_PORT}/{tcp,udp} --permanent && firewall-cmd --reload${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}\n"
    hold_screen
}

show_status() {
    if [[ -x "${INSTALL_DIR}/easytier-core" ]]; then
        echo -e "核心状态: ${GREEN}已安装${PLAIN} ($(${INSTALL_DIR}/easytier-core --version 2>/dev/null | head -n 1))"
    else
        echo -e "核心状态: ${RED}未安装${PLAIN}"
    fi
    if systemctl is-active --quiet easytier 2>/dev/null; then
        echo -e "运行状态: ${GREEN}运行中${PLAIN}"
    else
        echo -e "运行状态: ${RED}未运行${PLAIN}"
    fi
    if [[ -f "${CONFIG_FILE}" ]]; then
        load_config
        get_public_ip
        echo -e "监听端口: ${CYAN}${LISTEN_PORT}${PLAIN}  模式: ${CYAN}${MODE}${PLAIN}"
        [[ "${MODE}" == "3" ]] && echo -e "白名单  : ${CYAN}${WHITELIST}${PLAIN}"
        echo -e "节点地址: ${CYAN}tcp://${SERVER_IP}:${LISTEN_PORT}${PLAIN} / ${CYAN}udp://${SERVER_IP}:${LISTEN_PORT}${PLAIN}"
    fi
}

show_log() {
    echo -e "${YELLOW}实时日志（Ctrl+C 退出）...${PLAIN}"
    journalctl -u easytier -n 50 -f
}

uninstall_easytier() {
    local confirm="y"
    if [[ "${OPT_YES}" -eq 0 ]]; then
        read -rp "确定彻底卸载 EasyTier（含配置与 systemd 单元）？[y/N]: " confirm
    fi
    [[ "${confirm}" != [yY] ]] && return
    systemctl stop easytier >/dev/null 2>&1
    systemctl disable easytier >/dev/null 2>&1
    rm -f "${SERVICE_FILE}"
    rm -rf "${CONFIG_DIR}"
    rm -f "${INSTALL_DIR}/easytier-core" "${INSTALL_DIR}/easytier-cli"
    systemctl daemon-reload
    echo -e "${GREEN}已完全卸载。${PLAIN}"
    hold_screen
}

hold_screen() {
    [[ "${OPT_YES}" -eq 1 ]] && return
    read -rp "按回车返回菜单..."
}

# =========================================================
# 入口
# =========================================================
main() {
    parse_args "$@"
    require_root
    build_mirror_order

    # 非交互：给了 --mode 就直接装好并配置好
    if [[ -n "${OPT_MODE}" ]]; then
        install_or_update_core && exit 0 || exit 1
    fi

    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${GREEN}        EasyTier 共享 / 中继节点管理脚本${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        show_status
        echo -e "----------------------------------------------------"
        echo -e " 1) 安装 / 升级 EasyTier 核心"
        echo -e " 2) 修改节点配置（模式 / 端口 / 白名单）"
        echo -e " 3) 启动服务    4) 停止服务    5) 重启服务"
        echo -e " 6) 查看实时日志"
        echo -e " 7) 彻底卸载"
        echo -e " 0) 退出"
        echo -e "----------------------------------------------------"
        read -rp "请输入选项 [0-7]: " choice
        case "${choice}" in
            1) install_or_update_core ;;
            2) configure_node ;;
            3) systemctl start easytier && echo -e "${GREEN}已启动${PLAIN}"; sleep 1 ;;
            4) systemctl stop easytier && echo -e "${YELLOW}已停止${PLAIN}"; sleep 1 ;;
            5) systemctl restart easytier && echo -e "${GREEN}已重启${PLAIN}"; sleep 1 ;;
            6) show_log ;;
            7) uninstall_easytier ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入有误${PLAIN}"; sleep 1 ;;
        esac
    done
}

main "$@"
