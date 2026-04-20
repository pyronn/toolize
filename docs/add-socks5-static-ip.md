# add-socks5-static-ip.sh — sing-box SOCKS5 链式代理配置生成脚本

为 sing-box 生成 SOCKS5 链式代理出站配置，实现通过指定 SOCKS5 代理的静态 IP 出站。

## 基本信息

| 项目 | 说明 |
|------|------|
| 路径 | `scripts/bash/proxy/add-socks5-static-ip.sh` |
| 运行环境 | Ubuntu（已安装 sing-box） |
| 权限要求 | root（`sudo bash add-socks5-static-ip.sh`） |
| 依赖 | `sing-box`、`curl`、`python3` |

## 快速使用

```bash
# 方式一：交互式
sudo bash scripts/bash/proxy/add-socks5-static-ip.sh

# 方式二：直接传参
sudo bash scripts/bash/proxy/add-socks5-static-ip.sh ip:port:username:password

# 方式三：远程直接执行
sudo bash <(curl -fsSL https://raw.githubusercontent.com/pyronn/toolize/main/scripts/bash/proxy/add-socks5-static-ip.sh)
```

## 参数格式

直接传参时使用冒号分隔：

```
<服务器地址>:<端口>:<用户名>:<密码>
```

密码中可以包含冒号，脚本会正确处理（第 4 段之后的内容全部作为密码）。

## 交互式流程

如果不传参数，脚本提供两种输入方式：

1. **逐项输入** — 分别输入 IP、端口、用户名、密码（密码隐藏输入）
2. **粘贴格式** — 直接粘贴 `ip:port:user:pass` 格式文本

## 执行流程

```
权限检查 → 依赖检查 → 解析参数 → 信息确认
    → 连通性测试 → 备份旧配置 → 生成 JSON → 语法校验 → 重启 sing-box
```

### 1. 前置检查

- 必须以 root 运行
- 检查 `sing-box`、`curl`、`python3` 是否已安装

### 2. 连通性测试

- 通过 `curl --socks5` 访问 `https://api.ipify.org` 测试代理连通性
- 超时设置：连接 10 秒，总计 15 秒
- 测试失败时会提示，用户可选择继续生成配置

### 3. 配置生成

生成文件路径：`/etc/sing-box/conf/socks-chain.json`

生成的 JSON 结构：

```json
{
  "outbounds": [
    {
      "tag": "socks-static-ip",
      "type": "socks",
      "server": "<地址>",
      "server_port": <端口>,
      "version": "5",
      "username": "<用户名>",
      "password": "<密码>"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "direct"
      }
    ],
    "final": "socks-static-ip"
  }
}
```

### 4. 校验与重启

- 使用 `sing-box check` 验证合并后的配置语法
- 语法检查通过后，交互确认是否立即重启 sing-box
- 重启后检查服务运行状态

## 文件路径

| 文件 | 说明 |
|------|------|
| `/etc/sing-box/config.json` | sing-box 主配置文件 |
| `/etc/sing-box/conf/` | 分片配置目录 |
| `/etc/sing-box/conf/socks-chain.json` | 本脚本生成的链式代理配置 |
| `*.bak.YYYYMMDDHHMMSS` | 旧配置自动备份 |

## 卸载 / 回滚

```bash
# 删除链式代理配置并重启
rm /etc/sing-box/conf/socks-chain.json && sing-box restart

# 或恢复备份
cp /etc/sing-box/conf/socks-chain.json.bak.<timestamp> /etc/sing-box/conf/socks-chain.json
sing-box restart
```

## 验证

配置生效后，通过代理访问以下地址确认出口 IP：

```bash
curl https://api.ipify.org
```

查看运行日志：

```bash
sing-box log
```
