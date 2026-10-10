# Run in an elevated PowerShell window only after reviewing docs/speechify-https.md.
# Keeps Next.js on localhost; exposes a separate TCP bridge only to the NAS.
param([ValidateSet('Status', 'Install', 'Remove')][string]$Action = 'Status')
$ErrorActionPreference = 'Stop'
$desktopAddress = '192.168.1.100'
$nasAddress = '192.168.1.200'
$bridgePort = 3001
$ruleNames = @('DungeonCrawler-NAS-Allow', 'DungeonCrawler-Others-Block')
$registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
$registryName = "$desktopAddress/$bridgePort"
$expectedTarget = '127.0.0.1/3000'
$currentTarget = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue).$registryName

if ($Action -eq 'Status') {
    [pscustomobject]@{ Bridge = $registryName; Target = $currentTarget; Expected = $expectedTarget }
    Get-NetFirewallRule -Name $ruleNames -ErrorAction SilentlyContinue |
        Select-Object Name, Enabled, Direction, Action
    return
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Open PowerShell as Administrator to change the private upstream.' }
if ($currentTarget -and $currentTarget -ne $expectedTarget) {
    throw "Another forwarding rule owns $registryName. No changes made."
}
if ($Action -eq 'Remove') {
    # Remove the listening bridge before its firewall protection.
    if ($currentTarget) {
        & netsh.exe interface portproxy delete v4tov4 "listenaddress=$desktopAddress" "listenport=$bridgePort" protocol=tcp
        if ($LASTEXITCODE -ne 0) { throw 'Bridge removal failed; firewall protection retained.' }
    }
    Get-NetFirewallRule -Name $ruleNames -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    return
}
if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $desktopAddress -ErrorAction SilentlyContinue)) {
    throw 'The expected desktop address is not assigned. No changes made.'
}
if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count) {
    throw 'All Windows Firewall profiles must be enabled. No changes made.'
}
if ((Get-Service iphlpsvc).Status -ne 'Running') {
    throw 'Windows IP Helper is not running. No changes made.'
}
if (-not (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue)) {
    throw 'Start the game on 127.0.0.1:3000 first. No changes made.'
}
if (-not $currentTarget -and (Get-NetTCPConnection -LocalAddress $desktopAddress -LocalPort $bridgePort -State Listen -ErrorAction SilentlyContinue)) {
    throw 'The bridge port is already occupied. No changes made.'
}
# Explicit blocks override ordinary broad allow rules. These ranges exclude only the NAS.
$blockedAddresses = @('0.0.0.0-192.168.1.199', '192.168.1.201-255.255.255.255')
if (-not (Get-NetFirewallRule -Name $ruleNames[1] -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleNames[1] -DisplayName 'DungeonCrawler: block other upstream clients' `
        -Direction Inbound -Action Block -Enabled True -Profile Any -Protocol TCP `
        -LocalAddress $desktopAddress -LocalPort $bridgePort -RemoteAddress $blockedAddresses | Out-Null
}
if (-not (Get-NetFirewallRule -Name $ruleNames[0] -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleNames[0] -DisplayName 'DungeonCrawler: allow Synology upstream' `
        -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP `
        -LocalAddress $desktopAddress -LocalPort $bridgePort -RemoteAddress $nasAddress | Out-Null
}
if (-not $currentTarget) {
    & netsh.exe interface portproxy add v4tov4 "listenaddress=$desktopAddress" "listenport=$bridgePort" `
        connectaddress=127.0.0.1 connectport=3000 protocol=tcp
    if ($LASTEXITCODE -ne 0) { throw 'Bridge creation failed; restrictive firewall rules retained.' }
}
Write-Output 'Private upstream installed. Verify access from Synology before saving the reverse proxy.'
