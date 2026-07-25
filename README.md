# Server Cat

Server Cat 是一个面向 Linux 服务器的本地管理工具，提供交互式维护菜单、签名更新和可选的常驻监控 Agent，适合个人服务器与小型部署环境。

## 特性

- 常用服务安装与维护：Docker、Nginx、Certbot、Bashtop
- 系统基础配置：SSH、防火墙、Sudo 用户、用户目录、网络优化
- 本地备份与恢复：覆盖 SSH、Nginx、Docker、Certbot 与用户常用目录
- 统一回滚：按功能声明执行对应的软件卸载或配置恢复
- 空间清理：按系统规则清理过期临时文件，按需清理 Docker 停止容器、悬空镜像和构建缓存
- 安全更新：检查、验证并安装已签名的发布包
- 本地监控：磁盘空间、inode、内存、Swap、系统负载与 TLS 证书到期
- 邮件告警：支持 SMTP 告警、等级升级提醒与恢复通知

## 项目结构

```text
server-cat/
├── main.sh                    # 本地 CLI 与交互式菜单入口
├── modules/                   # 系统配置功能
├── softwares/                 # 常用软件安装功能
├── backups/                   # 本地备份与恢复功能
├── configs/                   # 菜单配置功能
├── templates/                 # Agent 运行配置模板
├── lib/                       # 公共功能与签名更新逻辑
├── crates/server-cat-agent/   # 常驻监控 Agent
├── packaging/                 # 安装器与 systemd 单元
├── scripts/                   # 构建与发布辅助脚本
└── tests/                     # Bash 与发布逻辑检查
```

## 支持范围

当前支持具备 `apt` 与 `systemd` 的 Ubuntu、Debian 系统。所有管理操作均需要 root 权限。

## 安装

首次安装使用 HTTPS 获取安装器：

```bash
curl -fsSL https://packages.catbuli.com/server-cat/install.sh | sudo bash
```

安装完成后查看可用命令：

```bash
sudo scat --help
```

## 常用操作

交互菜单支持方向键或 `j/k` 选择、Enter 确认、Backspace 或 Esc 返回，也可以直接按数字键。

```bash
# 打开交互式管理菜单
sudo scat

# 在“系统设置”中选择“更新 Server Cat”
# 程序会先验证更新，再询问是否安装

# 用于脚本化或排障的更新命令
sudo scat update check
sudo scat update apply

# 检查安装、配置、依赖、定时器与发布通道
sudo scat doctor

# 在“系统设置”中选择“清理系统空间”
# 不会清理 Docker 卷、运行中的容器、已命名镜像、业务目录或备份

# 管理本地监控 Agent
sudo scat agent configure
sudo scat agent check
sudo scat agent enable
sudo scat agent disable
sudo scat agent status
sudo scat agent mute 30m
sudo scat agent unmute
```

## 监控与邮件

Agent 默认不启用邮件和定时运行。可从“系统设置 → 配置监控 Agent”或 `sudo scat agent configure` 配置巡检周期、资源阈值、额外巡检目标和邮件通知。所有配置均保存到权限为 `0600` 的 `/etc/server-cat/agent.toml`，保存前会先校验，配置错误时不会覆盖原文件。

```toml
[email]
enabled = true
from = "server-cat@example.com"
recipients = ["ops@example.com"]
reminder_hours = 6
smtp_host = "smtp.example.com"
smtp_port = 587
smtp_security = "starttls"
smtp_username = "username"
smtp_password = "password"
```

启用邮件后，可先发送测试邮件确认 SMTP 与收件人可用；此命令不会创建或更新告警状态：

```bash
sudo scat agent test-email
```

可选的 `[checks]` 配置可巡检 systemd 服务和 HTTP/HTTPS 地址：

```toml
[checks]
systemd_services = ["nginx", "docker"]
http_urls = ["https://example.com/health"]
http_timeout_seconds = 10
docker_containers = ["redis", "grafana"]
check_reboot_required = true
certificate_paths = ["/etc/letsencrypt/live/example.com/fullchain.pem"]
certificate_warning_days = 14
```

服务未处于 `active`、HTTP 非成功响应、超时或连接失败、Docker 容器未运行、证书文件不存在或证书无效均会产生严重告警。证书将在预警天数内到期、重启需求为警告级。

`sudo scat agent status` 会汇总定时器状态、实际巡检间隔与上次执行时间、已配置巡检目标、邮件开关和当前活跃告警。每条活跃告警都会显示首次发现、最近发现和最近通知时间。

部署、重启服务或维护 Docker 时，可使用 `sudo scat agent mute 30m` 静默邮件通知。支持 `m`、`h`、`d` 三种单位，例如 `30m`、`2h`、`1d`，单次最长 30 天。巡检和 journal 记录不会停止；可用 `sudo scat agent unmute` 提前恢复邮件通知。

`server-cat` 仍保留为兼容命令，新脚本和日常操作统一使用 `scat`。

安装后重新打开 Bash，即可使用 `scat` 的 Tab 补全；当前终端可执行 `source /usr/share/bash-completion/completions/scat` 立即加载。

## 更新与信任

首次安装依赖 HTTPS。后续更新从 `packages.catbuli.com` 获取发布清单与安装包，客户端会验证 GPG 签名、文件大小和 SHA-256，通过配置校验后替换当前版本。

运行中的服务器不需要访问 GitHub 或保留 Git 仓库；GitHub 只用于项目源代码协作和发布构建。

## 注意事项

- 软件安装、更新与邮件通知需要网络连接。
- 建议先在测试机器验证新版本，再更新生产服务器。
- 备份与恢复操作可能覆盖配置或数据，执行前请确认目标范围。

## 贡献

欢迎提交 Issue 与 Pull Request。请说明使用的发行版、复现步骤和期望行为；涉及系统配置、删除或网络暴露的改动应明确说明影响范围。

## 许可

项目当前声明使用 MIT License。
