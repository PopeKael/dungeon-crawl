# One-time private edge installation/migration. Normal startup is unprivileged.
param([ValidateSet('Status', 'Install', 'Repair', 'Remove')][string]$Action = 'Status')
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$config = Get-Content (Join-Path $taskRoot 'config/launcher.json') -Raw | ConvertFrom-Json
$gateway = $config.privateGateway
if (-not $gateway) { throw 'Configure privateGateway in config/launcher.json first.' }
$desktopAddress = [string]$gateway.bind
$nasAddress = [string]$gateway.allowedPeer
$bridgePort = [int]$gateway.port
if ($desktopAddress -ne '192.168.1.100' -or $nasAddress -ne '192.168.1.200' -or $bridgePort -ne 3001 -or $config.port -ne 3000) {
    throw 'This installation script covers only the reviewed desktop/NAS deployment. No changes made.'
}
$ruleNames = @('DungeonCrawler-NAS-Allow', 'DungeonCrawler-Others-Block')
$blockedAddresses = @('0.0.0.0-192.168.1.199', '192.168.1.201-255.255.255.255')
$registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
$registryName = "$desktopAddress/$bridgePort"
$currentTarget = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue).$registryName
if ($Action -eq 'Status') {
    [pscustomobject]@{ Bind = "$desktopAddress`:$bridgePort"; LegacyForwarder = $currentTarget; Mode = 'Application-owned gateway' }
    Get-NetFirewallRule -Name $ruleNames -ErrorAction SilentlyContinue | Select-Object Name, Enabled, Direction, Action
    return
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator permission is required for one-time gateway installation/migration.'
}
if ($currentTarget -and $currentTarget -ne '127.0.0.1/3000') { throw 'Another forwarding rule owns this endpoint. No changes made.' }
if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $desktopAddress -ErrorAction SilentlyContinue)) { throw 'The configured desktop address is not assigned.' }
if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count) { throw 'All Windows Firewall profiles must be enabled.' }

# Validate every existing rule before changing anything. Never repurpose a rule
# whose scope differs from the reviewed NAS-only installation.
foreach ($name in $ruleNames) {
    $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if (-not $rule) { continue }
    $address = $rule | Get-NetFirewallAddressFilter
    $port = $rule | Get-NetFirewallPortFilter
    $expectedAction = if ($name -eq $ruleNames[0]) { 'Allow' } else { 'Block' }
    $expectedRemote = if ($name -eq $ruleNames[0]) { @($nasAddress) } else { $blockedAddresses }
    if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne $expectedAction -or $rule.Profile -ne 'Any' -or
        $address.LocalAddress -ne $desktopAddress -or @(Compare-Object @($address.RemoteAddress) $expectedRemote).Count -ne 0 -or
        $port.Protocol -ne 'TCP' -or $port.LocalPort -ne "$bridgePort") {
        throw "Unexpected firewall scope on $name. No changes made."
    }
}
if ($Action -ne 'Remove') {
    if (-not (Get-NetFirewallRule -Name $ruleNames[1] -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $ruleNames[1] -DisplayName 'DungeonCrawler: block other upstream clients' -Direction Inbound -Action Block -Enabled True -Profile Any -Protocol TCP -LocalAddress $desktopAddress -LocalPort $bridgePort -RemoteAddress $blockedAddresses | Out-Null
    }
    if (-not (Get-NetFirewallRule -Name $ruleNames[0] -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $ruleNames[0] -DisplayName 'DungeonCrawler: allow Synology upstream' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalAddress $desktopAddress -LocalPort $bridgePort -RemoteAddress $nasAddress | Out-Null
    }
}
if ($currentTarget) {
    & netsh.exe interface portproxy delete v4tov4 "listenaddress=$desktopAddress" "listenport=$bridgePort" protocol=tcp
    if ($LASTEXITCODE -ne 0) { throw 'Legacy forwarding removal failed; firewall protection retained.' }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Get-NetTCPConnection -LocalAddress $desktopAddress -LocalPort $bridgePort -State Listen -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (Get-NetTCPConnection -LocalAddress $desktopAddress -LocalPort $bridgePort -State Listen -ErrorAction SilentlyContinue) {
        throw 'The old listener has not closed. Firewall protection retained; stop Dungeon before retrying.'
    }
}
if ($Action -eq 'Remove') {
    if (Get-NetTCPConnection -LocalAddress $desktopAddress -LocalPort $bridgePort -State Listen -ErrorAction SilentlyContinue) { throw 'Stop Dungeon before removing its firewall protection.' }
    Get-NetFirewallRule -Name $ruleNames -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    return
}
Write-Output 'Private gateway installation ready. Legacy Windows forwarding removed; NAS-only firewall retained. Start Dungeon normally.'
