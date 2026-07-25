use lettre::message::Mailbox;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{Message, SmtpTransport, Transport};
use nix::sys::statvfs::statvfs;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_CONFIG_PATH: &str = "/etc/server-cat/agent.toml";

#[derive(Debug, Deserialize)]
struct Config {
    agent: AgentConfig,
    schedule: ScheduleConfig,
    thresholds: ThresholdConfig,
    email: EmailConfig,
    #[serde(default)]
    telegram: TelegramConfig,
    #[serde(default)]
    checks: CheckConfig,
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
    #[serde(default = "default_swap_warning_percent")]
    swap_warning_percent: u8,
    load_warning_per_cpu: f64,
}

#[derive(Debug, Deserialize)]
struct EmailConfig {
    enabled: bool,
    from: String,
    recipients: Vec<String>,
    reminder_hours: u64,
    #[serde(default)]
    smtp_host: String,
    #[serde(default = "default_smtp_port")]
    smtp_port: u16,
    #[serde(default = "default_smtp_security")]
    smtp_security: String,
    #[serde(default)]
    smtp_username: String,
    #[serde(default)]
    smtp_password: String,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
struct TelegramConfig {
    enabled: bool,
    bot_token: String,
    chat_ids: Vec<String>,
    reminder_hours: u64,
}

#[derive(Debug, Deserialize)]
struct TelegramApiResponse {
    ok: bool,
    description: Option<String>,
}

impl Default for TelegramConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            bot_token: String::new(),
            chat_ids: Vec::new(),
            reminder_hours: 6,
        }
    }
}

#[derive(Debug, Deserialize)]
struct CheckConfig {
    #[serde(default)]
    systemd_services: Vec<String>,
    #[serde(default)]
    http_urls: Vec<String>,
    #[serde(default = "default_http_timeout_seconds")]
    http_timeout_seconds: u64,
    #[serde(default)]
    docker_containers: Vec<String>,
    #[serde(default)]
    check_reboot_required: bool,
    #[serde(default)]
    certificate_paths: Vec<String>,
    #[serde(default = "default_certificate_warning_days")]
    certificate_warning_days: u64,
}

impl Default for CheckConfig {
    fn default() -> Self {
        Self {
            systemd_services: Vec::new(),
            http_urls: Vec::new(),
            http_timeout_seconds: default_http_timeout_seconds(),
            docker_containers: Vec::new(),
            check_reboot_required: false,
            certificate_paths: Vec::new(),
            certificate_warning_days: default_certificate_warning_days(),
        }
    }
}

fn default_http_timeout_seconds() -> u64 {
    10
}

fn default_swap_warning_percent() -> u8 {
    80
}

fn default_certificate_warning_days() -> u64 {
    14
}

fn default_smtp_port() -> u16 {
    587
}

fn default_smtp_security() -> String {
    "starttls".to_owned()
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
    first_detected_unix: Option<u64>,
    #[serde(default)]
    last_detected_unix: Option<u64>,
    #[serde(default)]
    last_sent_unix: Option<u64>,
    #[serde(default)]
    last_telegram_sent_unix: Option<u64>,
}

#[derive(Default, Deserialize, Serialize)]
struct AgentState {
    #[serde(default)]
    alerts: BTreeMap<String, ActiveAlert>,
    #[serde(default)]
    last_scheduled_check_unix: Option<u64>,
    #[serde(default, alias = "email_mute_until_unix")]
    notification_mute_until_unix: Option<u64>,
}

impl AgentState {
    fn notifications_muted(&self, now: u64) -> bool {
        self.notification_mute_until_unix
            .is_some_and(|mute_until| mute_until > now)
    }
}

