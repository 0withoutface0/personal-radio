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
# Notification controls are loaded by name, so a source-level check cannot
# detect their removal by Android's release resource shrinker.
$androidSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android/sdk' }
$aapt = Get-ChildItem -LiteralPath (Join-Path $androidSdk 'build-tools') -Filter aapt2.exe -Recurse |
    Sort-Object FullName -Descending | Select-Object -First 1
if (!$aapt) { throw 'Android SDK aapt2 is required to verify the release APK.' }
$resources = & $aapt.FullName dump resources $apk
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Android release resources.' }
foreach ($icon in @('ic_radio_notification', 'ic_radio_like_outline', 'ic_radio_like_filled', 'audio_service_play_arrow', 'audio_service_pause', 'audio_service_skip_next', 'audio_service_stop')) {
    if (!($resources | Select-String -SimpleMatch "drawable/$icon")) {
        throw "Release APK is missing media control icon: $icon"
    }
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
