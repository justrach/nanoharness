param(
    [Parameter(Mandatory)][string]$ReleasesUrl,
    # `headless` is the smaller shipped engine; CI passes `release` for smoke.
    [ValidateSet('headless', 'dist', 'release')][string]$CargoProfile = 'headless'
)
$ErrorActionPreference = 'Stop'
if (-not $ReleasesUrl.StartsWith('https://')) { throw 'Release feed must use HTTPS' }
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    cargo build --profile $CargoProfile --locked -p harness-engine --bin harness-engine
    if ($LASTEXITCODE -ne 0) { throw 'Windows engine build failed' }
    # The CRT is statically linked (.cargo/config.toml); a leftover
    # VCRUNTIME140 import would break clean installs without the VC++ redist.
    $engineExe = "./target/$CargoProfile/harness-engine.exe"
    if ([System.Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($engineExe)) -match 'VCRUNTIME140') {
        throw 'harness-engine.exe still imports VCRUNTIME140.dll — expected a static CRT'
    }
    # Nano loads the native WebView2 loader dynamically. Building its module
    # does not run nanoui's install step, so ship the loader explicitly.
    $sdkVersion = '1.0.2903.40'
    $sdk = Join-Path $root "target/webview2-$sdkVersion"
    $loader = Join-Path $sdk 'build/native/x64/WebView2Loader.dll'
    if (-not (Test-Path -LiteralPath $loader)) {
        $archive = "$sdk.zip"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$sdkVersion/microsoft.web.webview2.$sdkVersion.nupkg" -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $sdk -Force
    }
    Push-Location (Join-Path $root 'apps/nano')
    try {
        zig build -Dtarget=x86_64-windows-msvc -Dcpu=baseline -Doptimize=ReleaseSafe "-Dwebview2-loader=$loader"
        if ($LASTEXITCODE -ne 0) { throw 'harness-nano Windows build failed' }
    } finally { Pop-Location }
    # Explicit pipes also work for the GUI-subsystem executable in CI. A
    # PowerShell collection match does not populate the scalar $Matches map.
    $probe = [Diagnostics.ProcessStartInfo]::new()
    $probe.FileName = (Resolve-Path -LiteralPath './apps/nano/zig-out/bin/harness.exe').Path
    $probe.Arguments = '--version'
    $probe.UseShellExecute = $false
    $probe.CreateNoWindow = $true
    $probe.RedirectStandardOutput = $true
    $probe.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($probe)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw 'Executable version probe timed out'
        }
        $versionMatch = [regex]::Match($stdout.Result.Trim(), '\Aharness (\d+\.\d+\.\d+)\z')
        if ($process.ExitCode -ne 0 -or -not $versionMatch.Success) {
            throw "Cannot read executable version: $($stderr.Result)"
        }
        $version = $versionMatch.Groups[1].Value
    } finally { $process.Dispose() }
    $out = Join-Path $root 'target/package'
    $stage = Join-Path $out "harness-$version-windows-x86_64"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath $engineExe -Destination (Join-Path $stage 'harness-engine.exe')
    Copy-Item -LiteralPath './apps/nano/zig-out/bin/harness.exe' -Destination (Join-Path $stage 'harness.exe')
    Copy-Item -LiteralPath './apps/nano/zig-out/bin/harness-nano.exe' -Destination (Join-Path $stage 'harness-nano.exe')
    Copy-Item -LiteralPath './apps/nano/zig-out/bin/WebView2Loader.dll' -Destination $stage
    foreach ($name in @('harness.exe', 'harness-nano.exe')) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $stage $name))
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt16($bytes, $pe + 24 + 68) -ne 2) {
            throw "$name must use the GUI subsystem (no console window)"
        }
    }
    @{ releases_url = $ReleasesUrl } | ConvertTo-Json | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $stage 'harness-update.json')
    Copy-Item -LiteralPath 'LICENSE','THIRD_PARTY_NOTICES.md' -Destination $stage
    $licenses = Join-Path $stage 'licenses/fonts'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item -Path 'apps/nano/assets/fonts/licenses/*' -Destination $licenses
    Copy-Item -LiteralPath 'third_party/licenses/Zeron-MIT.txt' -Destination (Join-Path $stage 'licenses')
    Copy-Item -LiteralPath 'third_party/licenses/CodeGraff-LICENSE.txt' -Destination (Join-Path $stage 'licenses')
    $webviewLicense = Join-Path $sdk 'LICENSE.txt'
    if (Test-Path -LiteralPath $webviewLicense) {
        Copy-Item -LiteralPath $webviewLicense -Destination (Join-Path $stage 'licenses/Microsoft.Web.WebView2.txt')
    }
    Compress-Archive -Path "$stage/*" -DestinationPath "$stage.zip" -Force
    Copy-Item -LiteralPath './apps/nano/zig-out/bin/harness.exe' -Destination "$stage.exe"
    $files = @{}
    foreach ($artifact in @("$stage.exe", "$stage.zip")) {
        $file = Split-Path $artifact -Leaf
        $files[$file] = @{ sha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    @{ version = $version; files = $files } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $out 'manifest.json')
    Write-Host "Packaged $stage.zip"
} finally { Pop-Location }
