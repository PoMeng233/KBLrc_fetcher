$ErrorActionPreference = 'Continue'
$exe = 'G:\kblrc_build\build\windows\x64\runner\Release\lyrics_fetcher.exe'
if (-not (Test-Path $exe)) { Write-Output 'EXE_MISSING'; exit 1 }
$p = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 6
if ($p.HasExited) {
  Write-Output ("EXITED_EARLY code=" + $p.ExitCode)
  exit 1
} else {
  Write-Output 'RUNNING_OK'
  Stop-Process -Id $p.Id -Force
  exit 0
}
