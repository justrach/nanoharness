//! Engine-owned managed Native Flint (`justrach/nanoattention`) loopback server.
//!
//! Runs strictly on Apple Silicon macOS (`aarch64-apple-darwin`) with an explicit
//! unified-memory guard (>= 32 GB) and explicit Start / Stop lifecycle. Exposes
//! an authenticated loopback OpenAI-compatible HTTP/1.1 API (`/health`,
//! `/v1/models`, `/v1/chat/completions` JSON + SSE) backed by `flint session`
//! with zero Python dependencies.

use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader as TokioBufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

use harness_adapters::NativeFlintEnv;

use crate::flint_policy::{
    FlintHardware, FlintRamAssessment, NativeModelKind, RamTier, assess_hardware,
    clamp_context_for_assessment, discover_default_checkpoint_for, estimated_footprint_gb_for,
    probe_host_hardware, resolve_flint_binary, resolve_nano_binary, resolve_runtime_binary,
    validate_checkpoint_dir, validate_context_for_assessment,
};
use crate::flint_protocol::{
    AdapterError, DEFAULT_MAX_OUTPUT_TOKENS, FlintBackend, FlintTokenizer, FlintWorker,
    WorkerRequest, WorkerResponse, sse_events, validate_request_for_model,
};
use crate::registry::HarnessRegistry;

const MAX_HTTP_BODY_BYTES: usize = 8 * 1024 * 1024;
const MAX_HTTP_HEADER_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeFlintState {
    Stopped,
    Starting,
    Running,
    Error,
}

