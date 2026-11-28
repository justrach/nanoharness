# Run only on the isolated GitHub-hosted Windows desktop in windows.yml.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $IsWindows) {
    throw 'A GitHub-hosted Windows runner is required.'
}
if (-not [Environment]::UserInteractive) { throw 'The hosted runner has no interactive Windows desktop.' }
$root = Join-Path $env:RUNNER_TEMP ('nano-smoke-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $root 'package'
$local = Join-Path $root 'Local'
$data = Join-Path $local 'Harness'
$zip = Join-Path $root 'harness.zip'
$gui = Join-Path $package 'harness-nano.exe'
$owned = @((Join-Path $package 'harness.exe'), (Join-Path $package 'harness-engine.exe'))

function Test-EngineInfo([string]$Token, [int]$Port) {
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $deadline = [Threading.CancellationTokenSource]::new(5000)
    $reply = [IO.MemoryStream]::new()
    try {
        $socket.Options.SetRequestHeader('Authorization', "Bearer $Token")
        [void]$socket.ConnectAsync([uri]"ws://127.0.0.1:$Port/", $deadline.Token).GetAwaiter().GetResult()
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"EngineInfo","params":{}}')
        [void]$socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $deadline.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(4096)
        do {
            $part = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $deadline.Token).GetAwaiter().GetResult()
            if ($part.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) { throw 'Expected a text IPC reply.' }
            $reply.Write($buffer, 0, $part.Count)
            if ($reply.Length -gt 65536) { throw 'IPC reply exceeded the probe limit.' }
        } until ($part.EndOfMessage)
        $frame = [Text.Encoding]::UTF8.GetString($reply.ToArray()) | ConvertFrom-Json
        if ($frame.id -ne 1 -or $frame.ok.version -ne '0.2.245' -or -not $frame.ok.deviceId) {
            throw 'The packaged engine did not return the expected EngineInfo.'
        }
        return $frame.ok.deviceId
    } finally {
        $reply.Dispose()
        $socket.Dispose()
        $deadline.Dispose()
    }
}

New-Item -ItemType Directory -Path $root | Out-Null
try {
    Invoke-WebRequest -Uri 'https://github.com/justrach/nanoharness/releases/download/v0.2.245/harness-0.2.245-windows-x86_64.zip' -OutFile $zip -TimeoutSec 90
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne 'cb8d2381049ee4d364c1679d4eaf801f23ace15b6b08b95d945185890196515c') {
        throw 'Published ZIP SHA-256 did not match GitHub release metadata.'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $package
    Write-Host 'PASS: published Windows ZIP SHA-256 verified.'

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $port = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
    $env:HOME = $null
    $env:HARNESS_DATA_DIR = $null
    $env:HARNESS_IPC_TOKEN = $null
    $env:HARNESS_EDGE_TOKEN = $null
    $env:HARNESS_ORG_ID = $null
    $env:HARNESS_SANDBOX_TOKEN_FILE = $null
    $env:HARNESS_ENGINE_BIN = $null
    $env:HARNESS_NANO_ENGINE_BIN = $null
    $env:HARNESS_NANO_NO_ENGINE_START = $null
    $env:USERPROFILE = $root
    $env:LOCALAPPDATA = $local
    $env:APPDATA = Join-Path $root 'Roaming'
    $env:HARNESS_IPC_PORT = "$port"
    $env:HARNESS_EDGE_URL = 'http://127.0.0.1:1'
    $env:HARNESS_PROVIDER = 'mock'
    $env:HARNESS_GRAFF_AUTO_UPDATE = '0'
    $env:HARNESS_AUTO_UPDATE = '0'
    $tokenPath = Join-Path $data "ipc-token-$port"
    $device = $null

    foreach ($cycle in 1..2) {
        $p = Start-Process -FilePath $gui -WorkingDirectory $package -PassThru
        try {
            $null = $p.Handle
            $watch = [Diagnostics.Stopwatch]::StartNew()
            do {
                $p.Refresh()
                if ($p.HasExited) { throw "Cycle ${cycle}: GUI exited before opening ($($p.ExitCode))." }
                if ($p.MainWindowHandle -ne 0) { break }
                Start-Sleep -Milliseconds 200
            } while ($watch.Elapsed.TotalSeconds -lt 30)
            if ($p.MainWindowHandle -eq 0) { throw "Cycle ${cycle}: no native GUI window appeared within 30 seconds." }
            Write-Host "PASS: cycle $cycle opened a native window."

            # Only accept a socket owned by the GUI process. A 401 closes the
            # connection; require the same loopback socket to persist.
            $watch.Restart()
            $previous = $null
            $stable = [Diagnostics.Stopwatch]::new()
            do {
                if ($p.HasExited) { throw "Cycle ${cycle}: GUI exited during local engine startup." }
                $conn = Get-NetTCPConnection -OwningProcess $p.Id -RemoteAddress 127.0.0.1 -RemotePort $port -State Established -ErrorAction SilentlyContinue | Select-Object -First 1
                $current = if ($conn) { $conn.LocalPort } else { $null }
                if ($current -ne $previous) { $stable.Restart(); $previous = $current }
                if ($current -and $stable.Elapsed.TotalSeconds -ge 2 -and (Test-Path -LiteralPath $tokenPath)) { break }
                Start-Sleep -Milliseconds 200
            } while ($watch.Elapsed.TotalSeconds -lt 35)
            if (-not $current -or $stable.Elapsed.TotalSeconds -lt 2 -or -not (Test-Path -LiteralPath $tokenPath)) {
                throw "Cycle ${cycle}: GUI did not hold a local engine connection with the token under LOCALAPPDATA/Harness."
            }
            $liveDevice = Test-EngineInfo -Port $port -Token ((Get-Content -LiteralPath $tokenPath -Raw).Trim())
            if ($device -and $device -ne $liveDevice) { throw 'The isolated engine identity changed after reopening.' }
            $device = $liveDevice
            Write-Host "PASS: cycle $cycle held the GUI IPC connection; authenticated EngineInfo succeeded without HOME or data-directory overrides."

            if (-not $p.CloseMainWindow()) { throw "Cycle ${cycle}: could not request a normal close." }
            if (-not $p.WaitForExit(15000)) { throw "Cycle ${cycle}: GUI did not exit within 15 seconds of close." }
            if ($p.ExitCode -ne 0) { throw "Cycle ${cycle}: normal close returned $($p.ExitCode)." }
            Write-Host "PASS: cycle $cycle closed normally with exit 0."
        } finally {
            if (-not $p.HasExited) { $p.Kill(); $null = $p.WaitForExit(5000) }
            $p.Dispose()
        }
    }
} finally {
    Get-CimInstance Win32_Process -Filter "Name = 'harness.exe' OR Name = 'harness-engine.exe'" |
        Where-Object { $owned -contains $_.ExecutablePath } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
