param([switch]$NoAutoStart, [switch]$ShowStatus)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DungeonTrayWindow {
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    public static void Restore(IntPtr window) { ShowWindow(window, 9); SetForegroundWindow(window); }
}
'@
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $taskRoot
[Windows.Forms.Application]::EnableVisualStyles()
$taskKey = ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($taskRoot))).Replace('/','_')
$mutex = [Threading.Mutex]::new($false, 'Local\DungeonCrawlerTray-' + $taskKey)
$openEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'Local\DungeonCrawlerOpen-' + $taskKey)
$statusEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'Local\DungeonCrawlerStatus-' + $taskKey)
if (-not $mutex.WaitOne(0)) {
    if ($ShowStatus) { $null = $statusEvent.Set() } else { $null = $openEvent.Set() }
    $statusEvent.Dispose(); $openEvent.Dispose(); $mutex.Dispose(); exit
}
$script:worker = $null
$script:operation = ''
$script:running = $false
$script:componentsReady = $false
$script:exitRequested = $false
$script:lastMessage = 'Not started.'
$logDirectory = Join-Path $taskRoot 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} PID {1}; NoAutoStart={2}; ShowStatus={3}" -f [DateTime]::UtcNow, $PID, $NoAutoStart, $ShowStatus)
$resultPath = Join-Path $logDirectory 'launcher-result.json'
$errorPath = Join-Path $logDirectory 'launcher-worker.stderr.log'
$config = Get-Content (Join-Path $taskRoot 'config/launcher.json') -Raw | ConvertFrom-Json
$context = [Windows.Forms.ApplicationContext]::new()
$tray = [Windows.Forms.NotifyIcon]::new()
$tray.Icon = [Drawing.Icon]::new((Join-Path $taskRoot 'assets/dungeon.ico'))
$tray.Text = 'Dungeon Crawl - stopped'
$tray.Visible = $true
$menu = [Windows.Forms.ContextMenuStrip]::new()
$tray.ContextMenuStrip = $menu
$control = [Windows.Forms.Form]::new()
$control.Text = 'Dungeon Crawl - launcher'
$control.Icon = $tray.Icon
$control.ClientSize = [Drawing.Size]::new(620, 330)
$control.StartPosition = 'CenterScreen'
$control.FormBorderStyle = 'FixedDialog'
$control.MaximizeBox = $false
$control.BackColor = [Drawing.Color]::FromArgb(19, 13, 9)
$control.ForeColor = [Drawing.Color]::FromArgb(255, 228, 154)
$control.Font = [Drawing.Font]::new('Segoe UI', 10)
$details = [Windows.Forms.TextBox]::new()
$details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
$details.Location = [Drawing.Point]::new(18, 18); $details.Size = [Drawing.Size]::new(584, 224)
$details.BackColor = $control.BackColor; $details.ForeColor = $control.ForeColor
$details.Text = 'Choose Start to check GPU readiness and open the game.'
$control.Controls.Add($details)
foreach ($definition in @(@('Start','Start'),@('Restart','Restart'),@('Stop web','Stop'),@('Readiness','Readiness'),@('Exit','Exit'))) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $definition[0]; $button.Tag = $definition[1]
    $button.Size = [Drawing.Size]::new(106, 36)
    $button.Location = [Drawing.Point]::new(18 + 118 * ($control.Controls.Count - 1), 260)
    $button.add_Click({ param($sender, $eventArgs) if ($sender.Tag -eq 'Exit') { Exit-Dungeon } else { Invoke-DungeonOperation $sender.Tag } })
    $control.Controls.Add($button)
}
$control.add_FormClosing({ param($sender, $eventArgs) if ($eventArgs.CloseReason -eq 'UserClosing') { $eventArgs.Cancel = $true; $control.Hide() } })
function Show-DungeonStatus {
    $details.Text = $script:lastMessage.Replace("`n", "`r`n")
    $control.Show(); $control.Activate()
    [DungeonTrayWindow]::Restore($control.Handle)
    Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} Status window visible={1}" -f [DateTime]::UtcNow, $control.Visible)
}

function Exit-Dungeon {
    if ($script:worker) { return }
    $script:exitRequested = $true
    Invoke-DungeonOperation 'Stop'
}

function Invoke-DungeonOperation([string]$action) {
    if ($script:worker) { return }
    $script:operation = $action
    if ($action -ne 'Status') { $tray.Text = ('Dungeon Crawl - ' + $action + ' in progress') }
    $tray.BalloonTipTitle = 'Dungeon Crawl'
    $tray.BalloonTipText = $(if ($action -eq 'Start' -or $action -eq 'Restart') { 'Checking GPU activity, VRAM and RAM, then preparing the 64K model and web app...' } else { $action + ' in progress...' })
    if ($action -ne 'Status') { $tray.ShowBalloonTip(4000) }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f (Join-Path $PSScriptRoot 'dungeon-worker.ps1'), $action
    $script:worker = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -WorkingDirectory $taskRoot -WindowStyle Hidden -RedirectStandardOutput $resultPath -RedirectStandardError $errorPath -PassThru
    if ($action -ne 'Status') {
        foreach ($item in $menu.Items) { $item.Enabled = $false }
        foreach ($item in $control.Controls) { if ($item -is [Windows.Forms.Button]) { $item.Enabled = $false } }
        $details.Text = $action + ' in progress...'
    }
}

