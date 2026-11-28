//! Read-only local token aggregation for the Settings usage view.
//!
//! This module deliberately returns aggregates only: no source paths, session ids,
//! or transcript contents escape the collector.

use std::collections::{BTreeMap, HashSet, btree_map::Entry};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, Local, NaiveDate, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

const MAX_LINE: usize = 2 * 1024 * 1024;
const MAX_FILES: usize = 20_000;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Row {
    pub runtime: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub period_start: String,
    pub as_of: String,
    pub rows: Vec<Row>,
    pub partial: bool,
}

#[derive(Default)]
struct Totals {
    input: u64,
    output: u64,
}

/// Aggregate usage over the local calendar month through `as_of`.
/// Roots are explicit and trusted by the caller; traversal below each root does
/// not follow symlinks. Missing sources are unavailable and therefore partial.
pub(crate) fn collect(
    projects: &[PathBuf],
    codex_home: &Path,
    claude_dir: &Path,
    journals_dir: &Path,
    antigravity_home: &Path,
    as_of: DateTime<Local>,
) -> Result<Snapshot, String> {
    let start = NaiveDate::from_ymd_opt(as_of.year(), as_of.month(), 1).unwrap();
    let start_dt = Local
        .from_local_datetime(&start.and_hms_opt(0, 0, 0).unwrap())
        .single();
    let start_ts = start_dt.map(|d| d.timestamp_millis()).unwrap_or(i64::MIN);
    let end_ts = as_of.timestamp_millis();
    let mut partial = false;
    let mut totals: BTreeMap<(String, String), Totals> = BTreeMap::new();

    let mut seen_runs = HashSet::new();
    for project in projects {
        let graff = project.join(".graff");
        let traces = graff.join("traces");
        let trajectories = graff.join("trajectories");
        if !graff.exists() {
            continue;
        }
        if !traces.exists() || !trajectories.exists() {
            partial = true;
            continue;
        }
        let files = match direct_jsonl_files(&traces) {
            Ok(v) => v,
            Err(()) => {
                partial = true;
                continue;
            }
        };
        for trace in files {
            let run_id = trace
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            if seen_runs.contains(&run_id) {
                continue;
            }
            let trajectory = trajectories.join(trace.file_name().unwrap_or_default());
            let timestamp = match first_line_unix_ms(&trajectory) {
                Ok(Some(t)) => t,
                _ => {
                    partial = true;
                    continue;
                }
            };
            if timestamp > end_ts {
                continue;
            }
            seen_runs.insert(run_id);
            if !parse_trace(&trace, timestamp, start_ts, end_ts, &mut totals) {
                partial = true;
            }
        }
    }

    for dir in [
        codex_home.join("sessions"),
        codex_home.join("archived_sessions"),
    ] {
        match recursive_jsonl_files(&dir) {
            Ok(files) => {
                for path in files {
                    if !parse_codex(&path, start_ts, end_ts, &mut totals) {
                        partial = true;
                    }
                }
            }
            Err(()) => partial = true,
        }
    }

    let journal_sessions = read_journal_sessions(journals_dir, &mut partial);
    let claude_projects = claude_dir.join("projects");
    match direct_child_dirs(&claude_projects) {
        Ok(dirs) => {
            for dir in dirs {
                match direct_jsonl_files(&dir) {
                    Ok(files) => {
                        for path in files {
                            if !parse_claude(
                                &path,
                                &journal_sessions,
                                start_ts,
                                end_ts,
                                &mut totals,
                            ) {
                                partial = true;
                            }
                        }
                    }
                    Err(()) => partial = true,
                }
            }
        }
        Err(()) => partial = true,
    }

    match direct_files(
        &antigravity_home
            .join("antigravity-cli")
            .join("conversations"),
    ) {
        Ok(files) => {
            for path in files
                .into_iter()
                .filter(|p| p.extension().is_some_and(|e| e == "db"))
            {
                if !parse_antigravity_db(&path, start_ts, end_ts, &mut totals) {
                    partial = true;
                }
            }
        }
        Err(()) => partial = true,
    }

    let mut rows: Vec<_> = totals
        .into_iter()
        .map(|((runtime, model), t)| Row {
            runtime,
            model,
            input_tokens: t.input,
            output_tokens: t.output,
        })
        .collect();
    rows.sort_by(|a, b| {
        b.input_tokens
            .saturating_add(b.output_tokens)
            .cmp(&a.input_tokens.saturating_add(a.output_tokens))
            .then_with(|| a.runtime.cmp(&b.runtime))
            .then_with(|| a.model.cmp(&b.model))
    });
    Ok(Snapshot {
        period_start: start.format("%Y-%m-%d").to_string(),
        as_of: as_of.to_rfc3339(),
        rows,
        partial,
    })
}