struct TimerStatus {
    unit_file_state: String,
    active_state: String,
    last_trigger: String,
    next_trigger: String,
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
                load_smtp_settings(&config)?;
                println!("SMTP 配置格式校验通过: {config_path}");
            } else {
                println!("邮件通知未启用，无需校验 SMTP 配置");
            }
            Ok(())
        }
        "validate-telegram" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            if config.telegram.enabled {
                println!("Telegram 配置格式校验通过: {config_path}");
            } else {
                println!("Telegram 通知未启用，无需校验");
            }
            Ok(())
        }
        "check" => {
            let (config_path, scheduled) = parse_check_arguments(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            run_check(&config, scheduled)
        }
        "status" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            show_status(&config)
        }
        "test-email" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            send_test_email(&config)
        }
        "test-telegram" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            send_test_telegram(&config)
        }
        "mute" => {
            let (duration_seconds, config_path) = parse_mute_arguments(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            mute_notifications(&config, duration_seconds)
        }
        "unmute" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            unmute_notifications(&config)
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
    "用法:\n  server-cat-agent validate-config [--config 路径]\n  server-cat-agent validate-smtp [--config 路径]\n  server-cat-agent validate-telegram [--config 路径]\n  server-cat-agent check [--config 路径]\n  server-cat-agent check --scheduled [--config 路径]\n  server-cat-agent status [--config 路径]\n  server-cat-agent test-email [--config 路径]\n  server-cat-agent test-telegram [--config 路径]\n  server-cat-agent mute <时长> [--config 路径]\n  server-cat-agent unmute [--config 路径]\n  server-cat-agent version"
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

fn parse_mute_arguments(arguments: &[String]) -> Result<(u64, String), String> {
    let Some((duration, remaining)) = arguments.split_first() else {
        return Err("静默时长不能为空，用法: mute <时长>，例如 30m、2h、1d".to_owned());
    };

    let duration_seconds = parse_mute_duration(duration)?;
    let config_path = parse_config_path(remaining)?;
    Ok((duration_seconds, config_path))
}

fn parse_mute_duration(input: &str) -> Result<u64, String> {
    let Some(unit) = input.chars().last() else {
        return Err("静默时长无效，请使用 30m、2h 或 1d".to_owned());
    };
    let multiplier = match unit {
        'm' => 60,
        'h' => 60 * 60,
        'd' => 24 * 60 * 60,
        _ => return Err("静默时长无效，请使用 30m、2h 或 1d".to_owned()),
    };
    let number = input[..input.len() - unit.len_utf8()]
        .parse::<u64>()
        .map_err(|_| "静默时长无效，请使用 30m、2h 或 1d".to_owned())?;
    if number == 0 {
        return Err("静默时长必须大于 0".to_owned());
    }
    let duration_seconds = number
        .checked_mul(multiplier)
        .ok_or_else(|| "静默时长过大".to_owned())?;
    if duration_seconds > 30 * 24 * 60 * 60 {
        return Err("单次静默最长 30 天".to_owned());
    }

    Ok(duration_seconds)
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

    if config.thresholds.swap_warning_percent == 0 || config.thresholds.swap_warning_percent > 100 {
        return Err("swap_warning_percent 必须在 1 到 100 之间".to_owned());
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

        load_smtp_settings(config)?;
    }

    if config.telegram.reminder_hours == 0 {
        return Err("telegram.reminder_hours 必须大于 0".to_owned());
    }

    if config.telegram.enabled {
        validate_telegram_bot_token(&config.telegram.bot_token)?;
        if config.telegram.chat_ids.is_empty() {
            return Err("启用 Telegram 时 telegram.chat_ids 必须至少包含一个 Chat ID".to_owned());
        }
        validate_unique_values(&config.telegram.chat_ids, "telegram.chat_ids")?;
        for chat_id in &config.telegram.chat_ids {
            if !is_valid_telegram_chat_id(chat_id) {
                return Err(format!("telegram.chat_ids 包含无效 Chat ID: {chat_id}"));
            }
        }
    }

    if config.checks.http_timeout_seconds == 0 || config.checks.http_timeout_seconds > 300 {
        return Err("checks.http_timeout_seconds 必须在 1 到 300 之间".to_owned());
    }

    validate_unique_values(&config.checks.systemd_services, "checks.systemd_services")?;
    for service in &config.checks.systemd_services {
        if !is_valid_systemd_service_name(service) {
            return Err(format!("checks.systemd_services 包含无效服务名: {service}"));
        }
    }

    validate_unique_values(&config.checks.http_urls, "checks.http_urls")?;
    for url in &config.checks.http_urls {
        if !is_valid_http_url(url) {
            return Err(format!("checks.http_urls 包含无效地址: {url}"));
        }
    }

    validate_unique_values(&config.checks.docker_containers, "checks.docker_containers")?;
    for container in &config.checks.docker_containers {
        if !is_valid_docker_container_name(container) {
            return Err(format!(
                "checks.docker_containers 包含无效容器名: {container}"
            ));
        }
    }

    if config.checks.certificate_warning_days == 0 || config.checks.certificate_warning_days > 365 {
        return Err("checks.certificate_warning_days 必须在 1 到 365 之间".to_owned());
    }

    validate_unique_values(&config.checks.certificate_paths, "checks.certificate_paths")?;
    for path in &config.checks.certificate_paths {
        if !Path::new(path).is_absolute() {
            return Err(format!("checks.certificate_paths 必须使用绝对路径: {path}"));
        }
    }

    Ok(())
}

fn validate_unique_values(values: &[String], name: &str) -> Result<(), String> {
    let mut seen = HashSet::new();
    for value in values {
        if value.trim().is_empty() || !seen.insert(value) {
            return Err(format!("{name} 不能包含空值或重复项"));
        }
    }

    Ok(())
}

fn is_valid_systemd_service_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "@_.-".contains(character))
}

fn is_valid_http_url(url: &str) -> bool {
    (url.starts_with("https://") || url.starts_with("http://"))
        && !url.contains('@')
        && !url.chars().any(char::is_whitespace)
}

fn is_valid_docker_container_name(name: &str) -> bool {
    let mut characters = name.chars();
    matches!(characters.next(), Some(character) if character.is_ascii_alphanumeric())
        && characters
            .all(|character| character.is_ascii_alphanumeric() || "_.-".contains(character))
}

fn validate_telegram_bot_token(token: &str) -> Result<(), String> {
    let Some((bot_id, secret)) = token.split_once(':') else {
        return Err("telegram.bot_token 格式无效".to_owned());
    };
    if bot_id.is_empty()
        || !bot_id.chars().all(|character| character.is_ascii_digit())
        || secret.len() < 20
        || !secret
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "_-".contains(character))
    {
        return Err("telegram.bot_token 格式无效".to_owned());
    }

    Ok(())
}

