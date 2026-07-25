use lettre::message::Mailbox;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{Message, SmtpTransport, Transport};
use nix::sys::statvfs::statvfs;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_CONFIG_PATH: &str = "/etc/server-cat/agent.toml";
const DEFAULT_SMTP_ENV_PATH: &str = "/etc/server-cat/smtp.env";

#[derive(Debug, Deserialize)]
struct Config {
    agent: AgentConfig,
    schedule: ScheduleConfig,
    thresholds: ThresholdConfig,
    email: EmailConfig,
}

#[derive(Debug, Deserialize)]
struct AgentConfig {
    channel: String,
    state_dir: String,
}

#[derive(Debug, Deserialize)]
struct ScheduleConfig {
    interval_seconds: u64,
}

#[derive(Debug, Deserialize)]
struct ThresholdConfig {
    disk_warning_percent: u8,
    disk_critical_percent: u8,
    inode_warning_percent: u8,
    inode_critical_percent: u8,
    memory_warning_percent: u8,
    load_warning_per_cpu: f64,
}

#[derive(Debug, Deserialize)]
struct EmailConfig {
    enabled: bool,
    from: String,
    recipients: Vec<String>,
    reminder_hours: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum AlertLevel {
    Warning,
    Critical,
}

impl AlertLevel {
    fn label(self) -> &'static str {
        match self {
            Self::Warning => "警告",
            Self::Critical => "严重",
        }
    }
}

