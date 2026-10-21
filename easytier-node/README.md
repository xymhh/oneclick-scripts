# easytier-node —— EasyTier 共享 / 中继节点一键管理

把一台 Linux VPS 变成 EasyTier 节点：只协助打洞、全量中继，或只给指定网络名中转（白名单）。装完带交互菜单，改配置不用背参数。

## 环境要求

- Linux，root 权限；systemd（Debian 9+/Ubuntu 18+/CentOS 7+/Rocky/Alma 均可）
- 架构：x86_64、aarch64、armv7、riscv64、loongarch64（与上游 Release 资产一致）
- 会自动装依赖：`curl wget unzip tar`
- 会写入的文件：`/usr/local/bin/easytier-core`、`/usr/local/bin/easytier-cli`、`/etc/easytier/node.conf`、`/etc/systemd/system/easytier.service`

## 一句话安装

### 境外 VPS

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)
```

### 国内 VPS（拉脚本这一步走加速）

```bash
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)
```

脚本拿到手后，**下载 EasyTier 核心时会自动挑源**：先试直连 `api.github.com`（4 秒超时），通就直连优先；不通就按 `ghfast.top → gh-proxy.com → ghproxy.net → 直连` 依次重试。也可以用 `--mirror proxy|direct|auto` 强制指定。

### 想先审一遍

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh -o et.sh
less et.sh
sudo bash et.sh
```

## 四种模式

| 模式 | 参数 | 行为 | 适用 |
| --- | --- | --- | --- |
| 1 打洞轻量 | `--mode 1` | `relay_network_whitelist=""` + `relay_all_peer_rpc`：只帮对端建立连接，**不转发数据** | 带宽小、只想帮朋友打洞 |
| 2 全量中继 | `--mode 2` | 白名单 `*`：任何网络都能用你中转 | 自用、明确知道带宽够 |
| 3 白名单 | `--mode 3 --whitelist "P????-MYR00"` | 只有网络名匹配的才允许中转 | **PCL2 联机推荐**，防白嫖 |
| 4 私有组网 | `--mode 4 --network-name X --network-secret Y` | 本机成为该网络的普通节点 | 自己组网，不做公共中继 |

默认值：模式 3、端口 11010、白名单 `P????-*`。

### 白名单怎么写

EasyTier 用 wildmatch 匹配网络名（源码 `easytier-core/src/peers/whitelist.rs`）：

- `*` 任意多个字符、`?` 单个字符、`[a-z]` 字符集，**区分大小写**
- 逗号或空格分隔多个模式，任一命中即放行
- **不写 `--relay-network-whitelist` 等于 `"*"`（全放行）**；显式写 `""` 才是「谁的都不转」

PCL2 联机的网络名格式是 `P<端口hex4>-<5位后缀>`，例如 `P63DD-MYR00`：

| 想要的放行范围 | 白名单写法 |
| --- | --- |
| 只放行自己那一组人（在 PCL 里把后缀固定成 `MYR00`） | `P????-MYR00` |
| 放行所有 PCL2 房间 | `P????-*` |
| 放行两组 | `P????-MYR00,P????-ABC12` |

## 非交互用法

```bash
# 白名单模式，指定端口
sudo bash install.sh --mode 3 --port 11010 --whitelist "P????-MYR00" --yes

# 私有组网
sudo bash install.sh --mode 4 --network-name mynet --network-secret mypass --yes

# 指定 EasyTier 版本 / 强制走加速
sudo bash install.sh --version v2.6.4 --mirror proxy --mode 3 --yes
```

取版本号失败时脚本内置 fallback `v2.6.4`（与 PCL2 内置版本一致，避免中继端比客户端旧）。

## 装完之后

菜单里可以：改配置、启停、看实时日志、彻底卸载。

常用运维命令：

```bash
systemctl status easytier          # 看状态
journalctl -u easytier -n 100      # 看日志
systemctl restart easytier         # 改过配置后重启
easytier-cli node info             # 看本节点信息（需服务在跑）
```

放行防火墙（脚本安装完会打印，记得执行）：

```bash
# ufw
ufw allow 11010/tcp; ufw allow 11010/udp
# firewalld
firewall-cmd --add-port=11010/tcp --permanent
firewall-cmd --add-port=11010/udp --permanent
firewall-cmd --reload
```

客户端（PCL2 → 设置 → 联机 → 自定义节点）填 `tcp://<服务器IP>:11010`，房主和加入者填同一个。

## 卸载

卸载走菜单 [7]：停服务、删 `easytier.service`、删 `/etc/easytier`、删 `/usr/local/bin/easytier-core` 与 `easytier-cli`。脚本没有提供 `--uninstall` 参数，避免误触。

## 排障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 下载阶段全部失败 | 国内直连 GitHub 不通且加速源被墙 | 加 `--mirror proxy`；仍失败就换机器或手动下载 zip 后 `--version` 指定 |
| 服务起不来，日志报 `Permission denied` / `Cannot create tun` | 容器或没 `/dev/net/tun` | 换 KVM 型 VPS；或本机只做纯中继可加 `--no-tun`（脚本未默认加，避免误判） |
| 客户端连上但一直 relay，速度慢 | 白名单没命中，节点拒绝中转；或对称 NAT | 用 `journalctl -u easytier \| grep whitelist` 确认；再检查网络名后缀 |
| 端口不通 | 云厂商安全组没放行 | 控制台放行 TCP+UDP 同端口 |
| 服务反复重启 | 启动参数非法（例如模式 4 少了 secret） | `journalctl -u easytier -n 30` 看 clap 报错 |

## 验证记录

见 [`../docs/test/2026-10-21-easytier-node.md`](../docs/test/2026-10-21-easytier-node.md)。