$open = $menu.Items.Add('Open game')
$open.add_Click({ Invoke-DungeonOperation 'Start' })
$start = $menu.Items.Add('Start')
$start.add_Click({ Invoke-DungeonOperation 'Start' })
$restart = $menu.Items.Add('Restart')
$restart.add_Click({ Invoke-DungeonOperation 'Restart' })
$stop = $menu.Items.Add('Stop web app')
$stop.add_Click({ Invoke-DungeonOperation 'Stop' })
$null = $menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$readiness = $menu.Items.Add('Check readiness')
$readiness.add_Click({ Invoke-DungeonOperation 'Readiness' })
$status = $menu.Items.Add('Show last status')
$status.add_Click({ Show-DungeonStatus })
$logs = $menu.Items.Add('Open launcher logs')
$logs.add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f $logDirectory) })
$null = $menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$quit = $menu.Items.Add('Exit')
$quit.add_Click({ Exit-Dungeon })
$tray.add_DoubleClick({ Invoke-DungeonOperation 'Start' })
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 500
$script:ticks = 0
$timer.add_Tick({
    try {
        if ($openEvent.WaitOne(0)) { Invoke-DungeonOperation 'Start' }
        if ($statusEvent.WaitOne(0)) { Show-DungeonStatus }
        if ($script:worker -and $script:worker.HasExited) {
            $result = $null
            try { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } catch { }
            $completed = $script:operation
            $script:worker.Dispose(); $script:worker = $null
            if ($script:exitRequested -and $completed -eq 'Stop') {
                $script:exitRequested = $false
                if ($result -and $result.Ok -and -not $result.Running) {
                    $context.ExitThread()
                    return
                }
                # Keep the tray available when stopping fails so the user can retry.
            }
            if ($result) {
                $statusChanged = $false
                if ($completed -eq 'Status') {
                    $readyNow = [bool]$result.ComponentsReady
                    if (($script:componentsReady -ne $readyNow) -or ($script:running -ne [bool]$result.Running)) {
                        $script:lastMessage = $result.Message
                        $statusChanged = $true
                    }
                    $script:componentsReady = $readyNow
                } elseif ($completed -eq 'Start' -or $completed -eq 'Restart') {
                    $script:componentsReady = [bool]$result.Ok
                } elseif ($completed -eq 'Stop' -and $result.Ok) { $script:componentsReady = $false }
                $script:running = [bool]$result.Running
                if ($completed -ne 'Status') { $script:lastMessage = $result.Message }
                if ($result.Readiness) {
                    $snapshot = $result.Readiness.Snapshot
                    $script:lastMessage += "`n`nModel: $($snapshot.Model) / $($snapshot.Context) tokens`nFree VRAM: $($snapshot.FreeVramGiB) GiB of $($snapshot.TotalVramGiB) GiB`nFree RAM: $($snapshot.FreeRamGiB) GiB`nGPU samples: $(($snapshot.Samples | ForEach-Object { $_.Busiest }) -join ', ') %`nProcesses: $($snapshot.ActiveProcesses)`n$($snapshot.Error)"
                }
                if ($result.Ok -and ($completed -eq 'Start' -or $completed -eq 'Restart')) { Start-Process $config.appUrl }
                if ($completed -ne 'Status' -and (-not $result.Ok -or $completed -eq 'Readiness')) { Show-DungeonStatus }
            } else {
                $script:lastMessage = 'Launcher operation failed. See logs/launcher-worker.stderr.log.'
                $null = [Windows.Forms.MessageBox]::Show($script:lastMessage, 'Dungeon Crawl')
            }
            $tray.Text = 'Dungeon Crawl - ' + $(if ($script:running) { 'running' } else { 'stopped' })
            foreach ($item in $menu.Items) { $item.Enabled = $true }
            foreach ($item in $control.Controls) { if ($item -is [Windows.Forms.Button]) { $item.Enabled = $true } }
            if ($completed -ne 'Status' -or $statusChanged) { $details.Text = $script:lastMessage.Replace("`n", "`r`n") }
            $open.Enabled = $script:running; $stop.Enabled = $script:running; $restart.Enabled = $script:running
        }
        $script:ticks++
        # Lightweight ownership/status check only; GPU sampling is on demand.
        if (-not $script:worker -and $script:ticks % 30 -eq 0) { Invoke-DungeonOperation 'Status' }
    } catch {
        $script:lastMessage = $_.Exception.Message
        $tray.Text = 'Dungeon Crawl - launcher error'
    }
})
try {
    $timer.Start()
    if (-not $NoAutoStart) { Invoke-DungeonOperation 'Start' }
    if ($ShowStatus) { Show-DungeonStatus }
    [Windows.Forms.Application]::Run($context)
} finally {
    $timer.Stop(); $timer.Dispose(); $tray.Visible = $false; $tray.Dispose(); $menu.Dispose(); $context.Dispose()
    $control.Dispose(); $statusEvent.Dispose(); $openEvent.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose()
}