#[derive(Clone, Debug)]
struct DetectedAlert {
    key: String,
    level: AlertLevel,
    label: String,
    message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ActiveAlert {
    level: AlertLevel,
    label: String,
    message: String,
    #[serde(default)]
    last_sent_unix: Option<u64>,
}

#[derive(Default, Deserialize, Serialize)]
struct AgentState {
    #[serde(default)]
    alerts: BTreeMap<String, ActiveAlert>,
    #[serde(default)]
    last_scheduled_check_unix: Option<u64>,
}

#[derive(Debug)]
struct SmtpSettings {
    host: String,
    port: u16,
    security: SmtpSecurity,
    credentials: Option<Credentials>,
}

#[derive(Clone, Copy, Debug)]
enum SmtpSecurity {
    StartTls,
    Tls,
    None,
}

fn main() -> ExitCode {
    match run(env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("错误: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: Vec<String>) -> Result<(), String> {
    let Some(command) = arguments.first().map(String::as_str) else {
        return Err(usage().to_owned());
    };

    match command {
        "validate-config" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            println!("配置文件格式和阈值校验通过: {config_path}");
            Ok(())
        }
        "validate-smtp" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            if config.email.enabled {
                load_smtp_settings()?;
                println!("SMTP 配置格式校验通过: {}", smtp_env_path().display());
            } else {
                println!("邮件通知未启用，无需校验 SMTP 配置");
            }
            Ok(())
        }
        "check" => {
            let (config_path, scheduled) = parse_check_arguments(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            run_check(&config, scheduled)
        }
        "version" | "--version" | "-V" => {
            println!("server-cat-agent {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        "help" | "--help" | "-h" => {
            println!("{}", usage());
            Ok(())
        }
        _ => Err(format!("未知命令: {command}\n{}", usage())),
    }
}

fn usage() -> &'static str {
    "用法:\n  server-cat-agent validate-config [--config 路径]\n  server-cat-agent validate-smtp [--config 路径]\n  server-cat-agent check [--config 路径]\n  server-cat-agent check --scheduled [--config 路径]\n  server-cat-agent version"
}

fn parse_config_path(arguments: &[String]) -> Result<String, String> {
    match arguments {
        [] => Ok(DEFAULT_CONFIG_PATH.to_owned()),
        [flag, path] if flag == "--config" && !path.is_empty() => Ok(path.to_owned()),
        _ => Err("配置参数无效，用法: --config <路径>".to_owned()),
    }
}

fn parse_check_arguments(arguments: &[String]) -> Result<(String, bool), String> {
    let mut config_path = DEFAULT_CONFIG_PATH.to_owned();
    let mut scheduled = false;
    let mut index = 0;

    while index < arguments.len() {
        match arguments[index].as_str() {
            "--scheduled" if !scheduled => {
                scheduled = true;
                index += 1;
            }
            "--config" if index + 1 < arguments.len() && !arguments[index + 1].is_empty() => {
                config_path = arguments[index + 1].clone();
                index += 2;
            }
            _ => return Err("监控检查参数无效".to_owned()),
        }
    }

    Ok((config_path, scheduled))
}

fn load_config(config_path: &str) -> Result<Config, String> {
    let contents = fs::read_to_string(Path::new(config_path))
        .map_err(|error| format!("无法读取配置 {config_path}: {error}"))?;

    toml::from_str(&contents).map_err(|error| format!("配置不是有效 TOML: {error}"))
}

fn validate_config(config: &Config) -> Result<(), String> {
    if config.agent.channel != "stable" && config.agent.channel != "beta" {
        return Err("agent.channel 只能为 stable 或 beta".to_owned());
    }

    if config.agent.state_dir.trim().is_empty() || !config.agent.state_dir.starts_with('/') {
        return Err("agent.state_dir 必须是绝对路径".to_owned());
    }

    if config.schedule.interval_seconds == 0 {
        return Err("调度间隔必须大于 0".to_owned());
    }

    validate_percent_pair(
        "disk",
        config.thresholds.disk_warning_percent,
        config.thresholds.disk_critical_percent,
    )?;
    validate_percent_pair(
        "inode",
        config.thresholds.inode_warning_percent,
        config.thresholds.inode_critical_percent,
    )?;

    if config.thresholds.memory_warning_percent == 0
        || config.thresholds.memory_warning_percent > 100
    {
        return Err("memory_warning_percent 必须在 1 到 100 之间".to_owned());
    }

    if !config.thresholds.load_warning_per_cpu.is_finite()
        || config.thresholds.load_warning_per_cpu <= 0.0
    {
        return Err("load_warning_per_cpu 必须大于 0".to_owned());
    }

    if config.email.reminder_hours == 0 {
        return Err("email.reminder_hours 必须大于 0".to_owned());
    }

    if config.email.enabled {
        if config.email.from.trim().is_empty() {
            return Err("启用邮件时 email.from 不能为空".to_owned());
        }

        if config.email.recipients.is_empty()
            || config
                .email
                .recipients
                .iter()
                .any(|recipient| recipient.trim().is_empty())
        {
            return Err("启用邮件时 email.recipients 必须至少包含一个地址".to_owned());
        }
    }

    Ok(())
}

fn validate_percent_pair(name: &str, warning: u8, critical: u8) -> Result<(), String> {
    if warning == 0 || critical == 0 || warning >= critical || critical > 100 {
        return Err(format!("{name} 阈值必须满足 0 < warning < critical <= 100"));
    }

    Ok(())
}

fn run_check(config: &Config, scheduled: bool) -> Result<(), String> {
    let state_path = Path::new(&config.agent.state_dir).join("alerts.json");
    let mut state = load_state(&state_path)?;
    let now = unix_timestamp()?;
    if scheduled
        && state.last_scheduled_check_unix.is_some_and(|last_check| {
            now.saturating_sub(last_check) < config.schedule.interval_seconds
        })
    {
        return Ok(());
    }

    let alerts = collect_alerts(config)?;
    let check_result = format_check_result(&alerts, config.email.enabled);
    let smtp = if config.email.enabled {
        Some(load_smtp_settings()?)
    } else {
        None
    };
    let hostname = read_hostname();
    let reminder_seconds = config.email.reminder_hours.saturating_mul(3600);
    let active_keys: HashSet<String> = alerts.iter().map(|alert| alert.key.clone()).collect();

    for alert in alerts {
        let previous = state.alerts.get(&alert.key).cloned();
        let should_notify =
            should_notify_active(previous.as_ref(), alert.level, now, reminder_seconds);

        if should_notify && let Some(settings) = smtp.as_ref() {
            send_email(
                settings,
                config,
                &format!("Server Cat {}告警: {}", alert.level.label(), alert.label),
                &format!("主机: {hostname}\n时间: {now}\n\n{}\n", alert.message),
            )?;
        }

        state.alerts.insert(
            alert.key,
            ActiveAlert {
                level: alert.level,
                label: alert.label,
                message: alert.message,
                last_sent_unix: if should_notify && smtp.is_some() {
                    Some(now)
                } else {
                    previous.and_then(|previous| previous.last_sent_unix)
                },
            },
        );
    }

    let recovered_keys: Vec<String> = state
        .alerts
        .keys()
        .filter(|key| !active_keys.contains(key.as_str()))
        .cloned()
        .collect();

    for key in recovered_keys {
        let previous = state
            .alerts
            .get(&key)
            .cloned()
            .ok_or_else(|| "告警状态读取失败".to_owned())?;
        if let Some(settings) = smtp.as_ref() {
            send_email(
                settings,
                config,
                &format!("Server Cat 告警恢复: {}", previous.label),
                &format!(
                    "主机: {hostname}\n时间: {now}\n\n{} 已恢复正常。\n上次告警: {}\n",
                    previous.label, previous.message
                ),
            )?;
        }
        state.alerts.remove(&key);
    }

    if scheduled {
        state.last_scheduled_check_unix = Some(now);
    }
    save_state(&state_path, &state)?;
    println!("{check_result}");
    Ok(())
}

fn format_check_result(alerts: &[DetectedAlert], email_enabled: bool) -> String {
    if alerts.is_empty() {
        return "监控检查完成: 未发现超过阈值的指标".to_owned();
    }

    let notification_status = if email_enabled {
        "邮件通知已启用"
    } else {
        "邮件通知未启用"
    };
    let details = alerts
        .iter()
        .map(|alert| format!("- [{}] {}", alert.level.label(), alert.message))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "监控检查完成: {} 项指标处于告警状态，{notification_status}\n\n告警详情:\n{details}",
        alerts.len()
    )
}

fn collect_alerts(config: &Config) -> Result<Vec<DetectedAlert>, String> {
    let mut alerts = Vec::new();

    for mount_point in monitored_mount_points()? {
        let stats = statvfs(&mount_point)
            .map_err(|error| format!("无法读取挂载点 {}: {error}", mount_point.display()))?;
        let mount = mount_point.display().to_string();

        if let Some(percent) = usage_percent(
            u64::from(stats.blocks()),
            u64::from(stats.blocks_available()),
        ) {
            add_percent_alert(
                &mut alerts,
                format!("disk:{mount}"),
                format!("磁盘 {mount}"),
                percent,
                config.thresholds.disk_warning_percent,
                config.thresholds.disk_critical_percent,
                "磁盘使用率",
            );
        }

        if let Some(percent) =
            usage_percent(u64::from(stats.files()), u64::from(stats.files_available()))
        {
            add_percent_alert(
                &mut alerts,
                format!("inode:{mount}"),
                format!("inode {mount}"),
                percent,
                config.thresholds.inode_warning_percent,
                config.thresholds.inode_critical_percent,
                "inode 使用率",
            );
        }
    }

    let memory_percent = memory_usage_percent()?;
    if memory_percent >= config.thresholds.memory_warning_percent {
        alerts.push(DetectedAlert {
            key: "memory".to_owned(),
            level: AlertLevel::Warning,
            label: "内存".to_owned(),
            message: format!(
                "内存使用率为 {memory_percent}%，阈值为 {}%",
                config.thresholds.memory_warning_percent
            ),
        });
    }

    let (load_average, cpu_count) = load_average_per_cpu()?;
    if load_average >= config.thresholds.load_warning_per_cpu {
        alerts.push(DetectedAlert {
            key: "load".to_owned(),
            level: AlertLevel::Warning,
            label: "系统负载".to_owned(),
            message: format!(
                "1 分钟负载每 CPU 为 {load_average:.2}（{cpu_count} 个 CPU），阈值为 {:.2}",
                config.thresholds.load_warning_per_cpu
            ),
        });
    }

    Ok(alerts)
}

fn monitored_mount_points() -> Result<Vec<PathBuf>, String> {
    let contents = fs::read_to_string("/proc/mounts")
        .map_err(|error| format!("无法读取 /proc/mounts: {error}"))?;
    let mut seen = HashSet::new();
    let mut mount_points = Vec::new();

    for line in contents.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 3 || ignored_filesystem(fields[2]) {
            continue;
        }

        let mount = unescape_mount_path(fields[1]);
        if seen.insert(mount.clone()) {
            mount_points.push(PathBuf::from(mount));
        }
    }

