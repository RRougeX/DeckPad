$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktopPath = [Environment]::GetFolderPath('Desktop')
$desktopShortcutPath = Join-Path $desktopPath 'DeckPad.lnk'
$programsPath = [Environment]::GetFolderPath('Programs')
$startMenuShortcutPath = Join-Path $programsPath 'DeckPad.lnk'
$targetPath = Join-Path $appRoot 'Start-DeckPad.vbs'
$workingDirectory = $appRoot
$iconOutputPath = Join-Path $appRoot 'assets\DeckPad.ico'
$legacyGeneratedIconPath = Join-Path $appRoot 'assets\DeckPad.generated.ico'

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class DeckPadShortcutInterop
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

function Convert-ImageFileToIcon {
    param([string]$Path)

    $bitmap = $null
    $icon = $null
    $cloned = $null
    $iconHandle = [IntPtr]::Zero

    try {
        $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
        $iconHandle = $bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($iconHandle)
        $cloned = [System.Drawing.Icon]$icon.Clone()
        return $cloned
    } catch {
        return $null
    } finally {
        if ($icon) {
            $icon.Dispose()
        }
        if ($iconHandle -ne [IntPtr]::Zero) {
            [void][DeckPadShortcutInterop]::DestroyIcon($iconHandle)
        }
        if ($bitmap) {
            $bitmap.Dispose()
        }
    }
}

function Get-ShortcutIconPath {
    $pngPath = Join-Path $appRoot 'assets\DeckPad.png'
    if (Test-Path -LiteralPath $pngPath) {
        $icon = Convert-ImageFileToIcon -Path $pngPath
        if (-not $icon) {
            return $null
        }

        try {
            $stream = [System.IO.File]::Create($iconOutputPath)
            try {
                $icon.Save($stream)
            } finally {
                $stream.Dispose()
            }
            if (Test-Path -LiteralPath $legacyGeneratedIconPath) {
                Remove-Item -LiteralPath $legacyGeneratedIconPath -Force -ErrorAction SilentlyContinue
            }
            return $iconOutputPath
        } finally {
            $icon.Dispose()
        }
    }

    if (Test-Path -LiteralPath $iconOutputPath) {
        return $iconOutputPath
    }

    return $null
}

function New-DeckPadShortcut {
    param([string]$ShortcutPath)

    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $targetPath
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.WindowStyle = 1
    $shortcut.Description = 'Launch DeckPad'

    $iconPath = Get-ShortcutIconPath
    if (Test-Path -LiteralPath $iconPath) {
        $shortcut.IconLocation = $iconPath
    } else {
        $shortcut.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,137"
    }

    $shortcut.Save()
}

New-DeckPadShortcut -ShortcutPath $desktopShortcutPath
New-DeckPadShortcut -ShortcutPath $startMenuShortcutPath

Write-Host "Created desktop shortcut: $desktopShortcutPath"
Write-Host "Created Start menu shortcut: $startMenuShortcutPath"
