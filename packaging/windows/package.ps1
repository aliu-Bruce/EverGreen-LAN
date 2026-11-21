# 合成 Windows payload(UI + 核心 + wintun + 许可),再打 portable zip 与 MSI。
param(
  [Parameter(Mandatory=$true)][string]$BuildDir,
  [Parameter(Mandatory=$true)][string]$Arch,
  [Parameter(Mandatory=$true)][string]$CoreExe,
  [Parameter(Mandatory=$true)][string]$OutDir
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$payload = Join-Path $OutDir 'payload'
New-Item -ItemType Directory -Force -Path $payload | Out-Null

Get-ChildItem $BuildDir -Force | Copy-Item -Destination $payload -Recurse -Force
Copy-Item $CoreExe (Join-Path $payload 'egland.exe') -Force
Copy-Item (Join-Path $root 'dist\wintun.dll') (Join-Path $payload 'wintun.dll') -Force
if (Test-Path (Join-Path $root 'dist\wintun-LICENSE.txt')) {
  Copy-Item (Join-Path $root 'dist\wintun-LICENSE.txt') (Join-Path $payload 'wintun-LICENSE.txt') -Force
}
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $payload 'LICENSE.txt') -Force
if (Test-Path (Join-Path $root 'THIRD_PARTY_LICENSES.md')) {
  Copy-Item (Join-Path $root 'THIRD_PARTY_LICENSES.md') (Join-Path $payload 'THIRD_PARTY_LICENSES.txt') -Force
}

# portable zip
$zip = Join-Path $OutDir "EverGreen-LAN-windows-$Arch-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -Force
Write-Output "ZIP=$zip"

# MSI(WiX v3:heat 扫目录生成文件清单 → candle → light)
$product = Join-Path $PSScriptRoot 'product.wxs'
if (Test-Path $product) {
  $wixbin = Join-Path $env:ProgramFiles 'WiX Toolset v3.14\bin'
  if (-not (Test-Path $wixbin)) { $wixbin = Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.14\bin' }
  $heat = Join-Path $wixbin 'heat.exe'
  $candle = Join-Path $wixbin 'candle.exe'
  $light = Join-Path $wixbin 'light.exe'
  $filesWxs = Join-Path $OutDir 'files.wxs'
  & $heat dir $payload -nologo -ag -srd -cg AppFiles -dr INSTALLFOLDER -var var.SourceDir -o $filesWxs
  if ($LASTEXITCODE -ne 0) { throw "heat 失败" }
  $productObj = Join-Path $OutDir 'product.wixobj'
  $filesObj = Join-Path $OutDir 'files.wixobj'
  & $candle -nologo -dSourceDir=$payload -out $productObj $product
  if ($LASTEXITCODE -ne 0) { throw "candle product 失败" }
  & $candle -nologo -dSourceDir=$payload -out $filesObj $filesWxs
  if ($LASTEXITCODE -ne 0) { throw "candle files 失败" }
  $msi = Join-Path $OutDir "EverGreen-LAN-windows-$Arch.msi"
  & $light -nologo -out $msi $productObj $filesObj -ext WixUIExtension
  if ($LASTEXITCODE -ne 0) { throw "light 失败" }
  Write-Output "MSI=$msi"
}