    if mount_points.is_empty() {
        return Err("未找到可监控的文件系统挂载点".to_owned());
    }

    Ok(mount_points)
}

fn ignored_filesystem(filesystem_type: &str) -> bool {
    matches!(
        filesystem_type,
        "autofs"
            | "bpf"
            | "cgroup"
            | "cgroup2"
            | "configfs"
            | "debugfs"
            | "devpts"
            | "devtmpfs"
            | "fusectl"
            | "hugetlbfs"
            | "mqueue"
            | "proc"
            | "pstore"
            | "securityfs"
            | "sysfs"
            | "tmpfs"
            | "tracefs"
    )
}

fn unescape_mount_path(path: &str) -> String {
    path.replace(r"\040", " ")
        .replace(r"\011", "\t")
        .replace(r"\012", "\n")
        .replace(r"\134", "\\")
}

fn usage_percent(total: u64, available: u64) -> Option<u8> {
    if total == 0 {
        return None;
    }

    let used = total.saturating_sub(available);
    Some(((used.saturating_mul(100) / total).min(100)) as u8)
}

fn add_percent_alert(
    alerts: &mut Vec<DetectedAlert>,
    key: String,
    label: String,
    percent: u8,
    warning: u8,
    critical: u8,
    metric_name: &str,
) {
    let level = if percent >= critical {
        Some(AlertLevel::Critical)
    } else if percent >= warning {
        Some(AlertLevel::Warning)
    } else {
        None
    };

    if let Some(level) = level {
        alerts.push(DetectedAlert {
            key,
            level,
            label: label.clone(),
            message: format!(
                "{label} 的{metric_name}为 {percent}%，警告阈值 {warning}%，严重阈值 {critical}%"
            ),
        });
    }
}

