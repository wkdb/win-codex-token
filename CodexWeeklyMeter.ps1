param([switch]$DebugConsole, [switch]$SmokeTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ')
    exit
}

$meterTempPath = Join-Path $env:LOCALAPPDATA 'CodexWeeklyMeter\tmp'
if (-not (Test-Path -LiteralPath $meterTempPath)) { New-Item -ItemType Directory -Path $meterTempPath -Force | Out-Null }
$env:TEMP = $meterTempPath
$env:TMP = $meterTempPath

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies @('System.Drawing.dll', 'System.Windows.Forms.dll') @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public sealed class CrispStatusLabel : Label {
    public CrispStatusLabel() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnPaintBackground(PaintEventArgs e) {
        // Keep the color-key background uniform so it is removed cleanly.
        e.Graphics.Clear(Parent == null ? BackColor : Parent.BackColor);
    }

    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(Parent == null ? BackColor : Parent.BackColor);
        e.Graphics.SmoothingMode = SmoothingMode.None;
        e.Graphics.PixelOffsetMode = PixelOffsetMode.Half;
        e.Graphics.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
        using (var brush = new SolidBrush(ForeColor))
        using (var format = new StringFormat()) {
            format.Alignment = StringAlignment.Center;
            format.LineAlignment = StringAlignment.Center;
            format.FormatFlags = StringFormatFlags.NoWrap;
            e.Graphics.DrawString(Text, Font, brush, ClientRectangle, format);
        }
    }
}
public static class NativeIcon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
public static class NativeStatusBar {
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    public static extern int GetWindowLong(IntPtr handle, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    public static extern int SetWindowLong(IntPtr handle, int index, int value);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr handle, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
}
'@

Import-Module (Join-Path $PSScriptRoot 'CodexMeter.Core.psm1') -Force

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\CodexWeeklyMeter', [ref]$createdNew)
if (-not $createdNew) {
    [Windows.Forms.MessageBox]::Show(
        'Codex Weekly Meter 已经在运行。请查看任务栏右下角的隐藏图标区域。',
        'Codex Weekly Meter',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    $mutex.Dispose()
    exit
}

$script:AppName = 'Codex Weekly Meter'
$script:Version = '0.1.0'
$script:Process = $null
$script:ReadTask = $null
$script:Initialized = $false
$script:RequestId = 10
$script:PendingRateLimitRequestId = $null
$script:PendingRateLimitRequestedAt = [DateTimeOffset]::MinValue
$script:RateLimitRequestTimeoutSeconds = 15
$script:ReconnectDelaySeconds = 5
$script:NextReconnectAt = [DateTimeOffset]::MinValue
$script:LastPoll = [DateTimeOffset]::MinValue
$script:Model = $null
$script:RateLimitsRaw = $null
$script:LastIcon = $null
$script:LastNotificationBand = $null
$script:Stopping = $false
$script:StatusBarEnabled = $true
$script:LastStatusBarCheck = [DateTimeOffset]::MinValue
$script:StatusTextColor = [Drawing.ColorTranslator]::FromHtml('#E4E6EA')
$script:StatusMutedTextColor = [Drawing.ColorTranslator]::FromHtml('#B8BDC7')
$script:LogPath = Join-Path $env:LOCALAPPDATA 'CodexWeeklyMeter\meter.log'
$script:CachePath = Join-Path $env:LOCALAPPDATA 'CodexWeeklyMeter\last-known.json'

function Write-AppLog {
    param([string]$Message)
    try {
        $directory = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        ('{0:u} {1}' -f [DateTime]::Now, $Message) | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
    } catch { }
}

function New-MeterIcon {
    param([string]$Text, [string]$Color)

    $bitmap = New-Object Drawing.Bitmap 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $brush = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($Color))
    $graphics.FillEllipse($brush, 1, 1, 30, 30)
    $fontSize = if ($Text.Length -ge 3) { 9 } else { 11 }
    $font = New-Object Drawing.Font('Segoe UI', $fontSize, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    $graphics.DrawString($Text, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, 32, 31)), $format)
    $handle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($handle).Clone()
    [NativeIcon]::DestroyIcon($handle) | Out-Null
    $format.Dispose(); $font.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    return $icon
}