pub const INKLING_KNOBS: &[&str] = &[
    "batch=4096",
    "expert_simd=true",
    "expert_wide_dot=true",
    "expert_gate_pair=true",
    "expert_prefill=true",
    "expert_wide_k=true",
    "expert_bf16_tiles=true",
    "expert_mlx_scale=true",
    "bf16_linear_tile=true",
    "bf16_prefill_tile=8",
    "bf16_prefill_matrix=true",
    "bf16_decode_vec=true",
    "fuse_bf16_cast=true",
    "concurrent_scratch=true",
    "relative_split=true",
    "relative_split_4=true",
    "relative_tile_prefill=true",
    "relative_stripes=true",
    "scratch_reuse=true",
    "expert_tile_rows=4096",
    "bf16_matrix_small=true",
    "tail_trim=512",
    "relative_bias16=true",
    "relative_bias_d8=true",
    "conv_ring=true",
    "expert_lists_split=true",
    "fuse_add_norm=true",
    "d2_gate=true",
    "decode_argmax=1",
    "fuse_controller_merge=true",
    "fuse_bf16_projections=true",
    "bf16_decode_splitk=true",
    "bf16_decode_wide=true",
    "fuse_head_softcap=true",
    "depth_attention_fast=true",
    "fuse_depth_norm=true",
    "rmsnorm_fast=true",
    "store_pack_bf16=true",
    "fuse_inkling_conv=true",
    "relative_bias_decode=true",
    "expert_nvfp4_fast=true",
    "relative_long_fast=true",
    "fuse_relative_gate=true",
    "relative_prefill_fast=true",
    "expert_block_m64n64=true",
    "expert_fp_lut=true",
    "expert_compact_tiles=true",
    "expert_bf16_io=true",
    "fuse_qkvr_prep=true",
    "relative_inline_bias=true",
    "fuse_merge_norm=true",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeFlintStatus {
    pub platform_supported: bool,
    pub ram_supported: bool,
    pub ram_tier: RamTier,
    pub total_ram_gb: u32,
    pub min_ram_gb: u32,
    pub recommended_context: u32,
    pub max_context: u32,
    pub estimated_footprint_gb: u32,
    pub model_kind: NativeModelKind,
    pub model_id: String,
    pub binary_available: bool,
    pub binary_path: Option<String>,
    pub flint_binary_available: bool,
    pub nano_binary_available: bool,
    pub checkpoint_dir: String,
    pub checkpoint_valid: bool,
    pub checkpoint_hint: Option<String>,
    pub flint_checkpoint_dir: String,
    pub flint_checkpoint_valid: bool,
    pub flint_checkpoint_hint: Option<String>,
    pub inkling_checkpoint_dir: String,
    pub inkling_checkpoint_valid: bool,
    pub inkling_checkpoint_hint: Option<String>,
    pub state: NativeFlintState,
    pub context: u32,
    pub endpoint_url: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartNativeFlintParams {
    #[serde(default)]
    pub checkpoint_dir: Option<String>,
    #[serde(default)]
    pub context: Option<u32>,
    #[serde(default)]
    pub model_kind: Option<NativeModelKind>,
}

/// Type-erased backend so the HTTP server stays monomorphized once.
trait DynBackend: Send {
    fn model_kind(&self) -> NativeModelKind;
    fn model_id(&self) -> &'static str;
    fn context(&self) -> u32;
    fn complete(
        &mut self,
        req: &crate::flint_protocol::ValidatedRequest,
    ) -> Result<Value, AdapterError>;
    fn close(&mut self);
}

impl<T: FlintTokenizer, W: FlintWorker> DynBackend for FlintBackend<T, W> {
    fn model_kind(&self) -> NativeModelKind {
        FlintBackend::model_kind(self)
    }
    fn model_id(&self) -> &'static str {
        FlintBackend::model_id(self)
    }
    fn context(&self) -> u32 {
        FlintBackend::context(self)
    }
    fn complete(
        &mut self,
        req: &crate::flint_protocol::ValidatedRequest,
    ) -> Result<Value, AdapterError> {
        FlintBackend::complete(self, req)
    }
    fn close(&mut self) {
        FlintBackend::close(self)
    }
}

struct RunningServer {
    addr: SocketAddr,
    #[allow(dead_code)]
    api_key: String,
    model_kind: NativeModelKind,
    context: u32,
    checkpoint_dir: PathBuf,
    cancel: CancellationToken,
    backend: Arc<Mutex<Box<dyn DynBackend>>>,
}

impl RunningServer {
    fn stop(self) {
        self.cancel.cancel();
        if let Ok(mut guard) = self.backend.lock() {
            guard.close();
        }
    }
}

struct Inner {
    state: NativeFlintState,
    server: Option<RunningServer>,
    last_error: Option<String>,
}

pub struct FlintManager {
    data_dir: PathBuf,
    registry: Arc<HarnessRegistry>,
    hardware: FlintHardware,
    inner: Mutex<Inner>,
}

fn validate_expected_checkpoint(dir: &Path, expected: NativeModelKind) -> (bool, Option<String>) {
    match validate_checkpoint_dir(dir) {
        Ok(cfg) if cfg.model_kind == expected => (true, None),
        Ok(cfg) => (
            false,
            Some(format!(
                "Checkpoint is {}; choose {} weights or switch model.",
                cfg.model_kind.model_id(),
                expected.model_id()
            )),
        ),
        Err(hint) => (false, Some(hint)),
    }
}

impl FlintManager {
    pub fn new(data_dir: PathBuf, registry: Arc<HarnessRegistry>) -> Self {
        Self::with_hardware(data_dir, registry, probe_host_hardware())
    }

    pub fn with_hardware(
        data_dir: PathBuf,
        registry: Arc<HarnessRegistry>,
        hardware: FlintHardware,
    ) -> Self {
        Self {
            data_dir,
            registry,
            hardware,
            inner: Mutex::new(Inner {
                state: NativeFlintState::Stopped,
                server: None,
                last_error: None,
            }),
        }
    }

    pub fn status(&self) -> NativeFlintStatus {
        let assessment = assess_hardware(self.hardware);
        let saved_flint_dir = self.registry.native_flint_checkpoint_dir();
        let saved_inkling_dir = self.registry.native_inkling_checkpoint_dir();
        let saved_kind = self
            .registry
            .native_model_kind()
            .unwrap_or(NativeModelKind::Flint);
        let saved_ctx = self.registry.native_flint_context();
        let flint_binary = resolve_flint_binary(&self.data_dir);
        let nano_binary = resolve_nano_binary(&self.data_dir);

        let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let (state, active_kind, active_ctx, running_dir, endpoint_url, error) = match &guard.server
        {
            Some(srv) => (
                NativeFlintState::Running,
                srv.model_kind,
                srv.context,
                Some(srv.checkpoint_dir.clone()),
                Some(format!("http://{}/v1/chat/completions", srv.addr)),
                None,
            ),
            None => (
                guard.state,
                saved_kind,
                clamp_context_for_assessment(&assessment, saved_ctx),
                None,
                None,
                guard.last_error.clone(),
            ),
        };
        drop(guard);

        let flint_dir = match (&running_dir, active_kind) {
            (Some(dir), NativeModelKind::Flint) => dir.clone(),
            _ => discover_default_checkpoint_for(
                NativeModelKind::Flint,
                saved_flint_dir.as_deref(),
                &self.data_dir,
            ),
        };
        let inkling_dir = match (&running_dir, active_kind) {
            (Some(dir), NativeModelKind::Inkling) => dir.clone(),
            _ => discover_default_checkpoint_for(
                NativeModelKind::Inkling,
                saved_inkling_dir.as_deref(),
                &self.data_dir,
            ),
        };

        let (flint_checkpoint_valid, flint_checkpoint_hint) =
            validate_expected_checkpoint(&flint_dir, NativeModelKind::Flint);
        let (inkling_checkpoint_valid, inkling_checkpoint_hint) =
            validate_expected_checkpoint(&inkling_dir, NativeModelKind::Inkling);

        let (binary, active_dir, checkpoint_valid, checkpoint_hint) = match active_kind {
            NativeModelKind::Flint => (
                flint_binary.clone(),
                flint_dir.clone(),
                flint_checkpoint_valid,
                flint_checkpoint_hint.clone(),
            ),
            NativeModelKind::Inkling => (
                nano_binary.clone(),
                inkling_dir.clone(),
                inkling_checkpoint_valid,
                inkling_checkpoint_hint.clone(),
            ),
        };
        let footprint_ctx = if active_ctx > 0 {
            active_ctx
        } else if assessment.recommended_context > 0 {
            assessment.recommended_context
        } else {
            8_192
        };
        let footprint = estimated_footprint_gb_for(active_kind, footprint_ctx);

        NativeFlintStatus {
            platform_supported: assessment.platform_supported,
            ram_supported: assessment.ram_supported,
            ram_tier: assessment.tier,
            total_ram_gb: assessment.total_ram_gb,
            min_ram_gb: assessment.min_ram_gb,
            recommended_context: assessment.recommended_context,
            max_context: assessment.max_context,
            estimated_footprint_gb: footprint,
            model_kind: active_kind,
            model_id: active_kind.model_id().to_string(),
            binary_available: binary.is_some(),
            binary_path: binary.map(|p| p.display().to_string()),
            flint_binary_available: flint_binary.is_some(),
            nano_binary_available: nano_binary.is_some(),
            checkpoint_dir: active_dir.display().to_string(),
            checkpoint_valid,
            checkpoint_hint,
            flint_checkpoint_dir: flint_dir.display().to_string(),
            flint_checkpoint_valid,
            flint_checkpoint_hint,
            inkling_checkpoint_dir: inkling_dir.display().to_string(),
            inkling_checkpoint_valid,
            inkling_checkpoint_hint,
            state,
            context: active_ctx,
            endpoint_url,
            error,
        }
    }

    pub async fn start(&self, params: StartNativeFlintParams) -> Result<NativeFlintStatus, String> {
        let assessment = assess_hardware(self.hardware);
        let requested_ctx = params
            .context
            .or_else(|| self.registry.native_flint_context())
            .unwrap_or(assessment.recommended_context);
        let context = validate_context_for_assessment(&assessment, requested_ctx)?;

        let requested_kind = params
            .model_kind
            .or_else(|| self.registry.native_model_kind())
            .unwrap_or(NativeModelKind::Flint);
        let saved_dir = match requested_kind {
            NativeModelKind::Flint => self.registry.native_flint_checkpoint_dir(),
            NativeModelKind::Inkling => self.registry.native_inkling_checkpoint_dir(),
        };

        let checkpoint_dir = match params
            .checkpoint_dir
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(dir) => crate::flint_policy::expand_tilde(dir),
            None => discover_default_checkpoint_for(
                requested_kind,
                saved_dir.as_deref(),
                &self.data_dir,
            ),
        };
        let checkpoint_cfg = validate_checkpoint_dir(&checkpoint_dir)?;
        if let Some(explicit) = params.model_kind
            && explicit != checkpoint_cfg.model_kind
        {
            return Err(format!(
                "Selected {} runtime, but {} is a {} checkpoint.",
                explicit.model_id(),
                checkpoint_dir.display(),
                checkpoint_cfg.model_kind.model_id()
            ));
        }
        let effective_kind = checkpoint_cfg.model_kind;
        if context > checkpoint_cfg.max_position_embeddings {
            return Err(format!(
                "Requested context {context} exceeds checkpoint max_position_embeddings ({}).",
                checkpoint_cfg.max_position_embeddings
            ));
        }

        let binary = resolve_runtime_binary(effective_kind, &self.data_dir).ok_or_else(|| {
            match effective_kind {
                NativeModelKind::Flint => {
                    "Native Flint runtime (`flint`) was not found in this app bundle or PATH (set FLINT_BINARY).".to_string()
                }
                NativeModelKind::Inkling => {
                    "Native Inkling runtime (`nano`) was not found in this app bundle or beside `flint` (set NANO_BINARY).".to_string()
                }
            }
        })?;

        self.registry.set_native_model_prefs(
            effective_kind,
            Some(checkpoint_dir.display().to_string()),
            Some(context),
        );

        // Stop any existing server before starting a fresh one.
        let previous = {
            let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            guard.state = NativeFlintState::Starting;
            guard.last_error = None;
            guard.server.take()
        };
        if let Some(prev) = previous {
            self.registry.set_graff_native_flint(None);
            prev.stop();
        }

        match start_native_backend(binary, checkpoint_dir.clone(), checkpoint_cfg, context).await {
            Ok((addr, api_key, cancel, backend)) => {
                let url = format!("http://{addr}/v1/chat/completions");
                {
                    let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
                    guard.state = NativeFlintState::Running;
                    guard.last_error = None;
                    guard.server = Some(RunningServer {
                        addr,
                        api_key: api_key.clone(),
                        model_kind: effective_kind,
                        context,
                        checkpoint_dir,
                        cancel,
                        backend,
                    });
                }
                self.registry.set_graff_native_flint(Some(NativeFlintEnv {
                    url,
                    api_key,
                    context,
                }));
                Ok(self.status())
            }
            Err(err) => {
                {
                    let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
                    guard.state = NativeFlintState::Error;
                    guard.last_error = Some(err.clone());
                }
                Err(err)
            }
        }
    }

    pub fn stop(&self) -> NativeFlintStatus {
        let previous = {
            let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            guard.state = NativeFlintState::Stopped;
            guard.last_error = None;
            guard.server.take()
        };
        self.registry.set_graff_native_flint(None);
        if let Some(prev) = previous {
            prev.stop();
        }
        self.status()
    }

    pub fn assessment(&self) -> FlintRamAssessment {
        assess_hardware(self.hardware)
    }
}

