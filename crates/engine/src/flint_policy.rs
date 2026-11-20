//! Pure hardware, unified-memory, binary, and checkpoint rules for Native Flint
//! (`justrach/nanoattention`). Kept free of I/O in the policy layer so every
//! RAM tier and context guard can be tested deterministically on every OS.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const GIB: u64 = 1024 * 1024 * 1024;
pub const MIN_RAM_GB: u32 = 32;
pub const MIN_RAM_BYTES: u64 = 30 * GIB;
pub const TIGHT_MAX_RAM_BYTES: u64 = 46 * GIB;
pub const GOOD_MAX_RAM_BYTES: u64 = 62 * GIB;
pub const HIGH_RAM_BYTES: u64 = 94 * GIB;

pub const CONTEXT_PRESETS: [u32; 5] = [8_192, 16_384, 32_768, 65_536, 131_072];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlintHardware {
    pub macos_arm64: bool,
    pub total_ram_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RamTier {
    UnsupportedPlatform,
    InsufficientRam,
    Tight,
    Good,
    Optimal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlintRamAssessment {
    pub platform_supported: bool,
    pub ram_supported: bool,
    pub tier: RamTier,
    pub total_ram_gb: u32,
    pub min_ram_gb: u32,
    pub recommended_context: u32,
    pub max_context: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckpointConfig {
    pub vocab_size: usize,
    pub max_position_embeddings: u32,
    pub eos_token_ids: Vec<u32>,
}

/// Estimated Apple Silicon unified memory footprint (GiB) for Flint INT4
/// (~22.6 GiB resident weights + FP32 KV cache + runtime buffers).
pub fn estimated_footprint_gb(context: u32) -> u32 {
    if context <= 8_192 {
        25
    } else if context <= 16_384 {
        27
    } else if context <= 32_768 {
        31
    } else if context <= 65_536 {
        37
    } else {
        49
    }
}

pub fn round_ram_gb(bytes: u64) -> u32 {
    ((bytes.saturating_add(GIB / 2)) / GIB) as u32
}

pub fn assess_hardware(hw: FlintHardware) -> FlintRamAssessment {
    let total_ram_gb = round_ram_gb(hw.total_ram_bytes);
    if !hw.macos_arm64 {
        return FlintRamAssessment {
            platform_supported: false,
            ram_supported: false,
            tier: RamTier::UnsupportedPlatform,
            total_ram_gb,
            min_ram_gb: MIN_RAM_GB,
            recommended_context: 0,
            max_context: 0,
        };
    }
    if hw.total_ram_bytes < MIN_RAM_BYTES {
        return FlintRamAssessment {
            platform_supported: true,
            ram_supported: false,
            tier: RamTier::InsufficientRam,
            total_ram_gb,
            min_ram_gb: MIN_RAM_GB,
            recommended_context: 0,
            max_context: 0,
        };
    }
    if hw.total_ram_bytes < TIGHT_MAX_RAM_BYTES {
        return FlintRamAssessment {
            platform_supported: true,
            ram_supported: true,
            tier: RamTier::Tight,
            total_ram_gb,
            min_ram_gb: MIN_RAM_GB,
            recommended_context: 8_192,
            max_context: 16_384,
        };
    }
    if hw.total_ram_bytes < GOOD_MAX_RAM_BYTES {
        return FlintRamAssessment {
            platform_supported: true,
            ram_supported: true,
            tier: RamTier::Good,
            total_ram_gb,
            min_ram_gb: MIN_RAM_GB,
            recommended_context: 32_768,
            max_context: 65_536,
        };
    }
    let recommended_context = if hw.total_ram_bytes >= HIGH_RAM_BYTES {
        65_536
    } else {
        32_768
    };
    FlintRamAssessment {
        platform_supported: true,
        ram_supported: true,
        tier: RamTier::Optimal,
        total_ram_gb,
        min_ram_gb: MIN_RAM_GB,
        recommended_context,
        max_context: 131_072,
    }
}

pub fn validate_context_for_assessment(
    assessment: &FlintRamAssessment,
    context: u32,
) -> Result<u32, String> {
    if !assessment.platform_supported {
        return Err("Native Flint currently requires macOS on Apple Silicon (arm64).".into());
    }
    if !assessment.ram_supported {
        return Err(format!(
            "Native Flint INT4 requires at least {} GB of unified memory (this Mac has {} GB).",
            assessment.min_ram_gb, assessment.total_ram_gb
        ));
    }
    if !CONTEXT_PRESETS.contains(&context) {
        return Err(format!(
            "Unsupported Native Flint context {context}; choose one of 8192, 16384, 32768, 65536, or 131072."
        ));
    }
    if context > assessment.max_context {
        return Err(format!(
            "{}K context (~{} GB) exceeds the safe limit ({}K) for this {} GB Mac.",
            context / 1024,
            estimated_footprint_gb(context),
            assessment.max_context / 1024,
            assessment.total_ram_gb
        ));
    }
    Ok(context)
}

pub fn clamp_context_for_assessment(
    assessment: &FlintRamAssessment,
    preferred: Option<u32>,
) -> u32 {
    if !assessment.platform_supported || !assessment.ram_supported {
        return 0;
    }
    match preferred {
        Some(ctx) if CONTEXT_PRESETS.contains(&ctx) && ctx <= assessment.max_context => ctx,
        _ => assessment.recommended_context,
    }
}

pub fn probe_host_hardware() -> FlintHardware {
    #[cfg(target_os = "macos")]
    {
        let total_ram_bytes = macos_memsize_bytes().unwrap_or(0);
        FlintHardware {
            macos_arm64: cfg!(target_arch = "aarch64"),
            total_ram_bytes,
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        FlintHardware {
            macos_arm64: false,
            total_ram_bytes: 0,
        }
    }
}

#[cfg(target_os = "macos")]
fn macos_memsize_bytes() -> Option<u64> {
    let mut memsize: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    let name = b"hw.memsize\0";
    // SAFETY: sysctlbyname writes into our u64 buffer up to `len` bytes.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr().cast(),
            (&mut memsize as *mut u64).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && len == std::mem::size_of::<u64>() && memsize > 0).then_some(memsize)
}

pub fn expand_tilde(raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    if let Some(rest) = trimmed.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    if trimmed == "~"
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home);
    }
    PathBuf::from(trimmed)
}

pub fn validate_checkpoint_dir(dir: &Path) -> Result<CheckpointConfig, String> {
    if !dir.is_dir() {
        return Err(format!("Checkpoint folder not found: {}", dir.display()));
    }
    let config_path = dir.join("config.json");
    let config_raw = std::fs::read_to_string(&config_path)
        .map_err(|_| format!("Missing config.json in {}", dir.display()))?;
    let config: serde_json::Value = serde_json::from_str(&config_raw)
        .map_err(|e| format!("Invalid config.json in {}: {e}", dir.display()))?;
    let vocab_size = config
        .get("vocab_size")
        .and_then(|v| v.as_u64())
        .and_then(|v| usize::try_from(v).ok())
        .filter(|&v| v > 0)
        .ok_or_else(|| "config.json is missing a positive vocab_size".to_string())?;
    let max_position_embeddings = config
        .get("max_position_embeddings")
        .and_then(|v| v.as_u64())
        .and_then(|v| u32::try_from(v).ok())
        .filter(|&v| v > 0)
        .ok_or_else(|| "config.json is missing a positive max_position_embeddings".to_string())?;
    let eos_token_ids = match config.get("eos_token_id") {
        Some(serde_json::Value::Number(n)) => {
            let id = n
                .as_u64()
                .and_then(|v| u32::try_from(v).ok())
                .ok_or_else(|| "config.json has an invalid eos_token_id".to_string())?;
            vec![id]
        }
        Some(serde_json::Value::Array(arr)) => {
            let mut ids = Vec::with_capacity(arr.len());
            for item in arr {
                let id = item
                    .as_u64()
                    .and_then(|v| u32::try_from(v).ok())
                    .ok_or_else(|| "config.json has an invalid eos_token_id entry".to_string())?;
                ids.push(id);
            }
            if ids.is_empty() {
                return Err("config.json has an empty eos_token_id list".into());
            }
            ids
        }
        _ => return Err("config.json is missing eos_token_id".into()),
    };
    if !dir.join("tokenizer.json").is_file() {
        return Err(format!("Missing tokenizer.json in {}", dir.display()));
    }
    let has_safetensors = std::fs::read_dir(dir)
        .map_err(|e| format!("Could not read {}: {e}", dir.display()))?
        .filter_map(Result::ok)
        .any(|entry| {
            entry
                .path()
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("safetensors"))
        });
    if !has_safetensors {
        return Err(format!(
            "No .safetensors weight shards found in {}",
            dir.display()
        ));
    }
    Ok(CheckpointConfig {
        vocab_size,
        max_position_embeddings,
        eos_token_ids,
    })
}

