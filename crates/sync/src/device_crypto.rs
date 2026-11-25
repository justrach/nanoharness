//! Per-device Ed25519 + X25519 keys, signed envelopes, and optional E2EE.
//!
//! Wire prefix (chat2 row payload or ControlRpc text):
//! - `H2S1` + JSON envelope wrapping unsigned inner bytes (signature only)
//! - `H2E1` + JSON envelope wrapping XChaCha20-Poly1305 ciphertext
//!
//! Legacy Loro / NDJSON payloads have neither prefix and stay readable so
//! existing chats migrate. Hosts and the edge verify when a prefix is
//! present; `HARNESS_REQUIRE_DEVICE_AUTH=1` (or [`E2EE_FLAG`] for seal)
//! refuses unsigned mutating pushes.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519Public, StaticSecret};

/// Env / prefs flag that seals new chat2 rows and ControlRpc payloads.
pub const E2EE_FLAG: &str = "HARNESS_E2EE";
/// Fail closed on unsigned mutating chat2 pushes / relay RPC.
pub const REQUIRE_DEVICE_AUTH: &str = "HARNESS_REQUIRE_DEVICE_AUTH";

pub const MAGIC_SIGNED: &[u8] = b"H2S1";
pub const MAGIC_E2EE: &[u8] = b"H2E1";

const WRAP_INFO: &[u8] = b"harness-workspace-wrap-v1";
const ENVELOPE_TTL_MS: i64 = 60_000;

#[derive(Debug, thiserror::Error)]
pub enum EnvelopeError {
    #[error("bad envelope")]
    BadEnvelope,
    #[error("bad signature")]
    BadSignature,
    #[error("replayed or stale envelope")]
    Replay,
    #[error("device mismatch")]
    DeviceMismatch,
    #[error("decrypt failed")]
    Decrypt,
    #[error("encrypt failed")]
    Encrypt,
}

#[derive(Clone)]
pub struct DeviceKeypair {
    signing: SigningKey,
    ecdh: StaticSecret,
}

impl DeviceKeypair {
    pub fn generate() -> Self {
        let mut sign_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut sign_bytes);
        let mut ecdh_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut ecdh_bytes);
        Self {
            signing: SigningKey::from_bytes(&sign_bytes),
            ecdh: StaticSecret::from(ecdh_bytes),
        }
    }

    pub fn from_bytes(signing: [u8; 32], ecdh: [u8; 32]) -> Self {
        Self {
            signing: SigningKey::from_bytes(&signing),
            ecdh: StaticSecret::from(ecdh),
        }
    }

    pub fn signing_secret(&self) -> [u8; 32] {
        self.signing.to_bytes()
    }

    pub fn ecdh_secret(&self) -> [u8; 32] {
        self.ecdh.to_bytes()
    }

    pub fn verifying_key(&self) -> [u8; 32] {
        self.signing.verifying_key().to_bytes()
    }

    pub fn ecdh_public(&self) -> [u8; 32] {
        X25519Public::from(&self.ecdh).to_bytes()
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        self.signing.sign(message).to_bytes()
    }

    pub fn verifying_key_b64(&self) -> String {
        b64(&self.verifying_key())
    }

    pub fn ecdh_public_b64(&self) -> String {
        b64(&self.ecdh_public())
    }
}

/// Load `{data_dir}/device-keys.json` or mint a new pair. Unix files are 0600.
pub fn load_or_create_device_keys(
    data_dir: &std::path::Path,
) -> Result<DeviceKeypair, EnvelopeError> {
    let path = data_dir.join("device-keys.json");
    if let Ok(text) = std::fs::read_to_string(&path) {
        if let Ok(stored) = serde_json::from_str::<StoredKeys>(&text) {
            if let (Ok(sign), Ok(ecdh)) = (unb64_32(&stored.signing), unb64_32(&stored.ecdh)) {
                return Ok(DeviceKeypair::from_bytes(sign, ecdh));
            }
        }
    }
    let keys = DeviceKeypair::generate();
    let stored = StoredKeys {
        signing: b64(&keys.signing_secret()),
        ecdh: b64(&keys.ecdh_secret()),
    };
    if let Ok(json) = serde_json::to_string(&stored) {
        let _ = std::fs::create_dir_all(data_dir);
        if std::fs::write(&path, json).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            }
        }
    }
    Ok(keys)
}

