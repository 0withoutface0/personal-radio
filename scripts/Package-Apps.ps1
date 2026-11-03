param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$radioRoot = Split-Path $PSScriptRoot -Parent
$release = Join-Path $radioRoot 'player/build/windows/x64/runner/Release'
$apk = Join-Path $radioRoot 'player/build/app/outputs/flutter-apk/app-release.apk'
$output = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $radioRoot 'dist' }
$windows = Join-Path $output 'windows/PersonalRadio'
if (!(Test-Path -LiteralPath (Join-Path $release 'personal_radio.exe')) -or !(Test-Path -LiteralPath $apk)) {
    throw 'Build both release applications first.'
}
$null = New-Item -ItemType Directory -Force -Path $windows
foreach ($file in Get-ChildItem -LiteralPath $release -File) {
    if ($file.Name -in @('media_kit_libs_windows_audio_plugin.dll', 'integration_test_plugin.dll')) { continue }
    Copy-Item -LiteralPath $file.FullName -Destination $windows -Force
}
Copy-Item -LiteralPath (Join-Path $radioRoot 'player/README.md') -Destination (Join-Path $windows 'SETUP.md') -Force
Copy-Item -LiteralPath (Join-Path $radioRoot 'player/native-notices') -Destination $windows -Recurse -Force
$assetOutput = Join-Path $windows 'data'
$null = New-Item -ItemType Directory -Force -Path $assetOutput
foreach ($item in Get-ChildItem -LiteralPath (Join-Path $release 'data')) {
    Copy-Item -LiteralPath $item.FullName -Destination $assetOutput -Recurse -Force
}
$zip = Join-Path $output 'PersonalRadio-Windows-x64.zip'
Compress-Archive -Path (Join-Path $windows '*') -DestinationPath $zip -Force
$apkOutput = Join-Path $output 'PersonalRadio-Android.apk'
Copy-Item -LiteralPath $apk -Destination $apkOutput -Force
$hashes = foreach ($artifact in @($zip, $apkOutput)) {
    $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
    "$($hash.Hash.ToLower())  $([IO.Path]::GetFileName($artifact))"
}
$hashes | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ASCII
Get-Item -LiteralPath $zip, $apkOutput | Select-Object Name, Length