function Set-TrayIcon {
    param([string]$Text, [string]$Color, [string]$Tooltip)
    $icon = New-MeterIcon -Text $Text -Color $Color
    $old = $script:LastIcon
    $script:LastIcon = $icon
    $script:NotifyIcon.Icon = $icon
    $script:NotifyIcon.Text = $Tooltip.Substring(0, [Math]::Min(63, $Tooltip.Length))
    if ($null -ne $old) { $old.Dispose() }
}

function Set-StatusText {
    param([string]$Message, [string]$Details = '')
    $script:FiveHourLabel.Visible = $false
    $script:FiveHourValue.Visible = $false
    $script:FiveHourReset.Visible = $false
    $script:WeeklyValue.Text = '--%'
    $script:WeeklyReset.Text = $Message
    $script:UpdatedLabel.Text = $Details
    if ($null -ne $script:StatusLabel) {
        $script:StatusLabel.Text = 'Codex  本周 --'
        $script:StatusLabel.ForeColor = $script:StatusTextColor
    }
    Set-TrayIcon -Text '?' -Color '#6C757D' -Tooltip "$($script:AppName)：$Message"
}

function Set-TransientStatus {
    param([string]$Message)
    if ($null -eq $script:Model -or $null -eq $script:Model.Weekly) {
        Set-StatusText $Message '等待下次自动刷新'
        return
    }

    $remaining = [int]$script:Model.Weekly.RemainingPercent
    $fiveHourText = if ($null -ne $script:Model.FiveHour) { "五小时 $([int]$script:Model.FiveHour.RemainingPercent)% · " } else { '' }
    $script:StatusLabel.Text = "Codex  $fiveHourText`本周 $remaining% · 暂存"
    $script:StatusLabel.ForeColor = $script:StatusMutedTextColor
    $script:UpdatedLabel.Text = "上次刷新：$($script:Model.UpdatedAt.ToString('yyyy-MM-dd HH:mm:ss')) · 暂存"
    Set-TrayIcon -Text ([string]$remaining) -Color '#6C757D' -Tooltip "Codex $fiveHourText`本周 $remaining%（暂存）"
}

function Save-ModelCache {
    if ($null -eq $script:Model -or $null -eq $script:Model.Weekly) { return }
    try {
        $directory = Split-Path -Parent $script:CachePath
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $resetAt = if ($null -ne $script:Model.Weekly.ResetsAt) { $script:Model.Weekly.ResetsAt.ToString('o') } else { $null }
        $fiveHour = $null
        if ($null -ne $script:Model.FiveHour) {
            $fiveHourResetAt = if ($null -ne $script:Model.FiveHour.ResetsAt) { $script:Model.FiveHour.ResetsAt.ToString('o') } else { $null }
            $fiveHour = @{ remainingPercent = [int]$script:Model.FiveHour.RemainingPercent; resetsAt = $fiveHourResetAt }
        }
        @{
            remainingPercent = [int]$script:Model.Weekly.RemainingPercent
            resetsAt = $resetAt
            fiveHour = $fiveHour
            updatedAt = $script:Model.UpdatedAt.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $script:CachePath -Encoding UTF8
    } catch {
        Write-AppLog "cache write failed: $($_.Exception.Message)"
    }
}

function Load-ModelCache {
    try {
        $remaining = $null
        $updatedAt = $null
        $resetsAt = $null
        $fiveHour = $null
        if (Test-Path -LiteralPath $script:CachePath) {
            $cache = Get-Content -LiteralPath $script:CachePath -Raw | ConvertFrom-Json
            $remaining = [int]$cache.remainingPercent
            $updatedAt = [DateTimeOffset]::Parse([string]$cache.updatedAt)
            if ($cache.resetsAt) { $resetsAt = [DateTimeOffset]::Parse([string]$cache.resetsAt) }
            if ($cache.PSObject.Properties['fiveHour'] -and $null -ne $cache.fiveHour) {
                $fiveHourResetAt = $null
                if ($cache.fiveHour.resetsAt) { $fiveHourResetAt = [DateTimeOffset]::Parse([string]$cache.fiveHour.resetsAt) }
                $fiveHour = [pscustomobject]@{ RemainingPercent = [int]$cache.fiveHour.remainingPercent; ResetsAt = $fiveHourResetAt; DurationMinutes = 300 }
            }
        } elseif (Test-Path -LiteralPath $script:LogPath) {
            # Migration fallback for installations created before cache support.
            $lastSuccess = Get-Content -LiteralPath $script:LogPath -Tail 500 |
                Where-Object { $_ -match 'limits updated: weekly=(\d+)%' } |
                Select-Object -Last 1
            if ($lastSuccess -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})Z .*weekly=(\d+)%') {
                $updatedAt = [DateTimeOffset]::ParseExact($matches[1] + 'Z', 'yyyy-MM-dd HH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
                $remaining = [int]$matches[2]
            }
        }
        if ($null -eq $remaining) { return }

        $script:Model = [pscustomobject]@{
            Weekly = [pscustomobject]@{ RemainingPercent = $remaining; ResetsAt = $resetsAt }
            FiveHour = $fiveHour
            Session = $null
            UpdatedAt = $updatedAt
        }
        Update-Display
        Set-TransientStatus '正在刷新'
    } catch {
        Write-AppLog "cache read failed: $($_.Exception.Message)"
    }
}

