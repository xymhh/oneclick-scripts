#!/usr/bin/env bash
# =========================================================
# 公共函数参考实现 —— 复制进各脚本，不要 source 远程文件
# （curl | bash 时本地没有这个文件，所以每个 install.sh 自带一份）
# =========================================================

# GitHub 加速前缀。顺序即重试顺序，空串代表直连。
GH_MIRRORS=(
    ""
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
)

# 探测本机能否直连 GitHub 下载链路（4 秒超时）
# api.github.com 通不代表能下 release 资产，两个域名都通才算直连可用
gh_can_direct() {
    curl -fsS -m 4 -o /dev/null https://api.github.com/ 2>/dev/null || return 1
    curl -fsS -m 4 -o /dev/null https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/README.md 2>/dev/null || return 1
    return 0
}

# 按「能否直连」排出本次使用的镜像顺序，写入全局 MIRROR_ORDER
# 用法：gh_build_mirror_order [auto|direct|proxy]
gh_build_mirror_order() {
    local mode="${1:-auto}"
    case "$mode" in
        direct) MIRROR_ORDER=("") ;;
        proxy)  MIRROR_ORDER=("https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/") ;;
        *)
            if gh_can_direct; then
                MIRROR_ORDER=("${GH_MIRRORS[@]}")
            else
                MIRROR_ORDER=("https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" "")
            fi
            ;;
    esac
}

# 下载：对每个镜像尝试一次，成功即返回 0
# 关键点（踩过的坑）：
#   1. 必须有进度条（--progress-bar），否则静默 curl 看起来就是「卡死」；
#   2. 必须加 --speed-limit/--speed-time，低到 1KB/s 持续 15 秒就换源，
#      不要靠 --max-time 干等几分钟；
#   3. 每次尝试打印「→ 尝试 X / ✗ 失败 Ns」，失败也要有回显。
# 用法：gh_fetch <原始 https://github.com/... 地址> <输出文件> [单源超时秒]
gh_fetch() {
    local url="$1" out="$2" timeout="${3:-90}" prefix label t0 cost
    for prefix in "${MIRROR_ORDER[@]}"; do
        if [[ -n "${prefix}" ]]; then label="加速源 ${prefix}"; else label="直连 GitHub"; fi
        echo "  → 尝试${label}"
        rm -f "$out"
        t0=$(date +%s)
        if curl -fL --progress-bar --connect-timeout 5 --speed-limit 1024 --speed-time 15 \
                --max-time "${timeout}" -o "$out" "${prefix}${url}" 2>&1; then
            cost=$(( $(date +%s) - t0 ))
            echo "  ✓ ${label}成功（${cost}s）"
            return 0
        fi
        cost=$(( $(date +%s) - t0 ))
        echo "  ✗ ${label}失败（${cost}s），换下一个"
    done
    rm -f "$out"
    return 1
}

# 取 GitHub 最新 release tag（对 api.github.com 也套镜像）
# 用法：gh_latest_tag <owner/repo> <失败时的 fallback tag>
gh_latest_tag() {
    local repo="$1" fallback="$2" prefix tag
    for prefix in "${MIRROR_ORDER[@]}"; do
        tag=$(curl -fsSL -m 10 "${prefix}https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name":' \
            | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -n "$tag" ]] && { echo "$tag"; return 0; }
    done
    echo "$fallback"
}