fn memory_usage_percent() -> Result<u8, String> {
    let contents = fs::read_to_string("/proc/meminfo")
        .map_err(|error| format!("无法读取 /proc/meminfo: {error}"))?;
    let mut total = None;
    let mut available = None;

    for line in contents.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let value = value
            .split_whitespace()
            .next()
            .and_then(|number| number.parse::<u64>().ok());
        match key {
            "MemTotal" => total = value,
            "MemAvailable" => available = value,
            _ => {}
        }
    }

    match (total, available) {
        (Some(total), Some(available)) => {
            usage_percent(total, available).ok_or_else(|| "内存总量不能为 0".to_owned())
        }
        _ => Err("/proc/meminfo 缺少 MemTotal 或 MemAvailable".to_owned()),
    }
}

fn load_average_per_cpu() -> Result<(f64, usize), String> {
    let contents = fs::read_to_string("/proc/loadavg")
        .map_err(|error| format!("无法读取 /proc/loadavg: {error}"))?;
    let load = contents
        .split_whitespace()
        .next()
        .ok_or_else(|| "/proc/loadavg 格式无效".to_owned())?
        .parse::<f64>()
        .map_err(|error| format!("无法解析 1 分钟负载: {error}"))?;
    let cpu_count = std::thread::available_parallelism()
        .map_err(|error| format!("无法获取 CPU 数量: {error}"))?
        .get();

    Ok((load / cpu_count as f64, cpu_count))
}