#[derive(Serialize, Deserialize)]
struct StoredKeys {
    signing: String,
    ecdh: String,
}

fn unb64_32(s: &str) -> Result<[u8; 32], EnvelopeError> {
    let v = unb64(s)?;
    v.try_into().map_err(|_| EnvelopeError::BadEnvelope)
}

#[derive(Clone, Copy)]
pub struct WorkspaceKey(pub [u8; 32]);

impl WorkspaceKey {
    pub fn generate() -> Self {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);
        Self(key)
    }
}

/// Signed (and optionally sealed) envelope around opaque inner bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceEnvelope {
    pub device_id: String,
    pub ts: i64,
    pub nonce: String,
    pub sig: String,
    /// Base64 of inner bytes (signed mode) or of ciphertext (e2ee mode).
    pub body: String,
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn unb64(s: &str) -> Result<Vec<u8>, EnvelopeError> {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(s)
        .map_err(|_| EnvelopeError::BadEnvelope)
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn sign_message(device_id: &str, ts: i64, nonce: &str, body: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(body);
    let digest = hasher.finalize();
    let mut msg = Vec::with_capacity(device_id.len() + nonce.len() + 80);
    msg.extend_from_slice(device_id.as_bytes());
    msg.push(b'|');
    msg.extend_from_slice(ts.to_string().as_bytes());
    msg.push(b'|');
    msg.extend_from_slice(nonce.as_bytes());
    msg.push(b'|');
    msg.extend_from_slice(&digest);
    msg
}

/// Wrap inner bytes in a signed envelope. When `workspace` is Some, seal first.
pub fn seal_bytes(
    keys: &DeviceKeypair,
    device_id: &str,
    inner: &[u8],
    workspace: Option<&WorkspaceKey>,
) -> Result<Vec<u8>, EnvelopeError> {
    let ts = now_ms();
    let mut nonce_raw = [0u8; 16];
    OsRng.fill_bytes(&mut nonce_raw);
    let nonce = b64(&nonce_raw);
    let (magic, body_bytes) = if let Some(wk) = workspace {
        let sealed = encrypt(wk, inner, device_id.as_bytes())?;
        (MAGIC_E2EE, sealed)
    } else {
        (MAGIC_SIGNED, inner.to_vec())
    };
    let msg = sign_message(device_id, ts, &nonce, &body_bytes);
    let sig = keys.sign(&msg);
    let env = DeviceEnvelope {
        device_id: device_id.to_string(),
        ts,
        nonce,
        sig: b64(&sig),
        body: b64(&body_bytes),
    };
    let json = serde_json::to_vec(&env).map_err(|_| EnvelopeError::BadEnvelope)?;
    let mut out = Vec::with_capacity(4 + json.len());
    out.extend_from_slice(magic);
    out.extend_from_slice(&json);
    Ok(out)
}

pub fn looks_signed(bytes: &[u8]) -> bool {
    bytes.starts_with(MAGIC_SIGNED) || bytes.starts_with(MAGIC_E2EE)
}

/// Verify and unwrap. `expected_device` when Some must match the envelope.
pub fn verify_envelope(
    bytes: &[u8],
    verifying_key: &[u8; 32],
    expected_device: Option<&str>,
    workspace: Option<&WorkspaceKey>,
    replay: Option<&mut ReplayCache>,
    now: i64,
) -> Result<(String, Vec<u8>), EnvelopeError> {
    let (magic, rest) = if let Some(r) = bytes.strip_prefix(MAGIC_SIGNED) {
        (MAGIC_SIGNED, r)
    } else if let Some(r) = bytes.strip_prefix(MAGIC_E2EE) {
        (MAGIC_E2EE, r)
    } else {
        return Err(EnvelopeError::BadEnvelope);
    };
    let env: DeviceEnvelope =
        serde_json::from_slice(rest).map_err(|_| EnvelopeError::BadEnvelope)?;
    if let Some(want) = expected_device
        && want != env.device_id
    {
        return Err(EnvelopeError::DeviceMismatch);
    }
    if (now - env.ts).abs() > ENVELOPE_TTL_MS {
        return Err(EnvelopeError::Replay);
    }
    if let Some(cache) = replay
        && !cache.admit(&env.device_id, &env.nonce, env.ts, now)
    {
        return Err(EnvelopeError::Replay);
    }
    let body = unb64(&env.body)?;
    let sig_bytes = unb64(&env.sig)?;
    let sig_arr: [u8; 64] = sig_bytes
        .try_into()
        .map_err(|_| EnvelopeError::BadSignature)?;
    let vk = VerifyingKey::from_bytes(verifying_key).map_err(|_| EnvelopeError::BadSignature)?;
    let msg = sign_message(&env.device_id, env.ts, &env.nonce, &body);
    vk.verify(&msg, &Signature::from_bytes(&sig_arr))
        .map_err(|_| EnvelopeError::BadSignature)?;
    let inner = if magic == MAGIC_E2EE {
        let wk = workspace.ok_or(EnvelopeError::Decrypt)?;
        decrypt(wk, &body, env.device_id.as_bytes())?
    } else {
        body
    };
    Ok((env.device_id, inner))
}

pub fn open_bytes(
    bytes: &[u8],
    verifying_key: &[u8; 32],
    expected_device: Option<&str>,
    workspace: Option<&WorkspaceKey>,
    replay: Option<&mut ReplayCache>,
) -> Result<(String, Vec<u8>), EnvelopeError> {
    verify_envelope(
        bytes,
        verifying_key,
        expected_device,
        workspace,
        replay,
        now_ms(),
    )
}

fn encrypt(key: &WorkspaceKey, plain: &[u8], aad: &[u8]) -> Result<Vec<u8>, EnvelopeError> {
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key.0));
    let mut nonce_bytes = [0u8; 24];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = XNonce::from_slice(&nonce_bytes);
    let mut ct = cipher
        .encrypt(nonce, chacha20poly1305::aead::Payload { msg: plain, aad })
        .map_err(|_| EnvelopeError::Encrypt)?;
    let mut out = Vec::with_capacity(24 + ct.len());
    out.extend_from_slice(&nonce_bytes);
    out.append(&mut ct);
    Ok(out)
}

