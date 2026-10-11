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
. (Join-Path $PSScriptRoot 'dungeon-processes.ps1')
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
$script:exitAfterStop = $false
$script:exitInProgress = $false
$script:splash = $null
$script:splashArtwork = $null
$script:splashProgress = $null
$script:splashStep = $null
$script:splashMessage = $null
$script:lastMessage = 'Not started.'
$logDirectory = Join-Path $taskRoot 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} PID {1}; NoAutoStart={2}; ShowStatus={3}" -f [DateTime]::UtcNow, $PID, $NoAutoStart, $ShowStatus)
$progressPath = Join-Path $logDirectory 'launcher-progress.json'
$script:activeResultPath = $null
$script:activeErrorPath = $null
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
$details.Text = 'Start Dungeon to prepare the narrator and renderer and open the page. Use Open web page to return to a running session, or Shut down to release Dungeon workloads.'
$control.Controls.Add($details)
# Keep a live form attached to the message loop while it is hidden. Without a
# MainForm, disposing the startup splash can end Application.Run and remove the
# tray icon before the user can retry, open the page or exit cleanly.
$context.MainForm = $control
$script:startButton = $null
$script:openPageButton = $null
$script:stopButton = $null
foreach ($definition in @(@('Start Dungeon','Start'),@('Open web page','Open'),@('Shut down','Stop'))) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $definition[0]; $button.Tag = $definition[1]
    $button.Size = [Drawing.Size]::new(180, 42)
    $button.Location = [Drawing.Point]::new(18 + 200 * ($control.Controls.Count - 1), 260)
    if ($definition[1] -eq 'Start') { $script:startButton = $button }
    if ($definition[1] -eq 'Open') { $script:openPageButton = $button; $button.Enabled = $false }
    if ($definition[1] -eq 'Stop') { $script:stopButton = $button; $button.Enabled = $false }
    $button.add_Click({ param($sender, $eventArgs) if ($sender.Tag -eq 'Open') { Open-DungeonPage } else { Invoke-DungeonOperation $sender.Tag } })
    $control.Controls.Add($button)
}
$control.add_FormClosing({ param($sender, $eventArgs) if ($eventArgs.CloseReason -eq 'UserClosing') { $eventArgs.Cancel = $true; $control.Hide() } })

