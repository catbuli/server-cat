# Server Cat

Server Cat 是一个面向 Linux 服务器的本地管理工具，提供交互式维护菜单、签名更新和可选的常驻监控 Agent，适合个人服务器与小型部署环境。

## 特性

- 常用服务安装与维护：Docker、Nginx、Certbot、Bashtop、Ncdu
- 系统基础配置：SSH、UFW 防火墙规则、Sudo 用户、网络优化
- SSH 公钥管理：按用户查看公钥指纹，校验并添加公钥或逐条撤销授权
- 安全卸载与恢复：Server Cat 自身卸载和系统组件恢复分离，软件与配置仅允许逐项操作
- 空间清理：按系统规则清理过期临时文件，按需清理 Docker 停止容器、悬空镜像和构建缓存
- 安全更新：检查、验证并安装已签名的发布包
- 本地监控：磁盘空间、inode、内存、Swap、系统负载与 TLS 证书到期
- 外部通知：支持 SMTP 邮件与 Telegram Bot 告警、等级升级提醒与恢复通知
- 服务器概览：集中展示系统资源、Docker、失败服务、监听端口和定时巡检状态
- 服务管理：筛选 systemd 服务，查看状态并单项启动、停止或重启

## 项目结构

```text
server-cat/
├── main.sh                    # 本地 CLI 与交互式菜单入口
├── modules/                   # 系统配置功能
├── softwares/                 # 常用软件安装功能
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

# 查看只读服务器概览
sudo scat status

# 在“系统设置”中选择“清理系统空间”
# 不会清理 Docker 卷、运行中的容器、已命名镜像、业务目录或备份

# 在“常用软件”中安装 Ncdu，使用 ncdu / 交互分析磁盘占用

# 在“卸载与恢复”中卸载 Server Cat，或逐项恢复已有系统设置

# 管理本地监控 Agent
sudo scat agent conf
sudo scat agent check
sudo scat agent enable
sudo scat agent disable
sudo scat agent status
sudo scat agent logs
sudo scat agent logs --follow
sudo scat agent test-email
sudo scat agent test-telegram
sudo scat agent mute 30m
sudo scat agent unmute
```

## 监控与通知

Agent 默认不启用外部通知和定时运行。可从“系统设置 → 配置监控 Agent”或 `sudo scat agent conf` 配置巡检周期、资源阈值、额外巡检目标、邮件与 Telegram 通知。配置向导会自动读取 Docker 容器并通过多选菜单配置巡检目标，无需手工查询容器名。所有配置均保存到权限为 `0600` 的 `/etc/server-cat/agent.toml`，保存前会先校验，配置错误时不会覆盖原文件。

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

[telegram]
enabled = true
bot_token = "123456789:replace-with-bot-token"
chat_ids = ["-1001234567890"]
reminder_hours = 6
```

Telegram Bot Token 由 Telegram 的 `@BotFather` 创建 Bot 后获得；`chat_ids` 可填写个人或群组的数字 Chat ID，也可填写 Bot 有权发消息的 `@channel`。Bot 必须已加入目标群组或频道并具备发消息权限。

同一轮巡检产生的 Telegram 告警会合并发送，恢复通知单独合并；消息超过 Telegram 限制时会自动拆分，避免多项异常连续刷屏。

启用通知后，应分别发送测试消息确认 SMTP、Telegram Bot 与接收目标可用；测试命令不会创建或更新告警状态：

```bash
sudo scat agent test-email
sudo scat agent test-telegram
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

`sudo scat agent status` 会汇总定时器状态、实际巡检间隔与上次执行时间、已配置巡检目标、邮件与 Telegram 开关和当前活跃告警。每条活跃告警都会分别显示最近邮件通知和最近 Telegram 通知时间。

定时巡检输出由 systemd journal 保存。`sudo scat agent logs` 显示最近 100 行，`sudo scat agent logs --follow` 持续查看新日志并可用 `Ctrl+C` 退出；Server Cat 不会额外创建日志文件。

部署、重启服务或维护 Docker 时，可使用 `sudo scat agent mute 30m` 同时静默邮件与 Telegram 通知。支持 `m`、`h`、`d` 三种单位，例如 `30m`、`2h`、`1d`，单次最长 30 天。巡检和 journal 记录不会停止；可用 `sudo scat agent unmute` 提前恢复外部通知。

`server-cat` 仍保留为兼容命令，新脚本和日常操作统一使用 `scat`。

安装后重新打开 Bash，即可使用 `scat` 的 Tab 补全；当前终端可执行 `source /usr/share/bash-completion/completions/scat` 立即加载。

## 卸载与恢复

从交互菜单进入“卸载与恢复 → 卸载 Server Cat”。卸载器只停止并移除 Server Cat 自身的 Agent、systemd 单元、命令、Bash 补全和 `/opt/server-cat`，不会卸载 Docker、Nginx、Certbot、bash-completion 等软件或依赖。

默认保留 `/etc/server-cat` 中的配置、SMTP 密码与 Telegram Bot Token，以及 `/var/lib/server-cat` 中的告警状态。只有额外输入强确认内容后才会删除这两个目录。

Docker、Nginx 和系统配置等已有回滚功能位于“单项恢复或卸载”，每次只能明确选择一个项目，不提供批量卸载或全部回滚。

## 更新与信任

首次安装依赖 HTTPS。后续更新从 `packages.catbuli.com` 获取发布清单与安装包，客户端会验证 GPG 签名、文件大小和 SHA-256，通过配置校验后替换当前版本。

运行中的服务器不需要访问 GitHub 或保留 Git 仓库；GitHub 只用于项目源代码协作和发布构建。

## 注意事项

- 软件安装、更新、邮件与 Telegram 通知需要网络连接。
- 建议先在测试机器验证新版本，再更新生产服务器。

## 贡献

欢迎提交 Issue 与 Pull Request。请说明使用的发行版、复现步骤和期望行为；涉及系统配置、删除或网络暴露的改动应明确说明影响范围。

## 许可

本项目使用 [MIT License](LICENSE)。
