$ErrorActionPreference = 'Stop'
$releaseDir = 'G:\kblrc_build\build\windows\x64\runner\Release'
$staging = 'G:\kblrc_build\build\kblrc_package'
$zip = 'G:\kblrc_build\build\lyrics_fetcher_windows_x64_4.0.0.zip'

if (-not (Test-Path (Join-Path $releaseDir 'lyrics_fetcher.exe'))) {
  Write-Error 'release exe not found'
}

# 重建干净的打包目录
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Path $staging | Out-Null

# 复制运行所需文件（exe + dll + data）
Get-ChildItem -Path $releaseDir | ForEach-Object {
  Copy-Item -Recurse -Force $_.FullName -Destination (Join-Path $staging $_.Name)
}

# 附带说明
$readme = @'
KB歌词搜索 v4.0.0
=================
多源歌词搜索下载工具（Flutter Material 3 / Windows x64）

歌词源：LRCLIB、Lyrics.ovh、酷狗、酷我、网易云、QQ 音乐

使用：
  1. 双击 lyrics_fetcher.exe 启动
  2. 输入歌曲名（或拖入音频文件）后点击「搜索歌词」
  3. 单击结果选中，双击预览，保存后生成 .lrc（UTF-8 BOM）
  4. 支持批量：拖入文件夹或选择文件夹自动处理

说明：
  - 首次运行会自动创建设置；歌词默认保存到歌曲所在目录
  - 如被杀毒软件误报，请添加信任（应用无任何网络之外的系统权限）
'@
Set-Content -Path (Join-Path $staging '使用说明.txt') -Value $readme -Encoding UTF8

# 打包 zip
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip

Write-Output "ZIP_OK $zip"
Write-Output ('SIZE ' + (Get-Item $zip).Length)
