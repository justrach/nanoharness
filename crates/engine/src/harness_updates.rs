//! Device-local monitoring and safe mutation of independently-installed agent
//! CLIs (`WatchHarnessUpdates`, `CheckHarnessUpdates`, `ApplyHarnessUpdate`,
//! `CancelHarnessUpdate`, `DismissHarnessUpdate`, `SetHarnessUpdatePolicy`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use harness_proto::{
    HarnessId, HarnessInstallSource, HarnessUpdateFailure, HarnessUpdateFailureKind,
    HarnessUpdatePhase, HarnessUpdatePolicy, HarnessUpdateStatus, version_triple,
};

use crate::now_ms;
use crate::registry::HarnessRegistry;

const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
pub(crate) const UPDATE_TIMEOUT: Duration = Duration::from_secs(30 * 60);
pub(crate) const APPLY_REPLY_DEADLINE: Duration = Duration::from_secs(40 * 60);
const BINARY_WATCH_INTERVAL: Duration = Duration::from_secs(5 * 60);
const PIPE_DRAIN_GRACE: Duration = Duration::from_secs(2);
const PIPE_CAPTURE_LIMIT: usize = 256 * 1024;

const NONINTERACTIVE_ENV: &[(&str, &str)] = &[
    ("CI", "1"),
    ("TERM", "dumb"),
    ("GIT_TERMINAL_PROMPT", "0"),
    ("GCM_INTERACTIVE", "never"),
    ("NONINTERACTIVE", "1"),
    ("npm_config_yes", "true"),
];

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct Preferences {
    policies: HashMap<HarnessId, HarnessUpdatePolicy>,
    dismissed_versions: HashMap<HarnessId, String>,
}

#[derive(Clone, Copy)]
enum LatestSource {
    Npm(&'static str),
    Github {
        repository: &'static str,
        tag_prefix: &'static str,
    },
    Command(&'static [&'static str]),
    Manual,
}

struct ProviderSpec {
    version_args: &'static [&'static str],
    latest: LatestSource,
    update_args: Option<&'static [&'static str]>,
    npm_package: Option<&'static str>,
    manual_command: &'static str,
}

fn provider(id: HarnessId) -> ProviderSpec {
    match id {
        HarnessId::ClaudeCode => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Npm("@anthropic-ai/claude-code"),
            update_args: Some(&["update"]),
            npm_package: Some("@anthropic-ai/claude-code"),
            manual_command: "claude update",
        },
        HarnessId::Codex => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Github {
                repository: "openai/codex",
                tag_prefix: "rust-v",
            },
            update_args: None,
            npm_package: Some("@openai/codex"),
            manual_command: "npm install -g @openai/codex",
        },
        HarnessId::Cursor => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: Some(&["update"]),
            npm_package: None,
            manual_command: "cursor-agent update",
        },
        HarnessId::Grok => ProviderSpec {
            version_args: &["version"],
            latest: LatestSource::Command(&["update", "--check"]),
            update_args: Some(&["update"]),
            npm_package: Some("@xai-official/grok"),
            manual_command: "grok update",
        },
        HarnessId::Hermes => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: Some(&["update", "--yes"]),
            npm_package: None,
            manual_command: "hermes update",
        },
        HarnessId::Graff => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "",
        },
        HarnessId::Pi => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Npm("@earendil-works/pi-coding-agent"),
            update_args: Some(&["update", "--self"]),
            npm_package: Some("@earendil-works/pi-coding-agent"),
            manual_command: "pi update --self",
        },
        HarnessId::Opencode => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Npm("opencode-ai"),
            update_args: Some(&["upgrade"]),
            npm_package: Some("opencode-ai"),
            manual_command: "opencode upgrade",
        },
        HarnessId::Devin => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "devin --version",
        },
        HarnessId::Antigravity => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "Update the configured Antigravity ACP server",
        },
        HarnessId::Exo => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "exo-cli --version",
        },
        HarnessId::Mock => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "",
        },
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BinaryFingerprint {
    path: PathBuf,
    modified: Option<std::time::SystemTime>,
    len: u64,
}

impl BinaryFingerprint {
    fn of(executable: &Path) -> Option<Self> {
        let path = std::fs::canonicalize(executable).ok()?;
        let metadata = path.metadata().ok()?;
        Some(Self {
            path,
            modified: metadata.modified().ok(),
            len: metadata.len(),
        })
    }
}

#[derive(Debug, Clone)]
enum UpdatePlan {
    Homebrew {
        brew: PathBuf,
        cask: bool,
        token: String,
    },
    NpmGlobal {
        npm: PathBuf,
        prefix: PathBuf,
        package: &'static str,
    },
    Command {
        executable: PathBuf,
        args: &'static [&'static str],
    },
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn classify_source(executable: &Path) -> HarnessInstallSource {
    let real = std::fs::canonicalize(executable).unwrap_or_else(|_| executable.to_path_buf());
    let text = real.to_string_lossy();
    if text.contains("/.harness/") {
        HarnessInstallSource::ManagedByHarness
    } else if text.contains("/Cellar/") || text.contains("/Caskroom/") {
        HarnessInstallSource::Homebrew
    } else if text.contains("node_modules") {
        HarnessInstallSource::Npm
    } else if text.contains("/.cargo/bin/") {
        HarnessInstallSource::Cargo
    } else {
        HarnessInstallSource::Vendor
    }
}

fn detect_homebrew(executable: &Path) -> Option<(PathBuf, bool, String)> {
    let real = std::fs::canonicalize(executable).ok()?;
    let parts: Vec<String> = real
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    for (idx, part) in parts.iter().enumerate() {
        if (part == "Cellar" || part == "Caskroom") && idx + 1 < parts.len() {
            let token = parts[idx + 1].clone();
            if token == "node" || token.starts_with("node@") {
                return None;
            }
            let mut prefix = PathBuf::new();
            for component in real.components().take(idx) {
                prefix.push(component);
            }
            let brew = prefix.join("bin").join("brew");
            if brew.is_file() {
                return Some((brew, part == "Caskroom", token));
            }
        }
    }
    None
}

fn detect_npm_global(executable: &Path) -> Option<(PathBuf, PathBuf)> {
    let real = std::fs::canonicalize(executable).ok()?;
    let mut prefix = PathBuf::new();
    let mut found = false;
    for component in real.components() {
        if component.as_os_str() == "node_modules" {
            if prefix.file_name().is_some_and(|name| name == "lib") {
                prefix.pop();
            }
            found = true;
            break;
        }
        prefix.push(component);
    }
    if !found || prefix.as_os_str().is_empty() {
        return None;
    }
    let candidate = prefix
        .join("bin")
        .join(if cfg!(windows) { "npm.cmd" } else { "npm" });
    if candidate.is_file() {
        return Some((candidate, prefix));
    }
    None
}

fn build_update_plan(harness: HarnessId, executable: &Path) -> Result<UpdatePlan, String> {
    let spec = provider(harness);
    if harness == HarnessId::Antigravity {
        // Only the native CLI documents `update`. Never send it (or a package
        // manager update) to a legacy or custom ACP server.
        return match executable.file_name().and_then(|name| name.to_str()) {
            Some("agy" | "agy.exe") => Ok(UpdatePlan::Command {
                executable: executable.to_path_buf(),
                args: &["update"],
            }),
            _ => Err(spec.manual_command.into()),
        };
    }
    if let Some((brew, cask, token)) = detect_homebrew(executable) {
        return Ok(UpdatePlan::Homebrew { brew, cask, token });
    }
    if let Some(package) = spec.npm_package
        && let Some((npm, prefix)) = detect_npm_global(executable)
    {
        return Ok(UpdatePlan::NpmGlobal {
            npm,
            prefix,
            package,
        });
    }
    if let Some(args) = spec.update_args {
        return Ok(UpdatePlan::Command {
            executable: executable.to_path_buf(),
            args,
        });
    }
    Err(if spec.manual_command.is_empty() {
        "this agent manages its own updates".into()
    } else {
        spec.manual_command.into()
    })
}

