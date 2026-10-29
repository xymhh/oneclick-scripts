# REALITY SNI 检测（check-sni.sh）

挑 Xray / sing-box **REALITY** 的 `dest`（SNI 目标）时用的一次性诊断脚本：**不安装、不改系统文件、不留残留**，跑完只输出结果。

REALITY 的目标站点必须同时满足三件事，缺一个客户端就握不上手：

1. **支持 TLS 1.3**（REALITY 内部按 1.3 握手）
2. **ALPN 协商出 `h2`**（客户端默认按 h2 拨号）
3. **证书覆盖这个域名**（否则中间人一眼看出异常）

脚本按这三条判定「合格 / 可用但不理想 / 不合格」，并顺带给出延迟、证书主体、OCSP、公共 CDN 特征。

## 一键运行

```bash
# 境外 VPS
bash <(curl -fsSL https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/reality-sni-check/check-sni.sh) www.cityu.edu.hk

# 国内 VPS（套加速前缀）
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/reality-sni-check/check-sni.sh) www.cityu.edu.hk
```

一次可以给多个域名，脚本逐个检测、最后汇总退出码：

```bash
bash check-sni.sh www.apple.com www.cloudflare.com www.bing.com
```

## 输出含义

| 行 | 含义 | 是否否决 |
| --- | --- | --- |
| `TLS 版本` | 协商到的版本，必须是 TLSv1.3 | ✅ 否决 |
| `ALPN` | 协商出的协议，必须是 `h2` | ✅ 否决 |
| `证书校验` | OpenSSL 链校验结果 + 证书主体 | ⚠️ 提示（自签/不匹配要人工判断） |
| `OCSP 装订` | 是否有装订 | ❌ 不否决（REALITY 不校验；且 Let's Encrypt 2025-05 起已停发 OCSP） |
| `CDN 特征` | Cloudflare / Akamai / Fastly / CloudFront 回源特征 | ⚠️ 不否决，但判为「可用但不理想」 |

**结论三档**

- `🎉 合格`：TLS1.3 + h2 + 未命中公共 CDN → 直接拿来当 SNI
- `⚠️ 可用但不理想`：握手达标但走了公共 CDN —— 与海量站点共用 IP，敏感期被牵连封锁的概率高
- `⛔ 不合格`：解析失败 / 443 无 TLS / 不支持 1.3 / 协商不出 h2

**退出码**（方便写进自动化）

| 码 | 含义 |
| --- | --- |
| 0 | 合格 |
| 2 | 参数合格但疑似公共 CDN |
| 3 | 不合格 |
| 4 | 本机缺依赖（curl / openssl / getent / timeout） |

## 挑 SNI 的经验

- 优先选**目标地区常用的中大型站点**（本地高校、当地运营商、当地银行官网），流量特征越大越不显眼。
- 别选**公共 CDN 回源**的站点：IP 上挂着几十万个域名，别人被墙会连坐。
- 别选**自己也在用 CDN/被墙**的域名：`www.google.com`、`www.wikipedia.org` 这类在国内解析就被污染。
- 选好后最好在**落地 VPS 上**跑本脚本（延迟/连通性以落地视角为准），而不是在本地机器上跑。
- 换完 SNI 记得用客户端实测一次：`curl --resolve` 或直接连代理访问 `https://<SNI域名>/` 看是否正常。

## 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `TLS 版本：未知` | OpenSSL 太老（1.0.x）不打印协商版本；`openssl version` 低于 1.1.1 请先升级 |
| `ALPN：未协商` | 站点只给 http/1.1。REALITY 客户端按 h2 拨号会失败，换站点 |
| `证书校验：链路不完整` | 站点没发中间证书，部分客户端仍能握手，但不建议选 |
| `CDN 特征：检测到` | 说明是 Cloudflare/Akamai 等回源，不是不能用，只是风险高 |
| 全部域名都 `443 未连通` | 本机出网被限（安全组 / 防火墙 / IPv6 优先），先 `curl -v https://<域名>` 排障 |
| Windows 上跑 | 需要 Git Bash 或 WSL，原生 cmd/PowerShell 不支持本脚本 |