impl Drop for FlintManager {
    fn drop(&mut self) {
        self.stop();
    }
}

fn generate_ephemeral_api_key() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(64);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
struct HfFlintTokenizer {
    inner: tokenizers::Tokenizer,
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
impl FlintTokenizer for HfFlintTokenizer {
    fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
        self.inner
            .encode(text, false)
            .map(|enc| enc.get_ids().to_vec())
            .map_err(|e| e.to_string())
    }

    fn decode(&self, ids: &[u32]) -> Result<String, String> {
        self.inner.decode(ids, false).map_err(|e| e.to_string())
    }
}

struct ChildFlintWorker {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
}

impl ChildFlintWorker {
    fn spawn(
        binary: &Path,
        checkpoint_dir: &Path,
        context: u32,
        model_kind: NativeModelKind,
    ) -> Result<Self, String> {
        let mut cmd = Command::new(binary);
        cmd.arg("session")
            .arg(checkpoint_dir)
            .arg("--context")
            .arg(context.to_string());
        match model_kind {
            NativeModelKind::Flint => {
                cmd.arg("--mlx-attention")
                    .arg("1")
                    .arg("--staged-row-tile")
                    .arg("2");
            }
            NativeModelKind::Inkling => {
                for knob in INKLING_KNOBS {
                    cmd.arg("--knob").arg(knob);
                }
            }
        }
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("could not spawn {}: {e}", binary.display()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "flint child has no stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "flint child has no stdout".to_string())?;
        Ok(Self {
            child,
            stdin: Some(stdin),
            stdout: BufReader::new(stdout),
        })
    }
}

impl FlintWorker for ChildFlintWorker {
    fn request(&mut self, req: &WorkerRequest) -> Result<WorkerResponse, String> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| "flint stdin closed".to_string())?;
        let mut line = serde_json::to_string(req).map_err(|e| e.to_string())?;
        line.push('\n');
        stdin
            .write_all(line.as_bytes())
            .and_then(|_| stdin.flush())
            .map_err(|e| format!("failed writing to flint session: {e}"))?;