pub fn extract_semver(output: &str) -> Option<String> {
    for raw in output.split(|c: char| c.is_whitespace() || matches!(c, '(' | ')' | ',' | ';')) {
        let trimmed = raw.trim_start_matches(['v', 'V']);
        if version_triple(trimmed).is_some() {
            return Some(trimmed.to_string());
        }
    }
    None
}

pub fn is_newer_version(installed: &str, latest: &str) -> bool {
    if installed == latest {
        return false;
    }
    match (version_triple(installed), version_triple(latest)) {
        (Some(cur), Some(next)) => next > cur,
        _ => false,
    }
}

struct ActiveUpdate {
    cancel: CancellationToken,
}

type ResolverFn = Arc<dyn Fn(HarnessId) -> Option<PathBuf> + Send + Sync>;

struct Inner {
    registry: Arc<HarnessRegistry>,
    order: Mutex<Vec<HarnessId>>,
    prefs_path: PathBuf,
    prefs: Mutex<Preferences>,
    statuses: Mutex<HashMap<HarnessId, HarnessUpdateStatus>>,
    status_tx: watch::Sender<Vec<HarnessUpdateStatus>>,
    cancellations: Mutex<HashMap<HarnessId, ActiveUpdate>>,
    operation_gates: Mutex<HashMap<HarnessId, Arc<tokio::sync::Mutex<()>>>>,
    checked_binaries: Mutex<HashMap<HarnessId, BinaryFingerprint>>,
    shutdown: CancellationToken,
    worker: Mutex<Option<tokio::task::JoinHandle<()>>>,
    client: reqwest::Client,
    resolver: ResolverFn,
}

#[derive(Clone)]
pub struct HarnessUpdateCoordinator {
    inner: Arc<Inner>,
}

impl HarnessUpdateCoordinator {
    pub fn new(data_dir: &Path, registry: Arc<HarnessRegistry>) -> Self {
        Self::with_resolver(
            data_dir,
            registry,
            Arc::new(harness_adapters::install::resolve_executable),
        )
    }

    pub(crate) fn with_resolver(
        data_dir: &Path,
        registry: Arc<HarnessRegistry>,
        resolver: ResolverFn,
    ) -> Self {
        let prefs_path = data_dir.join("harness-update-prefs.json");
        let prefs: Preferences = std::fs::read_to_string(&prefs_path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let order: Vec<_> = registry
            .descriptors()
            .into_iter()
            .filter(|d| d.id != HarnessId::Mock)
            .map(|d| d.id)
            .collect();
        let enabled = registry.enabled_set();
        let statuses: HashMap<_, _> = order
            .iter()
            .copied()
            .map(|harness| {
                let policy = prefs.policies.get(&harness).copied().unwrap_or_default();
                let phase = if enabled.contains(&harness) && policy != HarnessUpdatePolicy::Off {
                    HarnessUpdatePhase::Checking
                } else {
                    HarnessUpdatePhase::Dormant
                };
                let spec = provider(harness);
                (
                    harness,
                    HarnessUpdateStatus {
                        harness,
                        installed_version: None,
                        latest_version: None,
                        channel: Some("stable".into()),
                        source: HarnessInstallSource::Unknown,
                        policy,
                        phase,
                        progress: None,
                        checked_at: None,
                        error: None,
                        can_apply: spec.update_args.is_some() || spec.npm_package.is_some(),
                        manual_command: (!spec.manual_command.is_empty())
                            .then(|| spec.manual_command.to_string()),
                        wait_reason: None,
                        compatibility: None,
                        held_back: None,
                    },
                )
            })
            .collect();
        let ordered = ordered_statuses(&order, &statuses, &prefs);
        let (status_tx, _) = watch::channel(ordered);
        let client = reqwest::Client::builder()
            .user_agent("harness-engine")
            .timeout(COMMAND_TIMEOUT)
            .build()
            .unwrap_or_default();
        Self {
            inner: Arc::new(Inner {
                registry,
                order: Mutex::new(order),
                prefs_path,
                prefs: Mutex::new(prefs),
                statuses: Mutex::new(statuses),
                status_tx,
                cancellations: Mutex::new(HashMap::new()),
                operation_gates: Mutex::new(HashMap::new()),
                checked_binaries: Mutex::new(HashMap::new()),
                shutdown: CancellationToken::new(),
                worker: Mutex::new(None),
                client,
                resolver,
            }),
        }
    }

    pub fn start(&self) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let mut slot = lock(&self.inner.worker);
        if slot.is_some() {
            return;
        }
        let coordinator = self.clone();
        *slot = Some(runtime.spawn(async move {
            coordinator.check_all().await;
            let mut check_tick = tokio::time::interval(CHECK_INTERVAL);
            check_tick.tick().await;
            let mut bin_tick = tokio::time::interval(BINARY_WATCH_INTERVAL);
            bin_tick.tick().await;
            loop {
                tokio::select! {
                    _ = coordinator.inner.shutdown.cancelled() => break,
                    _ = check_tick.tick() => coordinator.check_all().await,
                    _ = bin_tick.tick() => coordinator.recheck_changed_binaries().await,
                }
            }
        }));
    }

    pub async fn shutdown(&self) {
        self.inner.shutdown.cancel();
        let cancellations: Vec<_> = lock(&self.inner.cancellations)
            .values()
            .map(|active| active.cancel.clone())
            .collect();
        for token in cancellations {
            token.cancel();
        }
        let handle = lock(&self.inner.worker).take();
        if let Some(handle) = handle {
            let _ = handle.await;
        }
    }

    pub fn watch(&self) -> watch::Receiver<Vec<HarnessUpdateStatus>> {
        self.inner.status_tx.subscribe()
    }

    pub fn snapshot(&self) -> Vec<HarnessUpdateStatus> {
        self.inner.status_tx.borrow().clone()
    }

    pub fn any_active(&self) -> bool {
        if !lock(&self.inner.cancellations).is_empty() {
            return true;
        }
        lock(&self.inner.statuses).values().any(|status| {
            matches!(
                status.phase,
                HarnessUpdatePhase::WaitingForIdle
                    | HarnessUpdatePhase::Preparing
                    | HarnessUpdatePhase::Downloading
                    | HarnessUpdatePhase::Installing
                    | HarnessUpdatePhase::Verifying
            )
        })
    }

