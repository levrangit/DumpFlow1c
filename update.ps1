#Requires -Version 5.1
# Если PowerShell запрещает запуск скрипта, выполните:
# Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
# Проверить текущую политику:
# Get-ExecutionPolicy -List

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Host "============================================================"
Write-Host "MCP - UPDATE"
Write-Host "============================================================"

& (Join-Path $root 'prepare.ps1')
if ($LASTEXITCODE -ne 0) { throw "prepare.ps1 завершился с кодом $LASTEXITCODE." }

& (Join-Path $root 'dump_config.ps1')
if ($LASTEXITCODE -ne 0) { throw "dump_config.ps1 завершился с кодом $LASTEXITCODE." }

& (Join-Path $root 'pack.ps1')
if ($LASTEXITCODE -ne 0) { throw "pack.ps1 завершился с кодом $LASTEXITCODE." }

& (Join-Path $root 'upload.ps1')
if ($LASTEXITCODE -ne 0) { throw "upload.ps1 завершился с кодом $LASTEXITCODE." }

Write-Host ""
Write-Host "============================================================"
Write-Host "MCP UPDATE COMPLETED"
Write-Host "============================================================"
exit 0
