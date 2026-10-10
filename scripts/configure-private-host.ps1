param([switch]$Install)
$ErrorActionPreference = 'Stop'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostName = 'dungeon.dia.net.au'
$line = '192.168.1.200 dungeon.dia.net.au # DungeonCrawler private HTTPS'
$contents = [IO.File]::ReadAllText($hostsPath)
$matches = @($contents -split '\r?\n' | Where-Object {
    (($_ -split '#', 2)[0] -split '\s+') -contains $hostName
})
if (-not $Install) { $matches; return }
if ($matches.Count) {
    if ($matches.Count -eq 1 -and $matches[0].Trim() -eq $line) {
        'Dungeon private hostname is already configured.'; return
    }
    throw 'An existing dungeon hosts entry needs review; no changes made.'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Open PowerShell as Administrator to install the private hostname.' }
$backupPath = Join-Path $PSScriptRoot '..\logs\hosts-before-dungeon.txt'
if (-not (Test-Path -LiteralPath $backupPath)) { [IO.File]::Copy($hostsPath, $backupPath) }
[IO.File]::AppendAllText($hostsPath, "`r`n$line`r`n", [Text.UTF8Encoding]::new($false))
& ipconfig.exe /flushdns | Out-Null
'Dungeon private hostname configured.'
