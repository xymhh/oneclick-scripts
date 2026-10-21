# easytier-node 验证记录（2026-10-21）

环境：容器内 Linux x86_64（无 systemd、无 /dev/net/tun），只做**参数 / 下载 / 二进制**层面的验证；systemd 单元与真实中继效果待在真机 VPS 上验证。

## 1. 语法

```
bash -n easytier-node/install.sh  → OK
bash -n lib/common.sh             → OK
```
（容器内未装 shellcheck，未做静态检查）

## 2. 镜像与下载（实测，非模拟）

用 `lib/common.sh` 里同一套函数实测：

| 项目 | 结果 |
| --- | --- |
| `gh_can_direct`（直连 api.github.com，4s 超时） | 可用 |
| `gh_build_mirror_order auto` | `["", ghfast.top, gh-proxy.com, ghproxy.net]` |
| `gh_latest_tag EasyTier/EasyTier v2.6.4` | `v2.6.4` |
| 直连下载 `easytier-linux-x86_64-v2.6.4.zip` | 成功，25 506 523 字节 |
| 仅加速源（ghfast.top → gh-proxy.com）下载同一资产 | 成功，25 506 523 字节（与直连同尺寸） |

## 3. Release 资产命名核对

`GET /repos/EasyTier/EasyTier/releases/latest`（2026-10-21）→ `v2.6.4`，linux 资产为
`easytier-linux-{x86_64,aarch64,armv7,armv7hf,armhf,arm,riscv64,loongarch64,mips,…}-v2.6.4.zip`。

脚本 `check_arch` 的映射（x86_64 / aarch64 / armv7 / riscv64 / loongarch64）与上述命名一致；`uname -m` 为 `armv7l`、`armv8l`、`armhf` 都归到 `armv7`。

## 4. 启动参数逐个跑真二进制验证

解压后 `easytier-core 2.6.4-8428a89d`，`--no-tun` 起 6 秒看它打印的生效配置：

| 脚本模式 | 实际传参 | 二进制输出 |
| --- | --- | --- |
| 1 打洞轻量 | `--relay-network-whitelist "" --relay-all-peer-rpc` | `relay_network_whitelist = ""`、`relay_all_peer_rpc = true` |
| 2 全量中继 | `--relay-network-whitelist "*"` | 与默认值相同 → dump 省略（默认即 `*`，全放行） |
| 3 白名单单组 | `--relay-network-whitelist "P????-MYR00"` | `relay_network_whitelist = "P????-MYR00"` |
| 3 白名单多组 | `--relay-network-whitelist "P????-MYR00,P????-ABC12"` | `relay_network_whitelist = "P????-MYR00 P????-ABC12"`（逗号→空格，白名单按空白/逗号切分都能命中） |
| 4 私有组网 | `--network-name` / `--network-secret` | `--help` 中均存在 |

同时确认 2.6.4 的 `--help` 里确实有 `--relay-network-whitelist`、`--relay-all-peer-rpc`、`--network-name`、`--network-secret` 四个参数（旧版第三方脚本里出现过上游不存在的参数，会直接起不来）。

## 5. 下载体验修复（同日二次验证）

现象：首版在真机（国内 VPS）上「卡在下载 EasyTier」，无任何输出。定位到三个原因：

1. 直连探测只测 `api.github.com`，国内常见「api 通、release 资产域名不通」→ 先卡在直连；
2. 单源 `--max-time 180`，4 个源最长干等 12 分钟；
3. `curl` 静默 + `2>/dev/null`，进度和失败原因全被吞掉。

修复后的实测：

| 项目 | 结果 |
| --- | --- |
| 坏源 `https://127.0.0.1:9/` → 换下一个 | 0 秒失败并回显，不阻塞 |
| 紧随其后 `https://ghfast.top/` 下载 25.5MB 资产 | 成功，10 秒，进度条正常，字节数 25 506 523 与直连一致 |
| `bash -n` | install.sh / lib/common.sh 均通过 |
| 直连探测改为 api + raw 双域名 | 任一不通即走加速源优先 |

`--speed-limit 1024 --speed-time 15`：15 秒内低于 1KB/s 视为卡死，立刻换源，不再靠 `--max-time` 干等。

## 6. 尚未验证（需真机）

- [ ] systemd 单元写入后 `systemctl start easytier` 正常拉起（容器无 systemd）
- [ ] 两台机器同填私有节点 + 白名单 `P????-MYR00`，PCL2 建房/加入成功
- [ ] 模式 1 下确实不转发数据（只有打洞协助）
