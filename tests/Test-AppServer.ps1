$ErrorActionPreference = 'Stop'
$process = $null

function Read-LineWithTimeout($Reader, [int]$Seconds = 10) {
    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait([TimeSpan]::FromSeconds($Seconds))) { throw 'Timed out waiting for codex app-server' }
    return $task.Result
}

try {
    $localCodex = Join-Path $PSScriptRoot '..\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    if (-not (Test-Path -LiteralPath $localCodex)) { throw 'Local Codex CLI is not installed' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Resolve-Path -LiteralPath $localCodex).Path
    $info.Arguments = 'app-server --stdio'
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $false
    $info.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Could not start codex app-server' }

    $initialize = @{ method = 'initialize'; id = 1; params = @{ clientInfo = @{ name = 'codex_weekly_meter_test'; title = 'Codex Weekly Meter Test'; version = '0.1.0' } } } | ConvertTo-Json -Compress -Depth 8
    $process.StandardInput.WriteLine($initialize)
    $process.StandardInput.Flush()
    $response = (Read-LineWithTimeout $process.StandardOutput) | ConvertFrom-Json
    if (-not $response.PSObject.Properties['result']) { throw 'Initialize failed' }

    $process.StandardInput.WriteLine((@{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress))
    $process.StandardInput.WriteLine((@{ method = 'account/rateLimits/read'; id = 2 } | ConvertTo-Json -Compress))
    $process.StandardInput.Flush()

    $found = $false
    for ($i = 0; $i -lt 20; $i++) {
        $message = (Read-LineWithTimeout $process.StandardOutput) | ConvertFrom-Json
        if ($message.PSObject.Properties['id'] -and [int]$message.id -eq 2) {
            if ($message.PSObject.Properties['error']) { throw $message.error.message }
            if (-not $message.result.PSObject.Properties['rateLimits']) { throw 'Rate-limit response has no rateLimits field' }
            $found = $true
            break
        }
    }
    if (-not $found) { throw 'No rate-limit response received' }
    Write-Host 'Codex app-server integration passed.' -ForegroundColor Green
} finally {
    if ($null -ne $process) {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        $process.Dispose()
    }
}
