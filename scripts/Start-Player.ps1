param([string]$Server = 'http://127.0.0.1:8765')
$ErrorActionPreference = 'Stop'
$radioRoot = Split-Path $PSScriptRoot -Parent
$appPath = Join-Path $radioRoot 'dist/windows/PersonalRadio/personal_radio.exe'
if (!(Test-Path -LiteralPath $appPath)) {
    $appPath = Join-Path $radioRoot 'player/build/windows/x64/runner/Release/personal_radio.exe'
}
if (!(Test-Path -LiteralPath $appPath)) { throw 'Build or unpack the Windows release first.' }
if ($Server -eq 'http://127.0.0.1:8765') {
    $python = Join-Path $radioRoot '.venv/Scripts/python.exe'
    $tokenPath = Join-Path $radioRoot 'data/device-token.txt'
    $available = $false
    if (Test-Path -LiteralPath $tokenPath) {
        try {
            $headers = @{ Authorization = 'Bearer ' + (Get-Content -LiteralPath $tokenPath -Raw).Trim() }
            $null = Invoke-RestMethod "$Server/api/accounts" -Headers $headers -TimeoutSec 2
            $available = $true
        } catch {}
    }
    if (!$available) {
        if (!(Test-Path -LiteralPath $python)) { throw 'Prepare the Python server as described in README.md.' }
        $null = New-Item -ItemType Directory -Path (Join-Path $radioRoot 'data') -Force
        $service = Start-Process -FilePath $python -ArgumentList '-m radio_prototype serve' -WorkingDirectory $radioRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $radioRoot 'data/server.log') -RedirectStandardError (Join-Path $radioRoot 'data/server-error.log')
        $service.Id | Set-Content -LiteralPath (Join-Path $radioRoot 'data/server.pid')
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            Start-Sleep -Milliseconds 500
            if ($service.HasExited) { throw 'The radio server could not start. Check data/server-error.log.' }
            if (Test-Path -LiteralPath $tokenPath) {
                try {
                    $headers = @{ Authorization = 'Bearer ' + (Get-Content -LiteralPath $tokenPath -Raw).Trim() }
                    $null = Invoke-RestMethod "$Server/api/accounts" -Headers $headers -TimeoutSec 2
                    $available = $true
                    break
                } catch {}
            }
        }
        if (!$available) { throw 'The radio server did not respond. Check data/server-error.log.' }
    }
    $pairingPath = Join-Path $radioRoot 'data/windows-pairing.json'
    @{ origin=$Server; token=(Get-Content -LiteralPath $tokenPath -Raw).Trim() } | ConvertTo-Json | Set-Content -LiteralPath $pairingPath -Encoding UTF8
    $env:RADIO_PAIRING_FILE = $pairingPath
}
try {
    Start-Process -FilePath $appPath -WorkingDirectory (Split-Path $appPath -Parent)
} finally {
    Remove-Item Env:RADIO_PAIRING_FILE -ErrorAction SilentlyContinue
}
