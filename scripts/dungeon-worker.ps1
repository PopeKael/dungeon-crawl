param([ValidateSet('Start','Stop','Restart','Readiness','Status')][string]$Action = 'Readiness')
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $taskRoot
$logDirectory = Join-Path $taskRoot 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$statePath = Join-Path $logDirectory 'launcher-process.json'
$gatewayStatePath = Join-Path $logDirectory 'launcher-gateway-process.json'
$config = Get-Content (Join-Path $taskRoot 'config/launcher.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'dungeon-readiness.ps1')
. (Join-Path $PSScriptRoot 'dungeon-processes.ps1')

function Get-OwnedWeb {
    Get-DungeonOwnedProcess $statePath
}
function Stop-OwnedWeb {
    Stop-DungeonOwnedProcesses @($gatewayStatePath, $statePath)
}
function Get-PrivateGateway {
    if (-not $config.PSObject.Properties['privateGateway']) {
        if (([uri]$config.appUrl).Scheme -eq 'https') { throw 'HTTPS startup requires privateGateway configuration. See docs/speechify-https.md.' }
        return $null
    }
    $gateway = $config.privateGateway
    if (-not $gateway -or ([uri]$config.appUrl).Scheme -ne 'https') { throw 'Invalid private gateway configuration.' }
    $gateway
}
function Test-GatewayPort($gateway) {
    if (-not $gateway) { return }
    $legacyTarget = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp' -ErrorAction SilentlyContinue).("$($gateway.bind)/$($gateway.port)")
    if ($legacyTarget) { throw 'The old Windows forwarding rule must be migrated once with configure-private-upstream.ps1 -Action Install as Administrator. Normal launches then need no elevation.' }
    $ownedGateway = Get-DungeonOwnedProcess $gatewayStatePath
    $listeners = @(Get-NetTCPConnection -LocalPort $gateway.port -State Listen -ErrorAction SilentlyContinue)
    if (@($listeners | Where-Object { -not $ownedGateway -or $_.OwningProcess -ne $ownedGateway.ProcessId }).Count) {
        throw "Private gateway port $($gateway.port) belongs to an unmanaged process. Nothing was stopped."
    }
}
function Start-PrivateGateway($gateway) {
    if (-not $gateway) { return }
    Test-GatewayPort $gateway
    $ownedGateway = Get-DungeonOwnedProcess $gatewayStatePath
    if (-not $ownedGateway) {
        $node = (Get-Command node.exe -ErrorAction Stop).Source
        $arguments = '"{0}" "{1}"' -f (Join-Path $PSScriptRoot 'dungeon-gateway.mjs'), (Join-Path $taskRoot 'config/launcher.json')
        $child = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $taskRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDirectory 'launcher-gateway.stdout.log') -RedirectStandardError (Join-Path $logDirectory 'launcher-gateway.stderr.log') -PassThru
        Save-DungeonOwnedProcess $child $gatewayStatePath
        $ownedGateway = Get-DungeonOwnedProcess $gatewayStatePath
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $listeners = @(Get-NetTCPConnection -LocalAddress $gateway.bind -LocalPort $gateway.port -State Listen -ErrorAction SilentlyContinue)
        if (@($listeners | Where-Object { $_.OwningProcess -eq $ownedGateway.ProcessId }).Count -eq 1) { return }
        if (-not (Get-DungeonOwnedProcess $gatewayStatePath)) { break }
        Start-Sleep -Milliseconds 250
    }
    throw 'The private gateway did not start. See logs/launcher-gateway.stderr.log.'
}
function Get-Settings {
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $raw = & $node (Join-Path $PSScriptRoot 'launcher-settings.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the saved model settings.' }
    $settings = $raw | ConvertFrom-Json
    $expected = $settings.ollamaUrl.TrimEnd('/')
    $actual = $settings.baseUrl.TrimEnd('/') -replace '/v1(/chat/completions)?$', ''
    $actual = $actual -replace '://localhost:', '://127.0.0.1:'
    $expected = $expected -replace '://localhost:', '://127.0.0.1:'
    if ($settings.provider -ne 'local' -and $actual -ne $expected) { throw 'This launcher currently safeguards the configured local Ollama backend only.' }
    if ($settings.imageBackend -ne 'manual') { throw 'Startup budgeting currently covers Manual prompt only. Disable local image rendering before launch.' }
    $settings
}
function Test-Readiness {
    $settings = Get-Settings
    $gateway = Get-PrivateGateway
    Test-GatewayPort $gateway
    $snapshot = Get-DungeonSnapshot $settings $config
    if ($settings.context -ne 65536) { $snapshot.ModelBudgetGiB = $null }
    Get-DungeonDecision $snapshot $config
}
function Start-Web($decision) {
    if (-not $decision.Ready) { throw ($decision.Reasons -join "`n") }
    $settings = Get-Settings
    $gateway = Get-PrivateGateway
    Test-GatewayPort $gateway
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $next = Join-Path $taskRoot 'node_modules/next/dist/bin/next'
    if (-not (Test-Path -LiteralPath (Join-Path $taskRoot '.next/BUILD_ID'))) { throw 'Production build is missing. Run npm run build in this project first.' }
    # Never replace a listener based solely on its port number.
    $owned = Get-OwnedWeb
    $listeners = @(Get-NetTCPConnection -LocalPort $config.port -State Listen -ErrorAction SilentlyContinue)
    if (@($listeners | Where-Object { -not $owned -or $_.OwningProcess -ne $owned.ProcessId }).Count) {
        throw "Port $($config.port) belongs to an unmanaged process. Close that specific server before using this launcher; nothing was stopped."
    }
    $ollamaUrl = $settings.ollamaUrl.TrimEnd('/')
    try { $null = Invoke-RestMethod ($ollamaUrl + '/api/version') -TimeoutSec 3 } catch {
        if ($ollamaUrl -ne 'http://127.0.0.1:11434' -and $ollamaUrl -ne 'http://localhost:11434') { throw 'Configured Ollama is offline; remote services are not started by this launcher.' }
        $ollama = (Get-Command ollama.exe -ErrorAction Stop).Source
        Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDirectory 'launcher-ollama.stdout.log') -RedirectStandardError (Join-Path $logDirectory 'launcher-ollama.stderr.log') | Out-Null
        $online = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try { $null = Invoke-RestMethod ($ollamaUrl + '/api/version') -TimeoutSec 2; $online = $true; break } catch { Start-Sleep -Milliseconds 500 }
        }
        if (-not $online) { throw 'Ollama did not become ready. See logs/launcher-ollama.stderr.log.' }
    }
    $models = Invoke-RestMethod ($ollamaUrl + '/api/tags') -TimeoutSec 5
    if ($settings.model -notin @($models.models.name)) { throw "Model $($settings.model) is not installed. Nothing will be downloaded automatically." }
    # A model-only request loads the selected allocation without generating prose.
    $payload = @{ model = $settings.model; stream = $false; keep_alive = '30m'; options = @{ num_ctx = $settings.context } } | ConvertTo-Json -Compress
    $null = Invoke-RestMethod ($ollamaUrl + '/api/generate') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 120
    $resident = Invoke-RestMethod ($ollamaUrl + '/api/ps') -TimeoutSec 5
    $model = @($resident.models | Where-Object { $_.name -eq $settings.model -and $_.context_length -eq $settings.context -and $_.size_vram -ge ($_.size * 0.99) })
    if ($model.Count -ne 1) { throw 'The requested 64K model is not fully on GPU. Startup is held; shared Ollama is left running.' }
    if (-not $owned) {
        $arguments = '"{0}" start --hostname 127.0.0.1 --port {1}' -f $next, $config.port
        $child = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $taskRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDirectory 'launcher-web.stdout.log') -RedirectStandardError (Join-Path $logDirectory 'launcher-web.stderr.log') -PassThru
        Save-DungeonOwnedProcess $child $statePath
    }
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $page = Invoke-WebRequest "http://127.0.0.1:$($config.port)/" -UseBasicParsing -TimeoutSec 2
            if ($page.StatusCode -eq 200 -and $page.Content -match '<title>Open Dungeon</title>') { $ready = $true; break }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $ready) { Stop-OwnedWeb; throw 'Web startup failed. See logs/launcher-web.stderr.log.' }
    try { Start-PrivateGateway $gateway } catch { Stop-OwnedWeb; throw }
    # Verify the actual user-facing route as well; do not silently substitute HTTP.
    try {
        $page = Invoke-WebRequest $config.appUrl -UseBasicParsing -TimeoutSec 10
        if ($page.StatusCode -ne 200 -or $page.Content -notmatch '<title>Open Dungeon</title>') { throw 'The configured URL did not return the Dungeon application.' }
    } catch {
        throw "Dungeon processes are running, but the browser route failed verification. Check Synology and DNS/hosts. HTTPS error: $($_.Exception.Message)"
    }
    [pscustomobject]@{ Ok = $true; Running = $true; Message = 'Ready: 64K model on GPU; private HTTPS verified.'; Url = $config.appUrl; Readiness = $decision }
}