fn add(
    totals: &mut BTreeMap<(String, String), Totals>,
    runtime: &str,
    model: &str,
    input: u64,
    output: u64,
) {
    let t = totals
        .entry((runtime.to_owned(), nonempty_model(model)))
        .or_default();
    t.input = t.input.saturating_add(input);
    t.output = t.output.saturating_add(output);
}
fn nonempty_model(s: &str) -> String {
    if s.trim().is_empty() {
        "Unknown model".into()
    } else {
        s.to_owned()
    }
}

fn safe_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
}
fn direct_child_dirs(path: &Path) -> Result<Vec<PathBuf>, ()> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if !safe_dir(path) {
        return Err(());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(path).map_err(|_| ())? {
        let e = entry.map_err(|_| ())?;
        let p = e.path();
        if safe_dir(&p) {
            out.push(p);
        }
        if out.len() > MAX_FILES {
            return Err(());
        }
    }
    out.sort();
    Ok(out)
}
fn direct_files(path: &Path) -> Result<Vec<PathBuf>, ()> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if !safe_dir(path) {
        return Err(());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(path).map_err(|_| ())? {
        let e = entry.map_err(|_| ())?;
        let p = e.path();
        if fs::symlink_metadata(&p).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink()) {
            out.push(p);
        }
        if out.len() > MAX_FILES {
            return Err(());
        }
    }
    out.sort();
    Ok(out)
}
fn direct_jsonl_files(path: &Path) -> Result<Vec<PathBuf>, ()> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if !safe_dir(path) {
        return Err(());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(path).map_err(|_| ())? {
        let e = entry.map_err(|_| ())?;
        let p = e.path();
        if fs::symlink_metadata(&p).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
            && p.extension().is_some_and(|e| e == "jsonl")
        {
            out.push(p);
        }
        if out.len() > MAX_FILES {
            return Err(());
        }
    }
    out.sort();
    Ok(out)
}
fn recursive_jsonl_files(root: &Path) -> Result<Vec<PathBuf>, ()> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), ()> {
        if !safe_dir(dir) {
            return Err(());
        }
        for entry in fs::read_dir(dir).map_err(|_| ())? {
            let e = entry.map_err(|_| ())?;
            let p = e.path();
            let md = fs::symlink_metadata(&p).map_err(|_| ())?;
            if md.file_type().is_symlink() {
                continue;
            }
            if md.is_dir() {
                walk(&p, out)?;
            } else if md.is_file() && p.extension().is_some_and(|x| x == "jsonl") {
                out.push(p);
            }
            if out.len() > MAX_FILES {
                return Err(());
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(root, &mut out)?;
    out.sort();
    Ok(out)
}
fn open_log(path: &Path) -> Result<BufReader<File>, ()> {
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink()) {
        return Err(());
    }
    File::open(path).map(BufReader::new).map_err(|_| ())
}

fn lines(path: &Path, mut f: impl FnMut(&[u8]) -> Result<(), ()>) -> Result<(), ()> {
    let mut reader = open_log(path)?;
    let mut buf = Vec::new();
    let mut complete = true;
    loop {
        buf.clear();
        let n = (&mut reader)
            .take(MAX_LINE as u64 + 1)
            .read_until(b'\n', &mut buf)
            .map_err(|_| ())?;
        if n == 0 {
            break;
        }
        if buf.len() > MAX_LINE {
            complete = false;
            if buf.last() != Some(&b'\n') {
                reader.skip_until(b'\n').map_err(|_| ())?;
            }
        } else if f(&buf).is_err() {
            complete = false;
        }
    }
    if complete { Ok(()) } else { Err(()) }
}

fn first_line_unix_ms(path: &Path) -> Result<Option<i64>, ()> {
    let mut buf = Vec::new();
    let n = open_log(path)?
        .take(MAX_LINE as u64 + 1)
        .read_until(b'\n', &mut buf)
        .map_err(|_| ())?;
    if n == 0 || n > MAX_LINE {
        return Err(());
    }
    let v: Value = serde_json::from_slice(&buf).map_err(|_| ())?;
    Ok(v.get("unix_ms").and_then(Value::as_i64))
}
fn parse_trace(
    path: &Path,
    session_start: i64,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    let mut ok = true;
    let res = lines(path, |line| {
        let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
        if v.get("ev").and_then(Value::as_str) == Some("usage") {
            let t = v.get("t").and_then(Value::as_i64).ok_or(())?;
            let model = v
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or("Unknown model");
            let input = v.get("input_tokens").and_then(Value::as_u64).ok_or(())?;
            let output = v.get("output_tokens").and_then(Value::as_u64).ok_or(())?;
            // `t` is a trace-relative timestamp; a run may straddle month start.
            let timestamp = session_start.saturating_add(t);
            if timestamp >= start && timestamp <= end {
                add(totals, "Harness", model, input, output);
            }
        }
        Ok(())
    });
    if res.is_err() {
        ok = false;
    }
    ok
}

fn parse_codex(
    path: &Path,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    let mut ok = true;
    let mut model = "Unknown model".to_owned();
    let mut seen = HashSet::new();
    let res = lines(path, |line| {
        let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
        let typ = v.get("type").and_then(Value::as_str).unwrap_or("");
        if typ == "turn_context" {
            if let Some(m) = v
                .pointer("/payload/model")
                .or_else(|| v.get("model"))
                .and_then(Value::as_str)
            {
                model = m.to_owned();
            }
        } else if typ == "token_usage_record" {
            let timestamp = v
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_timestamp)
                .or_else(|| {
                    v.pointer("/payload/timestamp")
                        .and_then(Value::as_str)
                        .and_then(parse_timestamp)
                });
            let Some(ts) = timestamp else {
                ok = false;
                return Ok(());
            };
            if ts < start || ts > end {
                return Ok(());
            }
            let payload = v.get("payload").unwrap_or(&Value::Null);
            let usage = payload.get("usage").ok_or(())?;
            let id = payload
                .get("response_id")
                .or_else(|| payload.get("id"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if !id.is_empty() && !seen.insert(id.to_owned()) {
                return Ok(());
            }
            let input = usage
                .get("input_tokens")
                .and_then(Value::as_u64)
                .ok_or(())?;
            let output = usage
                .get("output_tokens")
                .and_then(Value::as_u64)
                .ok_or(())?;
            add(totals, "Codex", &model, input, output);
        }
        Ok(())
    });
    if res.is_err() {
        ok = false;
    }
    ok
}
fn parse_timestamp(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|x| x.timestamp_millis())
}

fn read_journal_sessions(root: &Path, partial: &mut bool) -> HashSet<String> {
    let mut ids = HashSet::new();
    let Ok(files) = recursive_jsonl_files(root) else {
        *partial = true;
        return ids;
    };
    for path in files {
        if lines(&path, |line| {
            let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
            let event = v.get("event").unwrap_or(&Value::Null);
            if event.get("type").and_then(Value::as_str) == Some("sessionStarted") {
                if let Some(id) = event.get("sessionId").and_then(Value::as_str) {
                    ids.insert(id.to_owned());
                }
            }
            if let Some(id) = v.get("session_id").and_then(Value::as_str) {
                ids.insert(id.to_owned());
            }
            Ok(())
        })
        .is_err()
        {
            *partial = true;
        }
    }
    ids
}
fn parse_claude(
    path: &Path,
    allowed: &HashSet<String>,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    let mut ok = true;
    let mut seen = HashSet::new();
    let res = lines(path, |line| {
        let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
        if v.get("type").and_then(Value::as_str) != Some("assistant") {
            return Ok(());
        }
        if !v
            .get("sessionId")
            .or_else(|| v.get("session_id"))
            .and_then(Value::as_str)
            .is_some_and(|id| allowed.contains(id))
        {
            return Ok(());
        }
        let ts = v
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_timestamp)
            .ok_or(())?;
        if ts < start || ts > end {
            return Ok(());
        }
        let msg = v.get("message").unwrap_or(&v);
        let id = msg.get("id").and_then(Value::as_str).unwrap_or("");
        if !id.is_empty() && !seen.insert(id.to_owned()) {
            return Ok(());
        }
        let usage = msg.get("usage").ok_or(())?;
        let input = [
            "input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
        ]
        .iter()
        .filter_map(|k| usage.get(k).and_then(Value::as_u64))
        .fold(0u64, u64::saturating_add);
        let output = usage
            .get("output_tokens")
            .and_then(Value::as_u64)
            .ok_or(())?;
        let model = msg
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("Unknown model");
        add(totals, "Harness", model, input, output);
        Ok(())
    });
    if res.is_err() {
        ok = false;
    }
    ok
}

