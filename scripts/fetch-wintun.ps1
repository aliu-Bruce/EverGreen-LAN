# 下载用于本地开发的已签名 Wintun 驱动。
#
# Wintun 是拥有独立许可证的第三方已签名内核驱动，本仓库有意不将其内置，
# 而是从官方来源获取。见 https://www.wintun.net/
param(
    [string]$Version = "0.14.1",
    [string]$Architecture = "amd64",
    [switch]$CopyToTarget
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$resources = Join-Path $root "apps\desktop\src-tauri\resources"
$destination = Join-Path $resources "wintun.dll"

New-Item -ItemType Directory -Force -Path $resources | Out-Null

if (Test-Path $destination) {
    Write-Output "wintun.dll already present at $destination"
} else {
    $url = "https://www.wintun.net/builds/wintun-$Version.zip"
    $zip = Join-Path $env:TEMP "wintun-$Version.zip"
    $extract = Join-Path $env:TEMP "wintun-$Version"

    Write-Output "downloading $url"
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    $dll = Get-ChildItem -Path $extract -Recurse -Filter "wintun.dll" |
        Where-Object { $_.Directory.Name -eq $Architecture } |
        Select-Object -First 1
    if (-not $dll) {
        throw "wintun.dll for '$Architecture' not found in the archive; try -Architecture x86 or arm64"
    }
    Copy-Item $dll.FullName $destination -Force
    Remove-Item $zip -Force
    Write-Output "installed $destination"
}

if ($CopyToTarget) {
    $debug = Join-Path $root "target\debug"
    if (Test-Path $debug) {
        Copy-Item $destination (Join-Path $debug "wintun.dll") -Force
        Write-Output "copied next to target\debug\evergreen-lan.exe"
    }
}

$info = (Get-Item $destination).VersionInfo
Write-Output ("version={0} company={1}" -f $info.FileVersion, $info.CompanyName)
