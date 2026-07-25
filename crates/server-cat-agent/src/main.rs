use serde::Deserialize;
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

const DEFAULT_CONFIG_PATH: &str = "/etc/server-cat/agent.toml";

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
    update_check_interval_hours: u64,
}

#[derive(Debug, Deserialize)]
struct ThresholdConfig {
    disk_warning_percent: u8,
    disk_critical_percent: u8,
    inode_warning_percent: u8,
    inode_critical_percent: u8,
    memory_warning_percent: u8,
    load_warning_per_cpu: f64,
    certificate_warning_days: u64,
    backup_max_age_hours: u64,
}

#[derive(Debug, Deserialize)]
struct EmailConfig {
    enabled: bool,
    from: String,
    recipients: Vec<String>,
    reminder_hours: u64,
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
            println!("配置有效: {config_path}");
            Ok(())
        }
        "check" => {
            let config_path = parse_config_path(&arguments[1..])?;
            let config = load_config(&config_path)?;
            validate_config(&config)?;
            println!("配置有效，监控检查功能尚未发布: {config_path}");
            Ok(())
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
    "用法:\n  server-cat-agent validate-config [--config 路径]\n  server-cat-agent check [--config 路径]\n  server-cat-agent version"
}

fn parse_config_path(arguments: &[String]) -> Result<String, String> {
    match arguments {
        [] => Ok(DEFAULT_CONFIG_PATH.to_owned()),
        [flag, path] if flag == "--config" && !path.is_empty() => Ok(path.to_owned()),
        _ => Err("配置参数无效，用法: --config <路径>".to_owned()),
    }
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

    if config.schedule.interval_seconds == 0 || config.schedule.update_check_interval_hours == 0 {
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

    if config.thresholds.certificate_warning_days == 0
        || config.thresholds.backup_max_age_hours == 0
    {
        return Err("证书和备份阈值必须大于 0".to_owned());
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

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_CONFIG: &str = r#"
[agent]
channel = "stable"
state_dir = "/var/lib/server-cat"

[schedule]
interval_seconds = 60
update_check_interval_hours = 6

[thresholds]
disk_warning_percent = 80
disk_critical_percent = 90
inode_warning_percent = 80
inode_critical_percent = 90
memory_warning_percent = 85
load_warning_per_cpu = 2.0
certificate_warning_days = 14
backup_max_age_hours = 26

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
}