fn is_valid_telegram_chat_id(chat_id: &str) -> bool {
    if let Some(username) = chat_id.strip_prefix('@') {
        return (5..=32).contains(&username.len())
            && username
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || character == '_');
    }

    let numeric = chat_id.strip_prefix('-').unwrap_or(chat_id);
    !numeric.is_empty() && numeric.chars().all(|character| character.is_ascii_digit())
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
    let notifications_muted = state.notifications_muted(now);
    let email_status = notification_status(config.email.enabled, &state, now);
    let telegram_status = notification_status(config.telegram.enabled, &state, now);
    let check_result = format_check_result(&alerts, &email_status, &telegram_status);
    let smtp = if config.email.enabled && !notifications_muted {
        Some(load_smtp_settings(config)?)
    } else {
        None
    };
    let hostname = read_hostname();
    let email_reminder_seconds = config.email.reminder_hours.saturating_mul(3600);
    let telegram_reminder_seconds = config.telegram.reminder_hours.saturating_mul(3600);
    let active_keys: HashSet<String> = alerts.iter().map(|alert| alert.key.clone()).collect();
    let mut notification_errors = Vec::new();

    for alert in alerts {
        let previous = state.alerts.get(&alert.key).cloned();
        let should_email = config.email.enabled
            && !notifications_muted
            && should_notify_active(
                previous.as_ref(),
                alert.level,
                previous.as_ref().and_then(|alert| alert.last_sent_unix),
                now,
                email_reminder_seconds,
            );
        let should_telegram = config.telegram.enabled
            && !notifications_muted
            && should_notify_active(
                previous.as_ref(),
                alert.level,
                previous
                    .as_ref()
                    .and_then(|alert| alert.last_telegram_sent_unix),
                now,
                telegram_reminder_seconds,
            );

        let email_sent = if should_email && let Some(settings) = smtp.as_ref() {
            match send_email(
                settings,
                config,
                &format!("Server Cat {}告警: {}", alert.level.label(), alert.label),
                &format!("主机: {hostname}\n时间: {now}\n\n{}\n", alert.message),
            ) {
                Ok(()) => true,
                Err(error) => {
                    notification_errors.push(format!("邮件告警 {}: {error}", alert.label));
                    false
                }
            }
        } else {
            false
        };
        let telegram_sent = if should_telegram {
            match send_telegram(
                config,
                &format!("Server Cat {}告警: {}", alert.level.label(), alert.label),
                &format!("主机: {hostname}\n时间: {now}\n\n{}\n", alert.message),
            ) {
                Ok(()) => true,
                Err(error) => {
                    notification_errors.push(format!("Telegram 告警 {}: {error}", alert.label));
                    false
                }
            }
        } else {
            false
        };

        let last_sent_unix = if email_sent {
            Some(now)
        } else {
            previous
                .as_ref()
                .and_then(|previous| previous.last_sent_unix)
        };
        let last_telegram_sent_unix = if telegram_sent {
            Some(now)
        } else {
            previous
                .as_ref()
                .and_then(|previous| previous.last_telegram_sent_unix)
        };
        let alert_key = alert.key.clone();
        let active_alert = active_alert_from_detection(
            alert,
            previous.as_ref(),
            now,
            last_sent_unix,
            last_telegram_sent_unix,
        );
        state.alerts.insert(alert_key, active_alert);
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
        let mut recovery_sent = true;
        if let Some(settings) = smtp.as_ref()
            && let Err(error) = send_email(
                settings,
                config,
                &format!("Server Cat 告警恢复: {}", previous.label),
                &format!(
                    "主机: {hostname}\n时间: {now}\n\n{} 已恢复正常。\n上次告警: {}\n",
                    previous.label, previous.message
                ),
            )
        {
            notification_errors.push(format!("邮件恢复通知 {}: {error}", previous.label));
            recovery_sent = false;
        }
        if config.telegram.enabled
            && !notifications_muted
            && let Err(error) = send_telegram(
                config,
                &format!("Server Cat 告警恢复: {}", previous.label),
                &format!(
                    "主机: {hostname}\n时间: {now}\n\n{} 已恢复正常。\n上次告警: {}\n",
                    previous.label, previous.message
                ),
            )
        {
            notification_errors.push(format!("Telegram 恢复通知 {}: {error}", previous.label));
            recovery_sent = false;
        }
        if recovery_sent {
            state.alerts.remove(&key);
        }
    }

    if scheduled {
        state.last_scheduled_check_unix = Some(now);
    }
    save_state(&state_path, &state)?;
    println!("{check_result}");
    if notification_errors.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "通知发送失败:\n- {}",
            notification_errors.join("\n- ")
        ))
    }
}

fn show_status(config: &Config) -> Result<(), String> {
    let state_path = Path::new(&config.agent.state_dir).join("alerts.json");
    let state = load_state(&state_path)?;
    let timer = read_timer_status();
    let last_scheduled_check = format_scheduled_check(state.last_scheduled_check_unix);
    let now = unix_timestamp()?;
    let email_status = notification_status(config.email.enabled, &state, now);
    let telegram_status = notification_status(config.telegram.enabled, &state, now);

    println!(
        "{}",
        format_agent_status(
            config,
            &state,
            &timer,
            &last_scheduled_check,
            &email_status,
            &telegram_status,
        )
    );
    Ok(())
}

fn mute_notifications(config: &Config, duration_seconds: u64) -> Result<(), String> {
    let now = unix_timestamp()?;
    let mute_until = now
        .checked_add(duration_seconds)
        .ok_or_else(|| "静默截止时间超出范围".to_owned())?;
    let state_path = Path::new(&config.agent.state_dir).join("alerts.json");
    let mut state = load_state(&state_path)?;
    state.notification_mute_until_unix = Some(mute_until);
    save_state(&state_path, &state)?;

    println!("外部通知已静默至: {}", format_unix_timestamp(mute_until));
    Ok(())
}

fn unmute_notifications(config: &Config) -> Result<(), String> {
    let state_path = Path::new(&config.agent.state_dir).join("alerts.json");
    let mut state = load_state(&state_path)?;
    if state.notification_mute_until_unix.is_none() {
        println!("外部通知当前未处于静默状态");
        return Ok(());
    }

    state.notification_mute_until_unix = None;
    save_state(&state_path, &state)?;
    println!("已恢复外部通知");
    Ok(())
}

fn send_test_email(config: &Config) -> Result<(), String> {
    if !config.email.enabled {
        return Err("邮件通知未启用，请先在 agent.toml 设置 email.enabled = true".to_owned());
    }

    let settings = load_smtp_settings(config)?;
    let hostname = read_hostname();
    let now = unix_timestamp()?;
    send_email(
        &settings,
        config,
        &format!("Server Cat 测试邮件: {hostname}"),
        &format!(
            "主机: {hostname}\n时间: {now}\n\n这是一封 Server Cat 测试邮件。收到此邮件表示 SMTP 配置可用于发送监控告警。\n"
        ),
    )?;
    println!("测试邮件已发送至: {}", config.email.recipients.join(", "));
    Ok(())
}

fn send_test_telegram(config: &Config) -> Result<(), String> {
    if !config.telegram.enabled {
        return Err(
            "Telegram 通知未启用，请先在 agent.toml 设置 telegram.enabled = true".to_owned(),
        );
    }

    let hostname = read_hostname();
    let now = unix_timestamp()?;
    send_telegram(
        config,
        &format!("Server Cat Telegram 测试: {hostname}"),
        &format!(
            "主机: {hostname}\n时间: {now}\n\n这是一条 Server Cat 测试通知。收到此消息表示 Telegram Bot 配置可用于发送监控告警。\n"
        ),
    )?;
    println!(
        "Telegram 测试通知已发送至: {}",
        config.telegram.chat_ids.join(", ")
    );
    Ok(())
}

fn read_timer_status() -> TimerStatus {
    TimerStatus {
        unit_file_state: read_timer_property("UnitFileState"),
        active_state: read_timer_property("ActiveState"),
        last_trigger: read_timer_property("LastTriggerUSec"),
        next_trigger: read_timer_property("NextElapseUSecRealtime"),
    }
}

fn read_timer_property(property: &str) -> String {
    Command::new("systemctl")
        .args([
            "show",
            "server-cat-agent.timer",
            "--property",
            property,
            "--value",
        ])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "未知".to_owned())
}