// Minimal protobuf wire reader. Returns (field number, wire type, scalar, bytes).
fn protobuf_fields(mut b: &[u8]) -> Result<Vec<(u32, u8, u64, &[u8])>, ()> {
    let mut out = Vec::new();
    while !b.is_empty() {
        let (key, n) = varint(b)?;
        b = &b[n..];
        let field = key >> 3;
        let wire = (key & 7) as u8;
        if !(1..=(1 << 29) - 1).contains(&field) {
            return Err(());
        }
        let (scalar, bytes) = match wire {
            0 => {
                let (x, n) = varint(b)?;
                b = &b[n..];
                (x, &b[0..0])
            }
            1 => {
                if b.len() < 8 {
                    return Err(());
                };
                let x = u64::from_le_bytes(b[..8].try_into().unwrap());
                b = &b[8..];
                (x, &b[0..0])
            }
            2 => {
                let (len, n) = varint(b)?;
                b = &b[n..];
                let len = usize::try_from(len).map_err(|_| ())?;
                if len > b.len() {
                    return Err(());
                };
                let x = &b[..len];
                b = &b[len..];
                (0, x)
            }
            5 => {
                if b.len() < 4 {
                    return Err(());
                };
                let x = u32::from_le_bytes(b[..4].try_into().unwrap()) as u64;
                b = &b[4..];
                (x, &b[0..0])
            }
            _ => return Err(()),
        };
        out.push((field as u32, wire, scalar, bytes));
    }
    Ok(out)
}
fn varint(b: &[u8]) -> Result<(u64, usize), ()> {
    let mut x = 0u64;
    for (i, c) in b.iter().enumerate().take(10) {
        if i == 9 && *c > 1 {
            return Err(());
        }
        x |= ((c & 0x7f) as u64) << (i * 7);
        if c & 0x80 == 0 {
            return Ok((x, i + 1));
        }
    }
    Err(())
}
fn parse_antigravity_db(
    path: &Path,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink()) {
        return false;
    }
    let conn = match Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return false,
    };
    let mut model_by_step = BTreeMap::new();
    let generation_complete = agy_step_models(&conn, &mut model_by_step).is_ok();
    let mut steps =
        match conn.prepare("SELECT idx, metadata FROM steps WHERE step_type IN (15, 23)") {
            Ok(s) => s,
            Err(_) => return false,
        };
    let rows = match steps.query_map([], |row| {
        let index = row.get::<_, i64>(0)?;
        let metadata = row.get_ref(1)?.as_blob()?;
        Ok((index, agy_usage(metadata)))
    }) {
        Ok(rows) => rows,
        Err(_) => return false,
    };
    let mut complete = generation_complete;
    let mut model_by_enum = BTreeMap::new();
    let mut unmapped = Vec::new();
    for row in rows {
        let (index, usage) = match row {
            Ok((index, Ok(Some(usage)))) => (index, usage),
            Ok((_, Ok(None))) => continue,
            _ => {
                complete = false;
                continue;
            }
        };
        let direct = model_by_step.get(&index);
        if let (Some(model), Some(model_enum)) = (direct, usage.model_enum) {
            // Use all observed direct matches in this conversation, including
            // those outside the window, to detect conflicting enum mappings.
            if let Some(model) = model {
                record_agy_model(&mut model_by_enum, model_enum, model);
            } else {
                model_by_enum.insert(model_enum, None);
            }
        }
        if !(start..=end).contains(&usage.at_ms) {
            continue;
        }
        match direct {
            Some(Some(model)) => add(totals, "AGY", model, usage.input, usage.output),
            Some(None) => add(totals, "AGY", "Unknown model", usage.input, usage.output),
            None => unmapped.push(usage),
        }
    }
    for usage in unmapped {
        // Incomplete observations could hide conflicts; don't infer in that case.
        let model = usage
            .model_enum
            .filter(|_| complete)
            .and_then(|key| model_by_enum.get(&key))
            .and_then(Option::as_deref)
            .unwrap_or("Unknown model");
        add(totals, "AGY", model, usage.input, usage.output);
    }
    complete
}