function Update-Display {
    if ($null -eq $script:Model -or $null -eq $script:Model.Weekly) { return }
    $weekly = $script:Model.Weekly
    $remaining = [int]$weekly.RemainingPercent
    $hasFiveHour = $null -ne $script:Model.FiveHour
    $fiveHourText = ''

    if ($hasFiveHour) {
        $fiveHourRemaining = [int]$script:Model.FiveHour.RemainingPercent
        $fiveHourText = "五小时 $fiveHourRemaining% · "
        $script:FiveHourLabel.Visible = $true
        $script:FiveHourValue.Visible = $true
        $script:FiveHourReset.Visible = $true
        $script:FiveHourValue.Text = "$fiveHourRemaining%"
        $script:FiveHourReset.Text = "重置：$(Format-CodexResetTime $script:Model.FiveHour.ResetsAt)"
        $script:WeeklyLabel.Location = New-Object Drawing.Point 20, 112
        $script:WeeklyValue.Location = New-Object Drawing.Point 225, 102
        $script:WeeklyReset.Location = New-Object Drawing.Point 20, 138
        $script:UpdatedLabel.Location = New-Object Drawing.Point 20, 162
        $script:Form.ClientSize = New-Object Drawing.Size 340, 200
        $script:StatusForm.Size = New-Object Drawing.Size 315, 38
        $script:StatusTextForm.Size = $script:StatusForm.Size
    } else {
        $script:FiveHourLabel.Visible = $false
        $script:FiveHourValue.Visible = $false
        $script:FiveHourReset.Visible = $false
        $script:WeeklyLabel.Location = New-Object Drawing.Point 20, 62
        $script:WeeklyValue.Location = New-Object Drawing.Point 225, 52
        $script:WeeklyReset.Location = New-Object Drawing.Point 20, 88
        $script:UpdatedLabel.Location = New-Object Drawing.Point 20, 112
        $script:Form.ClientSize = New-Object Drawing.Size 340, 150
        $script:StatusForm.Size = New-Object Drawing.Size 225, 38
        $script:StatusTextForm.Size = $script:StatusForm.Size
    }

    $script:WeeklyValue.Text = "$remaining%"
    $script:WeeklyReset.Text = "重置：$(Format-CodexResetTime $weekly.ResetsAt)"
    $script:UpdatedLabel.Text = "上次刷新：$($script:Model.UpdatedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
    $color = Get-CodexMeterColor -RemainingPercent $remaining
    Set-TrayIcon -Text ([string]$remaining) -Color $color -Tooltip "Codex $fiveHourText`本周剩余 $remaining%"
    if ($null -ne $script:StatusLabel) {
        $script:StatusLabel.Text = "Codex  $fiveHourText`本周 $remaining%"
        # Keep the always-on overlay calm; the tray icon still uses the
        # threshold color for at-a-glance warnings.
        $script:StatusLabel.ForeColor = $script:StatusTextColor
    }

    $band = if ($remaining -le 5) { 5 } elseif ($remaining -le 10) { 10 } elseif ($remaining -le 20) { 20 } else { $null }
    if ($null -ne $band -and $band -ne $script:LastNotificationBand) {
        $script:NotifyIcon.ShowBalloonTip(5000, 'Codex 每周额度提醒', "本周剩余 $remaining%", [Windows.Forms.ToolTipIcon]::Warning)
        $script:LastNotificationBand = $band
    } elseif ($null -eq $band) {
        $script:LastNotificationBand = $null
    }
}