fn decrypt(key: &WorkspaceKey, sealed: &[u8], aad: &[u8]) -> Result<Vec<u8>, EnvelopeError> {
    if sealed.len() < 24 {
        return Err(EnvelopeError::Decrypt);
    }
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key.0));
    let nonce = XNonce::from_slice(&sealed[..24]);
    cipher
        .decrypt(
            nonce,
            chacha20poly1305::aead::Payload {
                msg: &sealed[24..],
                aad,
            },
        )
        .map_err(|_| EnvelopeError::Decrypt)
}

/// Wrap the workspace key to a device's X25519 public key (ephemeral + HKDF).
pub fn wrap_workspace_key(
    workspace: &WorkspaceKey,
    recipient_public: &[u8; 32],
) -> Result<Vec<u8>, EnvelopeError> {
    let mut eph_bytes = [0u8; 32];
    OsRng.fill_bytes(&mut eph_bytes);
    let eph = StaticSecret::from(eph_bytes);
    let eph_pub = X25519Public::from(&eph);
    let shared = eph.diffie_hellman(&X25519Public::from(*recipient_public));
    let hk = Hkdf::<Sha256>::new(None, shared.as_bytes());
    let mut wrap_key = [0u8; 32];
    hk.expand(WRAP_INFO, &mut wrap_key)
        .map_err(|_| EnvelopeError::Encrypt)?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&wrap_key));
    let mut nonce_bytes = [0u8; 24];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = XNonce::from_slice(&nonce_bytes);
    let ct = cipher
        .encrypt(nonce, workspace.0.as_slice())
        .map_err(|_| EnvelopeError::Encrypt)?;
    let mut out = Vec::with_capacity(32 + 24 + ct.len());
    out.extend_from_slice(eph_pub.as_bytes());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

pub fn unwrap_workspace_key(
    wrapped: &[u8],
    recipient: &DeviceKeypair,
) -> Result<WorkspaceKey, EnvelopeError> {
    if wrapped.len() < 32 + 24 + 16 {
        return Err(EnvelopeError::Decrypt);
    }
    let eph_pub: [u8; 32] = wrapped[..32]
        .try_into()
        .map_err(|_| EnvelopeError::Decrypt)?;
    let nonce = XNonce::from_slice(&wrapped[32..56]);
    let ct = &wrapped[56..];
    let shared = recipient.ecdh.diffie_hellman(&X25519Public::from(eph_pub));
    let hk = Hkdf::<Sha256>::new(None, shared.as_bytes());
    let mut wrap_key = [0u8; 32];
    hk.expand(WRAP_INFO, &mut wrap_key)
        .map_err(|_| EnvelopeError::Decrypt)?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&wrap_key));
    let plain = cipher
        .decrypt(nonce, ct)
        .map_err(|_| EnvelopeError::Decrypt)?;
    let arr: [u8; 32] = plain.try_into().map_err(|_| EnvelopeError::Decrypt)?;
    Ok(WorkspaceKey(arr))
}