    pub fn recheck_changed_binaries_soon(&self) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let coordinator = self.clone();
        runtime.spawn(async move {
            coordinator.recheck_changed_binaries().await;
        });
    }

    async fn recheck_changed_binaries(&self) {
        let order = lock(&self.inner.order).clone();
        for harness in order {
            if self.inner.shutdown.is_cancelled() {
                return;
            }
            let resolver = self.inner.resolver.clone();
            let current = tokio::task::spawn_blocking(move || {
                (resolver)(harness).and_then(|p| BinaryFingerprint::of(&p))
            })
            .await
            .ok()
            .flatten();
            if self.inner.shutdown.is_cancelled() {
                return;
            }
            let changed = lock(&self.inner.checked_binaries).get(&harness).cloned() != current;
            if changed {
                let _ = self.check_one(harness).await;
            }
        }
    }

    pub async fn check_all(&self) {
        let order = lock(&self.inner.order).clone();
        let enabled = self.inner.registry.enabled_set();
        for harness in order {
            if self.inner.shutdown.is_cancelled() {
                return;
            }
            let policy = lock(&self.inner.prefs)
                .policies
                .get(&harness)
                .copied()
                .unwrap_or_default();
            if policy == HarnessUpdatePolicy::Off || !enabled.contains(&harness) {
                self.mutate(harness, |status| {
                    status.policy = policy;
                    status.phase = HarnessUpdatePhase::Dormant;
                    status.error = None;
                });
                continue;
            }
            let _ = self.check_one(harness).await;
        }
    }

    pub async fn check_one(&self, harness: HarnessId) -> Result<(), String> {
        if self.inner.shutdown.is_cancelled() {
            return Ok(());
        }
        let gate = self.gate_for(harness);
        let _guard = tokio::select! {
            biased;
            _ = self.inner.shutdown.cancelled() => return Ok(()),
            guard = gate.lock() => guard,
        };
        let policy = lock(&self.inner.prefs)
            .policies
            .get(&harness)
            .copied()
            .unwrap_or_default();
        if policy == HarnessUpdatePolicy::Off {
            self.mutate(harness, |status| {
                status.policy = policy;
                status.phase = HarnessUpdatePhase::Dormant;
                status.error = None;
            });
            return Ok(());
        }
        let resolver = self.inner.resolver.clone();
        let resolved = tokio::task::spawn_blocking(move || {
            let executable = (resolver)(harness)?;
            let fp = BinaryFingerprint::of(&executable);
            let source = classify_source(&executable);
            let plan_res = build_update_plan(harness, &executable);
            Some((executable, fp, source, plan_res))
        })
        .await
        .map_err(|e| format!("failed to probe harness binary: {e}"))?;
        if self.inner.shutdown.is_cancelled() {
            return Ok(());
        }
        let Some((executable, fp, source, plan_res)) = resolved else {
            lock(&self.inner.checked_binaries).remove(&harness);
            self.mutate(harness, |status| {
                status.installed_version = None;
                status.latest_version = None;
                status.phase = HarnessUpdatePhase::Dormant;
                status.error = None;
                status.checked_at = Some(now_ms());
            });
            return Ok(());
        };
        if let Some(fp) = fp {
            lock(&self.inner.checked_binaries).insert(harness, fp);
        }
        self.mutate(harness, |status| {
            status.phase = HarnessUpdatePhase::Checking;
            status.error = None;
        });

        let can_apply = plan_res.is_ok();
        let manual_command = plan_res.err().filter(|msg| !msg.is_empty());

        let spec = provider(harness);
        let installed = run_capture_with_cancel(
            &executable,
            spec.version_args,
            COMMAND_TIMEOUT,
            Some(&self.inner.shutdown),
        )
        .await
        .ok()
        .and_then(|out| extract_semver(&out));
        if self.inner.shutdown.is_cancelled() {
            return Ok(());
        }

        let Some(installed_ver) = installed else {
            self.mutate(harness, |status| {
                status.source = source;
                status.can_apply = can_apply;
                status.manual_command = manual_command;
                status.phase = HarnessUpdatePhase::Current;
                status.checked_at = Some(now_ms());
            });
            return Ok(());
        };

        let latest = tokio::select! {
            biased;
            _ = self.inner.shutdown.cancelled() => return Ok(()),
            res = self.fetch_latest(harness, &executable) => match res {
                Ok(ver) => ver,
                Err(message) => {
                    self.mutate(harness, |status| {
                        status.installed_version = Some(installed_ver);
                        status.source = source;
                        status.can_apply = can_apply;
                        status.manual_command = manual_command;
                        status.phase = HarnessUpdatePhase::Failed;
                        status.checked_at = Some(now_ms());
                        status.error = Some(HarnessUpdateFailure {
                            message,
                            retryable: true,
                            kind: HarnessUpdateFailureKind::Check,
                        });
                    });
                    return Ok(());
                }
            }
        };

        let phase = match latest.as_deref() {
            Some(lat) if is_newer_version(&installed_ver, lat) => {
                if can_apply {
                    HarnessUpdatePhase::Available
                } else {
                    HarnessUpdatePhase::ManualActionRequired
                }
            }
            // The native CLI has no documented read-only latest-version query.
            // Offer an explicit check/install action without claiming an update
            // exists or scheduling an automatic apply.
            None if harness == HarnessId::Antigravity && can_apply => {
                HarnessUpdatePhase::ManualActionRequired
            }
            _ => HarnessUpdatePhase::Current,
        };

        self.mutate(harness, |status| {
            status.installed_version = Some(installed_ver);
            status.latest_version = latest;
            status.source = source;
            status.can_apply = can_apply;
            status.manual_command = manual_command;
            status.phase = phase;
            status.error = None;
            status.checked_at = Some(now_ms());
        });
        Ok(())
    }

    pub async fn apply(&self, harness: HarnessId) -> Result<Option<String>, String> {
        if self.inner.shutdown.is_cancelled() {
            return Err("update cancelled".into());
        }
        let gate = self.gate_for(harness);
        let _guard = tokio::select! {
            biased;
            _ = self.inner.shutdown.cancelled() => return Err("update cancelled".into()),
            guard = gate.lock() => guard,
        };
        let resolver = self.inner.resolver.clone();
        let (executable, plan) = tokio::task::spawn_blocking(move || {
            let executable = (resolver)(harness)
                .ok_or_else(|| "agent CLI is not installed on this device".to_string())?;
            let plan = build_update_plan(harness, &executable)?;
            Ok::<_, String>((executable, plan))
        })
        .await
        .map_err(|e| format!("failed to prepare updater: {e}"))??;
        let cancel = self.inner.shutdown.child_token();
        let previous_phase = lock(&self.inner.statuses)
            .get(&harness)
            .map(|s| s.phase)
            .unwrap_or(HarnessUpdatePhase::Available);
        lock(&self.inner.cancellations).insert(
            harness,
            ActiveUpdate {
                cancel: cancel.clone(),
            },
        );
        self.mutate(harness, |status| {
            status.phase = HarnessUpdatePhase::Installing;
            status.error = None;
        });

        let run_res = execute_plan(&plan, &cancel).await;
        lock(&self.inner.cancellations).remove(&harness);

        if cancel.is_cancelled() {
            self.mutate(harness, |status| {
                status.phase = previous_phase;
                status.error = None;
            });
            return Err("update cancelled".into());
        }

        if let Err(message) = run_res {
            self.mutate(harness, |status| {
                status.phase = HarnessUpdatePhase::Failed;
                status.error = Some(HarnessUpdateFailure {
                    message: message.clone(),
                    retryable: true,
                    kind: HarnessUpdateFailureKind::Install,
                });
            });
            return Err(message);
        }

        self.mutate(harness, |status| {
            status.phase = HarnessUpdatePhase::Verifying;
        });

        let resolver = self.inner.resolver.clone();
        let fallback_exe = executable.clone();
        let (post_exe, fp) = tokio::task::spawn_blocking(move || {
            harness_adapters::install::invalidate_versions(harness);
            let post_exe = (resolver)(harness).unwrap_or(fallback_exe);
            let fp = BinaryFingerprint::of(&post_exe);
            (post_exe, fp)
        })
        .await
        .unwrap_or((executable, None));
        if let Some(fp) = fp {
            lock(&self.inner.checked_binaries).insert(harness, fp);
        }
        let verified = run_capture_with_cancel(
            &post_exe,
            provider(harness).version_args,
            COMMAND_TIMEOUT,
            Some(&self.inner.shutdown),
        )
        .await
        .ok()
        .and_then(|out| extract_semver(&out));

        self.mutate(harness, |status| {
            if let Some(ver) = &verified {
                status.installed_version = Some(ver.clone());
                status.latest_version = Some(ver.clone());
            }
            status.phase = HarnessUpdatePhase::Updated;
            status.error = None;
            status.checked_at = Some(now_ms());
        });
        Ok(verified)
    }

    pub fn cancel(&self, harness: HarnessId) -> bool {
        if let Some(active) = lock(&self.inner.cancellations).get(&harness) {
            active.cancel.cancel();
            true
        } else {
            false
        }
    }

    pub fn dismiss(&self, harness: HarnessId, version: Option<String>) -> Vec<HarnessUpdateStatus> {
        {
            let mut prefs = lock(&self.inner.prefs);
            let target = version.or_else(|| {
                lock(&self.inner.statuses)
                    .get(&harness)
                    .and_then(|s| s.latest_version.clone())
            });
            if let Some(ver) = target {
                prefs.dismissed_versions.insert(harness, ver);
            } else {
                prefs.dismissed_versions.remove(&harness);
            }
            save_prefs(&self.inner.prefs_path, &prefs);
        }
        self.publish()
    }

    pub fn set_policy(
        &self,
        harness: HarnessId,
        policy: HarnessUpdatePolicy,
    ) -> Vec<HarnessUpdateStatus> {
        {
            let mut prefs = lock(&self.inner.prefs);
            prefs.policies.insert(harness, policy);
            save_prefs(&self.inner.prefs_path, &prefs);
        }
        self.mutate(harness, |status| {
            status.policy = policy;
            if policy == HarnessUpdatePolicy::Off {
                status.phase = HarnessUpdatePhase::Dormant;
                status.error = None;
            }
        });
        self.snapshot()
    }

    async fn fetch_latest(
        &self,
        harness: HarnessId,
        executable: &Path,
    ) -> Result<Option<String>, String> {
        match provider(harness).latest {
            LatestSource::Manual => Ok(None),
            LatestSource::Command(args) => {
                let out = run_capture_with_cancel(
                    executable,
                    args,
                    COMMAND_TIMEOUT,
                    Some(&self.inner.shutdown),
                )
                .await?;
                Ok(extract_semver(&out))
            }
            LatestSource::Npm(package) => {
                let encoded = package.replace('/', "%2F");
                let url = format!("https://registry.npmjs.org/{encoded}/latest");
                let resp = self
                    .inner
                    .client
                    .get(url)
                    .send()
                    .await
                    .map_err(|e| format!("npm registry lookup failed: {e}"))?;
                if !resp.status().is_success() {
                    return Err(format!("npm registry HTTP {}", resp.status()));
                }
                let body: serde_json::Value = resp
                    .json()
                    .await
                    .map_err(|e| format!("invalid npm registry JSON: {e}"))?;
                Ok(body
                    .get("version")
                    .and_then(|v| v.as_str())
                    .and_then(extract_semver))
            }
            LatestSource::Github {
                repository,
                tag_prefix,
            } => {
                let url = format!("https://api.github.com/repos/{repository}/releases/latest");
                let resp = self
                    .inner
                    .client
                    .get(url)
                    .header("Accept", "application/vnd.github+json")
                    .send()
                    .await
                    .map_err(|e| format!("GitHub release lookup failed: {e}"))?;
                if !resp.status().is_success() {
                    return Err(format!("GitHub releases HTTP {}", resp.status()));
                }
                let body: serde_json::Value = resp
                    .json()
                    .await
                    .map_err(|e| format!("invalid GitHub release JSON: {e}"))?;
                let tag = body
                    .get("tag_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let stripped = tag.strip_prefix(tag_prefix).unwrap_or(tag);
                Ok(extract_semver(stripped))
            }
        }
    }

    fn gate_for(&self, harness: HarnessId) -> Arc<tokio::sync::Mutex<()>> {
        lock(&self.inner.operation_gates)
            .entry(harness)
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    }

    fn mutate(&self, harness: HarnessId, f: impl FnOnce(&mut HarnessUpdateStatus)) {
        {
            let mut statuses = lock(&self.inner.statuses);
            if let Some(status) = statuses.get_mut(&harness) {
                f(status);
            }
        }
        let _ = self.publish();
    }

    fn publish(&self) -> Vec<HarnessUpdateStatus> {
        let order = lock(&self.inner.order).clone();
        let statuses = lock(&self.inner.statuses);
        let prefs = lock(&self.inner.prefs);
        let snapshot = ordered_statuses(&order, &statuses, &prefs);
        self.inner.status_tx.send_replace(snapshot.clone());
        snapshot
    }
}

