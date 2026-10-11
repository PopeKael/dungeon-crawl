param(
  [switch]$IncludeOllama
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Repo

function Write-Step($Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

Write-Step "Stopping Open Dungeon"
$result = & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'dungeon-worker.ps1') -Action Stop
if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
$operation = $result | ConvertFrom-Json
if (-not $operation.Ok) { throw $operation.Message }
Write-Host $operation.Message

if ($IncludeOllama) {
  Write-Step "Stopping Ollama"
  $ollamaProcesses = @(Get-Process -Name "ollama" -ErrorAction SilentlyContinue)
  if (-not $ollamaProcesses.Count) {
    Write-Host "Ollama is not running."
  }
  foreach ($process in $ollamaProcesses) {
    Write-Host "Stopping Ollama: $($process.ProcessName) ($($process.Id))"
    Stop-Process -Id $process.Id -Force
  }
} else {
  Write-Host ""
  Write-Host "Ollama was left running. Run scripts\stop-windows.ps1 -IncludeOllama if you want to stop it too."
}

Write-Host ""
Write-Host "Open Dungeon stop complete." -ForegroundColor Green
