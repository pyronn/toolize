# vps-init.sh — VPS 服务器初始化脚本

Ubuntu 服务器安全初始化一站式脚本，覆盖用户管理、SSH 加固、防火墙、入侵防护等常见运维操作。

## 基本信息

| 项目 | 说明 |
|------|------|
| 路径 | `scripts/bash/vps-init/vps-init.sh` |
| 运行环境 | Ubuntu 22.04 / 24.04 |
| 权限要求 | root（`sudo bash vps-init.sh`） |
| 依赖 | 无外部依赖，所需软件包由脚本自动安装 |

## 快速使用

```bash
# 方式一：克隆仓库后执行
sudo bash scripts/bash/vps-init/vps-init.sh

# 方式二：远程直接执行
sudo bash <(curl -fsSL https://raw.githubusercontent.com/pyronn/toolize/main/scripts/bash/vps-init/vps-init.sh)
```

## 主菜单

```
╔══════════════════════════════════════════════╗
║       VPS Server Initialization Script       ║
╠══════════════════════════════════════════════╣
║  1) SSH Security Init (Create User + SSH)    ║
║  2) Add Public Key to authorized_keys        ║
║  3) Disable Password Auth (After Key Upload) ║
║  4) Server Security Hardening                ║
║  0) Exit                                     ║
╚══════════════════════════════════════════════╝
```

---

## 选项 1：SSH Security Init

交互式子菜单，支持单选、多选或全部执行。

### Step 1 — 创建 sudo 用户

- 输入新用户名和密码（二次确认）
- 若用户已存在则跳过创建
- 自动创建 `~/.ssh/authorized_keys` 并设置正确权限（700/600）
- 将用户加入 `sudo` 组

### Step 2 — 重置 root 密码

- 交互输入新 root 密码（二次确认）
- 通过 `chpasswd` 设置

### Step 3 — 配置 SSH 守护进程

修改 `/etc/ssh/sshd_config`，应用以下安全策略：

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `Port` | 用户指定 | 自定义 SSH 端口（默认保持当前值） |
| `PermitRootLogin` | `no` | 禁止 root 直接 SSH 登录 |
| `MaxAuthTries` | `5` | 最大认证尝试次数 |
| `LoginGraceTime` | `60` | 登录超时（秒） |
| `ClientAliveInterval` | `300` | 客户端保活间隔（秒） |
| `ClientAliveCountMax` | `3` | 保活最大失败次数 |
| `X11Forwarding` | `no` | 关闭 X11 转发 |
| `AllowUsers` | 用户指定 | 仅允许指定用户 SSH 登录 |

**安全机制：**
- 修改前自动备份原配置（`sshd_config.bak.YYYYMMDDHHMMSS`）
- 同时清理 `/etc/ssh/sshd_config.d/` 下的冲突配置（兼容 Ubuntu 24.04 drop-in 机制）
- 通过 `sshd -t` 验证语法，失败自动回滚
- 提醒用户在新终端测试连接后再关闭当前会话

---

## 选项 2：Add Public Key

- 输入目标用户名
- 自动创建 `.ssh` 目录结构和权限
- 粘贴公钥后按 Enter + Ctrl+D 确认
- 校验公钥格式（支持 `ssh-rsa`、`ssh-ed25519`、`ecdsa-*`、`sk-*`）
- 自动去重，已存在的公钥不会重复添加

---

## 选项 3：Disable Password Auth

在确认公钥登录可用后，禁用密码认证：

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `PasswordAuthentication` | `no` | 禁用密码登录 |
| `KbdInteractiveAuthentication` | `no` | 禁用键盘交互认证 |
| `UsePAM` | `no` | 禁用 PAM |
| `PubkeyAuthentication` | `yes` | 启用公钥认证 |

**前置检查：**
- 验证指定用户的 `authorized_keys` 文件存在且非空
- 要求用户确认已在另一个会话中测试过公钥登录

---

## 选项 4：Server Security Hardening

子菜单支持任意组合选择，各项互相独立：

### 4.1 System Update & Common Tools

- `apt-get update && upgrade`
- 安装常用工具：`curl` `wget` `vim` `htop` `iotop` `net-tools` `unzip` `zip` `git` `tmux` `lsof` `tree` `jq` `software-properties-common` `ca-certificates` `gnupg`

### 4.2 UFW Firewall

- 重置防火墙规则
- 默认策略：拒绝入站、允许出站
- 自动放行当前 SSH 端口
- 交互式询问是否开放 HTTP (80)、HTTPS (443)
- 支持输入额外自定义端口（逗号分隔）

### 4.3 Fail2ban

- 安装并配置 `/etc/fail2ban/jail.local`
- SSH 专用规则：3 次失败封禁 2 小时
- 默认规则：5 次失败封禁 1 小时
- 联动 UFW 进行封禁（`banaction = ufw`）

### 4.4 Automatic Security Updates

- 安装 `unattended-upgrades`
- 启用每日安全更新检查
- 自动清理旧包，但不自动重启

### 4.5 Kernel Network Hardening (sysctl)

写入 `/etc/sysctl.d/99-security.conf`：

| 类别 | 配置 |
|------|------|
| IP 转发 | 禁用 IPv4/IPv6 转发 |
| SYN Flood | 启用 syncookies，限制 backlog |
| ICMP 重定向 | 全部禁用（防 MITM） |
| 源路由 | 全部禁用 |
| 反向路径过滤 | 启用（防 IP 欺骗） |
| 日志 | 记录异常包（martians） |
| 广播 | 忽略 ICMP 广播请求 |
| TIME_WAIT | 启用 RFC1337 保护 |

### 4.6 Timezone & NTP

- 显示当前时区，可选切换到 `Asia/Shanghai`
- 安装并启用 `systemd-timesyncd` 进行 NTP 同步

### 4.7 Disable Unused Services

停用并禁用以下服务（若存在）：`snapd`、`cups`、`avahi-daemon`、`bluetooth`

---

## 推荐执行顺序

首次初始化 VPS 建议按以下顺序操作：

1. **选项 1** → 创建用户 + 配置 SSH（选 "Run all"）
2. 在新终端测试 SSH 登录
3. **选项 2** → 添加公钥
4. 在新终端测试公钥登录
5. **选项 3** → 禁用密码认证
6. **选项 4** → 服务器安全加固（选 "Select ALL"）

> **警告：** 每次修改 SSH 配置后，务必保持当前会话不关闭，先用新终端验证连接正常。

## 兼容性

| 系统版本 | 状态 | 说明 |
|----------|------|------|
| Ubuntu 22.04 LTS | 完全支持 | OpenSSH 8.9 |
| Ubuntu 24.04 LTS | 完全支持 | OpenSSH 9.6，已处理 drop-in 配置覆盖问题 |
| 其他 Linux 发行版 | 部分支持 | 脚本检测到非 Ubuntu 系统会警告，用户可选择继续 |
