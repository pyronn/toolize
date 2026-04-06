
个人常用工具、脚本合集

## 在服务器上直接下载执行

无需克隆仓库，在目标服务器上直接下载并执行脚本：

```bash
# VPS 初始化
sudo bash <(curl -fsSL https://raw.githubusercontent.com/pyronn/toolize/main/scripts/bash/vps-init/vps-init.sh)

# 添加 SOCKS5 静态 IP
sudo bash <(curl -fsSL https://raw.githubusercontent.com/pyronn/toolize/main/scripts/bash/proxy/add-socks5-static-ip.sh)
```

> 执行前可先下载查看脚本内容：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/pyronn/toolize/main/scripts/bash/vps-init/vps-init.sh | less
> ```