/// Nonce replay window, keyed by device.
#[derive(Default)]
pub struct ReplayCache {
    seen: HashMap<String, HashMap<String, i64>>,
}

impl ReplayCache {
    pub fn admit(&mut self, device_id: &str, nonce: &str, ts: i64, now: i64) -> bool {
        self.seen.retain(|_, m| {
            m.retain(|_, t| (now - *t).abs() <= ENVELOPE_TTL_MS);
            !m.is_empty()
        });
        let bucket = self.seen.entry(device_id.to_string()).or_default();
        if bucket.contains_key(nonce) {
            return false;
        }
        bucket.insert(nonce.to_string(), ts);
        true
    }
}

/// Env helper used by the edge twin and tests.
pub fn require_device_auth_from_env() -> bool {
    matches!(
        std::env::var(REQUIRE_DEVICE_AUTH).as_deref(),
        Ok("1") | Ok("true") | Ok("TRUE")
    )
}

pub fn e2ee_from_env() -> bool {
    matches!(
        std::env::var(E2EE_FLAG).as_deref(),
        Ok("1") | Ok("true") | Ok("TRUE")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_roundtrip_and_reject_tamper() {
        let keys = DeviceKeypair::generate();
        let inner = b"loro-update-bytes";
        let wrapped = seal_bytes(&keys, "phone", inner, None).unwrap();
        assert!(looks_signed(&wrapped));
        let mut replay = ReplayCache::default();
        let (device, out) = open_bytes(
            &wrapped,
            &keys.verifying_key(),
            Some("phone"),
            None,
            Some(&mut replay),
        )
        .unwrap();
        assert_eq!(device, "phone");
        assert_eq!(out, inner);
        assert!(matches!(
            open_bytes(
                &wrapped,
                &keys.verifying_key(),
                Some("phone"),
                None,
                Some(&mut replay),
            ),
            Err(EnvelopeError::Replay)
        ));
        let mut bad = wrapped.clone();
        *bad.last_mut().unwrap() ^= 1;
        assert!(open_bytes(&bad, &keys.verifying_key(), None, None, None).is_err());
    }

    #[test]
    fn e2ee_roundtrip_and_rotate_wrap() {
        let a = DeviceKeypair::generate();
        let b = DeviceKeypair::generate();
        let wk = WorkspaceKey::generate();
        let wrapped_a = wrap_workspace_key(&wk, &a.ecdh_public()).unwrap();
        let wrapped_b = wrap_workspace_key(&wk, &b.ecdh_public()).unwrap();
        assert_eq!(unwrap_workspace_key(&wrapped_a, &a).unwrap().0, wk.0);
        assert_eq!(unwrap_workspace_key(&wrapped_b, &b).unwrap().0, wk.0);
        assert!(unwrap_workspace_key(&wrapped_a, &b).is_err());

        let inner = b"secret-chat2-row";
        let sealed = seal_bytes(&a, "host", inner, Some(&wk)).unwrap();
        assert!(sealed.starts_with(MAGIC_E2EE));
        let (_, out) =
            open_bytes(&sealed, &a.verifying_key(), Some("host"), Some(&wk), None).unwrap();
        assert_eq!(out, inner);
        assert!(open_bytes(&sealed, &a.verifying_key(), Some("host"), None, None).is_err());
    }

    #[test]
    fn device_keys_persist_and_reload() {
        let dir = tempfile::tempdir().unwrap();
        let a = load_or_create_device_keys(dir.path()).unwrap();
        let b = load_or_create_device_keys(dir.path()).unwrap();
        assert_eq!(a.verifying_key(), b.verifying_key());
        assert_eq!(a.ecdh_public(), b.ecdh_public());
    }

    #[test]
    fn unsigned_bytes_are_not_envelopes() {
        assert!(!looks_signed(b"plain loro"));
        assert!(verify_envelope(b"plain loro", &[0; 32], None, None, None, now_ms()).is_err());
    }
}
