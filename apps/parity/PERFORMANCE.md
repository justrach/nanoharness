# Performance monitor

The iOS app times itself on the device (`apps/ios/Harness/App/PerfMonitor.swift`) and shows the result under
Settings > Performance. Anonymous sharing is on by default and can be turned off in Settings; existing explicit
opt-outs are preserved. "Copy report" produces plain numbers (no chat content, names or identifiers). The desktop
client's own responsiveness stats are described in [`docs/desktop-responsiveness.md`](../../docs/desktop-responsiveness.md).

| | iOS (`PerfMonitor.swift`) |
| --- | --- |
| Operations against budgets | `Perf.measure`, also signpost intervals for Instruments |
| Frame health | main run loop turn length: slow over 16.7 ms, frozen over 700 ms |
| Main-thread stalls | any turn of 50 ms or more, recorded as `main.stall` |
| Startup | process start to first screen |
| Device | memory footprint, thermal state, Low Power Mode |

The operations and budgets are pinned in `perf-contract.json`: `startup.firstFrame`, `nav.open` (tap to the page it
opened), `transcript.rows`, `markdown.parse`, `home.group`, `send.apply`, `main.stall`. An operation over budget is
shown in red and logged in the `perf` category.

Reading it: a stall with no slow operation beside it is work the monitor does not name yet, so add a span there.

## Sharing anonymous performance numbers

iOS sends **OpenTelemetry OTLP/HTTP JSON** to `POST /v1/metrics`: one resource, one
`harness.ios.performance` instrumentation scope, and delta explicit-bucket histograms. The payload uses standard
OTLP nanosecond timestamp strings, string-encoded 64-bit counts, units, bounds, sums and maxima. It does not require
an SDK dependency or send raw samples. Bucket percentiles estimate a range's upper bound, not an exact sample
percentile.

Sharing is on by default. iOS honors the latest explicit setting, including opt-outs from earlier timing-only
releases. Only physical-device release builds collect or upload diagnostics; simulator and debug builds never do.
iOS samples its own process every five foreground seconds:
CPU utilization (`1`, where 1 means one occupied core), physical memory footprint (`By`), physical disk-write bytes
per sampled interval (`By`) and write rate (`By/s`). Counter failures and suspension gaps are omitted, never made into
zero samples. Disk I/O counters are not logical filesystem writes or SQLite attribution.

While a visible transcript scrolls or streams, iOS also records display-link callback delay (`ms`) using the current
refresh interval. This is a responsiveness proxy, **not measured GPU/render-server hitch time or FPS**. Its display
link stops while idle/backgrounded or sharing is disabled. Existing operation and main-thread timings use `ms`.

The receiver accepts only the fixed iOS meter, metric names, units, histogram bounds and coarse resource attributes;
it rejects extra attributes/exemplars or cumulative histograms before storing anything. Metadata is app/OS version,
architecture, hardware model and maximum refresh rate, plus a random per-launch `service.instance.id`. No account,
persistent device/session identifier, process ID, raw uptime, chat content or paths are exported. Aggregates retain
90 days. Uploads happen periodically in the foreground and on backgrounding, no more than once per ten minutes,
subject to the sharing setting, power, thermal and network restrictions.

The older `harness.mobile.stats.v1` JSON body is still pinned, as a compatibility contract, in
`vectors/perf-stats.json` and tested by `ParityTests.swift`; iOS does not send it.

- **Content:** `os`, `arch`, app and OS version, the hardware model (never the name the owner gave it, capped at 40
  characters), the refresh rate, the time window, and per metric a count, sum, max and the range counts. Metric names
  outside the list are dropped before sending, each sample is clamped to 0..60000 ms, and values are made to fit
  what the server accepts (the version is limited to letters, digits and `.+-`, and a window never reaches back more
  than six days), so one odd value cannot get every batch of a launch refused.
- **Identity:** `install_id` is a random v4 UUID made fresh for every launch, so one launch's batches can be joined
  but never linked to a person or to the next launch. No account, device or session identifier, and no chat content.
- **Rules:** an endpoint exists, sharing is on, the window has samples, at most one attempt per 10 minutes. Samples
  that could not go stay and merge into the next window; samples recorded while sharing is off are dropped and never
  sent later.
- **Never uploaded:** debug builds, or while Low Power Mode is on, or at a moderate or higher thermal state. iOS
  refuses expensive and constrained networks.
- **Transport:** a JSON POST over https (loopback http for tests), with no cookies, credentials, cache or redirects.
- **Store listings and disclosure:** declare diagnostics (performance data, not linked to the user) in store privacy
  answers and the privacy policy. The iOS privacy manifest already declares Performance Data and the elapsed-time API
  reason; absolute system uptime is never exported.

How the app treats the server's answer:

| Status | Meaning | The app |
| --- | --- | --- |
| 2xx | stored, or accepted and dropped by a cap | counts as sent |
| 429, other 4xx | rate limited, or for example a route not deployed yet | keeps the samples, starts the 10 minute wait |
| 400, 413, 415 | the batch is invalid, too large, or not JSON | drops it and stops sending for the rest of the launch |
| 5xx, no connection | server or network trouble | keeps the samples, no wait, tries again at the next chance |

## What it costs the device

The monitor must not be what slows the app or drains the phone.

- **Per call:** `PerfMonitorTests` fails if recording an operation or tallying a main run loop turn takes 25 µs or
  more in a debug build, to catch a hundredfold regression.
- **Uploads:** built and sent off the main thread, at most one batch per 10 minutes. Nothing is built or sent while
  sharing is off, in a debug build, while Low Power Mode is on, or at a moderate or higher thermal state, and iOS
  refuses expensive and constrained networks. Waking a mobile radio costs more battery than the batch is worth, so it
  is simply tried again at the next chance.

Not measured on iOS: CPU, write and battery overhead of the resource sampler and display link on a physical device.