function Send-AppServerMessage {
    param($Message)
    if ($null -eq $script:Process -or $script:Process.HasExited) { return $false }
    try {
        $json = $Message | ConvertTo-Json -Compress -Depth 10
        $script:Process.StandardInput.WriteLine($json)
        $script:Process.StandardInput.Flush()
        return $true
    } catch {
        Write-AppLog "app-server write failed: $($_.Exception.Message)"
        return $false
    }
}

function Request-RateLimits {
    if (-not $script:Initialized) { return }
    if ($null -ne $script:PendingRateLimitRequestId) { return }
    $script:RequestId++
    $requestId = $script:RequestId
    if (Send-AppServerMessage @{ method = 'account/rateLimits/read'; id = $requestId }) {
        $script:PendingRateLimitRequestId = $requestId
        $script:PendingRateLimitRequestedAt = [DateTimeOffset]::Now
        $script:LastPoll = $script:PendingRateLimitRequestedAt
    } else {
        Schedule-AppServerReconnect "could not send rate-limit request $requestId"
    }
}

function Stop-AppServer {
    if ($null -ne $script:Process) {
        try {
            if (-not $script:Process.HasExited) { $script:Process.Kill() }
            $script:Process.Dispose()
        } catch { }
    }
    $script:Process = $null
    $script:ReadTask = $null
    $script:Initialized = $false
    $script:PendingRateLimitRequestId = $null
    $script:PendingRateLimitRequestedAt = [DateTimeOffset]::MinValue
}

function Schedule-AppServerReconnect {
    param(
        [string]$Reason,
        [string]$Status = 'Codex connection lost; reconnecting'
    )

    if ($script:Stopping) { return }
    Write-AppLog "app-server reconnect scheduled: $Reason"
    Stop-AppServer
    Set-TransientStatus $Status
    $script:NextReconnectAt = [DateTimeOffset]::Now.AddSeconds($script:ReconnectDelaySeconds)
}

function Resolve-CodexExecutable {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_METER_CLI) -and (Test-Path -LiteralPath $env:CODEX_METER_CLI)) {
        return (Resolve-Path -LiteralPath $env:CODEX_METER_CLI).Path
    }

    $localCodex = Join-Path $PSScriptRoot 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    if (Test-Path -LiteralPath $localCodex) { return (Resolve-Path -LiteralPath $localCodex).Path }

    $command = Get-Command 'codex.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) { return $command.Source }

    # The Store app does not add its bundled CLI to PATH for processes started
    # by wscript.exe. Reuse the path of the running Codex desktop process.
    $running = Get-Process -Name 'codex' -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) -and (Test-Path -LiteralPath $_.Path) } |
        Select-Object -First 1
    if ($null -ne $running) { return $running.Path }

    # Final fallback for the Microsoft Store package when Codex is not open.
    $packageRoot = Join-Path $env:ProgramFiles 'WindowsApps'
    $packaged = Get-ChildItem -Path $packageRoot -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'app\resources\codex.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ($null -ne $packaged) { return $packaged }

    throw '未找到 Codex。请先打开 Codex 桌面应用，然后选择“立即刷新”。'
}

