#!/usr/bin/env bash
# =========================================================
# REALITY SNI 可用性检测（一次性运行，不安装任何东西、不改系统文件）
#
# 用途：挑 Xray / sing-box REALITY 的 dest(SNI) 时，先确认目标站点满足：
#   TLS 1.3 可协商 + ALPN h2 + 证书覆盖该域名 + 不是公共 CDN 回源
# 用法：bash check-sni.sh www.cityu.edu.hk [更多域名...]
# 退出码：0 合格 / 2 参数合格但疑似 CDN / 3 不合格 / 4 环境缺依赖
# 支持：任意 Linux（需要 curl、openssl、getent、timeout）
# =========================================================
set -uo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

if [ $# -eq 0 ]; then
    echo -e "${RED}[错误] 请提供要检测的域名！${NC}"
    echo -e "用法: bash check-sni.sh <域名> [更多域名...]"
    echo -e "例如: bash check-sni.sh www.cityu.edu.hk www.apple.com"
    exit 1
fi

for bin in curl openssl getent timeout; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "${RED}[错误] 缺少依赖: $bin${NC}"
        echo -e "  Debian/Ubuntu: apt-get install -y curl openssl coreutils"
        echo -e "  RHEL/CentOS:   yum install -y curl openssl coreutils"
        exit 4
    fi
done

OVERALL=0

check_one() {
    local domain="$1"
    local pass=1
    local cdn=0

    echo -e "\n${CYAN}================ 正在检测: ${BOLD}${domain}${NC}${CYAN} ================${NC}"

    # ---------- 1. 解析 + 延迟 ----------
    local resolved
    resolved=$(getent ahosts "$domain" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$resolved" ]; then
        echo -e "${RED}✗ DNS 解析       : [失败] 域名不存在或被本地 DNS 污染${NC}"
        echo -e "${RED}⛔ 判定结果: 【不合格】无法解析，不能作为 SNI${NC}"
        return 3
    fi
    local ver="IPv4"
    case "$resolved" in *:*) ver="IPv6" ;; esac

    local curl_data latency_ms remote_ip
    # -k：这一项只测「TCP 能不能连上、多久」，证书问题交给后面的 openssl 判定
    curl_data=$(curl -k -o /dev/null -s -4 -w "%{time_connect}|%{remote_ip}" \
        --connect-timeout 4 --max-time 8 "https://${domain}" 2>/dev/null || true)
    latency_ms=$(echo "$curl_data" | cut -d'|' -f1)
    remote_ip=$(echo "$curl_data" | cut -d'|' -f2)
    [ -z "$remote_ip" ] && remote_ip="$resolved"

    echo -e "🎯 解析 IP       : ${YELLOW}${remote_ip}${NC} (${ver})"
    if [ -n "$latency_ms" ] && [ "$latency_ms" != "0.000000" ]; then
        printf "⚡ TCP 握手延迟  : ${GREEN}%s ms${NC}\n" "$(awk -v t="$latency_ms" 'BEGIN{printf "%.1f", t*1000}')"
    else
        echo -e "⚡ TCP 握手延迟  : ${YELLOW}-- (443 未连通)${NC}"
    fi

    # ---------- 2. TLS 握手（不强制版本，让服务端自己协商） ----------
    # 用默认握手而不是 -tls1_3：强制版本会在对端不支持时直接失败，
    # 拿不到 ALPN/证书信息，也无法区分「不支持 1.3」和「根本连不上」。
    local ssl_out
    ssl_out=$(timeout 6 openssl s_client -connect "${domain}:443" \
        -servername "${domain}" -verify_hostname "${domain}" \
        -alpn h2,http/1.1 -status </dev/null 2>&1 || true)

    if ! echo "$ssl_out" | grep -q "BEGIN CERTIFICATE"; then
        echo -e "${RED}✗ TLS 握手       : [失败] 443 端口无有效 TLS（或该域名不提供 HTTPS）${NC}"
        echo -e "${RED}⛔ 判定结果: 【不合格】握手都建不起来，REALITY 无法伪装${NC}"
        return 3
    fi

    local proto
    # OpenSSL 3.x 只打印 "New, TLSv1.3, Cipher is ..."；1.1.1 另有 "Protocol  : TLSv1.3"
    proto=$(echo "$ssl_out" | grep -Eo 'New, *TLSv[0-9.]+' | head -1 | grep -Eo 'TLSv[0-9.]+' || true)
    [ -z "$proto" ] && proto=$(echo "$ssl_out" | grep -Eo 'Protocol *: *TLSv[0-9.]+' | head -1 | grep -Eo 'TLSv[0-9.]+' || true)
    if [ "$proto" = "TLSv1.3" ]; then
        echo -e "✅ TLS 版本       : ${GREEN}${proto} (可用)${NC}"
    else
        echo -e "✗ TLS 版本       : ${RED}${proto:-未知}（REALITY 必须 TLS 1.3）${NC}"
        pass=0
    fi

    # ---------- 3. ALPN h2 ----------
    local alpn
    alpn=$(echo "$ssl_out" | grep -Eo 'ALPN protocol: *[A-Za-z0-9./-]+' | head -1 | awk '{print $NF}' || true)
    if [ "$alpn" = "h2" ]; then
        echo -e "✅ ALPN           : ${GREEN}h2 (可用)${NC}"
    else
        echo -e "✗ ALPN           : ${RED}${alpn:-未协商}（客户端按 h2 拨号会失败，建议换成 h2 站点）${NC}"
        pass=0
    fi

    # ---------- 4. 证书是否覆盖该域名 ----------
    local verify_code subject
    verify_code=$(echo "$ssl_out" | grep -Eo 'Verify return code: [0-9]+ \([^)]*\)' | head -1 || true)
    subject=$(echo "$ssl_out" | grep -E '^subject=' | head -1 | sed 's/^subject=//' || true)
    if echo "$verify_code" | grep -q "0 (ok)"; then
        echo -e "✅ 证书校验       : ${GREEN}链路可信${NC} ${subject:+| $subject}"
    else
        echo -e "⚠️  证书校验       : ${YELLOW}${verify_code:-未返回}（自签 / 链不完整 / 域名不匹配都要留意）${NC}"
    fi

    # ---------- 5. OCSP 装订（仅提示） ----------
    # Let's Encrypt 2025-05 起已停发 OCSP，很多完全正常的站点这里是空的；
    # REALITY 客户端做 TLS 1.3 握手时不校验 OCSP，所以这里不再作为否决项。
    if echo "$ssl_out" | grep -q "OCSP Response Status: successful"; then
        echo -e "✅ OCSP 装订      : ${GREEN}有${NC}"
    else
        echo -e "ℹ️  OCSP 装订      : ${YELLOW}无（REALITY 不校验，可忽略）${NC}"
    fi

    # ---------- 6. 公共 CDN 特征 ----------
    local headers
    headers=$(curl -sI -m 5 -4 "https://${domain}" 2>/dev/null || true)
    if echo "$headers" | grep -Eqi '^(cf-ray|x-amz-cf-id|x-served-by|x-akamai-|server: *cloudflare|server: *AkamaiGHost|via: .*fastly)'; then
        cdn=1
        echo -e "⚠️  CDN 特征      : ${RED}检测到公共大厂 CDN（与别人共用 IP，敏感期更容易被牵连封锁）${NC}"
    elif echo "$headers" | grep -Eqi '^server: *cloudflare|cf-cache-status'; then
        cdn=1
        echo -e "⚠️  CDN 特征      : ${RED}检测到 Cloudflare 回源特征${NC}"
    else
        echo -e "✅ CDN 特征      : ${GREEN}未检测到公共 CDN${NC}"
    fi

    # ---------- 7. 结论 ----------
    echo -e "${CYAN}-------------------------------------------------------${NC}"
    local code
    if [ $pass -eq 1 ] && [ $cdn -eq 0 ]; then
        echo -e "${GREEN}${BOLD}🎉 【合格】TLS1.3 + h2 + 独立 IP，可作为 REALITY 的 dest/SNI${NC}"
        code=0
    elif [ $pass -eq 1 ]; then
        echo -e "${YELLOW}${BOLD}⚠️  【可用但不理想】握手参数达标，但走了公共 CDN：能连，敏感期风险高${NC}"
        code=2
    else
        echo -e "${RED}${BOLD}⛔ 【不合格】缺少关键握手参数，客户端会连不上${NC}"
        code=3
    fi
    echo -e "${CYAN}=======================================================${NC}"
    return $code
}

for d in "$@"; do
    check_one "$d"
    rc=$?
    # 不合格的结论优先展示（0 合格 > 2 CDN > 3 不合格 > 4 依赖）
    if [ $rc -eq 3 ]; then
        OVERALL=3
    elif [ $rc -eq 2 ] && [ $OVERALL -ne 3 ]; then
        OVERALL=2
    fi
done

if [ "$#" -gt 1 ]; then
    echo -e "\n${BOLD}总计：检查 $# 个域名，最差结论退出码 ${OVERALL}${NC}"
fi
exit $OVERALL