function Show-DungeonSplash {
    if (-not $script:splash) {
        $script:splash = [Windows.Forms.Form]::new()
        $script:splash.Text = 'Dungeon Crawl is starting'
        $script:splash.ClientSize = [Drawing.Size]::new(640, 480)
        $script:splash.StartPosition = 'CenterScreen'
        $script:splash.FormBorderStyle = 'None'
        $script:splash.ShowInTaskbar = $false
        $script:splash.TopMost = $true
        $script:splash.BackColor = [Drawing.Color]::FromArgb(14, 12, 10)
        $artPath = Join-Path $taskRoot 'assets/dungeon-startup.png'
        if (Test-Path -LiteralPath $artPath) {
            $script:splashArtwork = [Drawing.Image]::FromFile($artPath)
            $script:splash.BackgroundImage = $script:splashArtwork
            $script:splash.BackgroundImageLayout = 'Stretch'
        }

        $title = [Windows.Forms.Label]::new()
        $title.Text = 'DUNGEON CRAWL'
        $title.Location = [Drawing.Point]::new(28, 24)
        $title.Size = [Drawing.Size]::new(450, 38)
        $title.Font = [Drawing.Font]::new('Georgia', 22, [Drawing.FontStyle]::Bold)
        $title.ForeColor = [Drawing.Color]::FromArgb(255, 239, 205)
        $title.BackColor = [Drawing.Color]::FromArgb(0, 0, 0, 0)
        $script:splash.Controls.Add($title)

        $subtitle = [Windows.Forms.Label]::new()
        $subtitle.Text = 'AETHELGARD AWAITS'
        $subtitle.Location = [Drawing.Point]::new(31, 66)
        $subtitle.Size = [Drawing.Size]::new(350, 28)
        $subtitle.Font = [Drawing.Font]::new('Segoe UI', 12, [Drawing.FontStyle]::Italic)
        $subtitle.ForeColor = [Drawing.Color]::FromArgb(255, 201, 121)
        $subtitle.BackColor = [Drawing.Color]::FromArgb(0, 0, 0, 0)
        $script:splash.Controls.Add($subtitle)

        $card = [Windows.Forms.Panel]::new()
        $card.Location = [Drawing.Point]::new(18, 340)
        $card.Size = [Drawing.Size]::new(604, 122)
        $card.BackColor = [Drawing.Color]::FromArgb(220, 15, 12, 10)
        $script:splash.Controls.Add($card)

        $script:splashStep = [Windows.Forms.Label]::new()
        $script:splashStep.Location = [Drawing.Point]::new(16, 10)
        $script:splashStep.Size = [Drawing.Size]::new(560, 21)
        $script:splashStep.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold)
        $script:splashStep.ForeColor = [Drawing.Color]::FromArgb(255, 198, 111)
        $script:splashStep.BackColor = $card.BackColor
        $card.Controls.Add($script:splashStep)

        $script:splashMessage = [Windows.Forms.Label]::new()
        $script:splashMessage.Location = [Drawing.Point]::new(16, 34)
        $script:splashMessage.Size = [Drawing.Size]::new(560, 24)
        $script:splashMessage.Font = [Drawing.Font]::new('Segoe UI', 10)
        $script:splashMessage.ForeColor = [Drawing.Color]::FromArgb(245, 239, 224)
        $script:splashMessage.BackColor = $card.BackColor
        $card.Controls.Add($script:splashMessage)

        $script:splashProgress = [Windows.Forms.ProgressBar]::new()
        $script:splashProgress.Location = [Drawing.Point]::new(16, 65)
        $script:splashProgress.Size = [Drawing.Size]::new(568, 17)
        $script:splashProgress.Minimum = 0
        $script:splashProgress.Maximum = 100
        $script:splashProgress.Style = 'Blocks'
        $card.Controls.Add($script:splashProgress)

        $credit = [Windows.Forms.Label]::new()
        $credit.Text = "A story engine by Warren 'Wazza' Gerdes"
        $credit.Location = [Drawing.Point]::new(16, 91)
        $credit.Size = [Drawing.Size]::new(560, 20)
        $credit.Font = [Drawing.Font]::new('Segoe UI', 8)
        $credit.ForeColor = [Drawing.Color]::FromArgb(190, 193, 177, 155)
        $credit.BackColor = $card.BackColor
        $card.Controls.Add($credit)
    }

    $script:splashStep.Text = 'STARTING DUNGEON - STEP 1 OF 6'
    $script:splashMessage.Text = 'Checking GPU load, memory headroom and saved settings'
    $script:splashProgress.Value = 0
    $script:splash.Show()
    $script:splash.Activate()
    [Windows.Forms.Application]::DoEvents()
}

function Update-DungeonSplash {
    if (-not $script:splash -or -not $script:splash.Visible) { return }
    try {
        $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
        $percent = [Math]::Max(0, [Math]::Min(100, [int]$progress.percent))
        $step = [Math]::Max(1, [Math]::Min(6, [int]$progress.step))
        $script:splashProgress.Value = $percent
        $script:splashStep.Text = "STARTING DUNGEON - STEP $step OF 6"
        $script:splashMessage.Text = [string]$progress.message + ('.' * (1 + ($script:ticks % 3)))
    } catch { }
}

function Close-DungeonSplash {
    if (-not $script:splash) { return }
    $script:splash.Close()
    $script:splash.Dispose()
    if ($script:splashArtwork) { $script:splashArtwork.Dispose() }
    $script:splash = $null
    $script:splashArtwork = $null
    $script:splashProgress = $null
    $script:splashStep = $null
    $script:splashMessage = $null
}