pub fn discover_default_checkpoint(saved: Option<&str>, data_dir: &Path) -> PathBuf {
    if let Some(saved) = saved.map(str::trim).filter(|s| !s.is_empty()) {
        return expand_tilde(saved);
    }
    let mut candidates = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        candidates.push(home.join("newflint").join("models").join("flint-int4"));
        candidates.push(home.join(".harness").join("models").join("flint-int4"));
    }
    candidates.push(data_dir.join("models").join("flint-int4"));
    for candidate in &candidates {
        if validate_checkpoint_dir(candidate).is_ok() {
            return candidate.clone();
        }
    }
    data_dir.join("models").join("flint-int4")
}

fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

pub fn resolve_flint_binary(data_dir: &Path) -> Option<PathBuf> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return None;
    }
    if let Some(explicit) = std::env::var_os("FLINT_BINARY") {
        let p = PathBuf::from(explicit);
        if is_executable(&p) {
            return Some(p);
        }
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(macos_dir) = exe.parent()
    {
        let bundled = macos_dir
            .parent()
            .map(|contents| contents.join("Resources").join("bin").join("flint"));
        if let Some(path) = bundled
            && is_executable(&path)
        {
            return Some(path);
        }
        let sibling = macos_dir.join("flint");
        if is_executable(&sibling) {
            return Some(sibling);
        }
    }
    let managed = data_dir.join("bin").join("flint");
    if is_executable(&managed) {
        return Some(managed);
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join("flint");
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_apple_silicon_is_unsupported() {
        let a = assess_hardware(FlintHardware {
            macos_arm64: false,
            total_ram_bytes: 128 * GIB,
        });
        assert!(!a.platform_supported);
        assert!(!a.ram_supported);
        assert_eq!(a.tier, RamTier::UnsupportedPlatform);
        assert_eq!(a.max_context, 0);
        assert!(validate_context_for_assessment(&a, 8_192).is_err());
    }

    #[test]
    fn apple_silicon_ram_tiers_match_flint_footprint() {
        let low = assess_hardware(FlintHardware {
            macos_arm64: true,
            total_ram_bytes: 16 * GIB,
        });
        assert!(low.platform_supported);
        assert!(!low.ram_supported);
        assert_eq!(low.tier, RamTier::InsufficientRam);
        assert!(validate_context_for_assessment(&low, 8_192).is_err());

        let m24 = assess_hardware(FlintHardware {
            macos_arm64: true,
            total_ram_bytes: 24 * GIB,
        });
        assert!(!m24.ram_supported);

        let m32 = assess_hardware(FlintHardware {
            macos_arm64: true,
            total_ram_bytes: 32 * GIB,
        });
        assert!(m32.ram_supported);
        assert_eq!(m32.tier, RamTier::Tight);
        assert_eq!(m32.recommended_context, 8_192);
        assert_eq!(m32.max_context, 16_384);
        assert!(validate_context_for_assessment(&m32, 16_384).is_ok());
        assert!(validate_context_for_assessment(&m32, 32_768).is_err());

        let m48 = assess_hardware(FlintHardware {
            macos_arm64: true,
            total_ram_bytes: 48 * GIB,
        });
        assert_eq!(m48.tier, RamTier::Good);
        assert_eq!(m48.recommended_context, 32_768);
        assert_eq!(m48.max_context, 65_536);
        assert!(validate_context_for_assessment(&m48, 65_536).is_ok());
        assert!(validate_context_for_assessment(&m48, 131_072).is_err());

        let m64 = assess_hardware(FlintHardware {
            macos_arm64: true,
            total_ram_bytes: 64 * GIB,
        });
        assert_eq!(m64.tier, RamTier::Optimal);
        assert_eq!(m64.recommended_context, 32_768);
        assert_eq!(m64.max_context, 131_072);
        assert!(validate_context_for_assessment(&m64, 131_072).is_ok());

        let m128 = assess_hardware(FlintHardware {
            macos_arm64: true,
            total_ram_bytes: 128 * GIB,
        });
        assert_eq!(m128.tier, RamTier::Optimal);
        assert_eq!(m128.recommended_context, 65_536);
        assert_eq!(m128.max_context, 131_072);
    }

    #[test]
    fn checkpoint_validation_checks_required_files_and_config() {
        let dir = tempfile::tempdir().unwrap();
        assert!(validate_checkpoint_dir(dir.path()).is_err());

        std::fs::write(
            dir.path().join("config.json"),
            r#"{"vocab_size":150144,"max_position_embeddings":131072,"eos_token_id":[150001,150003]}"#,
        )
        .unwrap();
        assert!(validate_checkpoint_dir(dir.path()).is_err());

        std::fs::write(dir.path().join("tokenizer.json"), "{}").unwrap();
        assert!(validate_checkpoint_dir(dir.path()).is_err());

        std::fs::write(dir.path().join("model-00001.safetensors"), b"").unwrap();
        let cfg = validate_checkpoint_dir(dir.path()).unwrap();
        assert_eq!(cfg.vocab_size, 150_144);
        assert_eq!(cfg.max_position_embeddings, 131_072);
        assert_eq!(cfg.eos_token_ids, vec![150_001, 150_003]);
    }
}
