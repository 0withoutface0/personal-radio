param(
    [string]$OutputDirectory,
    [string]$EngineDirectory,
    [string]$CrtDirectory,
    [string]$InstallerCompiler,
    [string]$AndroidApk,
    [string]$AndroidServerOnlyApk
)
$ErrorActionPreference = 'Stop'
$radioRoot = Split-Path $PSScriptRoot -Parent
$release = Join-Path $radioRoot 'player/build/windows/x64/runner/Release'
$apk = if ($AndroidApk) { (Resolve-Path -LiteralPath $AndroidApk).Path } else { Join-Path $radioRoot 'player/build/app/outputs/flutter-apk/app-release.apk' }
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
if (Test-Path -LiteralPath $windows) {
    throw 'Choose a new output directory to avoid mixing files from previous builds.'
}
if ($EngineDirectory) {
    $engineSource = (Resolve-Path -LiteralPath $EngineDirectory).Path
    if (!(Test-Path -LiteralPath (Join-Path $engineSource 'personal_radio_engine.exe')) -or !$CrtDirectory) {
        throw 'The bundled engine and an app-local Visual C++ x64 CRT directory are required.'
    }
    $catalog = Join-Path $engineSource '_internal/ytmusicapi/locales/en/LC_MESSAGES/base.mo'
    if (!(Test-Path -LiteralPath $catalog -PathType Leaf)) {
        throw 'Rebuild the Windows engine to include the YouTube Music locale catalog.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        foreach ($abi in @('arm64-v8a', 'x86_64')) {
            if (!$archive.GetEntry("lib/$abi/libpython3.13.so")) {
                throw "Standalone Android APK is missing Python for $abi."
            }
        }
    } finally {
        $archive.Dispose()
    }
}
$null = New-Item -ItemType Directory -Force -Path $windows
foreach ($file in Get-ChildItem -LiteralPath $release -File) {
    if ($file.Name -in @('media_kit_libs_windows_audio_plugin.dll', 'integration_test_plugin.dll')) { continue }
    Copy-Item -LiteralPath $file.FullName -Destination $windows -Force
}
Copy-Item -LiteralPath (Join-Path $radioRoot 'player/README.md') -Destination (Join-Path $windows 'SETUP.md') -Force
Copy-Item -LiteralPath (Join-Path $radioRoot 'player/STANDALONE.md') -Destination $windows -Force
Copy-Item -LiteralPath (Join-Path $radioRoot 'player/native-notices') -Destination $windows -Recurse -Force
$assetOutput = Join-Path $windows 'data'
$null = New-Item -ItemType Directory -Force -Path $assetOutput
foreach ($item in Get-ChildItem -LiteralPath (Join-Path $release 'data')) {
    Copy-Item -LiteralPath $item.FullName -Destination $assetOutput -Recurse -Force
}
if ($EngineDirectory) {
    Copy-Item -LiteralPath $engineSource -Destination (Join-Path $windows 'engine') -Recurse
    $crt = (Resolve-Path -LiteralPath $CrtDirectory).Path
    foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        if (!(Test-Path -LiteralPath (Join-Path $crt $dll))) { throw "Missing x64 runtime file $dll" }
    }
    Get-ChildItem -LiteralPath $crt -File -Filter '*.dll' | Copy-Item -Destination $windows
}
$zip = Join-Path $output 'PersonalRadio-Windows-x64.zip'
Compress-Archive -Path (Join-Path $windows '*') -DestinationPath $zip -Force
$apkOutput = Join-Path $output 'PersonalRadio-Android.apk'
Copy-Item -LiteralPath $apk -Destination $apkOutput -Force
$artifacts = @($zip, $apkOutput)
if ($InstallerCompiler) {
    if (!$EngineDirectory) { throw 'The standalone installer requires the embedded engine.' }
    $versionLine = Get-Content -LiteralPath (Join-Path $radioRoot 'player/pubspec.yaml') |
        Select-String '^version:\s+([^+]+)' | Select-Object -First 1
    $version = $versionLine.Matches[0].Groups[1].Value
    & $InstallerCompiler "/DPackageDir=$windows" "/DAppVersion=$version" "/O$output" (Join-Path $PSScriptRoot 'PersonalRadio.iss')
    if ($LASTEXITCODE) { throw 'Could not build the Windows installer.' }
    $artifacts += Join-Path $output 'PersonalRadio-Windows-x64-Setup.exe'
}
if ($AndroidServerOnlyApk) {
    $serverOnly = Join-Path $output 'PersonalRadio-Android-Server-ARMv7.apk'
    Copy-Item -LiteralPath $AndroidServerOnlyApk -Destination $serverOnly
    $artifacts += $serverOnly
}
$hashes = foreach ($artifact in $artifacts) {
    $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
    "$($hash.Hash.ToLower())  $([IO.Path]::GetFileName($artifact))"
}
$hashes | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ASCII
Get-Item -LiteralPath $artifacts | Select-Object Name, Length
