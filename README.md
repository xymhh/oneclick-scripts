# oneclick-scripts

常用 VPS 一键脚本合集。每个脚本一个目录，自带 `README.md` 使用教程，**国内 / 境外机器都能一键跑**（自动挑 GitHub 加速源）。

## 脚本索引

| 脚本 | 用途 | 一键命令 |
| --- | --- | --- |
| [`easytier-node`](easytier-node/) | EasyTier 共享 / 中继节点安装与交互管理（含网络白名单、私有组网） | `bash <(curl -fsSL https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)` |
| [`reality-sni-check`](reality-sni-check/) | REALITY SNI 目标检测（TLS1.3 / h2 / 证书 / 公共 CDN），一次性运行不改系统 | `bash <(curl -fsSL https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/reality-sni-check/check-sni.sh) www.cityu.edu.hk` |

> 国内机器如果连不上 `raw.githubusercontent.com`，把命令换成下面「加速用法」里的写法。

## 用法

### 1. 直接跑（境外 VPS）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/<脚本目录>/install.sh)
```

### 2. 加速跑（国内 VPS）

任选一个加速前缀套在原始地址前面：

```bash
# ghfast.top
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)

# gh-proxy.com
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)

# ghproxy.net
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh)
```

脚本内部下载 GitHub Release 时也会按 `ghfast.top → gh-proxy.com → ghproxy.net → 直连` 的顺序自动重试，所以**只有在拉取脚本本体这一步**才需要手动套加速。

### 3. 先看再跑（推荐）

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/xymhh/oneclick-scripts/main/easytier-node/install.sh -o et.sh
less et.sh      # 审一遍
sudo bash et.sh
```

## 约定（新增脚本时遵守）

```
<脚本目录>/
├── install.sh       # 安装类脚本：自包含，curl | bash 可直接跑；不依赖仓库里其它文件
│   └─ 或 <动作>.sh  # 诊断类脚本（只读、不安装）：如 reality-sni-check/check-sni.sh
└── README.md        # 使用教程：用途 / 国内 / 境外 / 参数 / 排障
```

1. **脚本必须自包含**：`curl | bash` 时拿不到仓库其它文件，公共逻辑复制进去而不是 `source ../lib/`。
2. 头部写清用途、支持的发行版与架构、是否会改系统文件。
3. 所有从 GitHub 下载的动作都要走 `lib/common.sh` 里的镜像链逻辑（见该文件注释），并留一个可用版本作 fallback。
4. 安装类脚本必须幂等：重复执行不重复写 systemd 单元、不重复装依赖。
5. 卸载 / 回滚命令写进 README，别只留安装。
6. 诊断类脚本（不写系统、不装服务）允许不叫 `install.sh`，用 `<动作>.sh`，并在 README 里写清退出码含义（方便接自动化）。

## 目录

- `lib/common.sh` —— 镜像探测与下载函数的「标准写法」参考，复制到各脚本里使用。
- `docs/` —— 每个脚本的测试记录（真机验证时间、系统版本、输出摘要）。

## 免责

脚本会以 root 身份修改系统（装包、写 `/usr/local/bin`、写 systemd 单元）。**先读再跑**，跑之前确认机器上没有同名服务。