function Start-AppServer {
    Stop-AppServer
    Set-TransientStatus '正在连接 Codex…'
    try {
        $codexPath = Resolve-CodexExecutable
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $codexPath
        $info.Arguments = 'app-server --stdio'
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $false
        $info.CreateNoWindow = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $script:Process = New-Object Diagnostics.Process
        $script:Process.StartInfo = $info
        if (-not $script:Process.Start()) { throw 'Codex app-server 未能启动' }

        if (-not (Send-AppServerMessage @{
            method = 'initialize'
            id = 1
            params = @{
                clientInfo = @{ name = 'codex_weekly_meter'; title = $script:AppName; version = $script:Version }
            }
        })) { throw 'Unable to send the app-server initialize request' }
        $script:ReadTask = $script:Process.StandardOutput.ReadLineAsync()
        $script:NextReconnectAt = [DateTimeOffset]::MinValue
        Write-AppLog "app-server started: $codexPath"
    } catch {
        Write-AppLog "start failed: $($_.Exception.Message)"
        Schedule-AppServerReconnect $_.Exception.Message 'Unable to connect to Codex; retrying'
    }
}

function Apply-RateLimitsMessage {
    param($RateLimits)
    if ($null -eq $RateLimits) { return }
    $script:RateLimitsRaw = $RateLimits
    $script:Model = ConvertFrom-CodexRateLimits -RateLimits $RateLimits
    Update-Display
    Save-ModelCache
    if ($null -ne $script:Model.Weekly) {
        Write-AppLog "limits updated: weekly=$($script:Model.Weekly.RemainingPercent)%"
    }
}

function Handle-AppServerLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try {
        $message = $Line | ConvertFrom-Json
        if ($message.PSObject.Properties['error']) {
            $errorMessage = if ($message.error.PSObject.Properties['message']) { $message.error.message } else { '未知错误' }
            Write-AppLog "rpc error: $errorMessage"
            if ($message.PSObject.Properties['id'] -and [int]$message.id -eq $script:PendingRateLimitRequestId) {
                $script:PendingRateLimitRequestId = $null
                $script:PendingRateLimitRequestedAt = [DateTimeOffset]::MinValue
            }
            Set-TransientStatus '读取额度失败'
            return
        }
        if ($message.PSObject.Properties['id'] -and [int]$message.id -eq 1) {
            if (-not (Send-AppServerMessage @{ method = 'initialized'; params = @{} })) {
                Schedule-AppServerReconnect 'could not send initialized notification'
                return
            }
            $script:Initialized = $true
            Request-RateLimits
            return
        }
        if ($message.PSObject.Properties['result'] -and $message.result.PSObject.Properties['rateLimits']) {
            Apply-RateLimitsMessage $message.result.rateLimits
            if ($message.PSObject.Properties['id'] -and [int]$message.id -eq $script:PendingRateLimitRequestId) {
                $script:PendingRateLimitRequestId = $null
                $script:PendingRateLimitRequestedAt = [DateTimeOffset]::MinValue
            }
            return
        }
        if ($message.PSObject.Properties['method'] -and $message.method -eq 'account/rateLimits/updated') {
            # Update notifications may be sparse. Refetch a complete snapshot instead
            # of accidentally clearing fields omitted by the notification.
            Request-RateLimits
        }
    } catch {
        Write-AppLog "invalid response: $Line | $($_.Exception.Message)"
    }
}

function Set-StartupEnabled {
    param([bool]$Enabled)
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enabled) {
        $launcher = Join-Path $PSScriptRoot 'Start-CodexWeeklyMeter.vbs'
        $value = 'wscript.exe "{0}"' -f $launcher
        New-ItemProperty -Path $runKey -Name 'CodexWeeklyMeter' -Value $value -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $runKey -Name 'CodexWeeklyMeter' -ErrorAction SilentlyContinue
    }
}

function Test-StartupEnabled {
    try { return $null -ne (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'CodexWeeklyMeter' -ErrorAction Stop) } catch { return $false }
}

function Show-MeterWindow {
    # The compact layers are topmost. Hide them while the detail window is
    # open so the click always exposes the complete dialog in front.
    Hide-StatusBar
    $workingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:Form.Location = New-Object Drawing.Point(($workingArea.Right - $script:Form.Width - 12), ($workingArea.Bottom - $script:Form.Height - 12))
    Update-Display
    $script:Form.Show()
    $script:Form.Activate()
}

