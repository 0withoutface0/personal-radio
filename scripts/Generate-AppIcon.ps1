# Code-drawn icon matching the player's equalizer mark; no external image asset.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$radioRoot = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $radioRoot 'player/windows/runner/resources/app_icon.ico'
$frames = @()
foreach ($size in @(16,24,32,48,64,128,256)) {
    $bitmap = New-Object Drawing.Bitmap($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::FromArgb(17,20,16))
    $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(213,248,135))
    for ($bar = 0; $bar -lt 5; $bar++) {
        $height = @(0.28,0.48,0.66,0.4,0.2)[$bar] * $size
        $graphics.FillRectangle($brush, [single](($bar * 0.115 + 0.23) * $size), [single](($size - $height)/2), [single]($size * .07), [single]$height)
    }
    $memory = New-Object IO.MemoryStream
    $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
    $frames += @{size=$size;bytes=$memory.ToArray()}
    $memory.Dispose(); $graphics.Dispose(); $brush.Dispose(); $bitmap.Dispose()
}
$stream = [IO.File]::Create($destination)
$writer = New-Object IO.BinaryWriter($stream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
    $offset = 6 + $frames.Count * 16
    foreach ($frame in $frames) {
        $edge = if ($frame.size -eq 256) { 0 } else { $frame.size }
        $writer.Write([byte]$edge); $writer.Write([byte]$edge); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.bytes.Length); $writer.Write([uint32]$offset)
        $offset += $frame.bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.bytes) }
} finally { $writer.Dispose(); $stream.Dispose() }
