param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$shell = New-Object -ComObject WScript.Shell
Add-Type -Path (Join-Path $PSScriptRoot 'shortcut-app-id.cs')
$executable = Join-Path $taskRoot 'DungeonCrawler.exe'
if (-not $Remove -and -not (Test-Path -LiteralPath $executable)) { throw 'Build DungeonCrawler.exe before installing shortcuts.' }
$locations = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))
foreach ($location in $locations) {
    $shortcutPath = Join-Path $location 'Dungeon Crawl.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        $existing = $shell.CreateShortcut($shortcutPath)
        $legacy = $existing.Arguments -eq ('"{0}"' -f (Join-Path $taskRoot 'Start-DungeonCrawler.vbs'))
        if (-not $legacy -and $existing.TargetPath -ne $executable) { throw "An unrelated shortcut exists at $shortcutPath. Nothing was overwritten." }
    }
    if ($Remove) { Remove-Item -LiteralPath $shortcutPath -ErrorAction SilentlyContinue; continue }
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $taskRoot
    $shortcut.IconLocation = $executable + ',0'
    $shortcut.Description = 'Dungeon Crawl - GPU readiness checks and tray controls'
    $shortcut.Save()
    [DungeonShortcutIdentity]::Set($shortcutPath, 'PopeKael.DungeonCrawler')
    Write-Output $shortcutPath
}