fn load_state(path: &Path) -> Result<AgentState, String> {
    if !path.exists() {
        return Ok(AgentState::default());
    }

    let contents = fs::read_to_string(path)
        .map_err(|error| format!("无法读取告警状态 {}: {error}", path.display()))?;
    serde_json::from_str(&contents)
        .map_err(|error| format!("告警状态文件格式无效 {}: {error}", path.display()))
}

fn save_state(path: &Path, state: &AgentState) -> Result<(), String> {
    let directory = path.parent().ok_or_else(|| "告警状态目录无效".to_owned())?;
    fs::create_dir_all(directory)
        .map_err(|error| format!("无法创建告警状态目录 {}: {error}", directory.display()))?;
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("无法设置告警状态目录权限 {}: {error}", directory.display()))?;

    let temporary_path = directory.join(format!(".alerts.{}.tmp", std::process::id()));
    let contents =
        serde_json::to_vec_pretty(state).map_err(|error| format!("无法序列化告警状态: {error}"))?;
    fs::write(&temporary_path, contents)
        .map_err(|error| format!("无法写入告警状态 {}: {error}", temporary_path.display()))?;
    fs::set_permissions(&temporary_path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("无法设置告警状态权限 {}: {error}", temporary_path.display()))?;
    fs::rename(&temporary_path, path)
        .map_err(|error| format!("无法原子更新告警状态 {}: {error}", path.display()))
}

fn should_notify_active(
    previous: Option<&ActiveAlert>,
    level: AlertLevel,
    now: u64,
    reminder_seconds: u64,
) -> bool {
    let Some(previous) = previous else {
        return true;
    };
    if previous.level != level {
        return true;
    }

    previous
        .last_sent_unix
        .is_none_or(|last_sent| now.saturating_sub(last_sent) >= reminder_seconds)
}

fn load_smtp_settings() -> Result<SmtpSettings, String> {
    let values = load_smtp_environment()?;
    let host = required_smtp_value(&values, "SERVER_CAT_SMTP_HOST")?;
    let port = smtp_value(&values, "SERVER_CAT_SMTP_PORT")
        .unwrap_or_else(|| "587".to_owned())
        .parse::<u16>()
        .map_err(|error| format!("SERVER_CAT_SMTP_PORT 必须是 1 到 65535 的端口: {error}"))?;
    if port == 0 {
        return Err("SERVER_CAT_SMTP_PORT 必须是 1 到 65535 的端口".to_owned());
    }

    let security = match smtp_value(&values, "SERVER_CAT_SMTP_SECURITY")
        .unwrap_or_else(|| "starttls".to_owned())
        .as_str()
    {
        "starttls" => SmtpSecurity::StartTls,
        "tls" => SmtpSecurity::Tls,
        "none" => SmtpSecurity::None,
        value => {
            return Err(format!(
                "SERVER_CAT_SMTP_SECURITY 必须为 starttls、tls 或 none，当前为 {value}"
            ));
        }
    };
    let username = smtp_value(&values, "SERVER_CAT_SMTP_USERNAME");
    let password = smtp_value(&values, "SERVER_CAT_SMTP_PASSWORD");
    let credentials = match (username, password) {
        (None, None) => None,
        (Some(username), Some(password)) => Some(Credentials::new(username, password)),
        _ => {
            return Err(
                "SERVER_CAT_SMTP_USERNAME 与 SERVER_CAT_SMTP_PASSWORD 必须同时设置".to_owned(),
            );
        }
    };

    Ok(SmtpSettings {
        host,
        port,
        security,
        credentials,
    })
}

