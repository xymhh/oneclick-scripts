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

# 探测本机能否直连 api.github.com（4 秒超时）
# 能直连 → 返回 1（优先直连）；不能 → 返回 0（优先走加速）
gh_can_direct() {
    curl -fsS -m 4 -o /dev/null https://api.github.com/ 2>/dev/null
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
# 用法：gh_fetch <原始 https://github.com/... 地址> <输出文件> [超时秒]
gh_fetch() {
    local url="$1" out="$2" timeout="${3:-60}" prefix
    for prefix in "${MIRROR_ORDER[@]}"; do
        rm -f "$out"
        if curl -fL --connect-timeout 8 --max-time "$timeout" -o "$out" "${prefix}${url}" 2>/dev/null \
            && [[ -s "$out" ]]; then
            return 0
        fi
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
