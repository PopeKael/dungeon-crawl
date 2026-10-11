param(
  [ValidateSet('Ensure', 'Status', 'Stop')]
  [string]$Action = 'Ensure'
)

$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $taskRoot
. (Join-Path $PSScriptRoot 'dungeon-processes.ps1')

$runtime = Join-Path $taskRoot 'runtime/sd-cpp-vulkan'
$serverExe = Join-Path $runtime 'dist/sd-server.exe'
$model = Join-Path $runtime 'models/sdxl_lightning_4step.safetensors'
$stateDir = Join-Path $runtime 'state'
$statePath = Join-Path $stateDir 'backend-process.json'
$logsDir = Join-Path $runtime 'logs'
$stdout = Join-Path $logsDir 'dungeon-server.stdout.log'
$stderr = Join-Path $logsDir 'dungeon-server.stderr.log'
$baseUrl = 'http://127.0.0.1:18191'

function Test-Listener {
  @(Get-DungeonTcpListeners -LocalAddress '127.0.0.1' -LocalPort 18191).Count -gt 0
}

function Get-Capabilities {
  try {
    $capabilities = Invoke-RestMethod -Uri "$baseUrl/sdcpp/v1/capabilities" -TimeoutSec 2
    if ('img_gen' -notin @($capabilities.supported_modes)) { return $null }
    return $capabilities
  } catch { return $null }
}

function Wait-Backend([int]$Seconds, $Process) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($Process) {
      $Process.Refresh()
      if ($Process.HasExited) { throw "Dungeon's stable-diffusion.cpp process exited with code $($Process.ExitCode). See $stderr." }
    }
    # The health URL can be slow or unreachable even after the server process
    # exists. Keep each probe bounded and fail this launch promptly.
    $capabilities = Get-Capabilities
    if ($capabilities) { return $capabilities }
    Start-Sleep -Milliseconds 300
  }
  throw "Dungeon's stable-diffusion.cpp backend did not become ready within $Seconds seconds. See $stdout and $stderr."
}

function Stop-OwnedBackend {
  $owned = Get-DungeonOwnedProcess $statePath
  if (-not $owned) {
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    return $false
  }

  $processId = [int]$owned.ProcessId
  Stop-Process -Id $processId -Force -ErrorAction Stop
  $deadline = [DateTime]::UtcNow.AddSeconds(2)
  do {
    Start-Sleep -Milliseconds 100
    $stillRunning = Get-Process -Id $processId -ErrorAction SilentlyContinue
  } while ($stillRunning -and [DateTime]::UtcNow -lt $deadline)
  if ($stillRunning) { throw "Dungeon's stable-diffusion.cpp PID $processId did not terminate." }
  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
  return $true
}

New-Item -ItemType Directory -Path $stateDir, $logsDir -Force | Out-Null
$mutexName = 'Local\DungeonCrawlerSdcpp-' + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($taskRoot))).Replace('\', '_').Replace('/', '_')
$mutex = [Threading.Mutex]::new($false, $mutexName)
$locked = $false
try {
  $locked = $mutex.WaitOne(0)
  if (-not $locked) { throw 'Another Dungeon image-backend lifecycle operation is in progress.' }

  switch ($Action) {
    'Status' {
      $owned = Get-DungeonOwnedProcess $statePath
      $ready = $owned -and (Get-Capabilities)
      @{ ok = [bool]$ready; running = [bool]$owned; processId = if ($owned) { [int]$owned.ProcessId } else { $null }; backend = 'stable-diffusion.cpp Vulkan / SDXL-Lightning'; vramLimitGiB = 6.0 } | ConvertTo-Json -Compress
    }
    'Stop' {
      $stopped = Stop-OwnedBackend
      @{ ok = $true; stopped = $stopped; message = if ($stopped) { 'Dungeon-owned Vulkan image backend stopped.' } else { 'Dungeon-owned Vulkan image backend was already stopped.' } } | ConvertTo-Json -Compress
    }
    'Ensure' {
      if (-not (Test-Path -LiteralPath $serverExe) -or -not (Test-Path -LiteralPath $model)) {
        throw "The Dungeon Vulkan runtime is incomplete. Expected $serverExe and $model. See docs/image-generation.md."
      }

      $owned = Get-DungeonOwnedProcess $statePath
      if ($owned) {
        $capabilities = Wait-Backend 15 $null
        @{ ok = $true; started = $false; processId = [int]$owned.ProcessId; ready = $true; model = $capabilities.model.name } | ConvertTo-Json -Compress
        break
      }

      Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
      if (Test-Listener) { throw 'Port 18191 is occupied by a process Dungeon does not own. It was left untouched.' }

      $arguments = @(
        '--listen-ip', '127.0.0.1', '--listen-port', '18191',
        '--model', $model, '--backend', 'vulkan0', '--max-vram', '6.0',
        '--eager-load',
        '--width', '960', '--height', '536', '--steps', '4', '--cfg-scale', '1.0',
        '--sampling-method', 'euler', '--scheduler', 'sgm_uniform', '--log-level', 'verbose'
      )
      $process = Start-Process -FilePath $serverExe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $serverExe) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
      try {
        Save-DungeonOwnedProcess $process $statePath "$serverExe $($arguments -join ' ')"
        $capabilities = Wait-Backend 45 $process
      } catch {
        try { $null = Stop-OwnedBackend } catch { }
        throw
      }
      @{ ok = $true; started = $true; processId = [int]$process.Id; ready = $true; model = $capabilities.model.name } | ConvertTo-Json -Compress
    }
  }
} catch {
  @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
  exit 1
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