fn smtp_env_path() -> PathBuf {
    env::var("SERVER_CAT_SMTP_ENV_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_SMTP_ENV_PATH))
}

fn load_smtp_environment() -> Result<BTreeMap<String, String>, String> {
    let path = smtp_env_path();
    let contents = fs::read_to_string(&path)
        .map_err(|error| format!("无法读取 SMTP 配置 {}: {error}", path.display()))?;
    let mut values = BTreeMap::new();

    for (line_number, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!(
                "SMTP 配置第 {} 行必须为 KEY=VALUE",
                line_number + 1
            ));
        };
        let key = key.trim();
        if key.is_empty() || !key.starts_with("SERVER_CAT_SMTP_") {
            return Err(format!("SMTP 配置第 {} 行的变量名无效", line_number + 1));
        }
        values.insert(key.to_owned(), unquote_environment_value(value.trim()));
    }

    Ok(values)
}

fn unquote_environment_value(value: &str) -> String {
    if value.len() >= 2
        && ((value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\'')))
    {
        value[1..value.len() - 1].to_owned()
    } else {
        value.to_owned()
    }
}

fn smtp_value(values: &BTreeMap<String, String>, name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .or_else(|| values.get(name).cloned())
        .filter(|value| !value.trim().is_empty())
}

fn required_smtp_value(values: &BTreeMap<String, String>, name: &str) -> Result<String, String> {
    smtp_value(values, name)
        .ok_or_else(|| format!("启用邮件时必须在 {} 设置 {name}", smtp_env_path().display()))
}

fn send_email(
    settings: &SmtpSettings,
    config: &Config,
    subject: &str,
    body: &str,
) -> Result<(), String> {
    let from: Mailbox = config
        .email
        .from
        .parse()
        .map_err(|error| format!("email.from 不是有效邮箱地址: {error}"))?;
    let mut builder = Message::builder().from(from).subject(subject);
    for recipient in &config.email.recipients {
        let mailbox: Mailbox = recipient
            .parse()
            .map_err(|error| format!("email.recipients 包含无效邮箱地址 {recipient}: {error}"))?;
        builder = builder.to(mailbox);
    }
    let message = builder
        .body(body.to_owned())
        .map_err(|error| format!("无法构建邮件: {error}"))?;

    let transport = match settings.security {
        SmtpSecurity::StartTls => build_starttls_transport(settings)?,
        SmtpSecurity::Tls => build_tls_transport(settings)?,
        SmtpSecurity::None => build_plain_transport(settings),
    };
    transport
        .send(&message)
        .map_err(|error| format!("发送 SMTP 邮件失败: {error}"))?;
    Ok(())
}

fn build_starttls_transport(settings: &SmtpSettings) -> Result<SmtpTransport, String> {
    let mut builder = SmtpTransport::starttls_relay(&settings.host)
        .map_err(|error| format!("无法配置 SMTP STARTTLS: {error}"))?;
    builder = builder.port(settings.port);
    if let Some(credentials) = settings.credentials.as_ref() {
        builder = builder.credentials(credentials.clone());
    }
    Ok(builder.build())
}

fn build_tls_transport(settings: &SmtpSettings) -> Result<SmtpTransport, String> {
    let mut builder = SmtpTransport::relay(&settings.host)
        .map_err(|error| format!("无法配置 SMTP TLS: {error}"))?;
    builder = builder.port(settings.port);
    if let Some(credentials) = settings.credentials.as_ref() {
        builder = builder.credentials(credentials.clone());
    }
    Ok(builder.build())
}

fn build_plain_transport(settings: &SmtpSettings) -> SmtpTransport {
    let mut builder = SmtpTransport::builder_dangerous(&settings.host).port(settings.port);
    if let Some(credentials) = settings.credentials.as_ref() {
        builder = builder.credentials(credentials.clone());
    }
    builder.build()
}

fn read_hostname() -> String {
    fs::read_to_string("/etc/hostname")
        .ok()
        .map(|hostname| hostname.trim().to_owned())
        .filter(|hostname| !hostname.is_empty())
        .unwrap_or_else(|| "未知主机".to_owned())
}

