[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = (Resolve-Path (Join-Path $PSScriptRoot '../mysql-firewall-scope.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-firewall-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$fixture = Join-Path $testRoot 'fixture.ps1'
# Elevation is excluded only from this private fixture. Every network mutation below is mocked.
$text = (Get-Content -LiteralPath $source -Raw) -replace '(?m)^Assert-FirewallAdministrator\r?$', '# fixture elevation check'
[IO.File]::WriteAllText($fixture, $text)
function Assert-Scope([bool]$Value, [string]$Message) { if (-not $Value) { throw ('ASSERT: ' + $Message) } }
function New-Case([string]$Role) {
    $program = if ($Role -eq 'PC1') { 'C:\users\user\appdata\local\programs\dockerdesktop\resources\com.docker.backend.exe' } else { 'C:\program files\docker\docker\resources\com.docker.backend.exe' }
    $name = if ($Role -eq 'PC1') { 'TCP Query User{A4D94FC7-08DB-49C1-B841-3B17F10DDA73}' + $program } else { 'TCP Query User{0FA4E96A-19B3-497B-AE70-C25397325492}' + $program }
    $global:FirewallScopeMock = @{
        Program = $program; LegacyName = $name; Public = $false; Profile = 'Public'; WrongIp = $false; WrongOwner = $false
        NativeAgent = $false; FailCreateAt = 0; Creates = 0; DisableCalls = 0; EnableCalls = 0; ProfileCalls = @(); Exports = 0
        Rules = @{}; Ports = 'Any'
    }
    $global:FirewallScopeMock.Rules[$name] = [pscustomobject]@{Name = $name; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Public'; Group = ''}
    Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
}
function global:Get-NetIPAddress { [CmdletBinding()]param($AddressFamily, $IPAddress)
    if (-not $global:FirewallScopeMock.WrongIp) { [pscustomobject]@{InterfaceIndex = 12} }
}
function global:Get-NetConnectionProfile { param($InterfaceIndex) [pscustomobject]@{NetworkCategory = $global:FirewallScopeMock.Profile} }
function global:Get-NetFirewallProfile { param($PolicyStore, $Name)
    [pscustomobject]@{Name = 'Public'; Enabled = [string]$global:FirewallScopeMock.Public; DefaultInboundAction = 'Block'; DefaultOutboundAction = 'Allow'}
}
function global:Get-NetFirewallRule { [CmdletBinding()]param($PolicyStore, $Name)
    if ($global:FirewallScopeMock.Rules.ContainsKey($Name)) { $global:FirewallScopeMock.Rules[$Name] }
    elseif ($ErrorActionPreference -eq 'Stop') { throw 'fixture rule not found' }
}
function global:Get-NetFirewallPortFilter { param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { [pscustomobject]@{Protocol = 'TCP'; LocalPort = $global:FirewallScopeMock.Ports} }
}
function global:Get-NetFirewallAddressFilter { param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { [pscustomobject]@{RemoteAddress = 'Any'; LocalAddress = 'Any'} }
}
function global:Get-NetFirewallApplicationFilter { param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { [pscustomobject]@{Program = $global:FirewallScopeMock.Program} }
}
function global:Get-NetFirewallServiceFilter { param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { [pscustomobject]@{Service = 'Any'} }
}
function global:Get-NetTCPConnection { [CmdletBinding()]param($State, $LocalPort)
    if ($LocalPort -eq 3306 -or $global:FirewallScopeMock.NativeAgent) { [pscustomobject]@{LocalAddress = '0.0.0.0'; OwningProcess = 123} }
}
function global:Get-Process { param($Id)
    [pscustomobject]@{Path = $(if ($global:FirewallScopeMock.WrongOwner) { 'C:\unexpected.exe' } else { $global:FirewallScopeMock.Program })}
}
function global:Test-Path { [CmdletBinding()]param($LiteralPath)
    if ($LiteralPath -eq $global:FirewallScopeMock.Program) { return $true }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function global:netsh.exe {
    $global:FirewallScopeMock.Exports++
    [IO.File]::WriteAllText([string]$args[-1], 'fixture firewall snapshot')
    $global:LASTEXITCODE = 0
}
function global:New-NetFirewallRule { param($PolicyStore, $Enabled, $Name, $DisplayName, $Direction, $Action, $Profile, $Protocol, $LocalPort, $Program, $RemoteAddress, $Group)
    $m = $global:FirewallScopeMock; $m.Creates++
    if ('::1' -in @($RemoteAddress)) { throw 'fixture unsupported IPv6 loopback rule address' }
    if ($m.FailCreateAt -eq $m.Creates) { throw 'fixture creation failure' }
    $m.Rules[$Name] = [pscustomobject]@{Name = $Name; Group = $Group; Enabled = 'True'; Action = $Action; Protocol = $Protocol; LocalPort = $LocalPort; RemoteAddress = $RemoteAddress; Profile = $Profile}
}
function global:Disable-NetFirewallRule { param($PolicyStore, $Name)
    $global:FirewallScopeMock.DisableCalls++; $global:FirewallScopeMock.Rules[$Name].Enabled = 'False'
}
function global:Enable-NetFirewallRule { param($PolicyStore, $Name)
    $global:FirewallScopeMock.EnableCalls++; $global:FirewallScopeMock.Rules[$Name].Enabled = 'True'
}
function global:Set-NetFirewallProfile { param($Profile, $Enabled)
    if ($Enabled -isnot [string] -or $Enabled -notin @('True', 'False')) { throw 'fixture GpoBoolean requires its string name, not System.Boolean' }
    $global:FirewallScopeMock.ProfileCalls += [string]$Profile
    $global:FirewallScopeMock.Public = $Enabled -eq 'True'
}
function global:Remove-NetFirewallRule { param($PolicyStore, $Name) $global:FirewallScopeMock.Rules.Remove($Name) }
function Expect-Guard([string]$Path, [string]$Expected) {
    $message = ''
    try { & $fixture -Role PC1 -Action Apply -StateDirectory $Path } catch { $message = $_.Exception.Message }
    Assert-Scope ($message -like ('*' + $Expected + '*')) ('Expected guard: ' + $Expected + '; got ' + $message)
    Assert-Scope ($global:FirewallScopeMock.Creates -eq 0 -and $global:FirewallScopeMock.DisableCalls -eq 0 -and $global:FirewallScopeMock.ProfileCalls.Count -eq 0) 'Guard changed a firewall setting'
}

$case = New-Case PC1
$null = & $fixture -Role PC1 -Action Plan -StateDirectory $case
Assert-Scope ($global:FirewallScopeMock.Creates -eq 0 -and $global:FirewallScopeMock.Exports -eq 0) 'Plan mutated state'
Write-Host 'PASS: Plan is read only'

$case = New-Case PC1; $global:FirewallScopeMock.WrongIp = $true; Expect-Guard $case 'Wrong host'
$case = New-Case PC1; $global:FirewallScopeMock.Profile = 'Private'; Expect-Guard $case 'not Public'
$case = New-Case PC1; $global:FirewallScopeMock.WrongOwner = $true; Expect-Guard $case 'unexpected process'
$case = New-Case PC1; $global:FirewallScopeMock.Ports = '3306'; Expect-Guard $case 'filters differ'
Write-Host 'PASS: wrong host/profile/process and changed rule fail before mutation'

$case = New-Case PC1
& $fixture -Role PC1 -Action Apply -StateDirectory $case
$m = $global:FirewallScopeMock
Assert-Scope ($m.Public -and $m.Rules[$m.LegacyName].Enabled -eq 'False') 'Apply did not replace the broad rule'
Assert-Scope (($m.Rules['Loop-DBScope-PC1-Docker-NonDB-TCP'].LocalPort -join ',') -eq '1-3305,3307-65535') 'DB leaked through non-DB rule'
Assert-Scope ('192.168.7.185' -in $m.Rules['Loop-DBScope-PC1-MySQL-TCP'].RemoteAddress -and '192.168.7.100' -in $m.Rules['Loop-DBScope-PC1-MySQL-TCP'].RemoteAddress -and '192.168.3.19' -in $m.Rules['Loop-DBScope-PC1-MySQL-TCP'].RemoteAddress) 'API or replica source omitted'
Assert-Scope ('192.168.3.21' -notin $m.Rules['Loop-DBScope-PC1-MySQL-TCP'].RemoteAddress) 'Ordinary user allowed'
Assert-Scope (@($m.ProfileCalls | Where-Object { $_ -ne 'Public' }).Count -eq 0) 'Other profile changed'
Assert-Scope ($m.Rules.ContainsKey('Loop-DBScope-PC1-Graylog-UDP')) 'Graylog UDP preservation missing'
& $fixture -Role PC1 -Action Rollback -StateDirectory $case
Assert-Scope (-not $m.Public -and $m.Rules[$m.LegacyName].Enabled -eq 'True' -and $m.Rules.Count -eq 1) 'Rollback did not restore previous state'
Write-Host 'PASS: PC1 apply preserves DB sources and rollback restores only owned changes'

$case = New-Case PC2; $global:FirewallScopeMock.NativeAgent = $true
& $fixture -Role PC2 -Action Apply -StateDirectory $case
$m = $global:FirewallScopeMock
Assert-Scope (($m.Rules['Loop-DBScope-PC2-MySQL-TCP'].RemoteAddress -join ',') -eq '127.0.0.1,192.168.3.19') 'Replica DB exposed to remote users'
Assert-Scope ($m.Rules.ContainsKey('Loop-DBScope-PC2-Zabbix-Agent-TCP')) 'Listening native Zabbix agent not preserved'
Write-Host 'PASS: PC2 DB remains local and existing native Zabbix listener is preserved'

$case = New-Case PC1; $global:FirewallScopeMock.FailCreateAt = 2
$failed = $false
try { & $fixture -Role PC1 -Action Apply -StateDirectory $case } catch { $failed = $_.Exception.Message -like '*fixture creation failure*' }
$m = $global:FirewallScopeMock
Assert-Scope ($failed -and -not $m.Public -and $m.Rules.Count -eq 1 -and $m.Rules[$m.LegacyName].Enabled -eq 'True') 'Partial failure did not roll back'
Write-Host 'PASS: partial creation failure restores previous policy'

# Reproduce the old interrupted attempt: NonDB rule exists, legacy remains enabled,
# the state file is still applying, and restoring False must bind as GpoBoolean.
$case = New-Case PC1
& $fixture -Role PC1 -Action Apply -StateDirectory $case
$m = $global:FirewallScopeMock
$m.Rules[$m.LegacyName].Enabled = 'True'
$m.Public = $false
$null = $m.Rules.Remove('Loop-DBScope-PC1-MySQL-TCP')
$null = $m.Rules.Remove('Loop-DBScope-PC1-Graylog-UDP')
$statePath = Join-Path $case 'state.json'
$saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$saved.Stage = 'applying'
$saved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
& $fixture -Role PC1 -Action Rollback -StateDirectory $case
Assert-Scope (-not $m.Public -and $m.Rules.Count -eq 1 -and $m.Rules[$m.LegacyName].Enabled -eq 'True') 'Interrupted old attempt was not recovered'
$retry = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
& $fixture -Role PC1 -Action Apply -StateDirectory $retry
Assert-Scope ($m.Public -and $m.Rules[$m.LegacyName].Enabled -eq 'False') 'Retry with a fresh state directory failed'
Write-Host 'PASS: old interrupted state recovers and fresh-state retry applies without IPv6 loopback or Boolean binding'
Write-Host 'PASS: all tests use mocked network cmdlets; live firewall unchanged'
