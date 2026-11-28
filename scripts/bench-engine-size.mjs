#!/usr/bin/env node
// Compare explicit harness-engine binaries using isolated mock data only.
// Usage: node scripts/bench-engine-size.mjs [--samples=10] [--repeat=200] [--seed-only] dist=/path/to/harness-engine headless=/path/to/harness-engine [z=/path/to/harness-engine]
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';

const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  console.log('Usage: node scripts/bench-engine-size.mjs [--samples=10] [--repeat=200] [--seed-only] label=/path/to/harness-engine label=/path/to/harness-engine [...]');
  process.exit(0);
}
let samples = 10;
let repeat = 200;
const seedOnly = args.includes('--seed-only');
const binaries = [];
for (const arg of args) {
  if (arg.startsWith('--samples=')) samples = Number(arg.slice('--samples='.length));
  else if (arg.startsWith('--repeat=')) repeat = Number(arg.slice('--repeat='.length));
  else if (arg === '--seed-only') continue;
  else {
    const at = arg.indexOf('=');
    assert(at > 0 && at < arg.length - 1, `Expected label=/absolute/path, got ${arg}`);
    const label = arg.slice(0, at);
    assert(/^[a-z0-9][a-z0-9_-]*$/i.test(label), `Invalid binary label: ${label}`);
    binaries.push({ label, path: path.resolve(arg.slice(at + 1)) });
  }
}
assert(Number.isInteger(samples) && samples >= 10, '--samples must be an integer >= 10');
assert(Number.isInteger(repeat) && repeat >= 1 && repeat <= 1000, '--repeat must be between 1 and 1000');
assert(binaries.length >= 2, 'Pass at least two explicit label=/path binary arguments');
assert.equal(new Set(binaries.map(({ label }) => label)).size, binaries.length, 'Labels must be unique');

const prompt = 'SYNTHETIC_ENGINE_SIZE_BENCHMARK';
const expectedText = 'Every turn flows through the same path';
const chatId = 'synthetic-size-bench-chat';
const spaceId = 'synthetic-size-bench-space';
const timeoutMs = 30_000;
const envBase = Object.fromEntries(['PATH', 'TMPDIR', 'LANG', 'LC_ALL'].filter(key => process.env[key]).map(key => [key, process.env[key]]));

function checkedVersion(binary) {
  const result = spawnSync(binary, ['--version'], { encoding: 'utf8', timeout: 10_000, env: envBase });
  assert.equal(result.status, 0, `${binary} --version failed: ${result.stderr || result.error || result.status}`);
  const version = (result.stdout || result.stderr).trim();
  assert(version.includes('harness-engine'), `Unexpected --version output for ${binary}: ${version}`);
  return version;
}

function countOccurrences(text, needle) {
  return text.split(needle).length - 1;
}

function gzipBytes(bytes, binary) {
  const result = spawnSync('gzip', ['-n', '-c'], { input: bytes, maxBuffer: bytes.length * 2 });
  assert.equal(result.status, 0, `gzip -n failed for ${binary}: ${result.stderr || result.error || result.status}`);
  return result.stdout.length;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function spread(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return { minMs: sorted[0], maxMs: sorted.at(-1), medianMs: median(sorted) };
}

async function freePort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return port;
}

function isolatedEnv(root, port, extra = {}) {
  const home = path.join(root, 'home');
  const data = path.join(root, 'data');
  return {
    ...envBase,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, '.config'),
    XDG_DATA_HOME: path.join(home, '.local', 'share'),
    XDG_CACHE_HOME: path.join(home, '.cache'),
    HARNESS_DATA_DIR: data,
    HARNESS_IPC_PORT: String(port),
    HARNESS_PROVIDER: 'mock',
    HARNESS_DEVICE_NAME: 'Synthetic engine-size host',
    HARNESS_EDGE_URL: 'http://127.0.0.1:9',
    HARNESS_CODEGRAFF_CLIENT_ID: '',
    HARNESS_CODEDB_AUTO_INSTALL: '0',
    HARNESS_AUTO_UPDATE: '0',
    HARNESS_GRAFF_AUTO_UPDATE: '0',
    HARNESS_MOCK_DELAY_MS: '0',
    RUST_LOG: 'error',
    ...extra,
  };
}

