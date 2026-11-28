//! harness-engine — minimal Rust binary hosting the `headless` engine runtime
//! and the `exo-acp` stdio bridge. All other CLI subcommands live in the native
//! Zig `harness` binary, which delegates `headless` and `exo-acp` here.

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
use harness_engine::{Engine, EngineConfig, HarnessId};

#[derive(Parser)]
#[command(
    name = "harness-engine",
    version,
    about = "Headless session engine and Exo ACP bridge for Harness"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the engine without a UI (local-only unless a saved session enables sync).
    Headless {
        /// Off-by-default agents to offer, kebab-case (`antigravity`, `cursor`).
        /// Repeatable. Also read from `HARNESS_OPTED_IN` (comma-separated).
        #[arg(long = "opt-in", value_name = "HARNESS")]
        opt_in: Vec<String>,
    },
    /// Serve Exo over ACP on stdin/stdout, bridging to Exo's agent-cli socket.
    #[command(name = "exo-acp")]
    ExoAcp,
}

const DEFAULT_EDGE_URL: &str = "https://edge.codegraff.com";
const DEFAULT_CODEGRAFF_CLIENT_ID: &str = "cg_client_43e753878956c2cf7b5b0f53";

#[cfg(target_os = "macos")]
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn spawn_malloc_trimmer() {
    const PERIOD: std::time::Duration = std::time::Duration::from_secs(60);
    let spawned = std::thread::Builder::new()
        .name("malloc-trim".into())
        .spawn(|| {
            loop {
                std::thread::sleep(PERIOD);
                let started = std::time::Instant::now();
                // SAFETY: malloc_trim takes no pointers and locks each arena itself.
                let released = unsafe { libc::malloc_trim(0) } != 0;
                tracing::debug!(released, elapsed = ?started.elapsed(), "malloc_trim");
            }
        });
    if let Err(error) = spawned {
        tracing::warn!(%error, "malloc trimmer not started");
    }
}

#[cfg(windows)]
fn attach_parent_console() {
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::System::Console::{
        ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE,
        STD_OUTPUT_HANDLE, SetStdHandle,
    };

    unsafe {
        let saved = [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]
            .map(|id| (id, GetStdHandle(id)));
        if AttachConsole(ATTACH_PARENT_PROCESS) != 0 {
            for (id, handle) in saved {
                if !handle.is_null() && handle != INVALID_HANDLE_VALUE {
                    SetStdHandle(id, handle);
                }
            }
        }
    }
}

fn data_dir() -> PathBuf {
    match resolve_data_dir(|name| std::env::var_os(name)) {
        Ok(dir) => dir,
        Err(err) => {
            eprintln!("harness-engine: {err}");
            std::process::exit(2);
        }
    }
}

fn resolve_data_dir(
    mut env: impl FnMut(&str) -> Option<OsString>,
) -> Result<PathBuf, &'static str> {
    if let Some(dir) = env("HARNESS_DATA_DIR").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    // Match the Zig CLI (`engine_cli.zig`): `DATA_DIR` is the older override.
    if let Some(dir) = env("DATA_DIR").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    #[cfg(windows)]
    {
        let local = env("LOCALAPPDATA")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                env("USERPROFILE")
                    .filter(|value| !value.is_empty())
                    .map(|home| PathBuf::from(home).join("AppData").join("Local"))
            })
            .ok_or("LOCALAPPDATA and USERPROFILE not set; set HARNESS_DATA_DIR")?;
        return Ok(first_existing([
            local.join("Harness"),
            local.join("Harnesser"),
        ]));
    }
    #[cfg(not(windows))]
    {
        let home = env("HOME")
            .filter(|value| !value.is_empty())
            .ok_or("HOME is not set; set HARNESS_DATA_DIR")?;
        return Ok(first_existing([
            PathBuf::from(&home).join(".harness"),
            PathBuf::from(home).join(".harnesser"),
        ]));
    }
}

fn first_existing(candidates: impl IntoIterator<Item = PathBuf>) -> PathBuf {
    let mut iter = candidates.into_iter();
    let first = iter.next().expect("data dir candidates");
    if first.exists() {
        return first;
    }
    for path in iter {
        if path.exists() {
            return path;
        }
    }
    first
}