function Position-StatusBar {
    $workingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $location = New-Object Drawing.Point(
        ($workingArea.Right - $script:StatusForm.Width - 12),
        ($workingArea.Bottom - $script:StatusForm.Height - 8)
    )
    $script:StatusForm.Location = $location
    $script:StatusTextForm.Location = $location
}

function Show-StatusBar {
    if (-not $script:StatusBarEnabled -or $script:Stopping) { return }
    Position-StatusBar
    if (-not $script:StatusForm.Visible) { $script:StatusForm.Show() }
    if (-not $script:StatusTextForm.Visible) { $script:StatusTextForm.Show() }
    # Restore the non-activating topmost state after a lock/unlock, sleep/resume,
    # or an Explorer restart. Calling Show() alone does not always restore z-order.
    [NativeStatusBar]::SetWindowPos($script:StatusForm.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0053) | Out-Null
    [NativeStatusBar]::SetWindowPos($script:StatusTextForm.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0053) | Out-Null
}

function Hide-StatusBar {
    $script:StatusTextForm.Hide()
    $script:StatusForm.Hide()
}

function Ensure-StatusBarVisible {
    if (-not $script:StatusBarEnabled -or $script:Stopping) { return }
    if ($script:Form.Visible) { return }
    if (([DateTimeOffset]::Now - $script:LastStatusBarCheck).TotalSeconds -lt 2) { return }
    $script:LastStatusBarCheck = [DateTimeOffset]::Now
    Show-StatusBar
}

$script:Form = New-Object Windows.Forms.Form
$script:Form.Text = $script:AppName
# Set the client area explicitly: the title bar and fixed border are extra,
# and the previous outer height clipped the last (last-refresh) row.
$script:Form.ClientSize = New-Object Drawing.Size 340, 150
$script:Form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
$script:Form.MaximizeBox = $false
$script:Form.MinimizeBox = $false
$script:Form.ShowInTaskbar = $false
$script:Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$script:Form.BackColor = [Drawing.Color]::White
$script:Form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.Add_Deactivate({
    $script:Form.Hide()
    Show-StatusBar
})

$script:StatusForm = New-Object Windows.Forms.Form
$script:StatusForm.Text = 'Codex Capacity Status'
$script:StatusForm.Size = New-Object Drawing.Size 225, 38
$script:StatusForm.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
$script:StatusForm.ShowInTaskbar = $false
$script:StatusForm.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$script:StatusForm.TopMost = $true
$statusBarColor = [Drawing.ColorTranslator]::FromHtml('#202124')
$script:StatusForm.BackColor = $statusBarColor
$script:StatusForm.Opacity = 0.50

$script:StatusTextForm = New-Object Windows.Forms.Form
$script:StatusTextForm.Text = 'Codex Capacity Status Text'
$script:StatusTextForm.Size = $script:StatusForm.Size
$script:StatusTextForm.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
$script:StatusTextForm.ShowInTaskbar = $false
$script:StatusTextForm.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$script:StatusTextForm.TopMost = $true
# Use the same neutral color as the background layer for color-key transparency.
# A bright key color causes ClearType/anti-aliased glyph edges to turn magenta/cyan.
$script:StatusTextForm.BackColor = $statusBarColor
$script:StatusTextForm.TransparencyKey = $statusBarColor
$script:StatusTextForm.Opacity = 0.95

$script:StatusLabel = New-Object CrispStatusLabel
$script:StatusLabel.Dock = [Windows.Forms.DockStyle]::Fill
$script:StatusLabel.Text = 'Codex  本周 --'
$script:StatusLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$script:StatusLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$script:StatusLabel.ForeColor = $script:StatusTextColor
$script:StatusLabel.BackColor = [Drawing.Color]::Transparent
$script:StatusLabel.Cursor = [Windows.Forms.Cursors]::Hand
$script:StatusTextForm.Controls.Add($script:StatusLabel)