class Rpc {
  constructor(ws) {
    this.ws = ws;
    this.next = 1;
    this.pending = new Map();
    this.streams = new Map();
    ws.addEventListener('message', event => {
      let frame;
      try { frame = JSON.parse(String(event.data)); }
      catch (error) {
        this.failAll(new Error(`Invalid JSON-RPC frame: ${error}`));
        return;
      }
      const pending = this.pending.get(frame.id);
      if (pending) {
        if (Object.hasOwn(frame, 'err')) pending.reject(new Error(`${pending.method}: ${JSON.stringify(frame.err)}`));
        else if (Object.hasOwn(frame, 'ok')) pending.resolve(frame.ok);
        else pending.reject(new Error(`Unexpected JSON-RPC response: ${JSON.stringify(frame)}`));
        this.pending.delete(frame.id);
      }
      const stream = this.streams.get(frame.id);
      if (stream) {
        if (Object.hasOwn(frame, 'err')) stream.fail(new Error(`${stream.method}: ${JSON.stringify(frame.err)}`));
        else if (Object.hasOwn(frame, 'item')) stream.push(frame.item);
        else if (frame.done) stream.finish();
      }
    });
    ws.addEventListener('error', () => this.failAll(new Error('IPC WebSocket error')));
    ws.addEventListener('close', () => this.failAll(new Error('IPC WebSocket closed')));
  }

  failAll(error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    for (const stream of this.streams.values()) stream.fail(error);
  }

  call(method, params = {}) {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out calling ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        method,
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); },
      });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  watch(method, params = {}) {
    const id = this.next++;
    const stream = {
      method,
      items: [],
      waits: new Set(),
      failure: null,
      closed: false,
      push: value => {
        stream.items.push(value);
        for (const waiter of stream.waits) {
          if (waiter.predicate(value)) {
            clearTimeout(waiter.timer);
            stream.waits.delete(waiter);
            waiter.resolve(value);
          }
        }
      },
      finish: () => stream.fail(new Error(`Stream ${method} ended before the benchmark completed`)),
      fail: error => {
        if (stream.failure || stream.closed) return;
        stream.failure = error;
        for (const waiter of stream.waits) {
          clearTimeout(waiter.timer);
          waiter.reject(error);
        }
        stream.waits.clear();
      },
      wait: (predicate, timeout = timeoutMs) => {
        if (stream.failure) return Promise.reject(stream.failure);
        const existing = stream.items.find(predicate);
        if (existing !== undefined) return Promise.resolve(existing);
        return new Promise((resolve, reject) => {
          const waiter = { predicate, resolve, reject, timer: null };
          waiter.timer = setTimeout(() => {
            stream.waits.delete(waiter);
            reject(new Error(`Timed out waiting for ${method}`));
          }, timeout);
          stream.waits.add(waiter);
        });
      },
      close: () => {
        if (stream.closed) return;
        stream.closed = true;
        this.streams.delete(id);
        this.ws.send(JSON.stringify({ id, cancel: true }));
        for (const waiter of stream.waits) {
          clearTimeout(waiter.timer);
          waiter.reject(new Error(`Cancelled ${method}`));
        }
        stream.waits.clear();
      },
    };
    this.streams.set(id, stream);
    this.ws.send(JSON.stringify({ id, method, params }));
    return stream;
  }

  close() {
    this.failAll(new Error('RPC client closed'));
    this.ws.close();
  }
}

async function connect(engine) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (engine.exitCode !== null || engine.signalCode !== null) {
      throw new Error(`Engine exited before IPC was ready (${engine.exitCode ?? engine.signalCode})`);
    }
    const ws = new WebSocket(`ws://127.0.0.1:${engine.port}`);
    const opened = await new Promise(resolve => {
      const timer = setTimeout(() => resolve(false), 500);
      ws.addEventListener('open', () => { clearTimeout(timer); resolve(true); }, { once: true });
      ws.addEventListener('error', () => { clearTimeout(timer); resolve(false); }, { once: true });
      ws.addEventListener('close', () => { clearTimeout(timer); resolve(false); }, { once: true });
    });
    if (opened) return new Rpc(ws);
    ws.close();
    await new Promise(resolve => setTimeout(resolve, 2));
  }
  throw new Error('Engine did not become IPC-ready within 30 seconds');
}