fn edge_url_from_env() -> String {
    std::env::var("HARNESS_EDGE_URL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_EDGE_URL.into())
}

fn codegraff_client_id_from_env(edge_token: &Option<String>) -> Option<String> {
    match std::env::var("HARNESS_CODEGRAFF_CLIENT_ID") {
        Ok(v) if v.trim().is_empty() => None,
        Ok(v) => Some(v),
        Err(_) if edge_token.is_some() => None,
        Err(_) => Some(DEFAULT_CODEGRAFF_CLIENT_ID.into()),
    }
}

/// Merge `--opt-in` values into `HARNESS_OPTED_IN` before the engine loads
/// prefs. Empty extra is a no-op so we never wipe an existing env list.
fn merge_cli_opt_ins(existing: Option<&str>, extra: &[String]) -> Option<String> {
    if extra.is_empty() {
        return None;
    }
    let extra = extra.join(",");
    Some(match existing {
        Some(existing) if !existing.trim().is_empty() => format!("{existing},{extra}"),
        _ => extra,
    })
}

fn apply_cli_opt_ins(opt_in: &[String]) {
    let Some(merged) = merge_cli_opt_ins(std::env::var("HARNESS_OPTED_IN").ok().as_deref(), opt_in)
    else {
        return;
    };
    // SAFETY: still on the main thread before Engine::new spawns work.
    unsafe { std::env::set_var("HARNESS_OPTED_IN", merged) };
}

fn harness_from_env() -> HarnessId {
    match std::env::var("HARNESS_PROVIDER")
        .ok()
        .as_deref()
        .map(str::trim)
    {
        Some("mock") => HarnessId::Mock,
        Some("codex") => HarnessId::Codex,
        Some("cursor") => HarnessId::Cursor,
        Some("devin") => HarnessId::Devin,
        Some("grok") => HarnessId::Grok,
        Some("hermes") => HarnessId::Hermes,
        Some("claude-code") => HarnessId::ClaudeCode,
        Some("pi") => HarnessId::Pi,
        Some("antigravity") => HarnessId::Antigravity,
        Some("exo") => HarnessId::Exo,
        _ => HarnessId::Graff,
    }
}

fn engine_config_from_env() -> EngineConfig {
    let edge_token = std::env::var("HARNESS_EDGE_TOKEN").ok();
    EngineConfig {
        data_dir: data_dir(),
        edge_url: edge_url_from_env(),
        ipc_port: std::env::var("HARNESS_IPC_PORT")
            .ok()
            .and_then(|p| p.parse().ok())
            .unwrap_or(27664),
        default_harness: harness_from_env(),
        org_id: std::env::var("HARNESS_ORG_ID").ok(),
        codegraff_client_id: codegraff_client_id_from_env(&edge_token),
        edge_token,
    }
}

fn open_log_file(mode: &str) -> Option<std::fs::File> {
    open_log_file_in(&data_dir().join("logs"), mode)
}

fn open_log_file_in(dir: &Path, mode: &str) -> Option<std::fs::File> {
    std::fs::create_dir_all(dir).ok()?;
    let path = dir.join(format!("harness-{mode}.log"));
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let preexisting = path.exists();
        let existing = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .ok()?;
        let rc = unsafe { libc::flock(existing.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            return std::fs::File::create(
                dir.join(format!("harness-{mode}.{}.log", std::process::id())),
            )
            .ok();
        }
        drop(existing);
        if preexisting {
            let _ = std::fs::rename(&path, dir.join(format!("harness-{mode}.log.old")));
        }
        let file = std::fs::File::create(&path).ok()?;
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        sweep_stale_pid_logs(dir, mode);
        Some(file)
    }
    #[cfg(not(unix))]
    {
        let _ = std::fs::rename(&path, dir.join(format!("harness-{mode}.log.old")));
        std::fs::File::create(&path).ok()
    }
}

#[cfg(unix)]
fn sweep_stale_pid_logs(dir: &Path, mode: &str) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let prefix = format!("harness-{mode}.");
    let week = std::time::Duration::from_secs(7 * 24 * 60 * 60);
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(middle) = name
            .strip_prefix(&prefix)
            .and_then(|rest| rest.strip_suffix(".log"))
        else {
            continue;
        };
        if !middle.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age > week);
        if stale {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn main() -> anyhow::Result<()> {
    #[cfg(windows)]
    attach_parent_console();
    let cli = Cli::parse();

    let is_headless = matches!(cli.command, Command::Headless { .. });
    let default_filter = if is_headless {
        "info,loro_internal=warn,loro=warn"
    } else {
        "warn"
    };
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| default_filter.into());
    let log_file = if is_headless {
        open_log_file("headless")
    } else {
        None
    };

    {
        use tracing_subscriber::layer::SubscriberExt;
        use tracing_subscriber::util::SubscriberInitExt;
        if matches!(cli.command, Command::ExoAcp) {
            tracing_subscriber::registry()
                .with(filter)
                .with(
                    tracing_subscriber::fmt::layer()
                        .with_ansi(false)
                        .with_writer(std::io::stderr),
                )
                .init();
        } else {
            let registry = tracing_subscriber::registry()
                .with(filter)
                .with(tracing_subscriber::fmt::layer());
            match log_file {
                Some(file) => registry
                    .with(
                        tracing_subscriber::fmt::layer()
                            .with_ansi(false)
                            .with_writer(std::sync::Arc::new(file)),
                    )
                    .init(),
                None => registry.init(),
            }
        }
    }

    if is_headless {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            tracing::error!(
                panic = %info,
                backtrace = %std::backtrace::Backtrace::force_capture(),
                "application panic"
            );
            default_hook(info);
        }));
        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        spawn_malloc_trimmer();
    }

    match cli.command {
        Command::Headless { opt_in } => {
            apply_cli_opt_ins(&opt_in);
            let runtime = tokio::runtime::Runtime::new()?;
            runtime.block_on(async {
                tokio::spawn(harness_adapters::codedb_bundle::keep_current());
                let engine = Engine::new(engine_config_from_env());
                engine.run().await
            })?;
            runtime.shutdown_timeout(std::time::Duration::from_secs(5));
            match harness_engine::update_bridge::reexec() {
                Some(err) => Err(anyhow::Error::from(err).context("restarting into the update")),
                None => Ok(()),
            }
        }
        Command::ExoAcp => {
            let runtime = tokio::runtime::Runtime::new()?;
            Ok(runtime.block_on(harness_adapters::serve_exo_acp())?)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(not(windows))]
    #[test]
    fn data_dir_prefers_harness_data_dir_then_data_dir_then_home() {
        let dir = resolve_data_dir(|name| match name {
            "HARNESS_DATA_DIR" => Some("/tmp/harness-data".into()),
            "DATA_DIR" => Some("/tmp/old-data".into()),
            "HOME" => Some("/home/carsten".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(dir, PathBuf::from("/tmp/harness-data"));

        let dir = resolve_data_dir(|name| match name {
            "DATA_DIR" => Some("/tmp/old-data".into()),
            "HOME" => Some("/home/carsten".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(dir, PathBuf::from("/tmp/old-data"));

        let dir = resolve_data_dir(|name| match name {
            "HOME" => Some("/home/carsten".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(dir, PathBuf::from("/home/carsten/.harness"));

        let err = resolve_data_dir(|_| None).unwrap_err();
        assert!(
            err.contains("HOME") && err.contains("HARNESS_DATA_DIR"),
            "{err}"
        );
    }

    #[test]
    fn merge_cli_opt_ins_joins_repeatable_flags_onto_existing_env() {
        assert_eq!(merge_cli_opt_ins(None, &[]), None);
        assert_eq!(
            merge_cli_opt_ins(None, &["antigravity".into()]).as_deref(),
            Some("antigravity")
        );
        assert_eq!(
            merge_cli_opt_ins(Some("cursor"), &["antigravity".into(), "grok".into()]).as_deref(),
            Some("cursor,antigravity,grok")
        );
        assert_eq!(
            merge_cli_opt_ins(Some("  "), &["antigravity".into()]).as_deref(),
            Some("antigravity")
        );
    }

    #[test]
    fn headless_opt_in_flag_accepts_repeatable_ids() {
        let cli = Cli::try_parse_from([
            "harness-engine",
            "headless",
            "--opt-in",
            "antigravity",
            "--opt-in",
            "cursor",
        ])
        .unwrap();
        match cli.command {
            Command::Headless { opt_in } => {
                assert_eq!(
                    opt_in,
                    vec!["antigravity".to_string(), "cursor".to_string()]
                );
            }
            Command::ExoAcp => panic!("expected Headless"),
        }
    }
}