# Keep both compact-bar layers out of Alt+Tab and prevent them from taking keyboard focus.
foreach ($statusWindow in @($script:StatusForm, $script:StatusTextForm)) {
    $statusHandle = $statusWindow.Handle
    $extendedStyle = [NativeStatusBar]::GetWindowLong($statusHandle, -20)
    [NativeStatusBar]::SetWindowLong($statusHandle, -20, ($extendedStyle -bor 0x08000000 -bor 0x00000080)) | Out-Null
}
# A click can land on either the transparent text layer or the dim background
# layer, depending on its pixel position. Handle both layers explicitly.
$openStatusDetails = {
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-MeterWindow }
}
$script:StatusLabel.Add_MouseUp($openStatusDetails)
$script:StatusTextForm.Add_MouseUp($openStatusDetails)
$script:StatusForm.Add_MouseUp($openStatusDetails)

$title = New-Object Windows.Forms.Label
$title.Text = 'Codex Capacity'
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 14, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point 18, 15
$title.AutoSize = $true
$script:Form.Controls.Add($title)

$script:FiveHourLabel = New-Object Windows.Forms.Label
$script:FiveHourLabel.Text = '五小时剩余'
$script:FiveHourLabel.Location = New-Object Drawing.Point 20, 62
$script:FiveHourLabel.Size = New-Object Drawing.Size 100, 24
$script:FiveHourLabel.Visible = $false
$script:Form.Controls.Add($script:FiveHourLabel)

$script:FiveHourValue = New-Object Windows.Forms.Label
$script:FiveHourValue.Text = '--%'
$script:FiveHourValue.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$script:FiveHourValue.Location = New-Object Drawing.Point 225, 52
$script:FiveHourValue.Size = New-Object Drawing.Size 90, 34
$script:FiveHourValue.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$script:FiveHourValue.Visible = $false
$script:Form.Controls.Add($script:FiveHourValue)

$script:FiveHourReset = New-Object Windows.Forms.Label
$script:FiveHourReset.Location = New-Object Drawing.Point 20, 88
$script:FiveHourReset.Size = New-Object Drawing.Size 295, 22
$script:FiveHourReset.ForeColor = [Drawing.Color]::DimGray
$script:FiveHourReset.Visible = $false
$script:Form.Controls.Add($script:FiveHourReset)

$script:WeeklyLabel = New-Object Windows.Forms.Label
$script:WeeklyLabel.Text = '本周剩余'
$script:WeeklyLabel.Location = New-Object Drawing.Point 20, 62
$script:WeeklyLabel.Size = New-Object Drawing.Size 100, 24
$script:Form.Controls.Add($script:WeeklyLabel)

$script:WeeklyValue = New-Object Windows.Forms.Label
$script:WeeklyValue.Text = '--%'
$script:WeeklyValue.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$script:WeeklyValue.Location = New-Object Drawing.Point 225, 52
$script:WeeklyValue.Size = New-Object Drawing.Size 90, 34
$script:WeeklyValue.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$script:Form.Controls.Add($script:WeeklyValue)

$script:WeeklyReset = New-Object Windows.Forms.Label
$script:WeeklyReset.Location = New-Object Drawing.Point 20, 88
$script:WeeklyReset.Size = New-Object Drawing.Size 295, 22
$script:WeeklyReset.ForeColor = [Drawing.Color]::DimGray
$script:Form.Controls.Add($script:WeeklyReset)

$script:UpdatedLabel = New-Object Windows.Forms.Label
$script:UpdatedLabel.Location = New-Object Drawing.Point 20, 112
$script:UpdatedLabel.Size = New-Object Drawing.Size 295, 22
$script:UpdatedLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$script:UpdatedLabel.ForeColor = [Drawing.Color]::Gray
$script:Form.Controls.Add($script:UpdatedLabel)