async function start(binary, root, extra = {}) {
  await mkdir(path.join(root, 'project'), { recursive: true });
  await mkdir(path.join(root, 'home'), { recursive: true });
  await mkdir(path.join(root, 'data'), { recursive: true });
  const port = await freePort();
  const spawnedAt = performance.now();
  const child = spawn(binary, ['headless'], {
    cwd: path.join(root, 'project'),
    env: isolatedEnv(root, port, extra),
    stdio: 'ignore',
  });
  child.port = port;
  child.spawnedAt = spawnedAt;
  try {
    const rpc = await connect(child);
    child.rpc = rpc;
    return child;
  } catch (error) {
    await stop(child);
    throw error;
  }
}

async function stop(engine) {
  engine.rpc?.close();
  if (engine.exitCode !== null || engine.signalCode !== null) return;
  const exited = once(engine, 'exit');
  engine.kill('SIGTERM');
  const timer = setTimeout(() => engine.kill('SIGKILL'), 5000);
  await exited;
  clearTimeout(timer);
}

async function devicesFrom(rpc) {
  const devices = rpc.watch('WatchDevices');
  try {
    const value = await devices.wait(item => {
      const rows = Array.isArray(item) ? item : item?.items ?? item?.devices ?? [];
      return rows.length > 0;
    });
    const rows = Array.isArray(value) ? value : value?.items ?? value?.devices ?? [];
    assert.equal(rows.length, 1, `Expected exactly one isolated synthetic device, got ${rows.length}`);
    assert(rows[0].id, 'Synthetic device has no id');
    return rows[0];
  } finally { devices.close(); }
}

