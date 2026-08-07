# 启动验证脚本：启动 release exe，6 秒无崩溃则输出 RUNNING_OK。
# 用法：powershell -ExecutionPolicy Bypass -File tools\smoke_run.ps1 [-ExePath <exe路径>]
param(
  [string]$ExePath
)

$ErrorActionPreference = 'Continue'
if (-not $ExePath) {
  $projectRoot = Split-Path -Parent $PSScriptRoot
  $ExePath = Join-Path $projectRoot 'build\windows\x64\runner\Release\lyrics_fetcher.exe'
}
if (-not (Test-Path $ExePath)) {
  Write-Output 'EXE_MISSING'
  exit 1
}
$p = Start-Process -FilePath $ExePath -PassThru
Start-Sleep -Seconds 6
if ($p.HasExited) {
  Write-Output ("EXITED_EARLY code=" + $p.ExitCode)
  exit 1
} else {
  Write-Output 'RUNNING_OK'
  Stop-Process -Id $p.Id -Force
  exit 0
}
