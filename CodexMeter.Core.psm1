Set-StrictMode -Version Latest

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertFrom-CodexWindow {
    param($Window)

    if ($null -eq $Window) { return $null }

    $used = [double](Get-PropertyValue -Object $Window -Name 'usedPercent' -Default 0)
    $duration = [int](Get-PropertyValue -Object $Window -Name 'windowDurationMins' -Default 0)
    $resetSeconds = [long](Get-PropertyValue -Object $Window -Name 'resetsAt' -Default 0)
    $remaining = [Math]::Max(0, [Math]::Min(100, [Math]::Round(100 - $used)))
    $resetAt = $null
    if ($resetSeconds -gt 0) {
        $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($resetSeconds).ToLocalTime()
    }

    [pscustomobject]@{
        UsedPercent      = $used
        RemainingPercent = [int]$remaining
        DurationMinutes  = $duration
        ResetsAt         = $resetAt
    }
}

function ConvertFrom-CodexRateLimits {
    param([Parameter(Mandatory = $true)]$RateLimits)

    $windows = @()
    foreach ($name in @('primary', 'secondary')) {
        $value = Get-PropertyValue -Object $RateLimits -Name $name
        $parsed = ConvertFrom-CodexWindow -Window $value
        if ($null -ne $parsed) { $windows += $parsed }
    }

    $ordered = @($windows | Sort-Object DurationMinutes)
    $session = if ($ordered.Count -gt 0) { $ordered[0] } else { $null }
    $weekly = if ($ordered.Count -gt 1) { $ordered[-1] } else { $session }

    [pscustomobject]@{
        Session          = $session
        Weekly           = $weekly
        PlanType         = Get-PropertyValue -Object $RateLimits -Name 'planType' -Default ''
        LimitReachedType = Get-PropertyValue -Object $RateLimits -Name 'rateLimitReachedType'
        UpdatedAt        = [DateTimeOffset]::Now
    }
}

function Get-CodexMeterColor {
    param([int]$RemainingPercent)

    if ($RemainingPercent -le 15) { return '#DC3545' }
    if ($RemainingPercent -le 40) { return '#F0A202' }
    return '#19A974'
}

function Format-CodexResetTime {
    param($ResetsAt)
    if ($null -eq $ResetsAt) { return '未知' }
    return ([DateTimeOffset]$ResetsAt).ToString('MM-dd HH:mm')
}

Export-ModuleMember -Function ConvertFrom-CodexRateLimits, Get-CodexMeterColor, Format-CodexResetTime