function Exit-DungeonLauncher {
    if ($script:exitInProgress) { return }
    $script:exitInProgress = $true
    $script:lastMessage = 'Exiting Dungeon Crawl and releasing its workloads.'
    $tray.Text = 'Dungeon Crawl - exiting'
    $exit.Enabled = $false
    if ($control.Visible) { $details.Text = $script:lastMessage }
    $errors = [Collections.Generic.List[string]]::new()

    # Do not queue Exit behind a startup or shutdown worker. Terminate the
    # worker, then use recorded PID/start-time/path identities for its children.
    if ($script:worker) {
        try {
            if (-not $script:worker.HasExited) {
                Stop-Process -Id $script:worker.Id -Force -ErrorAction Stop
                $null = $script:worker.WaitForExit(1500)
            }
        } catch { $errors.Add('Launcher worker: ' + $_.Exception.Message) }
        try { $script:worker.Dispose() } catch { }
        $script:worker = $null
    }

    $ownedStatePaths = @(
        (Join-Path $logDirectory 'launcher-image-action-process.json'),
        (Join-Path $taskRoot 'runtime/sd-cpp-vulkan/state/backend-process.json'),
        (Join-Path $logDirectory 'launcher-gateway-process.json'),
        (Join-Path $logDirectory 'launcher-process.json')
    )
    foreach ($statePath in $ownedStatePaths) {
        try { Stop-DungeonOwnedProcesses @($statePath) -Force }
        catch { $errors.Add(([IO.Path]::GetFileName($statePath) + ': ' + $_.Exception.Message)) }
    }

    try {
        $node = (Get-Command node.exe -ErrorAction Stop).Source
        $settings = (& $node (Join-Path $PSScriptRoot 'launcher-settings.mjs')) | ConvertFrom-Json
        $null = Stop-DungeonOllamaServer $settings.ollamaUrl (Join-Path $logDirectory 'launcher-ollama-process.json') -Force
    } catch { $errors.Add('Ollama: ' + $_.Exception.Message) }

    if ($errors.Count) {
        $message = 'Dungeon Crawl is exiting. Some process identities could not be verified or stopped:' + "`r`n" + ($errors -join "`r`n")
        try { Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-exit.log') -Value ("{0:o} {1}" -f [DateTime]::UtcNow, $message) } catch { }
        [Windows.Forms.MessageBox]::Show($message, 'Dungeon Crawl - shutdown details', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
    $tray.Visible = $false
    $context.ExitThread()
}

function Show-DungeonStatus {
    $details.Text = $script:lastMessage.Replace("`n", "`r`n")
    $control.Show(); $control.Activate()
    [DungeonTrayWindow]::Restore($control.Handle)
    Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} Status window visible={1}" -f [DateTime]::UtcNow, $control.Visible)
}

function Open-DungeonPage {
    if (-not $script:running) {
        Invoke-DungeonOperation 'Start'
        return
    }
    try {
        Start-Process $config.appUrl
        $script:lastMessage = 'Dungeon is running. Opened the web page.'
        if ($control.Visible) { $details.Text = $script:lastMessage }
    } catch {
        $script:lastMessage = 'Could not open the web page: ' + $_.Exception.Message
        Show-DungeonStatus
    }
}

function Invoke-DungeonOperation([string]$action) {
    if ($script:worker) { return }
    if ($action -eq 'Open' -or ($action -eq 'Start' -and $script:running)) {
        Open-DungeonPage
        return
    }
    if ($action -eq 'Start') {
        Set-Content -LiteralPath $progressPath -Value (@{ percent = 0; step = 1; steps = 6; message = 'Checking GPU load, memory headroom and saved settings' } | ConvertTo-Json -Compress) -Encoding UTF8
        Show-DungeonSplash
    }
    $script:operation = $action
    if ($action -ne 'Status') { $tray.Text = ('Dungeon Crawl - ' + $action + ' in progress') }
    $tray.BalloonTipTitle = 'Dungeon Crawl'
    $tray.BalloonTipText = $(if ($action -eq 'Start' -or $action -eq 'Restart') { 'Checking GPU activity, VRAM and RAM, then preparing the 64K model and web app...' } else { $action + ' in progress...' })
    if ($action -ne 'Status') { $tray.ShowBalloonTip(4000) }
    # A child started by the worker can outlive it and inherit its redirected
    # stdout/stderr handles. Give each invocation private files so an old
    # background process cannot block the next launch when it truncates logs.
    $invocationId = [guid]::NewGuid().ToString('N')
    $script:activeResultPath = Join-Path $logDirectory ('launcher-worker-' + $action.ToLowerInvariant() + '-' + $invocationId + '.json')
    $script:activeErrorPath = Join-Path $logDirectory ('launcher-worker-' + $action.ToLowerInvariant() + '-' + $invocationId + '.stderr.log')
    Set-Content -LiteralPath $script:activeResultPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $script:activeErrorPath -Value '' -Encoding UTF8
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action {1} -ProgressPath "{2}"' -f (Join-Path $PSScriptRoot 'dungeon-worker.ps1'), $action, $progressPath
    try {
        $script:worker = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -WorkingDirectory $taskRoot -WindowStyle Hidden -RedirectStandardOutput $script:activeResultPath -RedirectStandardError $script:activeErrorPath -PassThru
        Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} Started {1} worker PID {2}" -f [DateTime]::UtcNow, $action, $script:worker.Id)
    } catch {
        if ($action -eq 'Start' -or $action -eq 'Restart') { Close-DungeonSplash }
        $script:lastMessage = "Could not start the $action worker: $($_.Exception.Message)"
        Show-DungeonStatus
        foreach ($item in $menu.Items) { $item.Enabled = $true }
        foreach ($item in $control.Controls) { if ($item -is [Windows.Forms.Button]) { $item.Enabled = $true } }
        return
    }
    if ($action -ne 'Status') {
        foreach ($item in $menu.Items) { if ($item -ne $exit) { $item.Enabled = $false } }
        foreach ($item in $control.Controls) { if ($item -is [Windows.Forms.Button]) { $item.Enabled = $false } }
        $details.Text = $action + ' in progress...'
    }
}

$open = $menu.Items.Add('Open web page')
$open.add_Click({ Open-DungeonPage })
$start = $menu.Items.Add('Start Dungeon')
$start.add_Click({ Invoke-DungeonOperation 'Start' })
$stop = $menu.Items.Add('Shut down Dungeon')
$stop.add_Click({ Invoke-DungeonOperation 'Stop' })
$exit = $menu.Items.Add('Exit')
$exit.ToolTipText = 'Shut down Dungeon workloads, then exit the launcher.'
$exit.add_Click({ Exit-DungeonLauncher })
$start.Enabled = $false
$open.Enabled = $false
$stop.Enabled = $false
$exit.Enabled = $true
$tray.add_DoubleClick({ if ($script:running) { Open-DungeonPage } else { Invoke-DungeonOperation 'Start' } })
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 500
$script:ticks = 0
$timer.add_Tick({
    try {
        Update-DungeonSplash
        if ($openEvent.WaitOne(0)) { Open-DungeonPage }
        if ($statusEvent.WaitOne(0)) { Show-DungeonStatus }
        if ($script:worker -and $script:worker.HasExited) {
            $result = $null
            $workerExitCode = $script:worker.ExitCode
            Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} {1} worker PID {2} exited with code {3}" -f [DateTime]::UtcNow, $script:operation, $script:worker.Id, $workerExitCode)
            try { $result = Get-Content -LiteralPath $script:activeResultPath -Raw | ConvertFrom-Json } catch { }
            $completed = $script:operation
            $script:worker.Dispose(); $script:worker = $null
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
                if ($result.Ok -and ($completed -eq 'Start' -or $completed -eq 'Restart')) {
                    Close-DungeonSplash
                    Start-Process $config.appUrl
                }
                if ($completed -ne 'Status' -and -not $result.Ok) { Show-DungeonStatus }
                if ($completed -eq 'Start' -and -not $result.Ok) { Close-DungeonSplash }
                $exitNow = $completed -eq 'Stop' -and $script:exitAfterStop -and $result.Ok -and -not $script:running
                if ($completed -eq 'Stop') { $script:exitAfterStop = $false }
            } else {
                if ($completed -eq 'Start') { Close-DungeonSplash }
                $workerError = if ($script:activeErrorPath -and (Test-Path -LiteralPath $script:activeErrorPath)) { (Get-Content -LiteralPath $script:activeErrorPath -Raw).Trim() } else { '' }
                $script:lastMessage = "The $completed worker exited without a result (exit code $workerExitCode)."
                if ($workerError) { $script:lastMessage += "`n`n$workerError" }
                $script:lastMessage += "`n`nSee $script:activeErrorPath for worker details. Choose Start to retry or Exit to run a clean shutdown."
                $script:running = (Test-Path -LiteralPath (Join-Path $logDirectory 'launcher-process.json')) -or
                    (Test-Path -LiteralPath (Join-Path $logDirectory 'launcher-gateway-process.json'))
                $script:componentsReady = $false
                $script:exitAfterStop = $false
                Show-DungeonStatus
                $exitNow = $false
            }
            $tray.Text = 'Dungeon Crawl - ' + $(if ($script:running) { 'running' } else { 'stopped' })
            foreach ($item in $menu.Items) { $item.Enabled = $true }
            foreach ($item in $control.Controls) { if ($item -is [Windows.Forms.Button]) { $item.Enabled = $true } }
            $script:startButton.Enabled = -not $script:running
            $script:openPageButton.Enabled = $script:running
            $script:stopButton.Enabled = $script:running
            if ($completed -ne 'Status' -or $statusChanged) { $details.Text = $script:lastMessage.Replace("`n", "`r`n") }
            $open.Enabled = $true; $start.Enabled = -not $script:running; $stop.Enabled = $script:running
            $exit.Enabled = $true
            if ($exitNow) { $context.ExitThread() }
        }
        $script:ticks++
        # Lightweight ownership/status check only; GPU sampling is on demand.
        if (-not $script:worker -and $script:ticks % 30 -eq 0) { Invoke-DungeonOperation 'Status' }
    } catch {
        $script:lastMessage = $_.Exception.Message
        $tray.Text = 'Dungeon Crawl - launcher error'
        try { Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} Timer error during {1}: {2}" -f [DateTime]::UtcNow, $script:operation, $_.Exception.ToString()) } catch { }
        if ($control.Visible) { $details.Text = $script:lastMessage }
    }
})
try {
    $timer.Start()
    if (-not $NoAutoStart) { Invoke-DungeonOperation 'Start' } else { Invoke-DungeonOperation 'Status' }
    if ($ShowStatus) { Show-DungeonStatus }
    [Windows.Forms.Application]::Run($context)
} finally {
    try { Add-Content -LiteralPath (Join-Path $logDirectory 'launcher-tray.log') -Value ("{0:o} Tray loop exiting; operation={1}; workerPid={2}" -f [DateTime]::UtcNow, $script:operation, $(if ($script:worker) { $script:worker.Id } else { 'none' })) } catch { }
    $timer.Stop(); $timer.Dispose(); $tray.Visible = $false; $tray.Dispose(); $menu.Dispose(); $context.Dispose()
    $control.Dispose(); $statusEvent.Dispose(); $openEvent.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose()
}