fn ordered_statuses(
    order: &[HarnessId],
    statuses: &HashMap<HarnessId, HarnessUpdateStatus>,
    prefs: &Preferences,
) -> Vec<HarnessUpdateStatus> {
    order
        .iter()
        .filter_map(|id| {
            let mut status = statuses.get(id)?.clone();
            if status.phase == HarnessUpdatePhase::Available
                && let (Some(latest), Some(dismissed)) = (
                    status.latest_version.as_deref(),
                    prefs.dismissed_versions.get(id).map(String::as_str),
                )
                && latest == dismissed
            {
                status.phase = HarnessUpdatePhase::Current;
            }
            Some(status)
        })
        .collect()
}

fn save_prefs(path: &Path, prefs: &Preferences) {
    if let Ok(json) = serde_json::to_string_pretty(prefs) {
        let _ = std::fs::write(path, json);
    }
}

fn configure_update_command(cmd: &mut Command) {
    #[cfg(unix)]
    cmd.process_group(0);
    harness_adapters::compose_login_shell_path(cmd);
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("HARNESS_") {
            cmd.env_remove(key);
        }
    }
    for key in [
        "HARNESS_IPC_TOKEN",
        "HARNESS_SANDBOX_TOKEN_FILE",
        "HARNESS_EDGE_TOKEN",
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_AGENT_SDK_VERSION",
    ] {
        cmd.env_remove(key);
    }
    for (k, v) in NONINTERACTIVE_ENV {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
}

#[derive(Debug)]
enum IsolationError {
    Cancelled,
    TimedOut,
    Failed(String),
}

struct IsolatedOutput {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

struct ProcessGroupGuard {
    #[cfg(unix)]
    pgid: Option<libc::pid_t>,
}

impl ProcessGroupGuard {
    fn from_child(child: &tokio::process::Child) -> Self {
        Self {
            #[cfg(unix)]
            pgid: child.id().map(|id| id as libc::pid_t),
        }
    }

    fn disarm(&mut self) {
        #[cfg(unix)]
        {
            self.pgid = None;
        }
    }