// A present key with no value records conflicting evidence, never a first-row win.
fn record_agy_model<K: Ord>(map: &mut BTreeMap<K, Option<String>>, key: K, model: &str) {
    match map.entry(key) {
        Entry::Vacant(entry) => {
            entry.insert(Some(model.to_owned()));
        }
        Entry::Occupied(mut entry) if entry.get().as_deref() != Some(model) => {
            entry.insert(None);
        }
        _ => {}
    }
}

fn agy_step_models(
    conn: &Connection,
    model_by_step: &mut BTreeMap<i64, Option<String>>,
) -> Result<(), ()> {
    let mut stmt = conn
        .prepare("SELECT data FROM gen_metadata")
        .map_err(|_| ())?;
    let mut rows = stmt.query([]).map_err(|_| ())?;
    let mut complete = true;
    while let Some(row) = rows.next().map_err(|_| ())? {
        let parsed = row
            .get_ref(0)
            .and_then(|data| Ok(data.as_blob()?))
            .map_err(|_| ())
            .and_then(agy_generation);
        match parsed {
            Ok(Some((model, indices))) => {
                for index in indices {
                    record_agy_model(model_by_step, index, model);
                }
            }
            Ok(None) => {}
            Err(()) => complete = false,
        }
    }
    if complete { Ok(()) } else { Err(()) }
}

