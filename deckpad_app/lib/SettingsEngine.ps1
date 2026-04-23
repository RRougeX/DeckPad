function New-DefaultSettings {
    [pscustomobject]@{
        launchOnWindowsStartup = $false
        startMinimizedToTray = $false
        minimizeToTray = $true
        closeToTray = $true
        resumeListeningOnStartup = $true
        loadDefaultProfileOnStartup = $true
        startupProfilePath = 'profiles\default-profile.json'
    }
}

function Normalize-Settings {
    param([object]$Settings)

    $defaults = New-DefaultSettings
    if (-not $Settings) {
        return $defaults
    }

    foreach ($name in $defaults.PSObject.Properties.Name) {
        if (-not ($Settings.PSObject.Properties.Name -contains $name)) {
            $Settings | Add-Member -NotePropertyName $name -NotePropertyValue $defaults.$name -Force
        }
    }

    return $Settings
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        $settings = New-DefaultSettings
        Save-Settings -Settings $settings
        return $settings
    }

    $raw = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
    return Normalize-Settings -Settings $raw
}

function Save-Settings {
    param(
        [Parameter(Mandatory)]
        [object]$Settings
    )

    $settingsDir = Split-Path -Parent $script:SettingsPath
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir | Out-Null
    }

    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsPath
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath('Startup')
    return (Join-Path $startupDir 'DeckPad.lnk')
}

function Set-DeckPadStartupShortcut {
    param([bool]$Enabled)

    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $targetPath = Join-Path $script:AppRoot 'Start-DeckPad.vbs'
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $targetPath
        $shortcut.Arguments = '-StartInTray'
        $shortcut.WorkingDirectory = $script:AppRoot
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Launch DeckPad at sign in'
        $iconPath = Join-Path $script:AppRoot 'assets\DeckPad.ico'
        if (Test-Path -LiteralPath $iconPath) {
            $shortcut.IconLocation = $iconPath
        } else {
            $shortcut.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,137"
        }
        $shortcut.Save()
        return
    }

    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}