$menu = New-Object Windows.Forms.ContextMenuStrip
$refreshItem = $menu.Items.Add('立即刷新')
$refreshItem.Add_Click({ Request-RateLimits })
$statusBarItem = $menu.Items.Add('显示常驻状态条')
$statusBarItem.CheckOnClick = $true
$statusBarItem.Checked = $true
$statusBarItem.Add_Click({
    $script:StatusBarEnabled = $statusBarItem.Checked
    if ($script:StatusBarEnabled) { Show-StatusBar } else { Hide-StatusBar }
})
$startupItem = $menu.Items.Add('开机启动')
$startupItem.CheckOnClick = $true
$startupItem.Checked = Test-StartupEnabled
$startupItem.Add_Click({
    try { Set-StartupEnabled -Enabled $startupItem.Checked } catch {
        $startupItem.Checked = -not $startupItem.Checked
        [Windows.Forms.MessageBox]::Show("设置开机启动失败：$($_.Exception.Message)", $script:AppName) | Out-Null
    }
})
$menu.Items.Add('-') | Out-Null
$logsItem = $menu.Items.Add('查看日志')
$logsItem.Add_Click({
    $directory = Split-Path -Parent $script:LogPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $directory)
})
$exitItem = $menu.Items.Add('退出')
$exitItem.Add_Click({
    $script:Stopping = $true
    $script:Form.Close()
    [Windows.Forms.Application]::ExitThread()
})

$script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
$script:NotifyIcon.ContextMenuStrip = $menu
$script:StatusForm.ContextMenuStrip = $menu
$script:StatusTextForm.ContextMenuStrip = $menu
$script:StatusLabel.ContextMenuStrip = $menu
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Add_MouseUp({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-MeterWindow }
})
Set-StatusText '正在启动…'
Load-ModelCache

if ($SmokeTest) {
    $script:Form.Show()
    Show-StatusBar
    [Windows.Forms.Application]::DoEvents()
    $script:Form.Hide()
    Hide-StatusBar
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    if ($null -ne $script:LastIcon) { $script:LastIcon.Dispose() }
    $script:Form.Dispose()
    $script:StatusForm.Dispose()
    $script:StatusTextForm.Dispose()
    if ($createdNew) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Write-Host 'Tray UI smoke test passed.' -ForegroundColor Green
    exit
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    try {
        if ($null -ne $script:Process -and $script:Process.HasExited) {
            Write-AppLog "app-server exited: $($script:Process.ExitCode)"
            Schedule-AppServerReconnect "process exited: $($script:Process.ExitCode)"
        }

        if ($null -ne $script:ReadTask -and $script:ReadTask.IsCompleted) {
            try {
                $line = $script:ReadTask.GetAwaiter().GetResult()
            } catch {
                Schedule-AppServerReconnect "stdout read failed: $($_.Exception.Message)"
                return
            }
            if ($null -ne $line) {
                Handle-AppServerLine $line
                if ($null -ne $script:Process -and -not $script:Process.HasExited) {
                    $script:ReadTask = $script:Process.StandardOutput.ReadLineAsync()
                }
            } else {
                # ReadLineAsync returns null when app-server closes stdout. The process
                # can still be alive, so HasExited alone cannot recover this state.
                Schedule-AppServerReconnect 'app-server closed stdout'
            }
        }

        if ($null -ne $script:PendingRateLimitRequestId -and
            ([DateTimeOffset]::Now - $script:PendingRateLimitRequestedAt).TotalSeconds -ge $script:RateLimitRequestTimeoutSeconds) {
            $requestId = $script:PendingRateLimitRequestId
            Schedule-AppServerReconnect "rate-limit request $requestId timed out after $($script:RateLimitRequestTimeoutSeconds)s"
        }

        if ($script:Initialized -and ([DateTimeOffset]::Now - $script:LastPoll).TotalMinutes -ge 1) {
            Request-RateLimits
        }
        if ($null -eq $script:Process -and [DateTimeOffset]::Now -ge $script:NextReconnectAt) {
            Start-AppServer
        }
        Ensure-StatusBarVisible
    } catch {
        Write-AppLog "timer error: $($_.Exception.Message)"
    }
})

$script:Form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:Stopping) { $eventArgs.Cancel = $true; $script:Form.Hide(); return }
    $timer.Stop()
    Stop-AppServer
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    if ($null -ne $script:LastIcon) { $script:LastIcon.Dispose() }
    $script:StatusTextForm.Close()
    $script:StatusTextForm.Dispose()
    $script:StatusForm.Close()
    $script:StatusForm.Dispose()
})

try {
    Start-AppServer
    $timer.Start()
    Show-StatusBar
    Show-MeterWindow
    [Windows.Forms.Application]::Run()
} finally {
    Stop-AppServer
    if ($createdNew) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