fn agy_generation(data: &[u8]) -> Result<Option<(&str, Vec<i64>)>, ()> {
    if data.len() > MAX_LINE {
        return Err(());
    }
    let mut model_field = None;
    let mut indices = Vec::new();
    for (field, wire, scalar, mut bytes) in protobuf_fields(data)? {
        match (field, wire) {
            (1, 2) => {
                if model_field.replace(bytes).is_some_and(|prev| prev != bytes) {
                    return Err(());
                }
            }
            (2, 2) => {
                while !bytes.is_empty() {
                    let (index, n) = varint(bytes)?;
                    indices.push(i64::try_from(index).map_err(|_| ())?);
                    bytes = &bytes[n..];
                }
            }
            (2, 0) => indices.push(i64::try_from(scalar).map_err(|_| ())?),
            (1 | 2, _) => return Err(()),
            _ => {}
        }
    }
    if indices.is_empty() {
        return Ok(None);
    }
    let field = model_field.ok_or(())?;
    // Field 1 can be a plain model ID or a generation message with the
    // resolved ID in field 19. Don't search the blob for model-like fragments.
    let model = if let Some(model) = agy_model_id(field) {
        model
    } else {
        let mut model = None;
        for (field, wire, _, bytes) in protobuf_fields(field)? {
            if field == 19 {
                if wire != 2 {
                    return Err(());
                }
                let value = agy_model_id(bytes).ok_or(())?;
                if model.is_some_and(|prev| prev != value) {
                    return Err(());
                }
                model = Some(value);
            }
        }
        model.ok_or(())?
    };
    Ok(Some((model, indices)))
}

fn agy_model_id(bytes: &[u8]) -> Option<&str> {
    // Only return identifiers from the known model field, never arbitrary text.
    if bytes.len() <= 256
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.iter().all(|b| {
            b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'/' | b':' | b'@' | b'+')
        })
    {
        std::str::from_utf8(bytes).ok()
    } else {
        None
    }
}

struct AgyUsage {
    input: u64,
    output: u64,
    at_ms: i64,
    model_enum: Option<u64>,
}