    #[cfg(unix)]
    fn signal(&self, sig: libc::c_int) {
        if let Some(pid) = self.pgid {
            // SAFETY: pid belongs to our spawned child's own process group (process_group(0)).
            unsafe {
                libc::kill(-pid, sig);
            }
        }
    }
}

impl Drop for ProcessGroupGuard {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.pgid.take() {
            // SAFETY: pid belongs to our spawned child's own process group (process_group(0)).
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
    }
}

async fn kill_isolated_child(guard: &mut ProcessGroupGuard, child: &mut tokio::process::Child) {
    #[cfg(unix)]
    {
        guard.signal(libc::SIGTERM);
        let grace_until = tokio::time::Instant::now() + Duration::from_millis(100);
        loop {
            if matches!(child.try_wait(), Ok(Some(_))) {
                break;
            }
            if tokio::time::Instant::now() >= grace_until {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        guard.signal(libc::SIGKILL);
    }
    #[cfg(not(unix))]
    let _ = guard;
    let _ = child.start_kill();
    let _ = tokio::time::timeout(Duration::from_millis(500), child.wait()).await;
    guard.disarm();
}

async fn drain_pipe_bounded<R: AsyncRead + Unpin>(mut pipe: R, buf: Arc<Mutex<Vec<u8>>>) {
    let mut chunk = [0u8; 4096];
    loop {
        match pipe.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let mut guard = lock(&buf);
                let remaining = PIPE_CAPTURE_LIMIT.saturating_sub(guard.len());
                if remaining > 0 {
                    guard.extend_from_slice(&chunk[..n.min(remaining)]);
                }
            }
        }
    }
}

async fn run_isolated_command(
    mut cmd: Command,
    cancel: Option<&CancellationToken>,
    timeout: Duration,
    action: &str,
) -> Result<IsolatedOutput, IsolationError> {
    if cancel.is_some_and(CancellationToken::is_cancelled) {
        return Err(IsolationError::Cancelled);
    }
    configure_update_command(&mut cmd);
    let mut child = cmd
        .spawn()
        .map_err(|e| IsolationError::Failed(format!("failed to {action}: {e}")))?;
    let mut pg_guard = ProcessGroupGuard::from_child(&child);
    let stdout_buf = Arc::new(Mutex::new(Vec::new()));
    let stderr_buf = Arc::new(Mutex::new(Vec::new()));
    let stdout_task = child
        .stdout
        .take()
        .map(|p| tokio::spawn(drain_pipe_bounded(p, stdout_buf.clone())));
    let stderr_task = child
        .stderr
        .take()
        .map(|p| tokio::spawn(drain_pipe_bounded(p, stderr_buf.clone())));
    let stdout_abort = stdout_task
        .as_ref()
        .map(tokio::task::JoinHandle::abort_handle);
    let stderr_abort = stderr_task
        .as_ref()
        .map(tokio::task::JoinHandle::abort_handle);

    let cancel_fut = async {
        match cancel {
            Some(tok) => tok.cancelled().await,
            None => std::future::pending::<()>().await,
        }
    };
    let status = tokio::select! {
        biased;
        _ = cancel_fut => {
            kill_isolated_child(&mut pg_guard, &mut child).await;
            if let Some(h) = stdout_abort {
                h.abort();
            }
            if let Some(h) = stderr_abort {
                h.abort();
            }
            return Err(IsolationError::Cancelled);
        }
        _ = tokio::time::sleep(timeout) => {
            kill_isolated_child(&mut pg_guard, &mut child).await;
            if let Some(h) = stdout_abort {
                h.abort();
            }
            if let Some(h) = stderr_abort {
                h.abort();
            }
            return Err(IsolationError::TimedOut);
        }
        res = child.wait() => res.map_err(|e| IsolationError::Failed(format!("failed awaiting child: {e}")))?,
    };

    let drain_both = async {
        if let Some(h) = stdout_task {
            let _ = h.await;
        }
        if let Some(h) = stderr_task {
            let _ = h.await;
        }
    };
    tokio::pin!(drain_both);
    if tokio::time::timeout(PIPE_DRAIN_GRACE, &mut drain_both)
        .await
        .is_err()
    {
        #[cfg(unix)]
        pg_guard.signal(libc::SIGKILL);
        let _ = tokio::time::timeout(Duration::from_millis(500), &mut drain_both).await;
        if let Some(h) = stdout_abort {
            h.abort();
        }
        if let Some(h) = stderr_abort {
            h.abort();
        }
    }
    pg_guard.disarm();
    let stdout = std::mem::take(&mut *lock(&stdout_buf));
    let stderr = std::mem::take(&mut *lock(&stderr_buf));
    Ok(IsolatedOutput {
        status,
        stdout,
        stderr,
    })
}

async fn run_capture_with_cancel(
    executable: &Path,
    args: &[&str],
    timeout: Duration,
    cancel: Option<&CancellationToken>,
) -> Result<String, String> {
    let mut cmd = Command::new(executable);
    cmd.args(args);
    let output = match run_isolated_command(
        cmd,
        cancel,
        timeout,
        &format!("launch `{}`", executable.display()),
    )
    .await
    {
        Ok(output) => output,
        Err(IsolationError::Cancelled) => return Err("check cancelled".into()),
        Err(IsolationError::TimedOut) => {
            return Err(format!("command `{}` timed out", executable.display()));
        }
        Err(IsolationError::Failed(msg)) => return Err(msg),
    };
    let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
    if !output.stderr.is_empty() {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
    }
    if !output.status.success() && combined.trim().is_empty() {
        return Err(format!("command exited with {}", output.status));
    }
    Ok(combined)
}

#[cfg(test)]
async fn run_capture(
    executable: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<String, String> {
    run_capture_with_cancel(executable, args, timeout, None).await
}

fn truncate_diagnostic(s: &str, max_chars: usize) -> String {
    let trimmed = s.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_string();
    }
    let mut out = String::new();
    for ch in trimmed.chars().take(max_chars.saturating_sub(1)) {
        out.push(ch);
    }
    out.push('…');
    out
}

/// Whether an installer line says the Xcode license blocks it. Phrases rather
/// than loose words: `xcode` is also an npm package with a LICENSE file. The
/// desktop's `isXcodeLicenseBlocker` (view_updates.zig) matches the same ones.
fn contains_xcode_license_blocker(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        "xcodebuild -license",
        "xcode license",
        "xcode/ios license",
        "xcode and apple sdks license",
    ]
    .iter()
    .any(|phrase| lower.contains(phrase))
}

/// The text of an `npm error ...` (`npm ERR! ...` before npm 10) line.
fn npm_error_text(line: &str) -> Option<&str> {
    ["npm error", "npm err!"].iter().find_map(|prefix| {
        line.get(..prefix.len())
            .filter(|head| head.eq_ignore_ascii_case(prefix))
            .map(|_| line[prefix.len()..].trim())
    })
}

/// npm's fields, log pointer and native-build chatter around the reason.
fn is_npm_error_detail(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.is_empty()
        || [
            "code ",
            "syscall ",
            "path ",
            "errno ",
            "command ",
            "dest ",
            "a complete log of this run",
            "gyp info",
            "gyp verb",
        ]
        .iter()
        .any(|prefix| lower.starts_with(prefix))
        || lower.contains("/_logs/")
        || lower.contains("\\_logs\\")
}

/// npm gives the reason first, then advice, then the path of its debug log.
fn npm_failure_line<'a>(lines: &[&'a str]) -> Option<&'a str> {
    let npm = || {
        lines
            .iter()
            .copied()
            .filter_map(|line| npm_error_text(line).map(|text| (line, text)))
    };
    npm()
        .find(|(_, text)| !is_npm_error_detail(text))
        .or_else(|| {
            npm().find(|(_, text)| text.starts_with("command ") && *text != "command failed")
        })
        .or_else(|| npm().find(|(_, text)| !text.is_empty()))
        .map(|(line, _)| line)
}

/// Homebrew's report that a command it ran failed, which isn't why.
fn is_homebrew_wrapper(line: &str) -> bool {
    line.to_ascii_lowercase()
        .starts_with("error: failure while executing;")
}

fn is_meaningful_error_line(line: &str) -> bool {
    let lower = line.trim_start().to_ascii_lowercase();
    lower.starts_with("error:")
        || lower.starts_with("error ")
        || lower.starts_with("fatal:")
        || lower.starts_with("npm error")
        || lower.starts_with("npm err!")
        || lower.starts_with("err!")
}

fn summarize_installer_failure(stderr: &str, stdout: &str, status_desc: &str) -> String {
    let mut combined = String::new();
    let stderr_t = stderr.trim();
    let stdout_t = stdout.trim();
    if !stderr_t.is_empty() {
        combined.push_str(stderr_t);
    }
    if !stdout_t.is_empty() {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str(stdout_t);
    }
    if combined.is_empty() {
        return format!("updater exited with {status_desc}");
    }

    let lines: Vec<&str> = combined
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();

    if let Some(license_line) = lines
        .iter()
        .copied()
        .find(|line| contains_xcode_license_blocker(line))
    {
        let message = if license_line
            .to_ascii_lowercase()
            .contains("xcodebuild -license")
        {
            license_line.to_string()
        } else {
            format!("{license_line} Run `sudo xcodebuild -license` and retry.")
        };
        let message = truncate_diagnostic(&message, 280);
        // The desktop recognizes the blocker from this text, so a long line
        // must not lose it.
        if contains_xcode_license_blocker(&message) {
            return message;
        }
        return "Xcode license agreement required. Run `sudo xcodebuild -license` and retry."
            .to_string();
    }

    if let Some(line) = npm_failure_line(&lines) {
        return truncate_diagnostic(line, 280);
    }

    if let Some(err_line) = lines
        .iter()
        .copied()
        .rev()
        .find(|line| is_meaningful_error_line(line) && !is_homebrew_wrapper(line))
    {
        return truncate_diagnostic(err_line, 280);
    }

    truncate_diagnostic(lines.last().copied().unwrap_or(combined.as_str()), 280)
}

