$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$automation = @(Get-ChildItem (Join-Path $env:SystemRoot 'Microsoft.NET/assembly/GAC_MSIL/System.Management.Automation') -Recurse -Filter System.Management.Automation.dll | Select-Object -ExpandProperty FullName)
if ($automation.Count -ne 1) { throw 'The installed Windows PowerShell hosting assembly could not be identified.' }
$output = Join-Path $taskRoot 'DungeonCrawler.exe'
$arguments = @('/nologo','/target:winexe','/platform:x64','/optimize+',('/out:' + $output),('/win32icon:' + (Join-Path $taskRoot 'assets/dungeon.ico')),('/reference:' + $automation[0]),'/reference:System.Windows.Forms.dll', (Join-Path $PSScriptRoot 'DungeonCrawler.cs'))
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'DungeonCrawler.exe compilation failed.' }
Write-Output $output
Get-FileHash -LiteralPath $output -Algorithm SHA256