async function waitForDone(dataRoot) {
  const journalName = `${chatId}.jsonl`;
  const deadline = performance.now() + timeoutMs;
  let journal;
  let lastEvent = 'journal missing';
  while (performance.now() < deadline) {
    if (!journal) {
      const files = await readdir(dataRoot, { recursive: true });
      const relative = files.find(file => file.replaceAll(path.sep, '/').endsWith(`/journals/${journalName}`));
      if (relative) journal = path.join(dataRoot, relative);
    }
    if (journal) {
      try {
        const lines = (await readFile(journal, 'utf8')).trim().split('\n').filter(Boolean);
        const last = JSON.parse(lines.at(-1));
        lastEvent = JSON.stringify(last.event);
        if (last.event?.type === 'done') return;
      } catch (error) {
        if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error;
      }
    }
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  const log = await readFile(path.join(dataRoot, 'logs', 'harness-headless.log'), 'utf8').catch(() => '');
  const files = await readdir(dataRoot, { recursive: true }).catch(() => []);
  throw new Error(`Synthetic mock run did not persist Done; last event=${lastEvent}; data files=${JSON.stringify(files)}; engine log tail=${log.slice(-3000)}`);
}

async function seedTranscript(binary, root, repeat) {
  const engine = await start(binary, root, { HARNESS_MOCK_REPEAT: String(repeat) });
  try {
    const device = await devicesFrom(engine.rpc);
    const project = path.join(root, 'project');
    await writeFile(path.join(project, 'README.md'), '# Synthetic engine-size benchmark\n');
    assert((await engine.rpc.call('Mutate', {
      op: 'createSpace', spaceId, deviceId: device.id, path: project, gitDetected: false,
    }))?.ok, 'Could not create synthetic benchmark project');
    assert((await engine.rpc.call('Mutate', {
      op: 'createChat', chatId, spaceId, config: {
        harness: 'mock', model: 'mock-1', reasoning: 'medium', modelOptions: {}, sandbox: 'workspace-write',
      },
    }))?.ok, 'Could not create synthetic benchmark chat');
    const initial = engine.rpc.watch('WatchDocMessages', { chatId });
    await initial.wait(frame => Array.isArray(frame.reset));
    initial.close();
    await engine.rpc.call('QueueCommand', {
      chatId,
      command: {
        kind: 'run', messageId: 'synthetic-engine-size-benchmark-message',
        request: {
          prompt, turnOrigin: 'human', harness: 'mock', model: 'mock-1', cwd: project,
          sandbox: 'workspace-write', modelOptions: {}, autoApprove: false,
        },
      },
    });
    await waitForDone(path.join(root, 'data'));
    const transcript = engine.rpc.watch('WatchDocMessages', { chatId });
    try {
      const reset = await transcript.wait(frame => Array.isArray(frame.reset));
      const encoded = JSON.stringify(reset.reset);
      assert(encoded.includes(prompt), 'Persisted transcript is missing the synthetic user prompt');
      assert(countOccurrences(encoded, expectedText) >= repeat, 'Persisted transcript is missing expected repeated mock output');
      return {
        entries: reset.reset.length,
        transcriptBytes: Buffer.byteLength(encoded),
        expectedTextRepeats: countOccurrences(encoded, expectedText),
      };
    } finally { transcript.close(); }
  } finally { await stop(engine); }
}

async function startupSample(binary, root) {
  const engine = await start(binary, root);
  try {
    await devicesFrom(engine.rpc);
    return performance.now() - engine.spawnedAt;
  } finally { await stop(engine); }
}

async function replaySample(binary, root, seedData) {
  await mkdir(root, { recursive: true });
  await cp(seedData, path.join(root, 'data'), { recursive: true, errorOnExist: false });
  const engine = await start(binary, root);
  try {
    const before = performance.now();
    const transcript = engine.rpc.watch('WatchDocMessages', { chatId });
    try {
      const frame = await transcript.wait(item => Array.isArray(item.reset));
      const elapsedMs = performance.now() - before;
      const encoded = JSON.stringify(frame.reset);
      assert(encoded.includes(prompt), 'First-open persisted replay omitted the synthetic prompt');
      assert(countOccurrences(encoded, expectedText) >= repeatCount, 'First-open persisted replay was incomplete');
      return { elapsedMs, entries: frame.reset.length, transcriptBytes: Buffer.byteLength(encoded) };
    } finally { transcript.close(); }
  } finally { await stop(engine); }
}

let repeatCount = repeat;
const root = await mkdtemp(path.join(os.tmpdir(), 'harness-engine-size-'));
try {
  const versions = {};
  const fileSizes = {};
  for (const binary of binaries) {
    versions[binary.label] = checkedVersion(binary.path);
    const bytes = await readFile(binary.path);
    fileSizes[binary.label] = {
      executableBytes: bytes.length,
      gzipBytes: gzipBytes(bytes, binary.path),
    };
  }

  const seedRoot = path.join(root, 'seed');
  const seededTranscript = await seedTranscript(binaries[0].path, seedRoot, repeat);
  if (seedOnly) console.log(JSON.stringify({ host: `${os.platform()} ${os.arch()}`, nodeVersion: process.version, mockRepeat: repeat, seededTranscript }, null, 2));
  if (!seedOnly) {
  const seedData = path.join(seedRoot, 'data');
  const startup = Object.fromEntries(binaries.map(({ label }) => [label, []]));
  const replay = Object.fromEntries(binaries.map(({ label }) => [label, []]));
  for (let sample = 0; sample < samples; sample++) {
    for (let offset = 0; offset < binaries.length; offset++) {
      const binary = binaries[(sample + offset) % binaries.length];
      const sampleRoot = path.join(root, `startup-${sample}-${binary.label}`);
      startup[binary.label].push(await startupSample(binary.path, sampleRoot));
      await rm(sampleRoot, { recursive: true, force: true });
    }
  }
  for (let sample = 0; sample < samples; sample++) {
    for (let offset = 0; offset < binaries.length; offset++) {
      const binary = binaries[(sample + offset) % binaries.length];
      const sampleRoot = path.join(root, `replay-${sample}-${binary.label}`);
      const result = await replaySample(binary.path, sampleRoot, seedData);
      replay[binary.label].push(result.elapsedMs);
      if (!result.transcriptBytes || result.entries < 2) throw new Error('Replay returned an empty or trivial transcript');
      await rm(sampleRoot, { recursive: true, force: true });
    }
  }

  const results = Object.fromEntries(binaries.map(({ label }) => [label, {
    version: versions[label],
    ...fileSizes[label],
    startup: spread(startup[label]),
    startupSamplesMs: startup[label].map(value => Number(value.toFixed(3))),
    firstOpenPersistedReplay: spread(replay[label]),
    firstOpenPersistedReplaySamplesMs: replay[label].map(value => Number(value.toFixed(3))),
  }]));
  console.log(JSON.stringify({
    host: `${os.platform()} ${os.arch()}`,
    nodeVersion: process.version,
    samplesPerBinary: samples,
    mockRepeat: repeat,
    seededTranscript,
    results,
  }, null, 2));
  }
} finally {
  await rm(root, { recursive: true, force: true });
}
