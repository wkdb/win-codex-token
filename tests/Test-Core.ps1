$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CodexMeter.Core.psm1') -Force

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { throw "$Name failed: expected '$Expected', got '$Actual'" }
}

$limits = [pscustomobject]@{
    primary = [pscustomobject]@{ usedPercent = 25; windowDurationMins = 300; resetsAt = 1785110400 }
    secondary = [pscustomobject]@{ usedPercent = 18; windowDurationMins = 10080; resetsAt = 1785542400 }
    planType = 'plus'
    rateLimitReachedType = $null
}

$model = ConvertFrom-CodexRateLimits $limits
Assert-Equal 75 $model.Session.RemainingPercent 'session remaining'
Assert-Equal 75 $model.FiveHour.RemainingPercent 'five-hour remaining'
Assert-Equal 300 $model.FiveHour.DurationMinutes 'five-hour classification'
Assert-Equal 82 $model.Weekly.RemainingPercent 'weekly remaining'
Assert-Equal 10080 $model.Weekly.DurationMinutes 'weekly classification'
Assert-Equal '#19A974' (Get-CodexMeterColor 82) 'green color'
Assert-Equal '#F0A202' (Get-CodexMeterColor 30) 'yellow color'
Assert-Equal '#DC3545' (Get-CodexMeterColor 10) 'red color'

$reversed = [pscustomobject]@{ primary = $limits.secondary; secondary = $limits.primary }
$reversedModel = ConvertFrom-CodexRateLimits $reversed
Assert-Equal 82 $reversedModel.Weekly.RemainingPercent 'duration-based classification'
Assert-Equal 75 $reversedModel.FiveHour.RemainingPercent 'five-hour reversed classification'

$weeklyOnly = ConvertFrom-CodexRateLimits ([pscustomobject]@{ primary = $limits.secondary })
Assert-Equal $null $weeklyOnly.FiveHour 'missing five-hour fallback'
Assert-Equal 82 $weeklyOnly.Weekly.RemainingPercent 'weekly-only remaining'

Write-Host 'All core tests passed.' -ForegroundColor Green