fn unix_timestamp() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|error| format!("系统时间早于 Unix epoch: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_CONFIG: &str = r#"
[agent]
channel = "stable"
state_dir = "/var/lib/server-cat"

[schedule]
interval_seconds = 60

[thresholds]
disk_warning_percent = 80
disk_critical_percent = 90
inode_warning_percent = 80
inode_critical_percent = 90
memory_warning_percent = 85
load_warning_per_cpu = 2.0

[email]
enabled = true
from = "server-cat@example.com"
recipients = ["ops@example.com"]
reminder_hours = 6
"#;

    #[test]
    fn accepts_valid_configuration() {
        let config: Config = toml::from_str(VALID_CONFIG).expect("configuration parses");
        assert!(validate_config(&config).is_ok());
    }

    #[test]
    fn rejects_invalid_disk_thresholds() {
        let invalid =
            VALID_CONFIG.replace("disk_warning_percent = 80", "disk_warning_percent = 95");
        let config: Config = toml::from_str(&invalid).expect("configuration parses");
        assert!(validate_config(&config).is_err());
    }

    #[test]
    fn rejects_enabled_email_without_recipients() {
        let invalid = VALID_CONFIG.replace("recipients = [\"ops@example.com\"]", "recipients = []");
        let config: Config = toml::from_str(&invalid).expect("configuration parses");
        assert!(validate_config(&config).is_err());
    }

    #[test]
    fn usage_percent_handles_empty_and_full_filesystems() {
        assert_eq!(usage_percent(0, 0), None);
        assert_eq!(usage_percent(100, 100), Some(0));
        assert_eq!(usage_percent(100, 0), Some(100));
        assert_eq!(usage_percent(100, 20), Some(80));
    }

    #[test]
    fn critical_threshold_overrides_warning_threshold() {
        let mut alerts = Vec::new();
        add_percent_alert(
            &mut alerts,
            "disk:/".to_owned(),
            "磁盘 /".to_owned(),
            90,
            80,
            90,
            "磁盘使用率",
        );
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].level, AlertLevel::Critical);
    }

    #[test]
    fn check_output_lists_every_alert_with_its_threshold() {
        let alerts = vec![DetectedAlert {
            key: "disk:/".to_owned(),
            level: AlertLevel::Critical,
            label: "磁盘 /".to_owned(),
            message: "磁盘 / 的磁盘使用率为 91%，警告阈值 80%，严重阈值 90%".to_owned(),
        }];

        assert_eq!(
            format_check_result(&alerts, false),
            "监控检查完成: 1 项指标处于告警状态，邮件通知未启用\n\n告警详情:\n- [严重] 磁盘 / 的磁盘使用率为 91%，警告阈值 80%，严重阈值 90%"
        );
    }

    #[test]
    fn only_notifies_for_new_escalated_or_due_alerts() {
        let previous = ActiveAlert {
            level: AlertLevel::Warning,
            label: "内存".to_owned(),
            message: "内存使用率为 90%".to_owned(),
            last_sent_unix: Some(100),
        };
        assert!(should_notify_active(None, AlertLevel::Warning, 101, 3600));
        assert!(!should_notify_active(
            Some(&previous),
            AlertLevel::Warning,
            200,
            3600
        ));
        assert!(should_notify_active(
            Some(&previous),
            AlertLevel::Critical,
            200,
            3600
        ));
        assert!(should_notify_active(
            Some(&previous),
            AlertLevel::Warning,
            3700,
            3600
        ));
    }

    #[test]
    fn unescapes_mount_paths() {
        assert_eq!(unescape_mount_path("/data\\040disk"), "/data disk");
    }

    #[test]
    fn parses_scheduled_check_with_custom_config() {
        let arguments = vec![
            "--scheduled".to_owned(),
            "--config".to_owned(),
            "/tmp/server-cat.toml".to_owned(),
        ];
        assert_eq!(
            parse_check_arguments(&arguments),
            Ok(("/tmp/server-cat.toml".to_owned(), true))
        );
    }

    #[test]
    fn parses_quoted_smtp_password_without_shell_evaluation() {
        assert_eq!(unquote_environment_value("'pa$$=word'"), "pa$$=word");
        assert_eq!(unquote_environment_value("plain=value"), "plain=value");
    }
}