async fn execute_plan(plan: &UpdatePlan, cancel: &CancellationToken) -> Result<(), String> {
    let cmd = match plan {
        UpdatePlan::Homebrew { brew, cask, token } => {
            let mut c = Command::new(brew);
            c.arg("upgrade")
                .arg(if *cask { "--cask" } else { "--formula" })
                .arg(token);
            c
        }
        UpdatePlan::NpmGlobal {
            npm,
            prefix,
            package,
        } => {
            let mut c = Command::new(npm);
            c.arg("install")
                .arg("-g")
                .arg("--prefix")
                .arg(prefix)
                .arg(format!("{package}@latest"));
            c
        }
        UpdatePlan::Command { executable, args } => {
            let mut c = Command::new(executable);
            c.args(*args);
            c
        }
    };
    let output =
        match run_isolated_command(cmd, Some(cancel), UPDATE_TIMEOUT, "start updater").await {
            Ok(output) => output,
            Err(IsolationError::Cancelled) => return Err("update cancelled".into()),
            Err(IsolationError::TimedOut) => return Err("updater timed out".into()),
            Err(IsolationError::Failed(msg)) => return Err(msg),
        };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(summarize_installer_failure(
            &stderr,
            &stdout,
            &output.status.to_string(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_semver_and_compares_strictly() {
        assert_eq!(
            extract_semver("claude 2.1.319 (Claude Code)"),
            Some("2.1.319".into())
        );
        assert_eq!(extract_semver("pi v1.5.0"), Some("1.5.0".into()));
        assert!(is_newer_version("2.1.319", "2.1.322"));
        assert!(!is_newer_version("2.1.322", "2.1.322"));
        assert!(!is_newer_version("2.1.322", "2.1.319"));
    }

    #[test]
    fn antigravity_native_update_plan_uses_the_resolved_executable() {
        for name in ["agy", "agy.exe"] {
            let executable = Path::new("synthetic-install").join(name);
            let plan = build_update_plan(HarnessId::Antigravity, &executable).unwrap();
            match plan {
                UpdatePlan::Command {
                    executable: actual,
                    args,
                } => {
                    assert_eq!(actual, executable);
                    assert_eq!(args, &["update"]);
                }
                other => panic!("expected a native update command, got {other:?}"),
            }
        }
    }

    #[test]
    fn antigravity_legacy_and_custom_servers_remain_manual_even_in_homebrew() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("brew"), "synthetic brew").unwrap();
        let cellar = dir.path().join("Cellar/antigravity/1.5.7/bin");
        std::fs::create_dir_all(&cellar).unwrap();
        for name in [
            "agy_acp_server",
            "agy_acp_server.exe",
            "custom-server",
            "agy-custom",
        ] {
            let executable = cellar.join(name);
            std::fs::write(&executable, "synthetic server").unwrap();
            assert!(detect_homebrew(&executable).is_some());
            assert_eq!(
                build_update_plan(HarnessId::Antigravity, &executable).unwrap_err(),
                "Update the configured Antigravity ACP server"
            );
        }
        let native = cellar.join("agy");
        std::fs::write(&native, "synthetic native CLI").unwrap();
        assert!(matches!(
            build_update_plan(HarnessId::Antigravity, &native).unwrap(),
            UpdatePlan::Command { executable, args } if executable == native && args == ["update"]
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn antigravity_native_check_and_apply_only_use_documented_commands() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let state_file = dir.path().join("ver.txt");
        let calls_file = dir.path().join("calls.txt");
        std::fs::write(&state_file, "1.5.7").unwrap();
        let cli = dir.path().join("agy");
        let script = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\n[ \"$#\" -eq 1 ] || exit 2\ncase \"$1\" in\n  --version) cat \"{}\";;\n  update) printf '1.5.8' > \"{}\";;\n  *) exit 2;;\nesac\n",
            calls_file.display(),
            state_file.display(),
            state_file.display()
        );
        std::fs::write(&cli, script).unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let registry = Arc::new(crate::default_registry());
        registry.load_prefs(dir.path());
        let cli_path = cli.clone();
        let coord = HarnessUpdateCoordinator::with_resolver(
            dir.path(),
            registry,
            Arc::new(move |id| (id == HarnessId::Antigravity).then(|| cli_path.clone())),
        );

        coord.check_one(HarnessId::Antigravity).await.unwrap();
        let status = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Antigravity)
            .unwrap();
        assert_eq!(status.installed_version.as_deref(), Some("1.5.7"));
        assert_eq!(status.latest_version, None);
        assert_eq!(status.phase, HarnessUpdatePhase::ManualActionRequired);
        assert!(status.show_update_notice());
        assert!(status.can_apply);
        assert_eq!(status.manual_command, None);
        assert_eq!(std::fs::read_to_string(&calls_file).unwrap(), "--version\n");

        assert_eq!(
            coord
                .apply(HarnessId::Antigravity)
                .await
                .unwrap()
                .as_deref(),
            Some("1.5.8")
        );
        let status = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Antigravity)
            .unwrap();
        assert_eq!(status.phase, HarnessUpdatePhase::Updated);
        assert_eq!(status.installed_version.as_deref(), Some("1.5.8"));
        assert_eq!(
            std::fs::read_to_string(&calls_file).unwrap(),
            "--version\nupdate\n--version\n"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn antigravity_legacy_apply_never_runs_the_server() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let calls_file = dir.path().join("calls.txt");
        let cli = dir.path().join("agy_acp_server");
        std::fs::write(
            &cli,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{}\"\n",
                calls_file.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let registry = Arc::new(crate::default_registry());
        registry.load_prefs(dir.path());
        let coord = HarnessUpdateCoordinator::with_resolver(
            dir.path(),
            registry,
            Arc::new(move |id| (id == HarnessId::Antigravity).then(|| cli.clone())),
        );
        assert_eq!(
            coord.apply(HarnessId::Antigravity).await.unwrap_err(),
            "Update the configured Antigravity ACP server"
        );
        assert!(
            !calls_file.exists(),
            "legacy server must not receive an update command"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn synthetic_cli_check_apply_and_dismiss_round_trip() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let state_file = dir.path().join("ver.txt");
        std::fs::write(&state_file, "1.2.0").unwrap();
        let cli = dir.path().join("grok");
        let script = format!(
            "#!/bin/sh\nif [ \"$1\" = \"version\" ]; then\n  cat \"{}\"\n  exit 0\nfi\nif [ \"$1\" = \"update\" ] && [ \"$2\" = \"--check\" ]; then\n  echo \"1.3.1\"\n  exit 0\nfi\nif [ \"$1\" = \"update\" ]; then\n  printf \"1.3.1\" > \"{}\"\n  exit 0\nfi\nexit 1\n",
            state_file.display(),
            state_file.display()
        );
        std::fs::write(&cli, script).unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();

        let registry = Arc::new(crate::default_registry());
        registry.load_prefs(dir.path());
        let cli_path = cli.clone();
        let coord = HarnessUpdateCoordinator::with_resolver(
            dir.path(),
            registry,
            Arc::new(move |id| (id == HarnessId::Grok).then(|| cli_path.clone())),
        );

        coord.check_one(HarnessId::Grok).await.unwrap();
        let grok = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(grok.phase, HarnessUpdatePhase::Available);
        assert_eq!(grok.installed_version.as_deref(), Some("1.2.0"));
        assert_eq!(grok.latest_version.as_deref(), Some("1.3.1"));
        assert!(grok.can_apply);

        let after_dismiss = coord.dismiss(HarnessId::Grok, Some("1.3.1".into()));
        let dismissed = after_dismiss
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(dismissed.phase, HarnessUpdatePhase::Current);

        let updated = coord.apply(HarnessId::Grok).await.unwrap();
        assert_eq!(updated.as_deref(), Some("1.3.1"));
        let final_row = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(final_row.phase, HarnessUpdatePhase::Updated);
        assert_eq!(final_row.installed_version.as_deref(), Some("1.3.1"));
    }

    #[test]
    fn summarize_installer_failure_preserves_xcode_license_blocker_and_error_lines() {
        let brew_stderr = "\
==> Upgrading 1 outdated package:
codex 0.171.0 -> 0.172.0
Error: Agreeing to the Xcode/iOS license requires admin privileges, please run “sudo xcodebuild -license” and then retry this command.
Error: Failure while executing; `brew upgrade --cask codex` exited with 69.";
        let msg = summarize_installer_failure(brew_stderr, "", "exit status: 1");
        assert!(msg.contains("Xcode/iOS license"));
        assert!(msg.contains("sudo xcodebuild -license"));

        let multi_stderr = "\
Warning: No available formula with the name
Error: SHA256 mismatch for downloaded codex archive
Please check your network or Homebrew tap.";
        assert_eq!(
            summarize_installer_failure(multi_stderr, "", "exit status: 1"),
            "Error: SHA256 mismatch for downloaded codex archive"
        );

        assert_eq!(
            summarize_installer_failure("", "stdout failure line", "exit status: 1"),
            "stdout failure line"
        );
        assert_eq!(
            summarize_installer_failure("", "   ", "exit status: 42"),
            "updater exited with exit status: 42"
        );
    }

    // npm ends every failure with the path of its debug log (#125).
    #[test]
    fn summarize_installer_failure_shows_npm_reason_not_its_log_path() {
        let eacces = "\
npm error code EACCES
npm error syscall mkdir
npm error path /synthetic/prefix/lib
npm error errno -13
npm error Error: EACCES: permission denied, mkdir '/synthetic/prefix/lib'
npm error     at async mkdir (node:internal/fs/promises:861:10) {
npm error   errno: -13,
npm error   code: 'EACCES'
npm error }
npm error
npm error The operation was rejected by your operating system.
npm error A complete log of this run can be found in: /synthetic/.npm/_logs/debug-0.log";
        assert_eq!(
            summarize_installer_failure(eacces, "", "exit status: 243"),
            "npm error Error: EACCES: permission denied, mkdir '/synthetic/prefix/lib'"
        );

        let script = "\
npm error code 1
npm error path /synthetic/prefix/lib/node_modules/demo-cli
npm error command failed
npm error command sh -c node install.js
npm error gyp: No Xcode or CLT version detected!
npm error A complete log of this run can be found in: /synthetic/.npm/_logs/debug-0.log";
        assert_eq!(
            summarize_installer_failure(script, "", "exit status: 1"),
            "npm error gyp: No Xcode or CLT version detected!"
        );

        let old_npm = "\
npm ERR! code ETARGET
npm ERR! notarget No matching version found for demo-cli@latest.
npm ERR! A complete log of this run can be found in:
npm ERR!     /synthetic/.npm/_logs/debug-0.log";
        assert_eq!(
            summarize_installer_failure(old_npm, "", "exit status: 1"),
            "npm ERR! notarget No matching version found for demo-cli@latest."
        );

        // A script that says nothing: the command, rather than the log path.
        let silent = "\
npm error code 1
npm error path /synthetic/prefix/lib/node_modules/demo-cli
npm error command failed
npm error command sh -c exit 1
npm error A complete log of this run can be found in: /synthetic/.npm/_logs/debug-0.log";
        assert_eq!(
            summarize_installer_failure(silent, "", "exit status: 1"),
            "npm error command sh -c exit 1"
        );

        // Nothing but fields: the code, rather than the log path.
        let code_only = "\
npm error code E500
npm error A complete log of this run can be found in: /synthetic/.npm/_logs/debug-0.log";
        assert_eq!(
            summarize_installer_failure(code_only, "", "exit status: 1"),
            "npm error code E500"
        );
    }

    // Homebrew wraps a failed command after saying what went wrong (#125).
    #[test]
    fn summarize_installer_failure_prefers_the_reason_over_homebrews_wrapper() {
        let stderr = "\
Error: SHA256 mismatch for downloaded codex archive
Error: Failure while executing; `brew upgrade --cask codex` exited with 1.";
        assert_eq!(
            summarize_installer_failure(stderr, "", "exit status: 1"),
            "Error: SHA256 mismatch for downloaded codex archive"
        );

        let wrapped = "\
Error: Failure while executing; `/usr/bin/curl --fail` exited with 22. Here's the output:
curl: (22) The requested URL returned error: 404";
        assert_eq!(
            summarize_installer_failure(wrapped, "", "exit status: 1"),
            "curl: (22) The requested URL returned error: 404"
        );

        let only = "Error: Failure while executing; `brew upgrade --cask codex` exited with 1.";
        assert_eq!(
            summarize_installer_failure(only, "", "exit status: 1"),
            only
        );
    }

    // The words "Xcode" and "license" apart don't make it the license (#125).
    #[test]
    fn summarize_installer_failure_ignores_unrelated_xcode_and_license_words() {
        let separate_lines = "\
npm warn deprecated demo-dep@1.0.0: license changed, see the homepage
npm error gyp: No Xcode or CLT version detected!";
        assert_eq!(
            summarize_installer_failure(separate_lines, "", "exit status: 1"),
            "npm error gyp: No Xcode or CLT version detected!"
        );

        // `xcode` is an npm package, and a package has a LICENSE file.
        let path =
            "npm error EACCES: permission denied, unlink '/synthetic/node_modules/xcode/LICENSE'";
        assert_eq!(
            summarize_installer_failure(path, "", "exit status: 1"),
            path
        );
    }

    #[test]
    fn summarize_installer_failure_recognizes_every_xcode_license_wording() {
        for stderr in [
            // Homebrew's own check.
            "Error: You have not agreed to the Xcode license.\nAgree to the license by opening Xcode.app or running:\n  sudo xcodebuild -license",
            // xcrun and git shims.
            "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license.",
            "Agreeing to the Xcode/iOS license requires admin privileges, please run “sudo xcodebuild -license” and then retry this command.",
            // Only the command survives.
            "Error: Failure while executing; `brew upgrade` exited with 1. Here's the output:\n  sudo xcodebuild -license accept",
        ] {
            let msg = summarize_installer_failure(stderr, "", "exit status: 1");
            assert!(msg.contains("sudo xcodebuild -license"), "{msg}");
        }

        // A long line keeps the command even when the line is cut.
        let long = format!("Error: {} run sudo xcodebuild -license", "x".repeat(400));
        let msg = summarize_installer_failure(&long, "", "exit status: 1");
        assert!(msg.contains("sudo xcodebuild -license"), "{msg}");
    }

    // The message the Updates popover shows is the installer's own, kept
    // through `apply` with the retry still available (#125).
    #[cfg(unix)]
    #[tokio::test]
    async fn failed_apply_keeps_the_xcode_license_reason_and_stays_retryable() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let cli = dir.path().join("grok");
        std::fs::write(
            &cli,
            "#!/bin/sh\nif [ \"$1\" = \"version\" ]; then echo 1.2.0; exit 0; fi\nif [ \"$2\" = \"--check\" ]; then echo 1.3.1; exit 0; fi\necho 'Error: You have not agreed to the Xcode license.' >&2\necho '  sudo xcodebuild -license' >&2\nexit 1\n",
        )
        .unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let registry = Arc::new(crate::default_registry());
        registry.load_prefs(dir.path());
        let coord = HarnessUpdateCoordinator::with_resolver(
            dir.path(),
            registry,
            Arc::new(move |id| (id == HarnessId::Grok).then(|| cli.clone())),
        );
        coord.check_one(HarnessId::Grok).await.unwrap();
        coord.apply(HarnessId::Grok).await.unwrap_err();
        let row = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(row.phase, HarnessUpdatePhase::Failed);
        assert!(row.can_apply);
        let error = row.error.unwrap();
        assert_eq!(error.kind, HarnessUpdateFailureKind::Install);
        assert!(error.message.contains("Xcode license"), "{}", error.message);
        assert!(
            error.message.contains("sudo xcodebuild -license"),
            "{}",
            error.message
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn execute_plan_and_run_capture_do_not_hang_when_grandchild_inherits_pipes() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let update_pidfile = dir.path().join("update.pid");
        let update_script = dir.path().join("slow-grandchild-update.sh");
        std::fs::write(
            &update_script,
            format!(
                "#!/bin/sh\nsleep 30 &\necho $! > \"{}\"\nexit 0\n",
                update_pidfile.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&update_script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let plan = UpdatePlan::Command {
            executable: update_script.clone(),
            args: &[],
        };
        let cancel = CancellationToken::new();
        tokio::time::timeout(Duration::from_secs(6), execute_plan(&plan, &cancel))
            .await
            .expect("execute_plan hung on grandchild pipe FD")
            .expect("execute_plan should succeed after wrapper exits");

        let capture_pidfile = dir.path().join("capture.pid");
        let capture_script = dir.path().join("slow-grandchild-capture.sh");
        std::fs::write(
            &capture_script,
            format!(
                "#!/bin/sh\necho 2.1.322\nsleep 30 &\necho $! > \"{}\"\nexit 0\n",
                capture_pidfile.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&capture_script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let out = tokio::time::timeout(
            Duration::from_secs(6),
            run_capture(&capture_script, &[], Duration::from_secs(30)),
        )
        .await
        .expect("run_capture hung on grandchild pipe FD")
        .expect("run_capture should return captured stdout");
        assert!(out.contains("2.1.322"), "{out}");

        for pf in [&update_pidfile, &capture_pidfile] {
            if let Ok(raw) = std::fs::read_to_string(pf)
                && let Ok(pid) = raw.trim().parse::<libc::pid_t>()
            {
                let exited = tokio::time::timeout(Duration::from_secs(2), async {
                    while unsafe { libc::kill(pid, 0) } == 0 {
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                })
                .await
                .is_ok();
                if !exited {
                    let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
                }
                assert!(exited, "orphaned grandchild {pid} survived pipe drain");
            }
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn update_children_set_ci_and_term_dumb_and_scrub_harness_secrets() {
        use std::ffi::OsStr;
        use std::os::unix::fs::PermissionsExt as _;

        let mut cmd = Command::new("/bin/sh");
        cmd.env("HARNESS_IPC_TOKEN", "secret-ipc")
            .env("HARNESS_SANDBOX_TOKEN_FILE", "/tmp/secret-sandbox")
            .env("HARNESS_EDGE_TOKEN", "secret-edge");
        configure_update_command(&mut cmd);
        let envs: std::collections::HashMap<_, _> = cmd
            .as_std()
            .get_envs()
            .map(|(k, v)| (k.to_os_string(), v.map(OsStr::to_os_string)))
            .collect();
        for secret_key in [
            "HARNESS_IPC_TOKEN",
            "HARNESS_SANDBOX_TOKEN_FILE",
            "HARNESS_EDGE_TOKEN",
        ] {
            assert_eq!(
                envs.get(OsStr::new(secret_key)),
                Some(&None),
                "{secret_key} must be scrubbed from updater env"
            );
        }
        assert_eq!(envs.get(OsStr::new("CI")), Some(&Some("1".into())));
        assert_eq!(envs.get(OsStr::new("TERM")), Some(&Some("dumb".into())));

        // Verify live child processes see non-interactive env and never receive inherited HARNESS_* tokens.
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("check-env.sh");
        std::fs::write(
            &script,
            "#!/bin/sh\ntest \"$CI\" = 1 && test \"$TERM\" = dumb && test \"$NONINTERACTIVE\" = 1\n",
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let plan = UpdatePlan::Command {
            executable: script.clone(),
            args: &[],
        };
        execute_plan(&plan, &CancellationToken::new())
            .await
            .expect("updater must set CI=1 and TERM=dumb");
        run_capture(&script, &[], Duration::from_secs(5))
            .await
            .expect("run_capture must set CI=1 and TERM=dumb");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancel_mid_install_kills_process_group_and_returns_promptly() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("child.pid");
        let script = dir.path().join("hang-install.sh");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nsleep 60 &\necho $! > \"{}\"\nwait\n",
                pidfile.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let plan = UpdatePlan::Command {
            executable: script,
            args: &[],
        };
        let cancel = CancellationToken::new();
        let task_cancel = cancel.clone();
        let task = tokio::spawn(async move { execute_plan(&plan, &task_cancel).await });
        tokio::time::timeout(Duration::from_secs(5), async {
            while !pidfile.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        cancel.cancel();
        let err = tokio::time::timeout(Duration::from_secs(4), task)
            .await
            .expect("cancel must return promptly")
            .unwrap()
            .expect_err("cancelled install should error");
        assert!(err.contains("cancelled"), "{err}");
        let pid: libc::pid_t = std::fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            while unsafe { libc::kill(pid, 0) } == 0 {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("process group descendant still alive after cancel");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn shutdown_cancels_in_flight_check_without_hanging() {
        use std::os::unix::fs::PermissionsExt as _;

        struct InstalledGrokStub;

        #[async_trait::async_trait]
        impl harness_adapters::Harness for InstalledGrokStub {
            fn id(&self) -> HarnessId {
                HarnessId::Grok
            }
            fn display_name(&self) -> &str {
                "Grok"
            }
            fn supports_steering(&self) -> bool {
                false
            }
            fn steering_mode(&self) -> harness_proto::SteeringMode {
                harness_proto::SteeringMode::StepBoundary
            }
            fn reasoning_levels(&self) -> &[harness_proto::ReasoningLevel] {
                &[]
            }
            fn installed(&self) -> bool {
                true
            }
            async fn models(
                &self,
            ) -> Result<Vec<harness_proto::Model>, harness_adapters::HarnessError> {
                Ok(Vec::new())
            }
            async fn run(
                &self,
                _request: harness_proto::RunRequest,
                _controls: harness_adapters::RunControls,
            ) -> Result<
                futures::stream::BoxStream<
                    'static,
                    Result<harness_proto::AgentEvent, harness_adapters::HarnessError>,
                >,
                harness_adapters::HarnessError,
            > {
                Err(harness_adapters::HarnessError::Protocol(
                    "unused in probe test".into(),
                ))
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("probe.pid");
        let cli = dir.path().join("grok");
        std::fs::write(
            &cli,
            format!("#!/bin/sh\necho $$ > \"{}\"\nsleep 30\n", pidfile.display()),
        )
        .unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let registry = HarnessRegistry::new();
        registry.register(Arc::new(InstalledGrokStub));
        registry.load_prefs(dir.path());
        registry.set_enabled(HarnessId::Grok, true).unwrap();
        let registry = Arc::new(registry);
        let coord = HarnessUpdateCoordinator::with_resolver(
            dir.path(),
            registry,
            Arc::new(move |id| (id == HarnessId::Grok).then(|| cli.clone())),
        );
        let worker_coord = coord.clone();
        let check_task = tokio::spawn(async move { worker_coord.check_all().await });
        tokio::time::timeout(Duration::from_secs(5), async {
            while !pidfile.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        tokio::time::timeout(Duration::from_secs(3), coord.shutdown())
            .await
            .expect("shutdown hung waiting for in-flight check_all");
        tokio::time::timeout(Duration::from_secs(3), check_task)
            .await
            .expect("check_all task did not abort on shutdown")
            .unwrap();
        if let Ok(raw) = std::fs::read_to_string(&pidfile)
            && let Ok(pid) = raw.trim().parse::<libc::pid_t>()
        {
            let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }

    #[test]
    fn any_active_tracks_active_phases_and_clears_when_idle() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Arc::new(crate::default_registry());
        let coord =
            HarnessUpdateCoordinator::with_resolver(dir.path(), registry, Arc::new(|_| None));
        assert!(!coord.any_active());

        for phase in [
            HarnessUpdatePhase::WaitingForIdle,
            HarnessUpdatePhase::Preparing,
            HarnessUpdatePhase::Downloading,
            HarnessUpdatePhase::Installing,
            HarnessUpdatePhase::Verifying,
        ] {
            coord.mutate(HarnessId::Grok, |s| s.phase = phase);
            assert!(
                coord.any_active(),
                "{phase:?} must keep engine non-quiescent"
            );
        }

        for phase in [
            HarnessUpdatePhase::Checking,
            HarnessUpdatePhase::Current,
            HarnessUpdatePhase::Available,
            HarnessUpdatePhase::Updated,
            HarnessUpdatePhase::ManualActionRequired,
            HarnessUpdatePhase::Failed,
            HarnessUpdatePhase::Dormant,
        ] {
            coord.mutate(HarnessId::Grok, |s| s.phase = phase);
            assert!(!coord.any_active(), "{phase:?} should allow quiescence");
        }
    }
}
