# 合成 Windows payload(UI + 核心 + wintun + 许可),再打 portable zip 与 MSI。
param(
  [Parameter(Mandatory=$true)][string]$BuildDir,
  [Parameter(Mandatory=$true)][string]$Arch,
  [Parameter(Mandatory=$true)][string]$CoreExe,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [string]$Version = '0.1.0',
  [string]$WixBin = ''
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$payload = Join-Path $OutDir 'payload'
if (Test-Path $payload) { Remove-Item $payload -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload | Out-Null

# Flutter 产物 + 核心 + wintun
Get-ChildItem $BuildDir -Force | Copy-Item -Destination $payload -Recurse -Force
Copy-Item $CoreExe (Join-Path $payload 'egland.exe') -Force
$wintunDll = if ($Arch -eq 'arm64') { 'wintun-arm64.dll' } else { 'wintun.dll' }
Copy-Item (Join-Path $root "packaging\windows\$wintunDll") (Join-Path $payload 'wintun.dll') -Force
Copy-Item (Join-Path $root 'packaging\windows\wintun-LICENSE.txt') (Join-Path $payload 'wintun-LICENSE.txt') -Force
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $payload 'LICENSE.txt') -Force
if (Test-Path (Join-Path $root 'THIRD_PARTY_LICENSES.md')) {
  Copy-Item (Join-Path $root 'THIRD_PARTY_LICENSES.md') (Join-Path $payload 'THIRD_PARTY_LICENSES.txt') -Force
}

# --- portable zip ---
$zip = Join-Path $OutDir "EverGreen-LAN-windows-$Arch-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -Force
Write-Output "ZIP=$zip"

# --- MSI(WiX v3:heat 扫目录生成文件清单 → candle → light) ---
$product = Join-Path $PSScriptRoot 'product.wxs'
if (-not (Test-Path $product)) { throw "缺少 $product" }

$candidates = @(
  $WixBin,
  $env:WIX_BIN,
  (Join-Path $env:ProgramFiles 'WiX Toolset v3.14\bin'),
  (Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.14\bin')
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'candle.exe')) }
if (-not $candidates) {
  throw '未找到 WiX v3(candle.exe)。请通过 -WixBin 指定解压后的 WiX bin 目录。'
}
$wixbin = @($candidates)[0]
$heat = Join-Path $wixbin 'heat.exe'
$candle = Join-Path $wixbin 'candle.exe'
$light = Join-Path $wixbin 'light.exe'

$filesWxs = Join-Path $OutDir 'files.wxs'
# heat 不支持排除单个文件,先把主程序挪开,避免同一文件被两个组件安装(ICE30)
$uiExe = Join-Path $payload 'eglan_ui.exe'
$uiBak = Join-Path $OutDir 'eglan_ui.exe.bak'
Move-Item $uiExe $uiBak -Force
try {
  & $heat dir $payload -nologo -ag -srd -cg AppFiles -dr INSTALLFOLDER -var var.SourceDir -o $filesWxs
  if ($LASTEXITCODE -ne 0) { throw 'heat 失败' }
  # 安装目录是 64 位目录,所有组件必须标记为 64 位,否则 ICE80
  $content = Get-Content $filesWxs -Raw
  $content = $content -replace '<Component ', '<Component Win64="yes" '
  Set-Content -Path $filesWxs -Value $content -Encoding UTF8 -NoNewline
} finally {
  Move-Item $uiBak $uiExe -Force
}

$productObj = Join-Path $OutDir 'product.wixobj'
$filesObj = Join-Path $OutDir 'files.wixobj'
& $candle -nologo "-dSourceDir=$payload" "-dVersion=$Version" -out $productObj $product
if ($LASTEXITCODE -ne 0) { throw 'candle product 失败' }
& $candle -nologo "-dSourceDir=$payload" -out $filesObj $filesWxs
if ($LASTEXITCODE -ne 0) { throw 'candle files 失败' }

$msi = Join-Path $OutDir "EverGreen-LAN-windows-$Arch.msi"
& $light -nologo -out $msi $productObj $filesObj -ext WixUIExtension
if ($LASTEXITCODE -ne 0) { throw 'light 失败' }
Write-Output "MSI=$msi"