        let mut resp_line = String::new();
        let n = self
            .stdout
            .read_line(&mut resp_line)
            .map_err(|e| format!("failed reading from flint session: {e}"))?;
        if n == 0 {
            return Err("flint session exited before replying".into());
        }
        serde_json::from_str::<WorkerResponse>(resp_line.trim())
            .map_err(|e| format!("invalid flint JSONL reply: {e}"))
    }

    fn close(&mut self, graceful: bool) {
        drop(self.stdin.take());
        if graceful {
            for _ in 0..20 {
                if matches!(self.child.try_wait(), Ok(Some(_))) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for ChildFlintWorker {
    fn drop(&mut self) {
        self.close(false);
    }
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
async fn start_native_backend(
    binary: PathBuf,
    checkpoint_dir: PathBuf,
    cfg: crate::flint_policy::CheckpointConfig,
    context: u32,
) -> Result<
    (
        SocketAddr,
        String,
        CancellationToken,
        Arc<Mutex<Box<dyn DynBackend>>>,
    ),
    String,
> {
    let tok_path = checkpoint_dir.join("tokenizer.json");
    let tokenizer = tokio::task::spawn_blocking(move || {
        tokenizers::Tokenizer::from_file(&tok_path)
            .map(|inner| HfFlintTokenizer { inner })
            .map_err(|e| format!("failed to load {}: {e}", tok_path.display()))
    })
    .await
    .map_err(|e| format!("tokenizer load task failed: {e}"))??;

    let worker_binary = binary.clone();
    let worker_dir = checkpoint_dir.clone();
    let model_kind = cfg.model_kind;
    let backend: Box<dyn DynBackend> = Box::new(FlintBackend::new_for_model(
        tokenizer,
        Box::new(move || ChildFlintWorker::spawn(&worker_binary, &worker_dir, context, model_kind)),
        model_kind,
        context,
        cfg.eos_token_ids,
        cfg.vocab_size,
    ));
    spawn_http_server(backend).await
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
async fn start_native_backend(
    _binary: PathBuf,
    _checkpoint_dir: PathBuf,
    _cfg: crate::flint_policy::CheckpointConfig,
    _context: u32,
) -> Result<
    (
        SocketAddr,
        String,
        CancellationToken,
        Arc<Mutex<Box<dyn DynBackend>>>,
    ),
    String,
> {
    Err("Native Flint currently requires macOS on Apple Silicon (arm64).".into())
}

async fn spawn_http_server(
    backend: Box<dyn DynBackend>,
) -> Result<
    (
        SocketAddr,
        String,
        CancellationToken,
        Arc<Mutex<Box<dyn DynBackend>>>,
    ),
    String,
> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|e| format!("could not bind Native Flint loopback port: {e}"))?;
    let addr = listener
        .local_addr()
        .map_err(|e| format!("could not read loopback address: {e}"))?;
    let api_key = generate_ephemeral_api_key();
    let cancel = CancellationToken::new();
    let shared_backend = Arc::new(Mutex::new(backend));
    let gate = Arc::new(Semaphore::new(1));

    let loop_cancel = cancel.clone();
    let loop_backend = shared_backend.clone();
    let loop_key = api_key.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = loop_cancel.cancelled() => break,
                accepted = listener.accept() => {
                    let Ok((stream, _peer)) = accepted else { continue };
                    let backend = loop_backend.clone();
                    let gate = gate.clone();
                    let key = loop_key.clone();
                    tokio::spawn(async move {
                        let _ = handle_connection(stream, backend, gate, &key).await;
                    });
                }
            }
        }
    });

    Ok((addr, api_key, cancel, shared_backend))
}