fn format_scheduled_check(timestamp: Option<u64>) -> String {
    let Some(timestamp) = timestamp else {
        return "尚未执行".to_owned();
    };

    format_unix_timestamp(timestamp)
}

fn format_optional_timestamp(timestamp: Option<u64>) -> String {
    timestamp
        .map(format_unix_timestamp)
        .unwrap_or_else(|| "未记录".to_owned())
}

fn format_unix_timestamp(timestamp: u64) -> String {
    let date_argument = format!("@{timestamp}");

    Command::new("date")
        .args(["--date", &date_argument, "+%Y-%m-%d %H:%M:%S %Z"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("Unix 时间戳 {timestamp}"))
}

fn format_agent_status(
    config: &Config,
    state: &AgentState,
    timer: &TimerStatus,
    last_scheduled_check: &str,
    email_status: &str,
    telegram_status: &str,
) -> String {
    let mut lines = vec![
        "Server Cat Agent 状态".to_owned(),
        format!("定时器: {} ({})", timer.unit_file_state, timer.active_state),
        format!("上次定时触发: {}", timer.last_trigger),
        format!("下次定时触发: {}", timer.next_trigger),
        format!("实际巡检间隔: {} 秒", config.schedule.interval_seconds),
        format!("上次实际巡检: {last_scheduled_check}"),
        format!("邮件通知: {email_status}"),
        format!("Telegram 通知: {telegram_status}"),
        "巡检目标:".to_owned(),
        format!(
            "- systemd 服务: {}",
            format_target_list(&config.checks.systemd_services)
        ),
        format!(
            "- HTTP 地址: {}",
            format_target_list(&config.checks.http_urls)
        ),
        format!(
            "- Docker 容器: {}",
            format_target_list(&config.checks.docker_containers)
        ),
        format!(
            "- TLS 证书: {}",
            format_target_list(&config.checks.certificate_paths)
        ),
        format!(
            "- 重启需求: {}",
            if config.checks.check_reboot_required {
                "检查"
            } else {
                "未配置"
            }
        ),
    ];

    if state.alerts.is_empty() {
        lines.push("当前告警: 无".to_owned());
    } else {
        lines.push(format!("当前告警: {} 项", state.alerts.len()));
        for alert in state.alerts.values() {
            lines.push(format_active_alert(alert));
        }
    }

    lines.join("\n")
}

fn format_active_alert(alert: &ActiveAlert) -> String {
    format!(
        "- [{}] {}\n  首次发现: {}\n  最近发现: {}\n  最近邮件通知: {}\n  最近 Telegram 通知: {}",
        alert.level.label(),
        alert.message,
        format_optional_timestamp(alert.first_detected_unix),
        format_optional_timestamp(alert.last_detected_unix),
        format_optional_timestamp(alert.last_sent_unix),
        format_optional_timestamp(alert.last_telegram_sent_unix),
    )
}

fn format_target_list(targets: &[String]) -> String {
    if targets.is_empty() {
        "未配置".to_owned()
    } else {
        targets.join(", ")
    }
}

fn notification_status(email_enabled: bool, state: &AgentState, now: u64) -> String {
    if !email_enabled {
        return "未启用".to_owned();
    }
    if let Some(mute_until) = state
        .notification_mute_until_unix
        .filter(|mute_until| *mute_until > now)
    {
        return format!("已静默至 {}", format_unix_timestamp(mute_until));
    }

    "已启用".to_owned()
}

fn format_check_result(
    alerts: &[DetectedAlert],
    email_status: &str,
    telegram_status: &str,
) -> String {
    if alerts.is_empty() {
        return format!(
            "监控检查完成: 未发现超过阈值的指标，邮件通知{email_status}，Telegram 通知{telegram_status}"
        );
    }
    let details = alerts
        .iter()
        .map(|alert| format!("- [{}] {}", alert.level.label(), alert.message))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "监控检查完成: {} 项指标处于告警状态，邮件通知{email_status}，Telegram 通知{telegram_status}\n\n告警详情:\n{details}",
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

    if let Some(swap_percent) = swap_usage_percent()?
        && swap_percent >= config.thresholds.swap_warning_percent
    {
        alerts.push(DetectedAlert {
            key: "swap".to_owned(),
            level: AlertLevel::Warning,
            label: "交换空间".to_owned(),
            message: format!(
                "交换空间使用率为 {swap_percent}%，阈值为 {}%",
                config.thresholds.swap_warning_percent
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

    for service in &config.checks.systemd_services {
        if !systemd_service_is_active(service)? {
            alerts.push(DetectedAlert {
                key: format!("systemd:{service}"),
                level: AlertLevel::Critical,
                label: format!("systemd 服务 {service}"),
                message: format!("systemd 服务 {service} 未处于 active 状态"),
            });
        }
    }

    for url in &config.checks.http_urls {
        if let Some(reason) = probe_http_url(url, config.checks.http_timeout_seconds)? {
            alerts.push(DetectedAlert {
                key: format!("http:{url}"),
                level: AlertLevel::Critical,
                label: format!("HTTP {url}"),
                message: format!("HTTP 探活失败: {url}，{reason}"),
            });
        }
    }

    alerts.extend(collect_docker_container_alerts(
        &config.checks.docker_containers,
    ));

    alerts.extend(collect_certificate_alerts(
        &config.checks.certificate_paths,
        config.checks.certificate_warning_days,
    ));

    if config.checks.check_reboot_required && Path::new("/var/run/reboot-required").exists() {
        alerts.push(DetectedAlert {
            key: "system:reboot-required".to_owned(),
            level: AlertLevel::Warning,
            label: "系统重启".to_owned(),
            message: "系统标记为需要重启".to_owned(),
        });
    }

    Ok(alerts)
}

fn collect_docker_container_alerts(containers: &[String]) -> Vec<DetectedAlert> {
    if containers.is_empty() {
        return Vec::new();
    }

    if let Err(reason) = ensure_docker_available() {
        return vec![DetectedAlert {
            key: "docker:runtime".to_owned(),
            level: AlertLevel::Critical,
            label: "Docker 运行环境".to_owned(),
            message: format!("无法检查 Docker 容器: {reason}"),
        }];
    }

    let mut alerts = Vec::new();
    for container in containers {
        match docker_container_is_running(container) {
            Ok(true) => {}
            Ok(false) => alerts.push(DetectedAlert {
                key: format!("docker:{container}"),
                level: AlertLevel::Critical,
                label: format!("Docker 容器 {container}"),
                message: format!("Docker 容器 {container} 未处于运行状态"),
            }),
            Err(reason) => alerts.push(DetectedAlert {
                key: format!("docker:{container}"),
                level: AlertLevel::Critical,
                label: format!("Docker 容器 {container}"),
                message: format!("无法检查 Docker 容器 {container}: {reason}"),
            }),
        }
    }

    alerts
}

fn collect_certificate_alerts(paths: &[String], warning_days: u64) -> Vec<DetectedAlert> {
    let mut alerts = Vec::new();
    let warning_seconds = warning_days.saturating_mul(24 * 60 * 60);

    for path in paths {
        if !Path::new(path).is_file() {
            alerts.push(DetectedAlert {
                key: format!("certificate:{path}"),
                level: AlertLevel::Critical,
                label: format!("TLS 证书 {path}"),
                message: format!("TLS 证书文件不存在或不是常规文件: {path}"),
            });
            continue;
        }

        match certificate_valid_for(path, warning_seconds) {
            Ok(true) => {}
            Ok(false) => match certificate_valid_for(path, 0) {
                Ok(true) => alerts.push(DetectedAlert {
                    key: format!("certificate:{path}"),
                    level: AlertLevel::Warning,
                    label: format!("TLS 证书 {path}"),
                    message: format!("TLS 证书将在 {warning_days} 天内到期: {path}"),
                }),
                Ok(false) => alerts.push(DetectedAlert {
                    key: format!("certificate:{path}"),
                    level: AlertLevel::Critical,
                    label: format!("TLS 证书 {path}"),
                    message: format!("TLS 证书已过期: {path}"),
                }),
                Err(reason) => alerts.push(certificate_check_error(path, reason)),
            },
            Err(reason) => alerts.push(certificate_check_error(path, reason)),
        }
    }

    alerts
}

fn certificate_valid_for(path: &str, seconds: u64) -> Result<bool, String> {
    let seconds = seconds.to_string();
    let output = Command::new("openssl")
        .args(["x509", "-in", path, "-noout", "-checkend", &seconds])
        .output()
        .map_err(|error| format!("无法执行 openssl: {error}"))?;

    if output.status.success() {
        Ok(true)
    } else {
        let validation = Command::new("openssl")
            .args(["x509", "-in", path, "-noout"])
            .output()
            .map_err(|error| format!("无法执行 openssl: {error}"))?;
        if validation.status.success() {
            Ok(false)
        } else {
            Err(format!(
                "无法读取有效 TLS 证书: {}",
                command_failure_reason(&validation)
            ))
        }
    }
}

fn certificate_check_error(path: &str, reason: String) -> DetectedAlert {
    DetectedAlert {
        key: format!("certificate:{path}"),
        level: AlertLevel::Critical,
        label: format!("TLS 证书 {path}"),
        message: format!("无法检查 TLS 证书 {path}: {reason}"),
    }
}

fn ensure_docker_available() -> Result<(), String> {
    let output = Command::new("docker")
        .args(["version", "--format", "{{.Server.Version}}"])
        .output()
        .map_err(|error| format!("无法执行 docker: {error}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(command_failure_reason(&output))
    }
}

fn docker_container_is_running(container: &str) -> Result<bool, String> {
    let output = Command::new("docker")
        .args(["inspect", "--format", "{{.State.Running}}", container])
        .output()
        .map_err(|error| format!("无法执行 docker: {error}"))?;

    if !output.status.success() {
        return Err(command_failure_reason(&output));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim() == "true")
}

fn command_failure_reason(output: &std::process::Output) -> String {
    let error_output = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if error_output.is_empty() {
        format!("命令退出状态 {status}", status = output.status)
    } else {
        error_output
    }
}

fn systemd_service_is_active(service: &str) -> Result<bool, String> {
    Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status()
        .map(|status| status.success())
        .map_err(|error| format!("无法检查 systemd 服务 {service}: {error}"))
}

fn probe_http_url(url: &str, timeout_seconds: u64) -> Result<Option<String>, String> {
    let timeout = timeout_seconds.to_string();
    let output = Command::new("curl")
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            &timeout,
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            url,
        ])
        .output()
        .map_err(|error| format!("无法执行 HTTP 探活 curl: {error}"))?;

    if output.status.success() {
        return Ok(None);
    }

    let status_code = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    let error_output = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    let reason = match (status_code.as_str(), error_output.as_str()) {
        ("" | "000", "") => "连接失败或请求超时".to_owned(),
        ("" | "000", error) => error.to_owned(),
        (status, "") => format!("HTTP 状态码 {status}"),
        (status, error) => format!("HTTP 状态码 {status}: {error}"),
    };

    Ok(Some(reason))
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
            | "squashfs"
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
    usage_percent_from_meminfo(&contents, "MemTotal", "MemAvailable")?
        .ok_or_else(|| "内存总量不能为 0".to_owned())
}

fn swap_usage_percent() -> Result<Option<u8>, String> {
    let contents = fs::read_to_string("/proc/meminfo")
        .map_err(|error| format!("无法读取 /proc/meminfo: {error}"))?;
    usage_percent_from_meminfo(&contents, "SwapTotal", "SwapFree")
}

fn usage_percent_from_meminfo(
    contents: &str,
    total_key: &str,
    available_key: &str,
) -> Result<Option<u8>, String> {
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
            key if key == total_key => total = value,
            key if key == available_key => available = value,
            _ => {}
        }
    }

    match (total, available) {
        (Some(total), Some(available)) => Ok(usage_percent(total, available)),
        _ => Err(format!("/proc/meminfo 缺少 {total_key} 或 {available_key}")),
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
    last_sent_unix: Option<u64>,
    now: u64,
    reminder_seconds: u64,
) -> bool {
    let Some(previous) = previous else {
        return true;
    };
    if previous.level != level {
        return true;
    }

    last_sent_unix.is_none_or(|last_sent| now.saturating_sub(last_sent) >= reminder_seconds)
}

fn active_alert_from_detection(
    detected: DetectedAlert,
    previous: Option<&ActiveAlert>,
    now: u64,
    last_sent_unix: Option<u64>,
    last_telegram_sent_unix: Option<u64>,
) -> ActiveAlert {
    ActiveAlert {
        level: detected.level,
        label: detected.label,
        message: detected.message,
        first_detected_unix: previous
            .and_then(|previous| previous.first_detected_unix)
            .or(Some(now)),
        last_detected_unix: Some(now),
        last_sent_unix,
        last_telegram_sent_unix,
    }
}

fn load_smtp_settings(config: &Config) -> Result<SmtpSettings, String> {
    let email = &config.email;
    let host = required_email_smtp_value(&email.smtp_host, "email.smtp_host")?;
    if email.smtp_port == 0 {
        return Err("email.smtp_port 必须是 1 到 65535 的端口".to_owned());
    }

    let security = match email.smtp_security.as_str() {
        "starttls" => SmtpSecurity::StartTls,
        "tls" => SmtpSecurity::Tls,
        "none" => SmtpSecurity::None,
        value => {
            return Err(format!(
                "email.smtp_security 必须为 starttls、tls 或 none，当前为 {value}"
            ));
        }
    };
    let username = optional_email_smtp_value(&email.smtp_username);
    let password = optional_email_smtp_value(&email.smtp_password);
    let credentials = match (username, password) {
        (None, None) => None,
        (Some(username), Some(password)) => Some(Credentials::new(username, password)),
        _ => {
            return Err("email.smtp_username 与 email.smtp_password 必须同时设置".to_owned());
        }
    };

    Ok(SmtpSettings {
        host,
        port: email.smtp_port,
        security,
        credentials,
    })
}

fn required_email_smtp_value(value: &str, name: &str) -> Result<String, String> {
    optional_email_smtp_value(value).ok_or_else(|| format!("启用邮件时 {name} 不能为空"))
}

fn optional_email_smtp_value(value: &str) -> Option<String> {
    (!value.trim().is_empty()).then(|| value.to_owned())
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

fn send_telegram(config: &Config, subject: &str, body: &str) -> Result<(), String> {
    let message = format_telegram_message(subject, body);
    for chat_id in &config.telegram.chat_ids {
        send_telegram_message(&config.telegram.bot_token, chat_id, &message)?;
    }
    Ok(())
}

fn format_telegram_message(subject: &str, body: &str) -> String {
    let message = format!("{subject}\n\n{}", body.trim());
    let mut characters = message.chars();
    let truncated: String = characters.by_ref().take(4093).collect();
    if characters.next().is_some() {
        format!("{truncated}...")
    } else {
        truncated
    }
}

fn send_telegram_message(bot_token: &str, chat_id: &str, message: &str) -> Result<(), String> {
    let api_url = format!("https://api.telegram.org/bot{bot_token}/sendMessage");
    let chat_argument = format!("chat_id={chat_id}");
    let text_argument = format!("text={message}");
    let mut child = Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--max-time",
            "20",
            "--request",
            "POST",
            "--data-urlencode",
            &chat_argument,
            "--data-urlencode",
            &text_argument,
            "--config",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("无法执行 Telegram 请求 curl: {error}"))?;

    let write_result = child
        .stdin
        .take()
        .ok_or_else(|| "无法打开 Telegram 请求输入".to_owned())?
        .write_all(format!("url = \"{api_url}\"\n").as_bytes());
    if let Err(error) = write_result {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("无法写入 Telegram 请求: {error}"));
    }

    let output = child
        .wait_with_output()
        .map_err(|error| format!("无法等待 Telegram 请求: {error}"))?;
    if !output.status.success() {
        let reason = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        if reason.is_empty() {
            return Err(format!("发送 Telegram 通知失败: {}", output.status));
        } else {
            return Err(format!("发送 Telegram 通知失败: {reason}"));
        }
    }

    parse_telegram_api_response(&output.stdout)
}

fn parse_telegram_api_response(contents: &[u8]) -> Result<(), String> {
    let response: TelegramApiResponse = serde_json::from_slice(contents)
        .map_err(|error| format!("Telegram API 返回无效响应: {error}"))?;
    if response.ok {
        Ok(())
    } else {
        Err(format!(
            "发送 Telegram 通知失败: {}",
            response
                .description
                .unwrap_or_else(|| "Telegram API 未说明原因".to_owned())
        ))
    }
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
smtp_host = "smtp.example.com"
smtp_port = 587
smtp_security = "starttls"
smtp_username = ""
smtp_password = ""
"#;

    #[test]
    fn accepts_valid_configuration() {
        let config: Config = toml::from_str(VALID_CONFIG).expect("configuration parses");
        assert!(validate_config(&config).is_ok());
        assert!(config.checks.systemd_services.is_empty());
        assert!(config.checks.http_urls.is_empty());
        assert_eq!(config.checks.http_timeout_seconds, 10);
        assert!(config.checks.docker_containers.is_empty());
        assert!(!config.checks.check_reboot_required);
        assert!(config.checks.certificate_paths.is_empty());
        assert_eq!(config.checks.certificate_warning_days, 14);
        assert_eq!(config.thresholds.swap_warning_percent, 80);
        assert!(!config.telegram.enabled);
        assert!(config.telegram.chat_ids.is_empty());
        assert_eq!(config.telegram.reminder_hours, 6);
    }

    #[test]
    fn accepts_valid_telegram_configuration() {
        let configuration = format!(
            "{VALID_CONFIG}\n[telegram]\nenabled = true\nbot_token = \"123456789:abcdefghijklmnopqrstuvwxyz_ABCDE\"\nchat_ids = [\"-1001234567890\", \"@server_cat_alerts\"]\nreminder_hours = 6\n"
        );
        let config: Config = toml::from_str(&configuration).expect("configuration parses");

        assert!(validate_config(&config).is_ok());
    }

    #[test]
    fn rejects_invalid_telegram_credentials() {
        let invalid_token = format!(
            "{VALID_CONFIG}\n[telegram]\nenabled = true\nbot_token = \"not-a-token\"\nchat_ids = [\"123456\"]\nreminder_hours = 6\n"
        );
        let invalid_chat = format!(
            "{VALID_CONFIG}\n[telegram]\nenabled = true\nbot_token = \"123456789:abcdefghijklmnopqrstuvwxyz_ABCDE\"\nchat_ids = [\"group name\"]\nreminder_hours = 6\n"
        );

        for configuration in [invalid_token, invalid_chat] {
            let config: Config = toml::from_str(&configuration).expect("configuration parses");
            assert!(validate_config(&config).is_err());
        }
    }

    #[test]
    fn accepts_valid_service_and_http_checks() {
        let configuration = format!(
            "{VALID_CONFIG}\n[checks]\nsystemd_services = [\"nginx\"]\nhttp_urls = [\"https://example.com/health\"]\nhttp_timeout_seconds = 10\ndocker_containers = [\"redis\"]\ncheck_reboot_required = true\ncertificate_paths = [\"/etc/letsencrypt/live/example.com/fullchain.pem\"]\ncertificate_warning_days = 14\n"
        );
        let config: Config = toml::from_str(&configuration).expect("configuration parses");
        assert!(validate_config(&config).is_ok());
    }

    #[test]
    fn rejects_invalid_check_entries() {
        let invalid_service = format!(
            "{VALID_CONFIG}\n[checks]\nsystemd_services = [\"nginx;rm\"]\nhttp_urls = []\nhttp_timeout_seconds = 10\n"
        );
        let invalid_url = format!(
            "{VALID_CONFIG}\n[checks]\nsystemd_services = []\nhttp_urls = [\"ftp://example.com\"]\nhttp_timeout_seconds = 10\n"
        );
        let duplicate_service = format!(
            "{VALID_CONFIG}\n[checks]\nsystemd_services = [\"nginx\", \"nginx\"]\nhttp_urls = []\nhttp_timeout_seconds = 10\n"
        );
        let invalid_container = format!(
            "{VALID_CONFIG}\n[checks]\nsystemd_services = []\nhttp_urls = []\nhttp_timeout_seconds = 10\ndocker_containers = [\"redis;rm\"]\n"
        );
        let invalid_certificate = format!(
            "{VALID_CONFIG}\n[checks]\ncertificate_paths = [\"relative/fullchain.pem\"]\ncertificate_warning_days = 14\n"
        );

        for configuration in [
            invalid_service,
            invalid_url,
            duplicate_service,
            invalid_container,
            invalid_certificate,
        ] {
            let config: Config = toml::from_str(&configuration).expect("configuration parses");
            assert!(validate_config(&config).is_err());
        }
    }

    #[test]
    fn rejects_invalid_disk_thresholds() {
        let invalid =
            VALID_CONFIG.replace("disk_warning_percent = 80", "disk_warning_percent = 95");
        let config: Config = toml::from_str(&invalid).expect("configuration parses");
        assert!(validate_config(&config).is_err());
    }

    #[test]
    fn rejects_invalid_swap_threshold() {
        let invalid = VALID_CONFIG.replace(
            "memory_warning_percent = 85",
            "memory_warning_percent = 85\nswap_warning_percent = 0",
        );
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
    fn parses_memory_and_swap_usage_from_meminfo() {
        let contents = "MemTotal:       1000 kB\nMemAvailable:    200 kB\nSwapTotal:        500 kB\nSwapFree:         100 kB\n";

        assert_eq!(
            usage_percent_from_meminfo(contents, "MemTotal", "MemAvailable"),
            Ok(Some(80))
        );
        assert_eq!(
            usage_percent_from_meminfo(contents, "SwapTotal", "SwapFree"),
            Ok(Some(80))
        );
    }

    #[test]
    fn ignores_swap_check_when_no_swap_is_configured() {
        let contents = "SwapTotal:          0 kB\nSwapFree:           0 kB\n";

        assert_eq!(
            usage_percent_from_meminfo(contents, "SwapTotal", "SwapFree"),
            Ok(None)
        );
    }

    #[test]
    fn ignores_snap_squashfs_mounts() {
        assert!(ignored_filesystem("squashfs"));
        assert!(!ignored_filesystem("ext4"));
    }

    #[test]
    fn reports_missing_certificate_as_critical_alert() {
        let alerts = collect_certificate_alerts(
            &["/definitely-not-a-server-cat-certificate.pem".to_owned()],
            14,
        );

        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].level, AlertLevel::Critical);
        assert!(alerts[0].message.contains("证书文件不存在"));
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
            format_check_result(&alerts, "未启用", "已启用"),
            "监控检查完成: 1 项指标处于告警状态，邮件通知未启用，Telegram 通知已启用\n\n告警详情:\n- [严重] 磁盘 / 的磁盘使用率为 91%，警告阈值 80%，严重阈值 90%"
        );
    }

    #[test]
    fn status_output_summarizes_timer_targets_and_active_alerts() {
        let configuration = format!(
            "{VALID_CONFIG}\n[checks]\nsystemd_services = [\"nginx\"]\nhttp_urls = [\"https://example.com/health\"]\ndocker_containers = [\"redis\"]\ncheck_reboot_required = true\ncertificate_paths = [\"/etc/letsencrypt/live/example.com/fullchain.pem\"]\n"
        );
        let config: Config = toml::from_str(&configuration).expect("configuration parses");
        let mut state = AgentState::default();
        state.alerts.insert(
            "docker:redis".to_owned(),
            ActiveAlert {
                level: AlertLevel::Critical,
                label: "Docker 容器 redis".to_owned(),
                message: "Docker 容器 redis 未处于运行状态".to_owned(),
                first_detected_unix: None,
                last_detected_unix: None,
                last_sent_unix: None,
                last_telegram_sent_unix: None,
            },
        );
        let timer = TimerStatus {
            unit_file_state: "enabled".to_owned(),
            active_state: "active".to_owned(),
            last_trigger: "Fri 2026-07-25 10:00:00 CST".to_owned(),
            next_trigger: "Fri 2026-07-25 10:01:00 CST".to_owned(),
        };

        assert_eq!(
            format_agent_status(
                &config,
                &state,
                &timer,
                "Fri 2026-07-25 10:00:00 CST",
                "已启用",
                "未启用",
            ),
            "Server Cat Agent 状态\n定时器: enabled (active)\n上次定时触发: Fri 2026-07-25 10:00:00 CST\n下次定时触发: Fri 2026-07-25 10:01:00 CST\n实际巡检间隔: 60 秒\n上次实际巡检: Fri 2026-07-25 10:00:00 CST\n邮件通知: 已启用\nTelegram 通知: 未启用\n巡检目标:\n- systemd 服务: nginx\n- HTTP 地址: https://example.com/health\n- Docker 容器: redis\n- TLS 证书: /etc/letsencrypt/live/example.com/fullchain.pem\n- 重启需求: 检查\n当前告警: 1 项\n- [严重] Docker 容器 redis 未处于运行状态\n  首次发现: 未记录\n  最近发现: 未记录\n  最近邮件通知: 未记录\n  最近 Telegram 通知: 未记录"
        );
    }

    #[test]
    fn parses_supported_mute_durations() {
        assert_eq!(parse_mute_duration("30m"), Ok(30 * 60));
        assert_eq!(parse_mute_duration("2h"), Ok(2 * 60 * 60));
        assert_eq!(parse_mute_duration("1d"), Ok(24 * 60 * 60));
        assert!(parse_mute_duration("0m").is_err());
        assert!(parse_mute_duration("31d").is_err());
        assert!(parse_mute_duration("90s").is_err());
    }

    #[test]
    fn parses_mute_with_custom_config() {
        let arguments = vec![
            "30m".to_owned(),
            "--config".to_owned(),
            "/tmp/server-cat.toml".to_owned(),
        ];

        assert_eq!(
            parse_mute_arguments(&arguments),
            Ok((30 * 60, "/tmp/server-cat.toml".to_owned()))
        );
    }

    #[test]
    fn mute_state_expires_without_writing_state() {
        let mut state = AgentState::default();
        state.notification_mute_until_unix = Some(200);

        assert!(state.notifications_muted(199));
        assert!(!state.notifications_muted(200));
        assert_eq!(notification_status(true, &state, 200), "已启用");
    }

    #[test]
    fn loads_legacy_email_state_without_telegram_fields() {
        let state: AgentState = serde_json::from_str(
            r#"{
                "alerts": {
                    "memory": {
                        "level": "warning",
                        "label": "内存",
                        "message": "内存使用率过高",
                        "last_sent_unix": 100
                    }
                },
                "email_mute_until_unix": 200
            }"#,
        )
        .expect("legacy state parses");

        assert_eq!(state.notification_mute_until_unix, Some(200));
        assert_eq!(state.alerts["memory"].last_telegram_sent_unix, None);
    }

    #[test]
    fn active_alert_keeps_first_detection_and_updates_recent_detection() {
        let previous = ActiveAlert {
            level: AlertLevel::Warning,
            label: "内存".to_owned(),
            message: "内存使用率为 90%".to_owned(),
            first_detected_unix: Some(100),
            last_detected_unix: Some(150),
            last_sent_unix: Some(150),
            last_telegram_sent_unix: Some(140),
        };
        let detected = DetectedAlert {
            key: "memory".to_owned(),
            level: AlertLevel::Critical,
            label: "内存".to_owned(),
            message: "内存使用率为 95%".to_owned(),
        };

        let updated =
            active_alert_from_detection(detected, Some(&previous), 200, Some(200), Some(200));

        assert_eq!(updated.first_detected_unix, Some(100));
        assert_eq!(updated.last_detected_unix, Some(200));
        assert_eq!(updated.last_sent_unix, Some(200));
        assert_eq!(updated.last_telegram_sent_unix, Some(200));
        assert_eq!(updated.level, AlertLevel::Critical);
    }

    #[test]
    fn scheduled_check_without_state_is_reported_as_not_run() {
        assert_eq!(format_scheduled_check(None), "尚未执行");
    }

    #[test]
    fn test_email_requires_enabled_notifications() {
        let configuration = VALID_CONFIG.replace("enabled = true", "enabled = false");
        let config: Config = toml::from_str(&configuration).expect("configuration parses");

        assert_eq!(
            send_test_email(&config),
            Err("邮件通知未启用，请先在 agent.toml 设置 email.enabled = true".to_owned())
        );
    }

    #[test]
    fn test_telegram_requires_enabled_notifications() {
        let config: Config = toml::from_str(VALID_CONFIG).expect("configuration parses");

        assert_eq!(
            send_test_telegram(&config),
            Err("Telegram 通知未启用，请先在 agent.toml 设置 telegram.enabled = true".to_owned())
        );
    }

    #[test]
    fn telegram_message_is_plain_text_and_limited_to_api_length() {
        assert_eq!(
            format_telegram_message("Server Cat 告警", "磁盘空间不足\n"),
            "Server Cat 告警\n\n磁盘空间不足"
        );
        assert_eq!(
            format_telegram_message("告警", &"x".repeat(5000))
                .chars()
                .count(),
            4096
        );
    }

    #[test]
    fn telegram_api_response_reports_remote_error() {
        assert!(parse_telegram_api_response(br#"{"ok":true}"#).is_ok());
        assert_eq!(
            parse_telegram_api_response(
                br#"{"ok":false,"description":"Bad Request: chat not found"}"#
            ),
            Err("发送 Telegram 通知失败: Bad Request: chat not found".to_owned())
        );
    }

    #[test]
    fn only_notifies_for_new_escalated_or_due_alerts() {
        let previous = ActiveAlert {
            level: AlertLevel::Warning,
            label: "内存".to_owned(),
            message: "内存使用率为 90%".to_owned(),
            first_detected_unix: Some(100),
            last_detected_unix: Some(100),
            last_sent_unix: Some(100),
            last_telegram_sent_unix: Some(90),
        };
        assert!(should_notify_active(
            None,
            AlertLevel::Warning,
            None,
            101,
            3600
        ));
        assert!(!should_notify_active(
            Some(&previous),
            AlertLevel::Warning,
            previous.last_sent_unix,
            200,
            3600
        ));
        assert!(should_notify_active(
            Some(&previous),
            AlertLevel::Critical,
            previous.last_sent_unix,
            200,
            3600
        ));
        assert!(should_notify_active(
            Some(&previous),
            AlertLevel::Warning,
            previous.last_telegram_sent_unix,
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
    fn rejects_enabled_email_without_smtp_host() {
        let invalid = VALID_CONFIG.replace("smtp_host = \"smtp.example.com\"", "smtp_host = \"\"");
        let config: Config = toml::from_str(&invalid).expect("configuration parses");

        assert!(validate_config(&config).is_err());
    }
}
