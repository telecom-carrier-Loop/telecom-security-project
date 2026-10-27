[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('PC1', 'PC2')][string]$Role,
    [ValidateSet('Plan', 'Apply', 'Status', 'Rollback')][string]$Action = 'Plan',
    [string]$StateDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$group = 'Loop Database Scope 20261027'
$hostAddress = if ($Role -eq 'PC1') { '192.168.3.18' } else { '192.168.3.19' }
$legacyName = if ($Role -eq 'PC1') {
    'TCP Query User{A4D94FC7-08DB-49C1-B841-3B17F10DDA73}C:\users\user\appdata\local\programs\dockerdesktop\resources\com.docker.backend.exe'
} else {
    'TCP Query User{0FA4E96A-19B3-497B-AE70-C25397325492}C:\program files\docker\docker\resources\com.docker.backend.exe'
}
if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
    $StateDirectory = Join-Path $env:USERPROFILE ('Downloads/telecom-db-scope-' + $Role)
}
$stateFile = Join-Path $StateDirectory 'state.json'

function Assert-FirewallAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this tool in an elevated Windows PowerShell.'
    }
}
function Save-ScopeState($State) {
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}
function Export-FirewallSnapshot([string]$Path) {
    & netsh.exe advfirewall export $Path
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path)) {
        throw 'Firewall export failed; nothing has been changed.'
    }
}
function Get-ScopePlan {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $hostAddress -ErrorAction SilentlyContinue)
    if ($addresses.Count -ne 1) { throw ('Wrong host: expected local address ' + $hostAddress) }
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $addresses[0].InterfaceIndex)
    if ($profiles.Count -ne 1 -or [string]$profiles[0].NetworkCategory -ne 'Public') {
        throw 'The reviewed interface is not Public; re-audit before changing profiles.'
    }
    $public = Get-NetFirewallProfile -PolicyStore ActiveStore -Name Public
    if ($null -ne $public.PSObject.Properties['AllowLocalFirewallRules'] -and [string]$public.AllowLocalFirewallRules -eq 'False') {
        throw 'Local firewall rules are disabled by policy; use the network administrator policy path.'
    }
    if ([string]$public.DefaultInboundAction -ne 'Block' -or [string]$public.DefaultOutboundAction -ne 'Allow') {
        throw 'Unexpected default firewall policy; re-audit first.'
    }
    $legacy = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $legacyName)
    if ($legacy.Count -ne 1 -or [string]$legacy[0].Enabled -ne 'True' -or
        [string]$legacy[0].Direction -ne 'Inbound' -or [string]$legacy[0].Action -ne 'Allow' -or
        [string]$legacy[0].Profile -ne 'Public') {
        throw 'The reviewed Docker rule has changed; do not disable other rules.'
    }
    $port = @($legacy[0] | Get-NetFirewallPortFilter)
    $address = @($legacy[0] | Get-NetFirewallAddressFilter)
    $application = @($legacy[0] | Get-NetFirewallApplicationFilter)
    $service = @($legacy[0] | Get-NetFirewallServiceFilter)
    if ($port.Count -ne 1 -or [string]$port[0].Protocol -notin @('TCP', '6') -or
        (@($port[0].LocalPort) -join ',') -ne 'Any' -or
        $address.Count -ne 1 -or (@($address[0].RemoteAddress) -join ',') -ne 'Any' -or
        (@($address[0].LocalAddress) -join ',') -ne 'Any' -or
        $application.Count -ne 1 -or $service.Count -ne 1 -or [string]$service[0].Service -ne 'Any') {
        throw 'Docker rule filters differ from the reviewed report.'
    }
    $program = [string]$application[0].Program
    $expectedProgram = $legacyName.Substring($legacyName.IndexOf('}') + 1)
    if ($program -ine $expectedProgram -or -not (Test-Path -LiteralPath $program)) {
        throw 'Unexpected or missing Docker backend program.'
    }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 3306 | Where-Object { $_.LocalAddress -in @('0.0.0.0', $hostAddress) })
    if ($listeners.Count -eq 0) { throw 'No external 3306 listener; inspect the container before applying.' }
    foreach ($listener in $listeners) {
        $process = Get-Process -Id $listener.OwningProcess
        if ([string]$process.Path -ine $program) { throw '3306 is served by an unexpected process; no policy changed.' }
    }
    $prefix = 'Loop-DBScope-' + $Role + '-'
    $dbSources = if ($Role -eq 'PC1') {
        @('127.0.0.1', '::1', '192.168.3.18', '192.168.3.19', '192.168.7.185', '192.168.7.100')
    } else { @('127.0.0.1', '::1', '192.168.3.19') }
    $specs = @(
        @{Name = $prefix + 'Docker-NonDB-TCP'; DisplayName = $prefix + 'Docker TCP except MySQL'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Public'; Protocol = 'TCP'; LocalPort = @('1-3305', '3307-65535'); Program = $program; RemoteAddress = 'Any'; Group = $group},
        @{Name = $prefix + 'MySQL-TCP'; DisplayName = $prefix + 'MySQL approved sources'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Public'; Protocol = 'TCP'; LocalPort = '3306'; Program = $program; RemoteAddress = $dbSources; Group = $group}
    )
    if ($Role -eq 'PC1') {
        $specs += @{Name = $prefix + 'Graylog-UDP'; DisplayName = $prefix + 'Graylog lab senders'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Public'; Protocol = 'UDP'; LocalPort = @('1514', '5140', '12201'); Program = $program; RemoteAddress = @('192.168.3.0/24', '192.168.7.0/24'); Group = $group}
    }
    if (@(Get-NetTCPConnection -State Listen -LocalPort 10050 -ErrorAction SilentlyContinue).Count -gt 0) {
        $specs += @{Name = $prefix + 'Zabbix-Agent-TCP'; DisplayName = $prefix + 'Zabbix server checks'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Public'; Protocol = 'TCP'; LocalPort = '10050'; RemoteAddress = @('192.168.3.18', '192.168.3.19'); Group = $group}
    }
    [pscustomobject]@{Public = $public; Specs = $specs; Program = $program}
}
function Restore-ScopeState($State) {
    if ($State.Format -ne 'loop-db-firewall-v1' -or $State.Role -ne $Role -or
        $State.HostAddress -ne $hostAddress -or $State.LegacyName -cne $legacyName -or
        $State.PreviousPublicEnabled -isnot [bool]) { throw 'Invalid rollback state.' }
    $allowedNames = @('Docker-NonDB-TCP', 'MySQL-TCP', 'Graylog-UDP', 'Zabbix-Agent-TCP') |
        ForEach-Object { 'Loop-DBScope-' + $Role + '-' + $_ }
    foreach ($name in @($State.NewRules)) {
        if ($name -notin $allowedNames) { throw 'Unexpected rule in rollback state.' }
        $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $rule -and [string]$rule.Group -ne $group) { throw 'Rule ownership changed; stop rollback.' }
    }
    Enable-NetFirewallRule -PolicyStore PersistentStore -Name $legacyName
    Set-NetFirewallProfile -Profile Public -Enabled $State.PreviousPublicEnabled
    foreach ($name in @($State.NewRules)) {
        if ($null -ne (Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue)) {
            Remove-NetFirewallRule -PolicyStore PersistentStore -Name $name
        }
    }
    $State.Stage = 'rolled-back'
    Save-ScopeState $State
    Write-Host 'Restored the previous Public profile state and the original Docker rule.'
}

Assert-FirewallAdministrator
if ($Action -eq 'Status') {
    Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name, Enabled, DefaultInboundAction
    if (Test-Path -LiteralPath $stateFile) {
        $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        Write-Host ('Stage: ' + $saved.Stage)
        foreach ($name in @($saved.NewRules)) {
            Get-NetFirewallRule -PolicyStore ActiveStore -Name $name -ErrorAction SilentlyContinue |
                Select-Object Name, Enabled, Action, Profile
        }
    }
    return
}
if ($Action -eq 'Rollback') {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if (@(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $hostAddress -ErrorAction SilentlyContinue).Count -ne 1) { throw 'Wrong host for rollback.' }
    Restore-ScopeState $state
    return
}
$plan = Get-ScopePlan
if ($Action -eq 'Plan') {
    Write-Host ('Host: ' + $Role + ' / ' + $hostAddress)
    Write-Host ('Legacy rule to disable: ' + $legacyName)
    foreach ($spec in $plan.Specs) {
        [pscustomobject]@{Name = $spec.Name; Protocol = $spec.Protocol; LocalPort = $spec.LocalPort -join ','; RemoteAddress = $spec.RemoteAddress -join ','; Profile = 'Public'}
    }
    Write-Host 'Plan only. No settings changed. Only Public will be enabled; other profiles remain unchanged.'
    return
}
if (Test-Path -LiteralPath $stateFile) { throw 'State already exists. Use Status or Rollback; do not repeat Apply.' }
foreach ($spec in $plan.Specs) {
    if ($null -ne (Get-NetFirewallRule -PolicyStore PersistentStore -Name $spec.Name -ErrorAction SilentlyContinue)) {
        throw 'A new rule name already exists; nothing changed.'
    }
}
$null = New-Item -ItemType Directory -Path $StateDirectory -Force
Export-FirewallSnapshot (Join-Path $StateDirectory 'before.wfw')
$state = [pscustomobject]@{
    Format = 'loop-db-firewall-v1'; Role = $Role; HostAddress = $hostAddress; LegacyName = $legacyName
    PreviousPublicEnabled = [bool]([string]$plan.Public.Enabled -eq 'True')
    NewRules = @($plan.Specs | ForEach-Object { $_.Name }); Stage = 'applying'
}
Save-ScopeState $state
try {
    foreach ($spec in $plan.Specs) { $null = New-NetFirewallRule -PolicyStore PersistentStore -Enabled True @spec }
    Disable-NetFirewallRule -PolicyStore PersistentStore -Name $legacyName
    Set-NetFirewallProfile -Profile Public -Enabled True
    $public = Get-NetFirewallProfile -PolicyStore ActiveStore -Name Public
    if ([string]$public.Enabled -ne 'True') { throw 'Public is not effectively enabled.' }
    foreach ($spec in $plan.Specs) {
        $effective = Get-NetFirewallRule -PolicyStore ActiveStore -Name $spec.Name
        if ([string]$effective.Enabled -ne 'True') { throw 'A required local rule is not active.' }
    }
    $effectiveLegacy = Get-NetFirewallRule -PolicyStore ActiveStore -Name $legacyName
    if ([string]$effectiveLegacy.Enabled -ne 'False') { throw 'The broad Docker rule is still enabled.' }
    $state.Stage = 'applied-needs-network-tests'
    Save-ScopeState $state
    Write-Host 'Applied. Verify new external connections, API/replication/backup and monitoring now.'
    Write-Host ('Rollback state: ' + $stateFile)
} catch {
    $failure = $_
    try { Restore-ScopeState $state } catch { Write-Warning ('Automatic rollback failed: ' + $_.Exception.Message) }
    throw $failure
}
