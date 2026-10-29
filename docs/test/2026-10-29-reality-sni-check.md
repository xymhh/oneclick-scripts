# reality-sni-check 验证记录

## 2026-10-29 首次入库

- 执行环境：Linux 6.1 x86_64，OpenSSL 3.0.22，curl 8.x
- 命令：`bash reality-sni-check/check-sni.sh <域名...>`

| 域名 | TLS | ALPN | 证书 | CDN | 结论 | 退出码 |
| --- | --- | --- | --- | --- | --- | --- |
| www.apple.com | 1.3 | h2 | 可信 CN=www.apple.com | 未命中 | 合格 | 0 |
| www.bing.com | 1.3 | h2 | 可信 CN=r.bing.com（SAN 覆盖） | 未命中 | 合格 | 0 |
| www.cityu.edu.hk | 1.3 | h2 | 可信 CN=imperva.com（SAN 覆盖 *.cityu.edu.hk） | 未命中 | 合格 | 0 |
| www.cloudflare.com | 1.3 | h2 | 可信 | 命中 | 可用但不理想 | 2 |
| example.org | 1.3 | h2 | 可信 | 命中（Cloudflare 回源） | 可用但不理想 | 2 |
| wrong.host.badssl.com | 1.2 | http/1.1 | **62 hostname mismatch** | 未命中 | 不合格 | 3 |
| no-such-host-8f2a.example | — | — | — | — | 不合格（DNS 失败） | 3 |

多域名汇总：`bash check-sni.sh www.cityu.edu.hk www.bing.com` → 退出码 0；混入 badssl 时退出码 3。

## 开发中修掉的 3 个问题

1. **TLS 版本抓不到**：首版匹配 `Protocol  : TLSv1.3`，OpenSSL 3.0 实际只打印 `New, TLSv1.3, Cipher is ...`，
   所有站点被判「TLS 版本未知」。改为先匹配 `New, TLSvx.y`，再回退旧格式 —— 修复后 apple/bing/cityu 均正确。
2. **OCSP 误杀**：原脚本把「无 OCSP 装订」当一票否决。Let's Encrypt 2025-05 起停止签发 OCSP，
   正常站点没有装订是常态，且 REALITY 客户端在 TLS 1.3 握手中不校验 OCSP。已降级为提示行。
3. **延迟探测受证书影响**：原来的 `curl` 探活遇到证书异常直接失败，导致「443 未连通」误报。
   改为 `curl -k` 只测 TCP 建连耗时，证书判定交给 `openssl s_client -verify_hostname`（能报 62 hostname mismatch）。
