param(
    [Parameter(Mandatory)][string]$Python,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pythonPath = (Resolve-Path -LiteralPath $Python).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Force -Path $output
Push-Location $root
try {
    $builderArgs = @(
        '--noconfirm', '--noupx', '--onedir', '--name', 'personal_radio_engine',
        '--paths', $root, '--distpath', $output, '--workpath', (Join-Path $output 'work'),
        '--specpath', $output, '--add-data', "$root/radio_prototype/setup.html:radio_prototype",
        '--hidden-import', 'uvicorn.loops.asyncio', '--hidden-import', 'uvicorn.protocols.http.h11_impl',
        '--hidden-import', 'uvicorn.lifespan.off', 'scripts/embedded_entry.py'
    )
    & $pythonPath -m PyInstaller @builderArgs
    if ($LASTEXITCODE) { throw 'Could not build the embedded Windows engine.' }
    $notices = Join-Path $output 'personal_radio_engine/third-party'
    $null = New-Item -ItemType Directory -Force -Path $notices
    $prefix = & $pythonPath -c 'import sys; print(sys.base_prefix)'
    Copy-Item -LiteralPath (Join-Path $prefix 'LICENSE.txt') -Destination (Join-Path $notices 'Python-LICENSE.txt')
    $packages = & $pythonPath -c 'import sysconfig; print(sysconfig.get_path("purelib"))'
    foreach ($item in Get-ChildItem -LiteralPath $packages -Directory -Filter '*.dist-info') {
        $licenses = Get-ChildItem -LiteralPath $item.FullName | Where-Object { $_.Name -match '^(licenses?|copying|notice)' }
        if ($licenses) {
            $target = New-Item -ItemType Directory -Force -Path (Join-Path $notices $item.Name)
            $licenses | Copy-Item -Destination $target.FullName -Recurse -Force
        }
    }
} finally {
    Pop-Location
}