$lock = [Threading.Mutex]::new($false, 'Local\DungeonCrawlerLifecycle-' + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($taskRoot))).Replace('\','_').Replace('/','_'))
$locked = $false
try {
    $locked = $lock.WaitOne(0)
    if (-not $locked) { throw 'Another launcher operation is in progress. Retry after it completes.' }
    switch ($Action) {
        'Readiness' { $decision = Test-Readiness; $result = @{ Ok = $decision.Ready; Running = [bool](Get-OwnedWeb); Message = $(if ($decision.Ready) { 'Ready to start.' } else { $decision.Reasons -join "`n" }); Readiness = $decision } }
        'Status' {
            $web = Get-OwnedWeb; $gateway = Get-PrivateGateway; $edge = Get-DungeonOwnedProcess $gatewayStatePath
            $webListening = $web -and @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $config.port -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $web.ProcessId).Count -eq 1
            $edgeListening = -not $gateway -or ($edge -and @(Get-NetTCPConnection -LocalAddress $gateway.bind -LocalPort $gateway.port -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $edge.ProcessId).Count -eq 1)
            $healthy = $webListening -and $edgeListening
            $result = @{ Ok = $true; Running = [bool]$web -or [bool]$edge; ComponentsReady = $healthy; Message = $(if ($healthy) { 'Dungeon processes are running.' } elseif ($web -or $edge) { 'A Dungeon component stopped. Choose Start to restore the complete application.' } else { 'Dungeon is stopped.' }) }
        }
        'Stop' { Stop-OwnedWeb; $result = @{ Ok = $true; Running = $false; Message = 'Dungeon web app and private gateway stopped. Shared Ollama and other applications were left running.' } }
        'Start' { $result = Start-Web (Test-Readiness) }
        'Restart' { $decision = Test-Readiness; if (-not $decision.Ready) { throw ($decision.Reasons -join "`n") }; Stop-OwnedWeb; $result = Start-Web $decision }
    }
    $result | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath (Join-Path $logDirectory ('launcher-last-' + $Action.ToLowerInvariant() + '.json'))
    $result | ConvertTo-Json -Depth 8 -Compress
} catch {
    @{ Ok = $false; Running = [bool]((Test-Path -LiteralPath $statePath) -or (Test-Path -LiteralPath $gatewayStatePath)); Message = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($locked) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