fn check_bearer(auth_header: Option<&str>, api_key: &str) -> bool {
    let expected = format!("Bearer {api_key}");
    let Some(actual) = auth_header else {
        return false;
    };
    actual.as_bytes().ct_eq(expected.as_bytes()).into()
}

async fn write_json(stream: &mut TcpStream, status: u16, body: &Value) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        502 => "Bad Gateway",
        _ => "Internal Server Error",
    };
    let payload = serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec());
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(&payload).await?;
    stream.flush().await
}

async fn handle_connection(
    stream: TcpStream,
    backend: Arc<Mutex<Box<dyn DynBackend>>>,
    gate: Arc<Semaphore>,
    api_key: &str,
) -> std::io::Result<()> {
    let mut reader = TokioBufReader::new(stream);
    let mut req_line = String::new();
    let n = tokio::time::timeout(Duration::from_secs(15), reader.read_line(&mut req_line))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "header timeout"))??;
    if n == 0 {
        return Ok(());
    }
    let mut parts = req_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let raw_path = parts.next().unwrap_or("");
    let path = raw_path.split('?').next().unwrap_or(raw_path);

    let mut total_hdr = req_line.len();
    let mut auth_header: Option<String> = None;
    let mut content_lengths: Vec<usize> = Vec::new();
    let mut has_transfer_encoding = false;

    loop {
        let mut line = String::new();
        let read = tokio::time::timeout(Duration::from_secs(15), reader.read_line(&mut line))
            .await
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "header timeout"))??;
        if read == 0 || line == "\r\n" || line == "\n" {
            break;
        }
        total_hdr += read;
        if total_hdr > MAX_HTTP_HEADER_BYTES {
            let mut s = reader.into_inner();
            return write_json(
                &mut s,
                413,
                &json!({"error": {"message": "headers too large"}}),
            )
            .await;
        }
        if let Some((k, v)) = line.split_once(':') {
            let key = k.trim().to_ascii_lowercase();
            let val = v.trim();
            match key.as_str() {
                "authorization" => auth_header = Some(val.to_string()),
                "transfer-encoding" => has_transfer_encoding = true,
                "content-length" => {
                    if let Ok(len) = val.parse::<usize>() {
                        content_lengths.push(len);
                    } else {
                        let mut s = reader.into_inner();
                        return write_json(
                            &mut s,
                            400,
                            &json!({"error": {"message": "invalid Content-Length"}}),
                        )
                        .await;
                    }
                }
                _ => {}
            }
        }
    }

    if method == "GET" {
        let (model_id, context) = {
            let guard = backend.lock().unwrap_or_else(|p| p.into_inner());
            (guard.model_id(), guard.context())
        };
        let mut s = reader.into_inner();
        return match path {
            "/health" => {
                write_json(
                    &mut s,
                    200,
                    &json!({"status": "listening", "model": model_id, "context_length": context}),
                )
                .await
            }
            "/v1/models" => {
                if !check_bearer(auth_header.as_deref(), api_key) {
                    write_json(&mut s, 401, &json!({"error": {"message": "unauthorized"}})).await
                } else {
                    write_json(
                        &mut s,
                        200,
                        &json!({
                            "object": "list",
                            "data": [{
                                "id": model_id,
                                "object": "model",
                                "owned_by": "nanoattention",
                                "context_length": context,
                            }]
                        }),
                    )
                    .await
                }
            }
            _ => {
                write_json(
                    &mut s,
                    404,
                    &json!({"error": {"message": "unknown endpoint"}}),
                )
                .await
            }
        };
    }

    if method != "POST" || path != "/v1/chat/completions" {
        let mut s = reader.into_inner();
        return write_json(
            &mut s,
            404,
            &json!({"error": {"message": "unknown endpoint"}}),
        )
        .await;
    }

    if !check_bearer(auth_header.as_deref(), api_key) {
        let mut s = reader.into_inner();
        return write_json(&mut s, 401, &json!({"error": {"message": "unauthorized"}})).await;
    }

    if has_transfer_encoding || content_lengths.len() != 1 {
        let mut s = reader.into_inner();
        return write_json(
            &mut s,
            400,
            &json!({"error": {"message": "one Content-Length is required"}}),
        )
        .await;
    }

    let length = content_lengths[0];
    if length == 0 || length > MAX_HTTP_BODY_BYTES {
        let mut s = reader.into_inner();
        return write_json(
            &mut s,
            413,
            &json!({"error": {"message": "request body exceeds limit"}}),
        )
        .await;
    }

    let mut body = vec![0u8; length];
    if reader.read_exact(&mut body).await.is_err() {
        let mut s = reader.into_inner();
        return write_json(
            &mut s,
            400,
            &json!({"error": {"message": "incomplete request body"}}),
        )
        .await;
    }
    let mut stream = reader.into_inner();

    let payload: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => {
            return write_json(
                &mut stream,
                400,
                &json!({"error": {"message": "invalid JSON request"}}),
            )
            .await;
        }
    };

    let Ok(_permit) = gate.try_acquire_owned() else {
        return write_json(
            &mut stream,
            429,
            &json!({"error": {"message": "one native sequence is already running", "type": "rate_limit_error"}}),
        )
        .await;
    };

    let (model_kind, context) = {
        let guard = backend.lock().unwrap_or_else(|p| p.into_inner());
        (guard.model_kind(), guard.context())
    };
    let max_output = DEFAULT_MAX_OUTPUT_TOKENS.min(context.saturating_sub(1).max(1));
    let validated = match validate_request_for_model(&payload, max_output, model_kind) {
        Ok(v) => v,
        Err(err) => {
            return write_json(
                &mut stream,
                err.status,
                &json!({"error": {"message": err.message, "type": "invalid_request_error"}}),
            )
            .await;
        }
    };

    if !validated.stream {
        let b = backend.clone();
        let req = validated;
        let result = tokio::task::spawn_blocking(move || {
            let mut guard = b.lock().unwrap_or_else(|p| p.into_inner());
            guard.complete(&req)
        })
        .await
        .map_err(|_| AdapterError::new(502, "native inference worker failed"))
        .and_then(|r| r);
        return match result {
            Ok(val) => write_json(&mut stream, 200, &val).await,
            Err(err) => {
                write_json(
                    &mut stream,
                    err.status,
                    &json!({"error": {"message": err.message, "type": if err.status < 500 { "invalid_request_error" } else { "server_error" }}}),
                )
                .await
            }
        };
    }

    let sse_head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
    stream.write_all(sse_head.as_bytes()).await?;
    stream.flush().await?;

    let include_usage = validated.include_usage;
    let b = backend.clone();
    let mut task = tokio::task::spawn_blocking(move || {
        let mut guard = b.lock().unwrap_or_else(|p| p.into_inner());
        guard.complete(&validated)
    });

    let result = loop {
        tokio::select! {
            res = &mut task => {
                break res
                    .map_err(|_| AdapterError::new(502, "native inference worker failed"))
                    .and_then(|r| r);
            }
            _ = tokio::time::sleep(Duration::from_secs(5)) => {
                stream.write_all(b": native inference in progress\n\n").await?;
                stream.flush().await?;
            }
        }
    };

    match result {
        Ok(val) => {
            for event in sse_events(&val, include_usage) {
                let line = format!(
                    "data: {}\n\n",
                    serde_json::to_string(&event).unwrap_or_else(|_| "{}".into())
                );
                stream.write_all(line.as_bytes()).await?;
            }
        }
        Err(err) => {
            let line = format!(
                "data: {}\n\n",
                serde_json::to_string(&json!({"error": {"message": err.message}}))
                    .unwrap_or_else(|_| "{}".into())
            );
            stream.write_all(line.as_bytes()).await?;
        }
    }
    stream.write_all(b"data: [DONE]\n\n").await?;
    stream.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flint_policy::GIB;

    struct ByteTok;
    impl FlintTokenizer for ByteTok {
        fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
            let mut out = Vec::new();
            let mut rest = text;
            while !rest.is_empty() {
                if let Some(after) = rest.strip_prefix("<|end_of_text|>") {
                    out.push(255);
                    rest = after;
                } else {
                    out.push(rest.as_bytes()[0] as u32);
                    rest = &rest[1..];
                }
            }
            Ok(out)
        }
        fn decode(&self, ids: &[u32]) -> Result<String, String> {
            let mut out = String::new();
            let mut buf = Vec::new();
            for &id in ids {
                if id == 255 {
                    out.push_str(
                        &String::from_utf8(std::mem::take(&mut buf)).map_err(|e| e.to_string())?,
                    );
                    out.push_str("<|end_of_text|>");
                } else {
                    buf.push(id as u8);
                }
            }
            out.push_str(&String::from_utf8(buf).map_err(|e| e.to_string())?);
            Ok(out)
        }
    }

    struct SlowMockWorker {
        delay: Duration,
        cache_len: u32,
    }
    impl FlintWorker for SlowMockWorker {
        fn request(&mut self, req: &WorkerRequest) -> Result<WorkerResponse, String> {
            if !self.delay.is_zero() {
                std::thread::sleep(self.delay);
            }
            if req.reset {
                self.cache_len = 0;
            }
            let before = self.cache_len;
            let mut reply: Vec<u32> = b"ok".iter().map(|&b| b as u32).collect();
            reply.push(255);
            self.cache_len = before + (req.tokens.len() as u32) + (reply.len() as u32);
            Ok(WorkerResponse {
                id: req.id,
                eos: true,
                tokens: reply.clone(),
                cache_before: before,
                cache_after: self.cache_len,
                prefill_tokens: req.tokens.len(),
                decode_forward_tokens: reply.len(),
                reused_prefix_tokens: before,
                prefill_seconds: 0.01,
                decode_seconds: 0.01,
                kv_allocated_bytes: 1024,
                kv_valid_bytes: 256,
                kv_storage: "fp32".into(),
            })
        }
        fn close(&mut self, _graceful: bool) {}
    }

    #[tokio::test]
    async fn loopback_http_enforces_auth_serves_models_and_returns_429_on_overlap() {
        let backend: Box<dyn DynBackend> = Box::new(FlintBackend::new(
            ByteTok,
            Box::new(|| {
                Ok(SlowMockWorker {
                    delay: Duration::from_millis(180),
                    cache_len: 0,
                })
            }),
            8192,
            vec![255],
            300,
        ));
        let (addr, api_key, cancel, _shared) = spawn_http_server(backend).await.unwrap();
        let client = reqwest::Client::new();

        // /health requires no auth
        let health = client
            .get(format!("http://{addr}/health"))
            .send()
            .await
            .unwrap();
        assert_eq!(health.status(), 200);

        // /v1/models rejects bad auth
        let unauth = client
            .get(format!("http://{addr}/v1/models"))
            .send()
            .await
            .unwrap();
        assert_eq!(unauth.status(), 401);

        // /v1/models succeeds with ephemeral bearer
        let models: Value = client
            .get(format!("http://{addr}/v1/models"))
            .bearer_auth(&api_key)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(models["data"][0]["id"], "flint");

        // Concurrent /v1/chat/completions returns 429 for the second request
        let body = json!({
            "model": "flint",
            "messages": [{"role": "user", "content": "hello"}],
            "stream": false
        });
        let f1 = client
            .post(format!("http://{addr}/v1/chat/completions"))
            .bearer_auth(&api_key)
            .json(&body)
            .send();
        let f2 = async {
            tokio::time::sleep(Duration::from_millis(30)).await;
            client
                .post(format!("http://{addr}/v1/chat/completions"))
                .bearer_auth(&api_key)
                .json(&body)
                .send()
                .await
        };
        let (r1, r2) = tokio::join!(f1, f2);
        let r1 = r1.unwrap();
        let r2 = r2.unwrap();
        assert_eq!(r1.status(), 200);
        assert_eq!(r2.status(), 429);
        let j1: Value = r1.json().await.unwrap();
        assert_eq!(j1["choices"][0]["message"]["content"], "ok");

        // SSE streaming returns chunks + [DONE]
        let sse = client
            .post(format!("http://{addr}/v1/chat/completions"))
            .bearer_auth(&api_key)
            .json(&json!({
                "model": "flint",
                "messages": [{"role": "user", "content": "stream"}],
                "stream": true
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(sse.status(), 200);
        let text = sse.text().await.unwrap();
        assert!(text.contains("data: [DONE]"));
        assert!(text.contains("\"content\":\"ok\""));

        cancel.cancel();
    }

    #[tokio::test]
    async fn manager_refuses_start_when_ram_below_32gb() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Arc::new(HarnessRegistry::new());
        let mgr = FlintManager::with_hardware(
            dir.path().to_path_buf(),
            registry,
            FlintHardware {
                macos_arm64: true,
                total_ram_bytes: 16 * GIB,
            },
        );
        let st = mgr.status();
        assert!(st.platform_supported);
        assert!(!st.ram_supported);
        assert_eq!(st.ram_tier, RamTier::InsufficientRam);
        let err = mgr
            .start(StartNativeFlintParams::default())
            .await
            .unwrap_err();
        assert!(err.contains("32 GB"));
    }

    #[tokio::test]
    async fn loopback_http_serves_inkling_model_id_and_completion() {
        struct InklingByteTok;
        impl FlintTokenizer for InklingByteTok {
            fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
                let mut out = Vec::new();
                let mut rest = text;
                while !rest.is_empty() {
                    if let Some(after) = rest.strip_prefix("<|content_model_end_sampling|>") {
                        out.push(254);
                        rest = after;
                    } else {
                        out.push(rest.as_bytes()[0] as u32);
                        rest = &rest[1..];
                    }
                }
                Ok(out)
            }
            fn decode(&self, ids: &[u32]) -> Result<String, String> {
                let mut out = String::new();
                let mut buf = Vec::new();
                for &id in ids {
                    if id == 254 {
                        out.push_str(
                            &String::from_utf8(std::mem::take(&mut buf))
                                .map_err(|e| e.to_string())?,
                        );
                        out.push_str("<|content_model_end_sampling|>");
                    } else {
                        buf.push(id as u8);
                    }
                }
                out.push_str(&String::from_utf8(buf).map_err(|e| e.to_string())?);
                Ok(out)
            }
        }
        struct InklingMockWorker {
            cache_len: u32,
        }
        impl FlintWorker for InklingMockWorker {
            fn request(&mut self, req: &WorkerRequest) -> Result<WorkerResponse, String> {
                if req.reset {
                    self.cache_len = 0;
                }
                let before = self.cache_len;
                let msg = "<|message_model|><|content_text|>inkling ok<|end_message|>";
                let mut reply: Vec<u32> = msg.bytes().map(|b| b as u32).collect();
                reply.push(254);
                self.cache_len = before + (req.tokens.len() as u32) + (reply.len() as u32);
                Ok(WorkerResponse {
                    id: req.id,
                    eos: true,
                    tokens: reply.clone(),
                    cache_before: before,
                    cache_after: self.cache_len,
                    prefill_tokens: req.tokens.len(),
                    decode_forward_tokens: reply.len(),
                    reused_prefix_tokens: before,
                    prefill_seconds: 0.01,
                    decode_seconds: 0.01,
                    kv_allocated_bytes: 1024,
                    kv_valid_bytes: 256,
                    kv_storage: "bf16".into(),
                })
            }
            fn close(&mut self, _graceful: bool) {}
        }

        let backend: Box<dyn DynBackend> = Box::new(FlintBackend::new_for_model(
            InklingByteTok,
            Box::new(|| Ok(InklingMockWorker { cache_len: 0 })),
            NativeModelKind::Inkling,
            32_768,
            vec![254],
            300,
        ));
        let (addr, api_key, cancel, _shared) = spawn_http_server(backend).await.unwrap();
        let client = reqwest::Client::new();

        let models: Value = client
            .get(format!("http://{addr}/v1/models"))
            .bearer_auth(&api_key)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(models["data"][0]["id"], "inkling-2-mini");

        let http_resp = client
            .post(format!("http://{addr}/v1/chat/completions"))
            .bearer_auth(&api_key)
            .json(&json!({
                "model": "inkling-2-mini",
                "messages": [{"role": "user", "content": "hi"}],
                "stream": false
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(http_resp.status(), 200);
        let resp: Value = http_resp.json().await.unwrap();
        assert_eq!(resp["model"], "inkling-2-mini");
        assert_eq!(resp["choices"][0]["message"]["content"], "inkling ok");

        cancel.cancel();
    }
}