fn agy_usage(metadata: &[u8]) -> Result<Option<AgyUsage>, ()> {
    if metadata.len() > MAX_LINE {
        return Err(());
    }
    let mut stamp = None;
    let mut usage = None;
    for (field, wire, _, bytes) in protobuf_fields(metadata)? {
        match (field, wire) {
            (1, 2) => stamp = Some(bytes),
            (9, 2) => usage = Some(bytes),
            (9, _) => return Err(()),
            _ => {}
        }
    }
    let Some(usage) = usage else {
        return Ok(None);
    };
    let mut seconds = None;
    let mut nanos = 0;
    for (field, wire, value, _) in protobuf_fields(stamp.ok_or(())?)? {
        match (field, wire) {
            (1, 0) => seconds = Some(value as i64),
            (2, 0) if value < 1_000_000_000 => nanos = value as i64,
            (1 | 2, _) => return Err(()),
            _ => {}
        }
    }
    let at_ms = seconds
        .ok_or(())?
        .checked_mul(1000)
        .and_then(|ms| ms.checked_add(nanos / 1_000_000))
        .ok_or(())?;
    let mut model_enum = None;
    let mut input = None;
    let mut output = None;
    for (field, wire, value, _) in protobuf_fields(usage)? {
        match (field, wire) {
            (1, 0) => model_enum = Some(value),
            (2, 0) => input = Some(value),
            (3, 0) => output = Some(value),
            (1..=3, _) => return Err(()),
            // Field 5 is an Antigravity prior-token marker, not cache usage.
            _ => {}
        }
    }
    Ok(Some(AgyUsage {
        input: input.ok_or(())?,
        output: output.ok_or(())?,
        at_ms,
        model_enum,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn trace_counts_usage_once_and_sorts_deterministically() {
        let dir = tempdir().unwrap();
        let project = dir.path();
        let trace = project.join(".graff/traces");
        let traj = project.join(".graff/trajectories");
        fs::create_dir_all(&trace).unwrap();
        fs::create_dir_all(&traj).unwrap();
        fs::write(traj.join("a.jsonl"), "{\"unix_ms\":1795300000000}\n").unwrap();
        fs::write(
            trace.join("a.jsonl"),
            "{\"ev\":\"usage\",\"t\":2,\"model\":\"m\",\"input_tokens\":12,\"output_tokens\":3}\n",
        )
        .unwrap();
        let as_of = Local.timestamp_millis_opt(1795300000002).single().unwrap();
        let snap = collect(
            &[project.to_path_buf()],
            &dir.path().join("missing-codex"),
            &dir.path().join("missing-claude"),
            &dir.path().join("missing-journal"),
            &dir.path().join("missing-agy"),
            as_of,
        )
        .unwrap();
        assert_eq!(
            snap.rows
                .iter()
                .find(|r| r.runtime == "Harness")
                .map(|r| (r.input_tokens, r.output_tokens)),
            Some((12, 3))
        );
    }

    #[test]
    fn codex_counts_timestamped_response_usage_once_and_tracks_model_switches() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        fs::write(
            &path,
            concat!(
                "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-a\"}}\n",
                "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"response_id\":\"r1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n",
                "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"response_id\":\"r1\",\"usage\":{\"input_tokens\":100,\"output_tokens\":100}}}\n",
                "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-b\"}}\n",
                "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"response_id\":\"r2\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n",
                "{\"type\":\"thread_token_usage\",\"payload\":{\"usage\":{\"input_tokens\":999,\"output_tokens\":999}}}\n"
            ),
        )
        .unwrap();
        let timestamp = parse_timestamp("2026-11-22T00:00:00Z").unwrap();
        let mut totals = BTreeMap::new();
        assert!(parse_codex(
            &path,
            timestamp - 1,
            timestamp + 1,
            &mut totals
        ));
        assert_eq!(
            totals
                .get(&("Codex".into(), "gpt-a".into()))
                .map(|t| (t.input, t.output)),
            Some((10, 2))
        );
        assert_eq!(
            totals
                .get(&("Codex".into(), "gpt-b".into()))
                .map(|t| (t.input, t.output)),
            Some((3, 1))
        );
    }

    #[test]
    fn codex_recovers_usage_after_oversized_and_bad_lines() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut content =
            b"{\"type\":\"turn_context\",\"payload\":{\"model\":\"sample-model\"}}\n".to_vec();
        content.resize(content.len() + MAX_LINE * 2, b' ');
        content.extend_from_slice(concat!(
            "\nnot-json\n",
            "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"usage\":{\"input_tokens\":42,\"output_tokens\":7}}}\n"
        ).as_bytes());
        fs::write(&path, content).unwrap();
        let timestamp = parse_timestamp("2026-11-22T00:00:00Z").unwrap();
        let mut totals = BTreeMap::new();
        assert!(!parse_codex(&path, timestamp, timestamp, &mut totals));
        assert_eq!(
            totals
                .get(&("Codex".into(), "sample-model".into()))
                .map(|t| (t.input, t.output)),
            Some((42, 7))
        );
    }

    #[test]
    fn claude_counts_cached_input_only_for_harness_linked_sessions() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("session.jsonl");
        fs::write(
            &path,
            concat!(
                "{\"type\":\"assistant\",\"sessionId\":\"linked\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"message\":{\"id\":\"m1\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":2,\"cache_read_input_tokens\":3,\"output_tokens\":4}}}\n",
                "{\"type\":\"assistant\",\"sessionId\":\"linked\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"message\":{\"id\":\"m1\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":100}}}\n",
                "{\"type\":\"assistant\",\"sessionId\":\"unlinked\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"message\":{\"id\":\"m2\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":100}}}\n"
            ),
        )
        .unwrap();
        let timestamp = parse_timestamp("2026-11-22T00:00:00Z").unwrap();
        let allowed = HashSet::from(["linked".to_owned()]);
        let mut totals = BTreeMap::new();
        assert!(parse_claude(
            &path,
            &allowed,
            timestamp - 1,
            timestamp + 1,
            &mut totals
        ));
        assert_eq!(
            totals
                .get(&("Harness".into(), "claude-test".into()))
                .map(|t| (t.input, t.output)),
            Some((15, 4))
        );
    }

    #[test]
    fn malformed_trace_is_reported_as_partial() {
        let dir = tempdir().unwrap();
        let project = dir.path();
        let traces = project.join(".graff/traces");
        let trajectories = project.join(".graff/trajectories");
        fs::create_dir_all(&traces).unwrap();
        fs::create_dir_all(&trajectories).unwrap();
        fs::write(
            trajectories.join("bad.jsonl"),
            "{\"unix_ms\":1795300000000}\n",
        )
        .unwrap();
        fs::write(traces.join("bad.jsonl"), "not json\n").unwrap();
        let as_of = Local.timestamp_millis_opt(1795300005000).single().unwrap();
        let snapshot = collect(
            &[project.to_path_buf()],
            &dir.path().join("codex"),
            &dir.path().join("claude"),
            &dir.path().join("journals"),
            &dir.path().join("agy"),
            as_of,
        )
        .unwrap();
        assert!(snapshot.partial);
        assert!(snapshot.rows.is_empty());
    }

    fn put_varint(mut n: u64, out: &mut Vec<u8>) {
        while n >= 128 {
            out.push((n as u8) | 0x80);
            n >>= 7;
        }
        out.push(n as u8);
    }

    fn msg(field: u64, bytes: &[u8], out: &mut Vec<u8>) {
        put_varint((field << 3) | 2, out);
        put_varint(bytes.len() as u64, out);
        out.extend_from_slice(bytes);
    }

    fn scalar(field: u64, value: u64, out: &mut Vec<u8>) {
        put_varint(field << 3, out);
        put_varint(value, out);
    }

    const AGY_TIMESTAMP: i64 = 1_795_300_000_123;

    fn step_usage(at_ms: i64, model_enum: Option<u64>, input: u64, output: u64) -> Vec<u8> {
        let mut stamp = Vec::new();
        scalar(1, (at_ms / 1000) as u64, &mut stamp);
        scalar(2, (at_ms % 1000) as u64 * 1_000_000, &mut stamp);
        let mut usage = Vec::new();
        if let Some(value) = model_enum {
            scalar(1, value, &mut usage);
        }
        scalar(2, input, &mut usage);
        scalar(3, output, &mut usage);
        scalar(5, 999, &mut usage);
        let mut metadata = Vec::new();
        msg(1, &stamp, &mut metadata);
        msg(9, &usage, &mut metadata);
        metadata
    }

    fn generation(model_field: &[u8], indices: &[u64]) -> Vec<u8> {
        let mut packed = Vec::new();
        for &index in indices {
            put_varint(index, &mut packed);
        }
        let mut blob = Vec::new();
        msg(1, model_field, &mut blob);
        msg(2, &packed, &mut blob);
        blob
    }

    fn antigravity_fixture(root: &Path) -> (PathBuf, Connection) {
        let conversations = root.join("antigravity-cli/conversations");
        fs::create_dir_all(&conversations).unwrap();
        let path = conversations.join("synthetic.db");
        let db = Connection::open(&path).unwrap();
        db.execute_batch(
            "CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB);
             CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);",
        )
        .unwrap();
        (path, db)
    }

    fn insert_step(db: &Connection, idx: i64, step_type: i64, bytes: &[u8]) {
        db.execute(
            "INSERT INTO steps VALUES (?1, ?2, ?3)",
            rusqlite::params![idx, step_type, bytes],
        )
        .unwrap();
    }

    fn insert_generation(db: &Connection, bytes: &[u8]) {
        db.execute("INSERT INTO gen_metadata(data) VALUES (?1)", [bytes])
            .unwrap();
    }

    fn agy_totals(totals: &BTreeMap<(String, String), Totals>, model: &str) -> Option<(u64, u64)> {
        totals
            .get(&("AGY".into(), model.into()))
            .map(|row| (row.input, row.output))
    }

    #[test]
    fn antigravity_decodes_generation_and_falls_back_to_an_observed_enum() {
        let dir = tempdir().unwrap();
        let (path, db) = antigravity_fixture(dir.path());
        let mut wrapped_model = Vec::new();
        msg(4, b"claude-decoy", &mut wrapped_model);
        msg(19, b"vendor/next-model.v2", &mut wrapped_model);
        insert_generation(&db, &generation(&wrapped_model, &[129, 500]));
        insert_generation(&db, &generation(b"gemini-example", &[2]));
        // Earlier direct evidence may inform this month's attribution, but its
        // own tokens must remain outside the window.
        insert_step(
            &db,
            129,
            15,
            &step_usage(AGY_TIMESTAMP - 1, Some(7), 84, 87),
        );
        insert_step(&db, 500, 23, &step_usage(AGY_TIMESTAMP, Some(8), 20, 4));
        insert_step(&db, 3, 15, &step_usage(AGY_TIMESTAMP, Some(7), 15, 6));
        insert_step(&db, 2, 23, &step_usage(AGY_TIMESTAMP, None, 2, 1));
        insert_step(&db, 4, 15, &step_usage(AGY_TIMESTAMP, None, 5, 3));
        insert_step(&db, 5, 23, &step_usage(AGY_TIMESTAMP + 1, Some(7), 99, 99));
        insert_step(&db, 6, 12, &step_usage(AGY_TIMESTAMP, Some(7), 99, 99));
        drop(db);

        let mut totals = BTreeMap::new();
        assert!(parse_antigravity_db(
            &path,
            AGY_TIMESTAMP,
            AGY_TIMESTAMP,
            &mut totals
        ));
        assert_eq!(totals.len(), 3);
        // The prior-token marker in field 5 must not inflate any row.
        assert_eq!(agy_totals(&totals, "vendor/next-model.v2"), Some((35, 10)));
        assert_eq!(agy_totals(&totals, "gemini-example"), Some((2, 1)));
        assert_eq!(agy_totals(&totals, "Unknown model"), Some((5, 3)));
    }

    #[test]
    fn antigravity_keeps_conflicting_attribution_unknown() {
        let dir = tempdir().unwrap();
        let (path, db) = antigravity_fixture(dir.path());
        insert_generation(&db, &generation(b"gemini-example", &[1, 4]));
        insert_generation(&db, &generation(b"gemini-example", &[1]));
        insert_generation(&db, &generation(b"claude-example", &[2, 4]));
        insert_generation(&db, &generation(b"gemini-example", &[4, 5]));
        for (idx, model_enum, input) in [
            (1, 7, 10),
            (2, 7, 20),
            (3, 7, 30),
            (4, 9, 40),
            (5, 9, 50),
            (6, 9, 60),
            (7, 8, 70),
        ] {
            insert_step(
                &db,
                idx,
                15,
                &step_usage(AGY_TIMESTAMP, Some(model_enum), input, 1),
            );
        }
        drop(db);

        let mut totals = BTreeMap::new();
        assert!(parse_antigravity_db(
            &path,
            AGY_TIMESTAMP,
            AGY_TIMESTAMP,
            &mut totals
        ));
        assert_eq!(agy_totals(&totals, "gemini-example"), Some((60, 2)));
        assert_eq!(agy_totals(&totals, "claude-example"), Some((20, 1)));
        assert_eq!(agy_totals(&totals, "Unknown model"), Some((200, 4)));
    }

    #[test]
    fn antigravity_marks_malformed_rows_partial_without_dropping_readable_usage() {
        let dir = tempdir().unwrap();
        let (path, db) = antigravity_fixture(dir.path());
        // A truncated packed index list must not claim even its valid prefix.
        let mut bad_generation = Vec::new();
        msg(1, b"gemini-invalid", &mut bad_generation);
        msg(2, &[1, 0x80], &mut bad_generation);
        insert_generation(&db, &bad_generation);
        insert_generation(&db, &generation(b"gemini-example", &[2]));
        insert_step(&db, 0, 15, &[0x4a, 0x05, 0x10]);
        insert_step(&db, 1, 15, &step_usage(AGY_TIMESTAMP, Some(7), 5, 1));
        insert_step(&db, 2, 23, &step_usage(AGY_TIMESTAMP, Some(7), 10, 2));
        insert_step(&db, 3, 15, &vec![0; MAX_LINE + 1]);
        db.execute("INSERT INTO steps VALUES (4, 23, NULL)", [])
            .unwrap();
        insert_step(&db, 5, 15, &step_usage(AGY_TIMESTAMP, Some(7), 15, 3));
        drop(db);

        let mut totals = BTreeMap::new();
        assert!(!parse_antigravity_db(
            &path,
            AGY_TIMESTAMP,
            AGY_TIMESTAMP,
            &mut totals
        ));
        assert_eq!(totals.len(), 2);
        assert_eq!(agy_totals(&totals, "gemini-example"), Some((10, 2)));
        assert_eq!(agy_totals(&totals, "Unknown model"), Some((20, 4)));
    }

    #[test]
    fn antigravity_missing_generation_table_still_counts_usage_as_partial() {
        let dir = tempdir().unwrap();
        let (_, db) = antigravity_fixture(dir.path());
        db.execute("DROP TABLE gen_metadata", []).unwrap();
        insert_step(&db, 1, 15, &step_usage(AGY_TIMESTAMP, None, 8, 2));
        drop(db);

        let as_of = Local.timestamp_millis_opt(AGY_TIMESTAMP).unwrap();
        let snapshot = collect(&[], dir.path(), dir.path(), dir.path(), dir.path(), as_of).unwrap();
        assert!(snapshot.partial);
        assert_eq!(
            snapshot.rows,
            [Row {
                runtime: "AGY".into(),
                model: "Unknown model".into(),
                input_tokens: 8,
                output_tokens: 2,
            }]
        );
    }

    #[test]
    fn antigravity_non_usage_rows_are_complete_but_malformed_wire_data_is_not() {
        let dir = tempdir().unwrap();
        let (path, db) = antigravity_fixture(dir.path());
        insert_step(&db, 1, 15, &[]);
        // A generation message without step indices contributes no mapping.
        insert_generation(&db, &generation(&[0x18, 0x01], &[]));
        drop(db);
        let mut totals = BTreeMap::new();
        assert!(parse_antigravity_db(
            &path,
            AGY_TIMESTAMP,
            AGY_TIMESTAMP,
            &mut totals
        ));
        assert!(totals.is_empty());

        // Varint overflow and overflowing field numbers must not wrap to valid data.
        assert!(varint(&[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2]).is_err());
        let mut wrapped_key = Vec::new();
        scalar((1 << 32) | 1, 0, &mut wrapped_key);
        assert!(protobuf_fields(&wrapped_key).is_err());
        let mut bad_usage = Vec::new();
        msg(9, &[0x10, 0x01, 0x18, 0x02], &mut bad_usage);
        assert!(agy_usage(&bad_usage).is_err());
        let mut bad_tokens = Vec::new();
        msg(1, &[0x08, 0x01], &mut bad_tokens);
        msg(9, &[0x12, 0x01, 0x01, 0x18, 0x02], &mut bad_tokens);
        assert!(agy_usage(&bad_tokens).is_err());
    }
}
