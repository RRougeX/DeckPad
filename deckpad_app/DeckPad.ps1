param(
    [switch]$StartInTray
)

$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'NativeInterop.ps1')
. (Join-Path $libRoot 'ProfileEngine.ps1')
. (Join-Path $libRoot 'ActionEngine.ps1')
. (Join-Path $libRoot 'ThemeEngine.ps1')
. (Join-Path $libRoot 'SettingsEngine.ps1')
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class DeckPadShellInterop
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProfilePath = Join-Path $script:AppRoot 'profiles\default-profile.json'
$script:SettingsPath = Join-Path $script:AppRoot 'settings\app-settings.json'
$script:Listening = $true
$script:CaptureNextKey = $false
$script:DeviceLockArmed = $false
$script:SelectedIndex = 0
$script:TileButtons = @()
$script:DeviceOptions = @()
$script:DevicePickerEntries = @()
$script:CompactMode = $false
$script:PinnedMode = $false
$script:UsesCleanLayout = $false
$script:PendingCorrelatedCapture = $null
$script:PendingCorrelatedTrigger = $null
$script:AllowExit = $false
$script:NormalWindowSize = New-Object System.Drawing.Size(1480, 960)
$script:CompactWindowSize = New-Object System.Drawing.Size(980, 800)
$script:CachedAppIcon = $null
$script:SingleInstanceMutex = $null
$script:OwnsSingleInstanceMutex = $false
$script:StartInTray = [bool]$StartInTray

$script:Theme = @{
    Background = [System.Drawing.Color]::FromArgb(244, 247, 251)
    Canvas = [System.Drawing.Color]::FromArgb(234, 240, 248)
    Panel = [System.Drawing.Color]::FromArgb(255, 255, 255)
    PanelAlt = [System.Drawing.Color]::FromArgb(239, 244, 251)
    Header = [System.Drawing.Color]::FromArgb(15, 23, 42)
    HeaderSoft = [System.Drawing.Color]::FromArgb(191, 205, 227)
    Shadow = [System.Drawing.Color]::FromArgb(203, 214, 230)
    Ink = [System.Drawing.Color]::FromArgb(17, 24, 39)
    Muted = [System.Drawing.Color]::FromArgb(100, 116, 139)
    Accent = [System.Drawing.Color]::FromArgb(37, 99, 235)
    AccentSoft = [System.Drawing.Color]::FromArgb(219, 234, 254)
    AccentWarm = [System.Drawing.Color]::FromArgb(71, 85, 105)
    Good = [System.Drawing.Color]::FromArgb(22, 163, 74)
    Border = [System.Drawing.Color]::FromArgb(211, 223, 237)
    StrongBorder = [System.Drawing.Color]::FromArgb(163, 184, 208)
    Surface = [System.Drawing.Color]::FromArgb(250, 252, 255)
    SurfaceInset = [System.Drawing.Color]::FromArgb(247, 250, 255)
}

function Get-PreferredIconPath {
    $iconCandidates = @(
        (Join-Path $script:AppRoot 'assets\DeckPad.png'),
        (Join-Path $script:AppRoot 'assets\DeckPad.ico')
    )

    foreach ($candidate in $iconCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

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
            [void][DeckPadShellInterop]::DestroyIcon($iconHandle)
        }
        if ($bitmap) {
            $bitmap.Dispose()
        }
    }
}

function Get-DeckPadIcon {
    if ($script:CachedAppIcon) {
        return $script:CachedAppIcon
    }

    $iconPath = Get-PreferredIconPath
    if ($iconPath) {
        try {
            if ([IO.Path]::GetExtension($iconPath).Equals('.png', [System.StringComparison]::OrdinalIgnoreCase)) {
                $pngIcon = Convert-ImageFileToIcon -Path $iconPath
                if ($pngIcon) {
                    $script:CachedAppIcon = $pngIcon
                    return $script:CachedAppIcon
                }
            } else {
                $script:CachedAppIcon = New-Object System.Drawing.Icon($iconPath)
                return $script:CachedAppIcon
            }
        } catch {
        }
    }

    $script:CachedAppIcon = [System.Drawing.SystemIcons]::Application
    return $script:CachedAppIcon
}

function Initialize-DeckPadShellIdentity {
    try {
        [void][DeckPadShellInterop]::SetCurrentProcessExplicitAppUserModelID('DeckPad.App')
    } catch {
    }
}

function Initialize-SingleInstanceGuard {
    $createdNew = $false
    $script:SingleInstanceMutex = New-Object System.Threading.Mutex($true, 'Local\DeckPad.SingleInstance', [ref]$createdNew)
    $script:OwnsSingleInstanceMutex = [bool]$createdNew

    if (-not $script:OwnsSingleInstanceMutex) {
        try {
            $script:SingleInstanceMutex.Dispose()
        } catch {
        }
        exit 0
    }
}

function Release-SingleInstanceGuard {
    if (-not $script:SingleInstanceMutex) {
        return
    }

    try {
        if ($script:OwnsSingleInstanceMutex) {
            $script:SingleInstanceMutex.ReleaseMutex()
        }
    } catch {
    } finally {
        $script:SingleInstanceMutex.Dispose()
        $script:SingleInstanceMutex = $null
        $script:OwnsSingleInstanceMutex = $false
    }
}

function Add-LogLine {
    param([string]$Message)
    if (-not $script:LogBox) { return }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    if ($script:LogBox.TextLength -gt 40000) {
        $cutoff = $script:LogBox.Text.IndexOf("`n", 8000)
        if ($cutoff -gt 0) { $script:LogBox.Text = $script:LogBox.Text.Substring($cutoff + 1) }
    }
    $script:LogBox.AppendText("[$timestamp] $Message`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Set-PanelSurface {
    param(
        [System.Windows.Forms.Control]$Control,
        [string]$Variant = 'default'
    )

    switch ($Variant) {
        'alt' {
            $Control.BackColor = $script:Theme.PanelAlt
        }
        'canvas' {
            $Control.BackColor = $script:Theme.Canvas
        }
        default {
            $Control.BackColor = $script:Theme.Panel
        }
    }

    if ($Control -is [System.Windows.Forms.Panel]) {
        $Control.BorderStyle = 'FixedSingle'
    }
}

function Add-GradientPaint {
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Drawing.Color]$TopColor,
        [System.Drawing.Color]$BottomColor
    )

    $Control.Add_Paint({
        param($sender, $eventArgs)

        $rect = $sender.ClientRectangle
        if ($rect.Width -le 0 -or $rect.Height -le 0) {
            return
        }

        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect,
            $TopColor,
            $BottomColor,
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical
        )
        $eventArgs.Graphics.FillRectangle($brush, $rect)
        $brush.Dispose()
    }.GetNewClosure())
}

function Set-InputStyle {
    param([System.Windows.Forms.Control]$Control)

    $Control.BackColor = $script:Theme.Surface
    $Control.ForeColor = $script:Theme.Ink

    if ($Control -is [System.Windows.Forms.TextBox]) {
        $Control.BorderStyle = 'FixedSingle'
    }
}

function Set-ButtonStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [string]$Variant = 'secondary'
    )

    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5, [System.Drawing.FontStyle]::Bold)

    switch ($Variant) {
        'primary' {
            $Button.BackColor = $script:Theme.Accent
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = $script:Theme.Accent
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
        }
        'dark' {
            $Button.BackColor = $script:Theme.Header
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = $script:Theme.Header
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
        }
        'success' {
            $Button.BackColor = $script:Theme.Good
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = $script:Theme.Good
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
        }
        default {
            $Button.BackColor = $script:Theme.Panel
            $Button.ForeColor = $script:Theme.Ink
            $Button.FlatAppearance.BorderColor = $script:Theme.Border
            $Button.FlatAppearance.MouseOverBackColor = $script:Theme.PanelAlt
            $Button.FlatAppearance.MouseDownBackColor = $script:Theme.AccentSoft
        }
    }
}

function Hide-DeckPadToTray {
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $true
    }

    if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:Form.WindowState = 'Normal'
    }

    $script:Form.ShowInTaskbar = $false
    $script:Form.Hide()
    Add-LogLine 'DeckPad minimized to tray'
}

function Show-DeckPadFromTray {
    $script:Form.ShowInTaskbar = $true
    $script:Form.Show()
    $script:Form.WindowState = 'Normal'
    $script:Form.Activate()
}

function Apply-AppSettings {
    if (-not $script:Settings) {
        return
    }

    try {
        Set-DeckPadStartupShortcut -Enabled ([bool]$script:Settings.launchOnWindowsStartup)
    } catch {
        Add-LogLine "Could not update startup shortcut: $($_.Exception.Message)"
    }
}

function Get-ProfileStartupChoices {
    $profileDir = Join-Path $script:AppRoot 'profiles'
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir | Out-Null
    }

    $files = @(Get-ChildItem -LiteralPath $profileDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0 -and (Test-Path -LiteralPath $script:ProfilePath)) {
        $files = @(Get-Item -LiteralPath $script:ProfilePath)
    }

    $choices = @()
    foreach ($file in $files) {
        $profileName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($raw.name) {
                $profileName = [string]$raw.name
            }
        } catch {
        }

        $relativePath = 'profiles\' + $file.Name
        $choices += [pscustomobject]@{
            Name = $profileName
            RelativePath = $relativePath
            Display = "$profileName  ($($file.Name))"
        }
    }

    if ($choices.Count -eq 0) {
        $choices += [pscustomobject]@{
            Name = '6-Key Stream Deck'
            RelativePath = 'profiles\default-profile.json'
            Display = '6-Key Stream Deck  (default-profile.json)'
        }
    }

    return $choices
}

function Show-LicenseTermsDialog {
    $terms = @"
DeckPad License and Terms

DeckPad is source-available for viewing and personal use only.

You may not copy, reuse, redistribute, resell, rebrand, sublicense, or publish DeckPad code, UI, assets, branding, or documentation without permission from the rights holder.

See the LICENSE file included with this project for the full terms.

This software is provided as-is, with no warranty or guarantee of support.
"@

    [System.Windows.Forms.MessageBox]::Show(
        $terms,
        'License and Terms',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-SettingsDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'DeckPad Settings'
    $dialog.ClientSize = New-Object System.Drawing.Size(850, 620)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = $script:Theme.Canvas
    $dialog.ForeColor = $script:Theme.Ink

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(18, 18)
    $card.Size = New-Object System.Drawing.Size(500, 560)
    $card.BackColor = $script:Theme.Panel
    $card.BorderStyle = 'FixedSingle'
    [void]$dialog.Controls.Add($card)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Settings'
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Theme.Ink
    [void]$card.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Tune how DeckPad starts, runs in the background, and loads your profile.'
    $subtitle.Location = New-Object System.Drawing.Point(28, 60)
    $subtitle.Size = New-Object System.Drawing.Size(438, 38)
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $subtitle.ForeColor = $script:Theme.Muted
    [void]$card.Controls.Add($subtitle)

    function New-SettingsCheckbox {
        param([string]$Text, [int]$Y, [bool]$Checked)

        $checkBox = New-Object System.Windows.Forms.CheckBox
        $checkBox.Text = $Text
        $checkBox.Location = New-Object System.Drawing.Point(30, $Y)
        $checkBox.Size = New-Object System.Drawing.Size(430, 28)
        $checkBox.Checked = $Checked
        $checkBox.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
        $checkBox.ForeColor = $script:Theme.Ink
        $checkBox.BackColor = $script:Theme.Panel
        return $checkBox
    }

    $appSectionLabel = New-Object System.Windows.Forms.Label
    $appSectionLabel.Text = 'App Startup'
    $appSectionLabel.Location = New-Object System.Drawing.Point(30, 106)
    $appSectionLabel.AutoSize = $true
    $appSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5, [System.Drawing.FontStyle]::Bold)
    $appSectionLabel.ForeColor = $script:Theme.Accent
    [void]$card.Controls.Add($appSectionLabel)

    $startupCheck = New-SettingsCheckbox -Text 'Launch DeckPad in the tray when Windows starts' -Y 132 -Checked ([bool]$script:Settings.launchOnWindowsStartup)
    [void]$card.Controls.Add($startupCheck)

    $traySectionLabel = New-Object System.Windows.Forms.Label
    $traySectionLabel.Text = 'Tray Behavior'
    $traySectionLabel.Location = New-Object System.Drawing.Point(30, 176)
    $traySectionLabel.AutoSize = $true
    $traySectionLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5, [System.Drawing.FontStyle]::Bold)
    $traySectionLabel.ForeColor = $script:Theme.Accent
    [void]$card.Controls.Add($traySectionLabel)

    $minimizeToTrayCheck = New-SettingsCheckbox -Text 'Minimize button sends DeckPad to the tray' -Y 202 -Checked ([bool]$script:Settings.minimizeToTray)
    [void]$card.Controls.Add($minimizeToTrayCheck)

    $closeToTrayCheck = New-SettingsCheckbox -Text 'Clicking X keeps DeckPad running in the tray' -Y 236 -Checked ([bool]$script:Settings.closeToTray)
    [void]$card.Controls.Add($closeToTrayCheck)

    $trayDefaultNote = New-Object System.Windows.Forms.Label
    $trayDefaultNote.Text = 'Enabled by default so mappings keep working after the window is closed.'
    $trayDefaultNote.Location = New-Object System.Drawing.Point(48, 262)
    $trayDefaultNote.Size = New-Object System.Drawing.Size(408, 20)
    $trayDefaultNote.Font = New-Object System.Drawing.Font('Segoe UI', 8.7, [System.Drawing.FontStyle]::Italic)
    $trayDefaultNote.ForeColor = $script:Theme.Muted
    [void]$card.Controls.Add($trayDefaultNote)

    $profileSectionLabel = New-Object System.Windows.Forms.Label
    $profileSectionLabel.Text = 'Profile on Startup'
    $profileSectionLabel.Location = New-Object System.Drawing.Point(30, 298)
    $profileSectionLabel.AutoSize = $true
    $profileSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5, [System.Drawing.FontStyle]::Bold)
    $profileSectionLabel.ForeColor = $script:Theme.Accent
    [void]$card.Controls.Add($profileSectionLabel)

    $resumeCheck = New-SettingsCheckbox -Text 'Resume listening automatically on startup' -Y 324 -Checked ([bool]$script:Settings.resumeListeningOnStartup)
    [void]$card.Controls.Add($resumeCheck)

    $profileCheck = New-SettingsCheckbox -Text 'Load saved profile on startup' -Y 356 -Checked ([bool]$script:Settings.loadDefaultProfileOnStartup)
    [void]$card.Controls.Add($profileCheck)

    $profileChoiceLabel = New-Object System.Windows.Forms.Label
    $profileChoiceLabel.Text = 'Startup profile'
    $profileChoiceLabel.Location = New-Object System.Drawing.Point(54, 390)
    $profileChoiceLabel.AutoSize = $true
    $profileChoiceLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $profileChoiceLabel.ForeColor = $script:Theme.Muted
    [void]$card.Controls.Add($profileChoiceLabel)

    $profileChoices = @(Get-ProfileStartupChoices)
    $profileChoiceBox = New-Object System.Windows.Forms.ComboBox
    $profileChoiceBox.Location = New-Object System.Drawing.Point(170, 386)
    $profileChoiceBox.Size = New-Object System.Drawing.Size(286, 30)
    $profileChoiceBox.DropDownStyle = 'DropDownList'
    [void](Set-InputStyle -Control $profileChoiceBox)
    foreach ($choice in $profileChoices) {
        [void]$profileChoiceBox.Items.Add($choice.Display)
    }
    $selectedProfilePath = if ($script:Settings.startupProfilePath) { [string]$script:Settings.startupProfilePath } else { 'profiles\default-profile.json' }
    $profileChoiceBox.SelectedIndex = 0
    for ($i = 0; $i -lt $profileChoices.Count; $i++) {
        if ($profileChoices[$i].RelativePath -eq $selectedProfilePath) {
            $profileChoiceBox.SelectedIndex = $i
            break
        }
    }
    [void]$card.Controls.Add($profileChoiceBox)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Tip: the tray icon lets DeckPad keep running without taking space on your taskbar.'
    $note.Location = New-Object System.Drawing.Point(30, 432)
    $note.Size = New-Object System.Drawing.Size(440, 38)
    $note.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
    $note.ForeColor = $script:Theme.Muted
    [void]$card.Controls.Add($note)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Save Settings'
    $saveButton.Location = New-Object System.Drawing.Point(248, 504)
    $saveButton.Size = New-Object System.Drawing.Size(126, 38)
    [void](Set-ButtonStyle -Button $saveButton -Variant 'primary')
    $saveButton.Add_Click({
        $script:Settings.launchOnWindowsStartup = [bool]$startupCheck.Checked
        $script:Settings.minimizeToTray = [bool]$minimizeToTrayCheck.Checked
        $script:Settings.closeToTray = [bool]$closeToTrayCheck.Checked
        $script:Settings.resumeListeningOnStartup = [bool]$resumeCheck.Checked
        $script:Settings.loadDefaultProfileOnStartup = [bool]$profileCheck.Checked
        if ($profileChoiceBox.SelectedIndex -ge 0 -and $profileChoiceBox.SelectedIndex -lt $profileChoices.Count) {
            $script:Settings.startupProfilePath = $profileChoices[$profileChoiceBox.SelectedIndex].RelativePath
        }
        Save-Settings -Settings $script:Settings
        Apply-AppSettings
        Add-LogLine 'Settings saved'
        $dialog.Close()
    })
    [void]$card.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(384, 504)
    $cancelButton.Size = New-Object System.Drawing.Size(86, 38)
    [void](Set-ButtonStyle -Button $cancelButton -Variant 'secondary')
    $cancelButton.Add_Click({ $dialog.Close() })
    [void]$card.Controls.Add($cancelButton)

    $creatorCard = New-Object System.Windows.Forms.Panel
    $creatorCard.Location = New-Object System.Drawing.Point(534, 18)
    $creatorCard.Size = New-Object System.Drawing.Size(292, 560)
    $creatorCard.BackColor = $script:Theme.Panel
    $creatorCard.BorderStyle = 'FixedSingle'
    [void]$dialog.Controls.Add($creatorCard)

    $creatorTitle = New-Object System.Windows.Forms.Label
    $creatorTitle.Text = 'Project'
    $creatorTitle.Location = New-Object System.Drawing.Point(22, 20)
    $creatorTitle.AutoSize = $true
    $creatorTitle.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $creatorTitle.ForeColor = $script:Theme.Ink
    [void]$creatorCard.Controls.Add($creatorTitle)

    $logoPath = Join-Path $script:AppRoot 'assets\Rouge.jpg'
    if (Test-Path -LiteralPath $logoPath) {
        $logoBox = New-Object System.Windows.Forms.PictureBox
        $logoBox.Location = New-Object System.Drawing.Point(24, 72)
        $logoBox.Size = New-Object System.Drawing.Size(96, 96)
        $logoBox.SizeMode = 'Zoom'
        $logoBox.BackColor = $script:Theme.Canvas
        $logoBox.ImageLocation = $logoPath
        [void]$creatorCard.Controls.Add($logoBox)
    }

    $creatorNote = New-Object System.Windows.Forms.Label
    $creatorNote.Text = 'DeckPad is a local-first desktop companion for small 6-key macro pads with one knob.'
    $creatorNote.Location = New-Object System.Drawing.Point(24, 184)
    $creatorNote.Size = New-Object System.Drawing.Size(238, 64)
    $creatorNote.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Italic)
    $creatorNote.ForeColor = $script:Theme.Muted
    [void]$creatorCard.Controls.Add($creatorNote)

    $privacyTitle = New-Object System.Windows.Forms.Label
    $privacyTitle.Text = 'Privacy Reminder'
    $privacyTitle.Location = New-Object System.Drawing.Point(24, 274)
    $privacyTitle.AutoSize = $true
    $privacyTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13, [System.Drawing.FontStyle]::Bold)
    $privacyTitle.ForeColor = $script:Theme.Accent
    [void]$creatorCard.Controls.Add($privacyTitle)

    $privacyBody = New-Object System.Windows.Forms.Label
    $privacyBody.Text = "Profiles and settings stay on your machine.`r`nReview any runtime JSON before sharing it publicly.`r`nThe repo keeps only sample config files."
    $privacyBody.Location = New-Object System.Drawing.Point(24, 308)
    $privacyBody.Size = New-Object System.Drawing.Size(238, 90)
    $privacyBody.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $privacyBody.ForeColor = $script:Theme.Ink
    [void]$creatorCard.Controls.Add($privacyBody)

    $termsLink = New-Object System.Windows.Forms.LinkLabel
    $termsLink.Text = 'License and Terms of Service'
    $termsLink.Location = New-Object System.Drawing.Point(24, 508)
    $termsLink.Size = New-Object System.Drawing.Size(238, 28)
    $termsLink.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $termsLink.LinkColor = $script:Theme.Accent
    $termsLink.Add_LinkClicked({ Show-LicenseTermsDialog })
    [void]$creatorCard.Controls.Add($termsLink)

    [void]$dialog.ShowDialog($script:Form)
}

function Get-KeyName {
    param([int]$VkCode)

    switch ($VkCode) {
        173 { return 'VolumeMute' }
        174 { return 'VolumeDown' }
        175 { return 'VolumeUp' }
        176 { return 'MediaNextTrack' }
        177 { return 'MediaPreviousTrack' }
        179 { return 'MediaPlayPause' }
    }

    try {
        return ([System.Windows.Forms.Keys]$VkCode).ToString()
    } catch {
        return "VK_$VkCode"
    }
}

function Format-TileKeyName {
    param([string]$KeyName)

    if ([string]::IsNullOrWhiteSpace($KeyName)) { return '' }

    switch ($KeyName) {
        'OemOpenBrackets' { return '[' }
        'Oem6'            { return ']' }
        'OemPeriod'       { return '.' }
        'OemComma'        { return ',' }
        'OemMinus'        { return '-' }
        'Oemplus'         { return '+' }
        'OemQuestion'     { return '/' }
        'OemSemicolon'    { return ';' }
        'Oemtilde'        { return '`' }
        'OemQuotes'       { return "'" }
        'OemBackslash'    { return '\' }
        'OemPipe'         { return '|' }
        'Return'          { return 'Enter' }
        'Prior'           { return 'PgUp' }
        'Next'            { return 'PgDn' }
        'Delete'          { return 'Del' }
        'Insert'          { return 'Ins' }
        'Capital'         { return 'CapsLk' }
        'Scroll'          { return 'ScrLk' }
        'Snapshot'        { return 'PrtSc' }
        default {
            if ($KeyName -match '^Oem') { return $KeyName -replace '^Oem', '' }
            return $KeyName
        }
    }
}

function Test-IsModifierVk {
    param([int]$VkCode)

    switch ($VkCode) {
        16 { return $true }
        17 { return $true }
        18 { return $true }
        160 { return $true }
        161 { return $true }
        162 { return $true }
        163 { return $true }
        164 { return $true }
        165 { return $true }
        91 { return $true }
        92 { return $true }
        default { return $false }
    }
}

function Test-IsMediaVk {
    param([int]$VkCode)

    switch ($VkCode) {
        173 { return $true }
        174 { return $true }
        175 { return $true }
        176 { return $true }
        177 { return $true }
        179 { return $true }
        default { return $false }
    }
}

function Start-CorrelatedCaptureWindow {
    param($RawEvent)

    $existingModifiers = @()
    if (
        $script:PendingCorrelatedCapture -and
        ([Environment]::TickCount -le $script:PendingCorrelatedCapture.Deadline) -and
        (
            $script:PendingCorrelatedCapture.DeviceId -eq $RawEvent.DeviceId -or
            (
                $script:PendingCorrelatedCapture.HardwareId -and
                $RawEvent.PSObject.Properties['HardwareId'] -and
                $script:PendingCorrelatedCapture.HardwareId -eq [string]$RawEvent.HardwareId
            )
        )
    ) {
        $existingModifiers = @($script:PendingCorrelatedCapture.ModifierVks)
    }

    $modifierVks = @($existingModifiers + @([int]$RawEvent.VirtualKey) | Select-Object -Unique | Sort-Object)
    $script:PendingCorrelatedCapture = [pscustomobject]@{
        DeviceId = $RawEvent.DeviceId
        HardwareId = if ($RawEvent.PSObject.Properties['HardwareId']) { [string]$RawEvent.HardwareId } else { '' }
        ModifierVks = $modifierVks
        Deadline = [Environment]::TickCount + 300
    }
}

function Start-CorrelatedTriggerWindow {
    param($RawEvent)

    $existingModifiers = @()
    if (
        $script:PendingCorrelatedTrigger -and
        ([Environment]::TickCount -le $script:PendingCorrelatedTrigger.Deadline) -and
        (
            $script:PendingCorrelatedTrigger.DeviceId -eq $RawEvent.DeviceId -or
            (
                $script:PendingCorrelatedTrigger.HardwareId -and
                $RawEvent.PSObject.Properties['HardwareId'] -and
                $script:PendingCorrelatedTrigger.HardwareId -eq [string]$RawEvent.HardwareId
            )
        )
    ) {
        $existingModifiers = @($script:PendingCorrelatedTrigger.ModifierVks)
    }

    $modifierVks = @($existingModifiers + @([int]$RawEvent.VirtualKey) | Select-Object -Unique | Sort-Object)
    $script:PendingCorrelatedTrigger = [pscustomobject]@{
        DeviceId = $RawEvent.DeviceId
        HardwareId = if ($RawEvent.PSObject.Properties['HardwareId']) { [string]$RawEvent.HardwareId } else { '' }
        ModifierVks = $modifierVks
        Deadline = [Environment]::TickCount + 300
    }
}

function Clear-ExpiredCorrelationWindows {
    $now = [Environment]::TickCount

    if ($script:PendingCorrelatedCapture -and ($now -gt $script:PendingCorrelatedCapture.Deadline)) {
        $script:PendingCorrelatedCapture = $null
    }

    if ($script:PendingCorrelatedTrigger -and ($now -gt $script:PendingCorrelatedTrigger.Deadline)) {
        $script:PendingCorrelatedTrigger = $null
    }
}

function Set-TargetDevice {
    param(
        [string]$DeviceId,
        [string]$DeviceName,
        [string]$HardwareId = ''
    )

    $script:TargetDeviceId = $DeviceId
    $script:TargetDeviceName = if ([string]::IsNullOrWhiteSpace($DeviceName) -or $DeviceName -match '^[\\/\s]+$') { 'Unknown keyboard' } else { $DeviceName }
    $script:TargetDeviceHardwareId = $HardwareId
    $script:Profile.targetDeviceId = $script:TargetDeviceId
    $script:Profile.targetDeviceName = $script:TargetDeviceName

    if ($script:DeviceValueLabel) {
        $script:DeviceValueLabel.Text = Get-DevicePickerLabel -Device @{
            DeviceName = $script:TargetDeviceName
            HardwareId = $script:TargetDeviceHardwareId
            DeviceId = $script:TargetDeviceId
        }
    }

    if ($script:DeviceStatusValueLabel) {
        if ($script:TargetDeviceId) {
            $script:DeviceStatusValueLabel.Text = 'Locked to device'
            $script:DeviceStatusValueLabel.ForeColor = $script:Theme.Good
        } else {
            $script:DeviceStatusValueLabel.Text = 'Not locked'
            $script:DeviceStatusValueLabel.ForeColor = $script:Theme.AccentWarm
        }
    }
}

function Get-DevicePickerLabel {
    param($Device)

    $name = if ($Device.DeviceName) { [string]$Device.DeviceName } else { 'Unknown keyboard' }
    $hardwareId = if ($Device.PSObject.Properties['HardwareId']) { [string]$Device.HardwareId } else { '' }
    $devicePath = if ($Device.PSObject.Properties['DevicePath']) { [string]$Device.DevicePath } else { '' }
    $role = ''

    if ($devicePath -match 'MI_00') {
        $role = 'main keys'
    } elseif ($devicePath -match 'MI_01') {
        $role = 'knob/media'
    } elseif ($devicePath -match 'Col0[34]') {
        $role = 'media collection'
    }

    if (-not [string]::IsNullOrWhiteSpace($hardwareId)) {
        if ($name -notmatch [regex]::Escape($hardwareId)) {
            $name = "$name - $hardwareId"
        }
    }

    if ($name -eq 'Unknown keyboard' -and $Device.DeviceId) {
        $name = "Unknown keyboard [$($Device.DeviceId)]"
    }

    if (-not [string]::IsNullOrWhiteSpace($role) -and $name -notmatch [regex]::Escape($role)) {
        $name = "$name [$role]"
    }

    return $name
}

function Get-DeviceRole {
    param([string]$DevicePath)

    if ([string]::IsNullOrWhiteSpace($DevicePath)) {
        return ''
    }

    if ($DevicePath -match 'MI_00') {
        return 'main keys'
    }

    if ($DevicePath -match 'MI_01') {
        return 'knob or media'
    }

    if ($DevicePath -match 'Col0[34]') {
        return 'media collection'
    }

    return 'keyboard input'
}

function Get-DeviceGroupKey {
    param($Device)

    if ($Device.PSObject.Properties['HardwareId'] -and -not [string]::IsNullOrWhiteSpace([string]$Device.HardwareId)) {
        return "hw::$([string]$Device.HardwareId)"
    }

    if ($Device.PSObject.Properties['DeviceName'] -and -not [string]::IsNullOrWhiteSpace([string]$Device.DeviceName)) {
        return "name::$([string]$Device.DeviceName)"
    }

    return "id::$([string]$Device.DeviceId)"
}

function New-DevicePickerLabel {
    param($Entry)

    $name = [string]$Entry.DeviceName
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '^[\\/\s]+$') {
        $name = 'Unknown keyboard'
    }

    $pieces = @($name)

    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.HardwareId) -and $name -notmatch [regex]::Escape([string]$Entry.HardwareId)) {
        $pieces += [string]$Entry.HardwareId
    }

    $roles = @($Entry.Roles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($roles.Count -gt 0) {
        $pieces += ($roles -join ', ')
    }

    if ($Entry.InterfaceCount -gt 1) {
        $pieces += "$($Entry.InterfaceCount) interfaces"
    }

    return ($pieces -join ' - ')
}

function Build-DevicePickerEntries {
    $groups = @{}

    foreach ($device in $script:DeviceOptions) {
        $groupKey = Get-DeviceGroupKey -Device $device
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [pscustomobject]@{
                GroupKey = $groupKey
                DeviceName = $device.DeviceName
                HardwareId = if ($device.PSObject.Properties['HardwareId']) { $device.HardwareId } else { '' }
                PrimaryDeviceId = $device.DeviceId
                DeviceIds = New-Object System.Collections.ArrayList
                Roles = New-Object System.Collections.ArrayList
                InterfaceCount = 0
            }
        }

        $entry = $groups[$groupKey]
        [void]$entry.DeviceIds.Add($device.DeviceId)
        [void]$entry.Roles.Add((Get-DeviceRole -DevicePath $(if ($device.PSObject.Properties['DevicePath']) { $device.DevicePath } else { '' })))
        $entry.InterfaceCount = $entry.DeviceIds.Count
    }

    $script:DevicePickerEntries = @(
        $groups.Values |
            Sort-Object DeviceName, HardwareId, PrimaryDeviceId
    )
}

function Device-MatchesTarget {
    param($RawEvent)

    if (-not $script:TargetDeviceId -and -not $script:TargetDeviceHardwareId) {
        return $false
    }

    if ($script:TargetDeviceHardwareId -and $RawEvent.PSObject.Properties['HardwareId']) {
        if (-not [string]::IsNullOrWhiteSpace([string]$RawEvent.HardwareId) -and $RawEvent.HardwareId -eq $script:TargetDeviceHardwareId) {
            return $true
        }
    }

    return $RawEvent.DeviceId -eq $script:TargetDeviceId
}

function Refresh-DevicePicker {
    $script:DeviceOptions = @([DeckPadNative.RawInputMonitor]::GetKeyboardDevices())
    Build-DevicePickerEntries
    $script:DeviceComboBox.Items.Clear()

    foreach ($entry in $script:DevicePickerEntries) {
        $label = New-DevicePickerLabel -Entry $entry
        [void]$script:DeviceComboBox.Items.Add($label)
    }

    if ($script:TargetDeviceHardwareId -or $script:TargetDeviceId) {
        for ($i = 0; $i -lt $script:DevicePickerEntries.Count; $i++) {
            $entry = $script:DevicePickerEntries[$i]
            if (
                ($script:TargetDeviceHardwareId -and $entry.HardwareId -eq $script:TargetDeviceHardwareId) -or
                ($entry.DeviceIds -contains $script:TargetDeviceId)
            ) {
                $script:DeviceComboBox.SelectedIndex = $i
                break
            }
        }
    } elseif ($script:DeviceComboBox.Items.Count -gt 0) {
        $script:DeviceComboBox.SelectedIndex = 0
    }
}

function Get-BindingForVk {
    param([int]$VkCode)

    foreach ($binding in $script:Profile.bindings) {
        $signature = if ($binding.PSObject.Properties['triggerSignature']) { [string]$binding.triggerSignature } else { '' }
        if ([string]::IsNullOrWhiteSpace($signature) -and [int]$binding.vkCode -eq $VkCode) {
            return $binding
        }
    }

    return $null
}

function Get-RawTriggerSignature {
    param(
        $RawEvent,
        [int[]]$ModifierVks = @()
    )

    $vk = [int]$RawEvent.VirtualKey
    $scan = if ($RawEvent.PSObject.Properties['ScanCode']) { [int]$RawEvent.ScanCode } else { 0 }
    $flags = if ($RawEvent.PSObject.Properties['KeyFlags']) { [int]$RawEvent.KeyFlags } else { 0 }
    $usage = if ($RawEvent.PSObject.Properties['ConsumerUsage']) { [int]$RawEvent.ConsumerUsage } else { 0 }
    $rawData = if ($RawEvent.PSObject.Properties['RawDataHex']) { [string]$RawEvent.RawDataHex } else { '' }
    $mods = (@($ModifierVks) | Where-Object { $_ -gt 0 } | Sort-Object -Unique) -join '+'

    if ($usage -gt 0 -or -not [string]::IsNullOrWhiteSpace($rawData)) {
        return "hid:vk=$vk;usage=$usage;raw=$rawData;mods=$mods"
    }

    return "kbd:vk=$vk;scan=$scan;flags=$flags;mods=$mods"
}

function Get-GlobalTriggerSignature {
    param([int]$VkCode)
    return "global:vk=$VkCode"
}

function Get-TriggerDisplayName {
    param(
        [string]$KeyName,
        [int[]]$ModifierVks = @()
    )

    $modNames = @()
    foreach ($vk in (@($ModifierVks) | Sort-Object -Unique)) {
        switch ([int]$vk) {
            16 { $modNames += 'Shift' }
            160 { $modNames += 'Shift' }
            161 { $modNames += 'Shift' }
            17 { $modNames += 'Ctrl' }
            162 { $modNames += 'Ctrl' }
            163 { $modNames += 'Ctrl' }
            18 { $modNames += 'Alt' }
            164 { $modNames += 'Alt' }
            165 { $modNames += 'Alt' }
            91 { $modNames += 'Win' }
            92 { $modNames += 'Win' }
        }
    }

    $modNames = @($modNames | Select-Object -Unique)
    if ($modNames.Count -eq 0) {
        return $KeyName
    }

    return (($modNames + @($KeyName)) -join '+')
}

function Get-BindingForRawEvent {
    param(
        $RawEvent,
        [int[]]$ModifierVks = @()
    )

    $signature = Get-RawTriggerSignature -RawEvent $RawEvent -ModifierVks $ModifierVks
    foreach ($binding in $script:Profile.bindings) {
        if ($binding.PSObject.Properties['triggerSignature'] -and [string]$binding.triggerSignature -eq $signature) {
            return $binding
        }
    }

    foreach ($binding in $script:Profile.bindings) {
        $bindingSignature = if ($binding.PSObject.Properties['triggerSignature']) { [string]$binding.triggerSignature } else { '' }
        if ([string]::IsNullOrWhiteSpace($bindingSignature) -and [int]$binding.vkCode -eq [int]$RawEvent.VirtualKey) {
            return $binding
        }
    }

    return $null
}

function Get-BindingForGlobalKey {
    param([int]$VkCode)

    $signature = Get-GlobalTriggerSignature -VkCode $VkCode
    foreach ($binding in $script:Profile.bindings) {
        if ($binding.PSObject.Properties['triggerSignature'] -and [string]$binding.triggerSignature -eq $signature) {
            return $binding
        }
    }

    return Get-BindingForVk -VkCode $VkCode
}

function Get-BindingTriggerSummary {
    param([object]$Binding)

    if (-not $Binding) {
        return 'Raw ID: not captured'
    }

    $signature = if ($Binding.PSObject.Properties['triggerSignature']) { [string]$Binding.triggerSignature } else { '' }
    if ([string]::IsNullOrWhiteSpace($signature)) {
        if ([int]$Binding.vkCode -gt 0) {
            return "Raw ID: legacy VK $($Binding.vkCode)"
        }
        return 'Raw ID: not captured'
    }

    if ($signature -match '^kbd:vk=(\d+);scan=(\d+);flags=(\d+);mods=(.*)$') {
        $mods = if ($matches[4]) { $matches[4] } else { 'none' }
        return "Raw ID: keyboard VK $($matches[1]), scan $($matches[2]), flags $($matches[3]), mods $mods"
    }

    if ($signature -match '^hid:vk=(\d+);usage=(\d+);raw=(.*);mods=(.*)$') {
        $raw = $matches[3]
        if ($raw.Length -gt 18) {
            $raw = $raw.Substring(0, 18) + '...'
        }
        $mods = if ($matches[4]) { $matches[4] } else { 'none' }
        return "Raw ID: HID VK $($matches[1]), usage $($matches[2]), raw $raw, mods $mods"
    }

    if ($signature -match '^global:vk=(\d+)$') {
        return "Raw ID: global VK $($matches[1])"
    }

    return "Raw ID: $signature"
}

function Set-BindingTriggerFromRawEvent {
    param(
        [object]$Binding,
        $RawEvent,
        [string]$KeyName,
        [int[]]$ModifierVks = @()
    )

    $Binding.vkCode = [int]$RawEvent.VirtualKey
    $Binding.keyName = Get-TriggerDisplayName -KeyName $KeyName -ModifierVks $ModifierVks
    if (-not ($Binding.PSObject.Properties.Name -contains 'triggerSignature')) {
        $Binding | Add-Member -NotePropertyName triggerSignature -NotePropertyValue '' -Force
    }
    $Binding.triggerSignature = Get-RawTriggerSignature -RawEvent $RawEvent -ModifierVks $ModifierVks
}

function Set-BindingTriggerFromGlobalKey {
    param(
        [object]$Binding,
        [int]$VkCode,
        [string]$KeyName
    )

    $Binding.vkCode = $VkCode
    $Binding.keyName = $KeyName
    if (-not ($Binding.PSObject.Properties.Name -contains 'triggerSignature')) {
        $Binding | Add-Member -NotePropertyName triggerSignature -NotePropertyValue '' -Force
    }
    $Binding.triggerSignature = Get-GlobalTriggerSignature -VkCode $VkCode
}

function ConvertTo-SafeProfileFileName {
    param([string]$Name)

    $safe = if ([string]::IsNullOrWhiteSpace($Name)) { 'deckpad-profile' } else { $Name.Trim().ToLowerInvariant() }
    $safe = $safe -replace '[^a-z0-9]+', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'deckpad-profile'
    }

    return $safe
}

function New-UniqueProfilePath {
    param([string]$ProfileName)

    $profileDir = Join-Path $script:AppRoot 'profiles'
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir | Out-Null
    }

    $baseName = ConvertTo-SafeProfileFileName -Name $ProfileName
    $candidate = Join-Path $profileDir "$baseName.json"
    $index = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $profileDir "$baseName-$index.json"
        $index++
    }

    return $candidate
}

function Get-RelativeProfilePath {
    param([string]$FullPath)
    return 'profiles\' + [IO.Path]::GetFileName($FullPath)
}

function New-DeckPadProfileFromCurrent {
    $inputName = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Name the new profile. DeckPad will copy your current key mappings and actions into it.',
        'Create Profile',
        $script:Profile.name
    )

    if ([string]::IsNullOrWhiteSpace($inputName)) {
        Add-LogLine 'Create profile cancelled'
        return
    }

    Save-CurrentBinding
    $script:Profile.name = $inputName.Trim()
    $newProfilePath = New-UniqueProfilePath -ProfileName $script:Profile.name
    $script:ProfilePath = $newProfilePath
    Save-Profile -Profile $script:Profile

    $relativePath = Get-RelativeProfilePath -FullPath $newProfilePath
    $script:Settings.startupProfilePath = $relativePath
    $script:Settings.loadDefaultProfileOnStartup = $true
    Save-Settings -Settings $script:Settings

    Populate-Editor
    Refresh-Tiles
    Add-LogLine "Created profile [$($script:Profile.name)] at [$relativePath]"
}

function Get-SelectedBinding {
    if ($script:SelectedIndex -lt 0 -or $script:SelectedIndex -ge $script:Profile.bindings.Count) {
        return $null
    }

    return $script:Profile.bindings[$script:SelectedIndex]
}

function Report-BindingConflicts {
    if (-not $script:Profile -or -not $script:Profile.bindings) {
        return
    }

    $duplicates = $script:Profile.bindings |
        Where-Object { [int]$_.vkCode -gt 0 } |
        ForEach-Object {
            $signature = if ($_.PSObject.Properties['triggerSignature'] -and -not [string]::IsNullOrWhiteSpace([string]$_.triggerSignature)) {
                [string]$_.triggerSignature
            } else {
                "vk:$($_.vkCode)"
            }
            [pscustomobject]@{
                Signature = $signature
                Binding = $_
            }
        } |
        Group-Object Signature |
        Where-Object { $_.Count -gt 1 }

    foreach ($group in $duplicates) {
        $keyNames = @($group.Group | ForEach-Object {
            if ($_.Binding.keyName) { $_.Binding.keyName } else { "VK $($_.Binding.vkCode)" }
        } | Select-Object -Unique)
        $slotNames = @($group.Group | ForEach-Object { $_.Binding.displayName })
        Add-LogLine ("Warning: duplicate trigger [{0}] is assigned to [{1}]" -f ($keyNames -join ', '), ($slotNames -join ', '))
    }
}

function Set-ListeningState {
    param([bool]$Enabled)

    $script:Listening = $Enabled
    if (-not $script:StatusPill -or -not $script:StatusValue) {
        return
    }

    if ($script:Listening) {
        $script:StatusPill.BackColor = $script:Theme.Good
        $script:StatusValue.Text = 'Live'
    } else {
        $script:StatusPill.BackColor = $script:Theme.AccentWarm
        $script:StatusValue.Text = 'Paused'
    }
}

function Update-ModeVisuals {
    if (-not $script:Form) {
        return
    }

    if ($script:UsesCleanLayout) {
        if ($script:CompactMode) {
            $script:Form.Size = $script:CompactWindowSize
            $script:Content.Panel2Collapsed = $true
            if ($script:CompactButton) { $script:CompactButton.Text = 'Expand' }
            if ($script:SubtitleLabel) { $script:SubtitleLabel.Text = 'Compact deck mode with device-aware input filtering.' }
            if ($script:DeviceHintLabel) { $script:DeviceHintLabel.Text = 'Choose or lock the mini pad, then keep the deck visible and ready.' }
            if ($script:ActivityHintLabel) { $script:ActivityHintLabel.Text = 'Compact mode shows just the deck and a short live log.' }
        } else {
            $script:Form.Size = $script:NormalWindowSize
            $script:Content.Panel2Collapsed = $false
            if ($script:CompactButton) { $script:CompactButton.Text = 'Compact' }
            if ($script:SubtitleLabel) { $script:SubtitleLabel.Text = 'Programmable deck controller - map 6 keys and 1 knob to apps, hotkeys, URLs, and more.' }
            if ($script:DeviceHintLabel) { $script:DeviceHintLabel.Text = 'Pick the mini pad from the list or use Lock To Device, then map every control however you want.' }
            if ($script:ActivityHintLabel) { $script:ActivityHintLabel.Text = 'Captured keys, app launches, Spotify controls, and device lock status.' }
            Apply-StableLayout
        }

        if ($script:PinButton) { $script:PinButton.Text = if ($script:PinnedMode) { 'Unpin' } else { 'Pin' } }
        $script:Form.TopMost = $script:PinnedMode
        return
    }

    if ($script:CompactMode) {
        $script:Form.Size = $script:CompactWindowSize
        $script:Content.Panel2Collapsed = $true
        $script:CompactButton.Text = 'Expand Mode'
        $script:SubtitleLabel.Text = 'Compact deck mode with device-aware input filtering.'
        $script:DeviceHintLabel.Text = 'Choose or lock the mini pad, then keep the deck visible and ready.'
        $script:ActivityHintLabel.Text = 'Compact mode shows just the deck and a short live log.'
        $script:DeviceCard.Size = New-Object System.Drawing.Size(900, 184)
        if ($script:GridSectionLabel) { $script:GridSectionLabel.Location = New-Object System.Drawing.Point(24, 278) }
        $script:GridPanel.Location = New-Object System.Drawing.Point(24, 300)
        $script:GridPanel.Size = New-Object System.Drawing.Size(900, 382)
        $script:ActivityTitle.Location = New-Object System.Drawing.Point(24, 704)
        $script:ActivityHintLabel.Location = New-Object System.Drawing.Point(24, 732)
        $script:LogBox.Location = New-Object System.Drawing.Point(24, 758)
        $script:LogBox.Size = New-Object System.Drawing.Size(900, 118)
    } else {
        $script:Form.Size = $script:NormalWindowSize
        $script:Content.Panel2Collapsed = $false
        $script:CompactButton.Text = 'Compact Mode'
        $script:SubtitleLabel.Text = 'Programmable deck controller - map 6 keys and 1 knob to apps, hotkeys, URLs, and more.'
        $script:DeviceHintLabel.Text = 'Pick the mini pad from the list or use Lock To Device, then map every control however you want.'
        $script:ActivityHintLabel.Text = 'Use this to see captured keys, app launches, Spotify volume changes, and device lock status.'
        $script:DeviceCard.Size = New-Object System.Drawing.Size(990, 184)
        if ($script:GridSectionLabel) { $script:GridSectionLabel.Location = New-Object System.Drawing.Point(24, 278) }
        $script:GridPanel.Location = New-Object System.Drawing.Point(24, 300)
        $script:GridPanel.Size = New-Object System.Drawing.Size(990, 374)
        $script:ActivityTitle.Location = New-Object System.Drawing.Point(24, 696)
        $script:ActivityHintLabel.Location = New-Object System.Drawing.Point(24, 724)
        $script:LogBox.Location = New-Object System.Drawing.Point(24, 750)
        $script:LogBox.Size = New-Object System.Drawing.Size(990, 128)
    }

    $script:PinButton.Text = if ($script:PinnedMode) { 'Unpin' } else { 'Pin' }
    $script:Form.TopMost = $script:PinnedMode
}

function Apply-StableLayout {
    if (-not $script:Content -or -not $script:Form) {
        return
    }

    if ($script:CompactMode) {
        return
    }

    $available = $script:Content.ClientSize.Width
    if ($available -le 0) {
        return
    }

    $rightWidth = 430
    $distance = $available - $rightWidth - $script:Content.SplitterWidth
    if ($distance -lt 940) {
        $distance = [Math]::Max(820, $available - 390 - $script:Content.SplitterWidth)
    }

    try {
        $script:Content.Panel1MinSize = 820
        $script:Content.Panel2MinSize = 380
        $script:Content.SplitterDistance = $distance
    } catch {
    }
}

function Toggle-CompactMode {
    $script:CompactMode = -not $script:CompactMode
    Update-ModeVisuals
    Add-LogLine ($(if ($script:CompactMode) { 'Switched to compact mode' } else { 'Returned to full mode' }))
}

function Toggle-PinnedMode {
    $script:PinnedMode = -not $script:PinnedMode
    Update-ModeVisuals
    Add-LogLine ($(if ($script:PinnedMode) { 'Window pinned on top' } else { 'Window unpinned' }))
}

function Refresh-TileStyles {
    for ($i = 0; $i -lt $script:TileButtons.Count; $i++) {
        $button = $script:TileButtons[$i]
        $binding = $script:Profile.bindings[$i]
        $palette = Get-SlotPalette -SlotId $binding.slotId

        if ($i -eq $script:SelectedIndex) {
            $button.BackColor = $script:Theme.Accent
            $button.ForeColor = [System.Drawing.Color]::White
            $button.FlatAppearance.BorderColor = $script:Theme.Accent
        } else {
            $button.BackColor = $palette.Fill
            $button.ForeColor = $script:Theme.Ink
            $button.FlatAppearance.BorderColor = $palette.Border
        }
    }
}

function Refresh-Tiles {
    for ($i = 0; $i -lt $script:Profile.bindings.Count; $i++) {
        $binding = $script:Profile.bindings[$i]
        $button = $script:TileButtons[$i]
        $badge = Get-ActionBadge -ActionType $binding.actionType
        $button.Text = "{1}`r`n{2}`r`n{0}  {3}" -f $badge, $binding.displayName, $binding.label, (Format-TileKeyName $binding.keyName)
    }

    Refresh-TileStyles
}

function Populate-Editor {
    $binding = Get-SelectedBinding
    if (-not $binding) {
        return
    }

    $script:ProfileNameBox.Text = $script:Profile.name
    $script:SlotNameValue.Text = $binding.displayName
    $script:LabelBox.Text = $binding.label
    $script:KeyBox.Text = $binding.keyName
    $script:VkBox.Text = [string]$binding.vkCode
    if ($script:TriggerDetailLabel) {
        $script:TriggerDetailLabel.Text = Get-BindingTriggerSummary -Binding $binding
    }
    $script:ActionTypeBox.SelectedItem = $binding.actionType
    $script:ValueBox.Text = $binding.value
    $script:SelectedBindingLabel.Text = "Editing $($binding.displayName)"
    $script:ActionHintLabel.Text = Get-ActionTemplate -ActionType $binding.actionType
    $script:DeviceValueLabel.Text = Get-DevicePickerLabel -Device @{
        DeviceName = $script:TargetDeviceName
        HardwareId = $script:TargetDeviceHardwareId
        DeviceId = $script:TargetDeviceId
    }
}

function Save-CurrentBinding {
    $binding = Get-SelectedBinding
    if (-not $binding) {
        return
    }

    $binding.label = $script:LabelBox.Text.Trim()
    $binding.keyName = $script:KeyBox.Text.Trim()
    $binding.vkCode = [int]$script:VkBox.Text
    $binding.actionType = [string]$script:ActionTypeBox.SelectedItem
    $binding.value = $script:ValueBox.Text
    $script:Profile.name = $script:ProfileNameBox.Text.Trim()
    Save-Profile -Profile $script:Profile
    Refresh-Tiles
    Populate-Editor
    Add-LogLine "Saved [$($binding.displayName)]"
    Report-BindingConflicts
}

function Build-TileGrid {
    $script:TileButtons = @()
    $script:GridPanel.Controls.Clear()

    for ($i = 0; $i -lt $script:Profile.bindings.Count; $i++) {
        $binding = $script:Profile.bindings[$i]
        $palette = Get-SlotPalette -SlotId $binding.slotId

        $button = New-Object System.Windows.Forms.Button
        $button.Dock = 'Fill'
        $button.Margin = New-Object System.Windows.Forms.Padding(12)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 1
        $button.FlatAppearance.BorderColor = $palette.Border
        $button.FlatAppearance.MouseDownBackColor = $script:Theme.AccentSoft
        $button.FlatAppearance.MouseOverBackColor = $palette.Hover
        $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
        $button.TextAlign = 'MiddleCenter'
        $button.UseVisualStyleBackColor = $false
        $button.Tag = $i
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        $button.Padding = New-Object System.Windows.Forms.Padding(10)
        $button.Add_Click({
            $script:SelectedIndex = [int]$this.Tag
            Populate-Editor
            Refresh-TileStyles
        })

        $script:TileButtons += $button
        [void]$script:GridPanel.Controls.Add($button)
    }
}

function Rebuild-CleanMainLayout {
    $script:Content.Panel1.Controls.Clear()
    $script:Content.Panel2.Controls.Clear()
    $script:UsesCleanLayout = $true

    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Dock = 'Fill'
    $leftPanel.BackColor = $script:Theme.Background
    [void]$script:Content.Panel1.Controls.Add($leftPanel)

    $rightPanel = New-Object System.Windows.Forms.Panel
    $rightPanel.Dock = 'Fill'
    $rightPanel.BackColor = $script:Theme.Panel
    $rightPanel.AutoScroll = $true
    [void]$script:Content.Panel2.Controls.Add($rightPanel)

    $commandBar = New-Object System.Windows.Forms.Panel
    $commandBar.Dock = 'Top'
    $commandBar.Height = 58
    $commandBar.BackColor = [System.Drawing.Color]::FromArgb(236, 242, 251)
    [void]$leftPanel.Controls.Add($commandBar)

    function New-CleanCommandButton {
        param(
            [string]$Text,
            [int]$X,
            [int]$W,
            [scriptblock]$OnClick,
            [string]$Variant = 'secondary'
        )

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, 12)
        $button.Size = New-Object System.Drawing.Size($W, 34)
        [void](Set-ButtonStyle -Button $button -Variant $Variant)
        $button.Add_Click($OnClick)
        [void]$commandBar.Controls.Add($button)
        return $button
    }

    [void](New-CleanCommandButton -Text 'Resume' -X 24 -W 86 -Variant 'primary' -OnClick {
        Set-ListeningState -Enabled $true
        Add-LogLine 'Listening resumed'
    })
    [void](New-CleanCommandButton -Text 'Pause' -X 118 -W 78 -OnClick {
        Set-ListeningState -Enabled $false
        Add-LogLine 'Listening paused'
    })
    [void](New-CleanCommandButton -Text 'Capture' -X 204 -W 92 -Variant 'success' -OnClick {
        $binding = Get-SelectedBinding
        if (-not $binding) {
            Add-LogLine 'Select a slot before capturing a key'
            return
        }
        $script:CaptureNextKey = $true
        if ($script:CaptureEditorButton) { $script:CaptureEditorButton.Text = 'Waiting...' }
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    })
    [void](New-CleanCommandButton -Text 'Save' -X 304 -W 72 -Variant 'primary' -OnClick { Save-CurrentBinding })
    [void](New-CleanCommandButton -Text 'Lock Device' -X 384 -W 106 -OnClick {
        $script:DeviceLockArmed = $true
        Add-LogLine 'Press any key on the mini pad to lock DeckPad to that device'
    })
    $script:CompactButton = New-CleanCommandButton -Text 'Compact' -X 498 -W 104 -OnClick { Toggle-CompactMode }
    $script:PinButton = New-CleanCommandButton -Text 'Pin' -X 610 -W 70 -OnClick { Toggle-PinnedMode }
    [void](New-CleanCommandButton -Text 'Settings' -X 688 -W 98 -Variant 'dark' -OnClick { Show-SettingsDialog })

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'
    $body.BackColor = $script:Theme.Background
    $body.Padding = New-Object System.Windows.Forms.Padding(24, 18, 24, 18)
    [void]$leftPanel.Controls.Add($body)
    $leftPanel.Controls.SetChildIndex($commandBar, 0)

    $deviceCard = New-Object System.Windows.Forms.Panel
    $deviceCard.Dock = 'Top'
    $deviceCard.Height = 172
    [void](Set-PanelSurface -Control $deviceCard)
    $script:DeviceCard = $deviceCard
    [void]$body.Controls.Add($deviceCard)

    $deviceTitle = New-Object System.Windows.Forms.Label
    $deviceTitle.Text = 'Programmable Deck'
    $deviceTitle.Location = New-Object System.Drawing.Point(20, 14)
    $deviceTitle.AutoSize = $true
    $deviceTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $deviceTitle.ForeColor = $script:Theme.Muted
    [void]$deviceCard.Controls.Add($deviceTitle)

    $deviceName = New-Object System.Windows.Forms.Label
    $deviceName.Text = '6 keys + 1 knob'
    $deviceName.Location = New-Object System.Drawing.Point(20, 38)
    $deviceName.AutoSize = $true
    $deviceName.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $deviceName.ForeColor = $script:Theme.Ink
    [void]$deviceCard.Controls.Add($deviceName)

    $deviceStatusLabel = New-Object System.Windows.Forms.Label
    $deviceStatusLabel.Text = 'Connection'
    $deviceStatusLabel.Location = New-Object System.Drawing.Point(20, 82)
    $deviceStatusLabel.AutoSize = $true
    $deviceStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $deviceStatusLabel.ForeColor = $script:Theme.Muted
    [void]$deviceCard.Controls.Add($deviceStatusLabel)

    $deviceStatusValueLabel = New-Object System.Windows.Forms.Label
    $deviceStatusValueLabel.Text = 'Not locked'
    $deviceStatusValueLabel.Location = New-Object System.Drawing.Point(20, 102)
    $deviceStatusValueLabel.AutoSize = $true
    $deviceStatusValueLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5, [System.Drawing.FontStyle]::Bold)
    $deviceStatusValueLabel.ForeColor = $script:Theme.AccentWarm
    $script:DeviceStatusValueLabel = $deviceStatusValueLabel
    [void]$deviceCard.Controls.Add($deviceStatusValueLabel)

    $deviceValueLabel = New-Object System.Windows.Forms.Label
    $deviceValueLabel.Text = $script:TargetDeviceName
    $deviceValueLabel.Location = New-Object System.Drawing.Point(20, 128)
    $deviceValueLabel.Size = New-Object System.Drawing.Size(430, 20)
    $deviceValueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $deviceValueLabel.ForeColor = $script:Theme.Accent
    $script:DeviceValueLabel = $deviceValueLabel
    [void]$deviceCard.Controls.Add($deviceValueLabel)

    $deviceHintLabel = New-Object System.Windows.Forms.Label
    $deviceHintLabel.Text = 'Pick the mini pad from the list or use Lock Device, then map every control however you want.'
    $deviceHintLabel.Location = New-Object System.Drawing.Point(20, 148)
    $deviceHintLabel.Size = New-Object System.Drawing.Size(430, 18)
    $deviceHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Regular)
    $deviceHintLabel.ForeColor = $script:Theme.Muted
    $script:DeviceHintLabel = $deviceHintLabel
    [void]$deviceCard.Controls.Add($deviceHintLabel)

    $devicePickerLabel = New-Object System.Windows.Forms.Label
    $devicePickerLabel.Text = 'Input Device'
    $devicePickerLabel.Location = New-Object System.Drawing.Point(500, 18)
    $devicePickerLabel.AutoSize = $true
    $devicePickerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $devicePickerLabel.ForeColor = $script:Theme.Muted
    [void]$deviceCard.Controls.Add($devicePickerLabel)

    $deviceComboBox = New-Object System.Windows.Forms.ComboBox
    $deviceComboBox.Location = New-Object System.Drawing.Point(500, 42)
    $deviceComboBox.Size = New-Object System.Drawing.Size(340, 30)
    $deviceComboBox.DropDownStyle = 'DropDownList'
    $deviceComboBox.DropDownWidth = 460
    [void](Set-InputStyle -Control $deviceComboBox)
    $script:DeviceComboBox = $deviceComboBox
    [void]$deviceCard.Controls.Add($deviceComboBox)

    $refreshDevicesButton = New-Object System.Windows.Forms.Button
    $refreshDevicesButton.Text = 'Refresh'
    $refreshDevicesButton.Location = New-Object System.Drawing.Point(500, 86)
    $refreshDevicesButton.Size = New-Object System.Drawing.Size(106, 34)
    [void](Set-ButtonStyle -Button $refreshDevicesButton -Variant 'secondary')
    $refreshDevicesButton.Add_Click({
        Refresh-DevicePicker
        Add-LogLine 'Refreshed keyboard device list'
    })
    [void]$deviceCard.Controls.Add($refreshDevicesButton)

    $useSelectedDeviceButton = New-Object System.Windows.Forms.Button
    $useSelectedDeviceButton.Text = 'Use Selected'
    $useSelectedDeviceButton.Location = New-Object System.Drawing.Point(616, 86)
    $useSelectedDeviceButton.Size = New-Object System.Drawing.Size(116, 34)
    [void](Set-ButtonStyle -Button $useSelectedDeviceButton -Variant 'primary')
    $useSelectedDeviceButton.Add_Click({
        if ($script:DeviceComboBox.SelectedIndex -ge 0 -and $script:DeviceComboBox.SelectedIndex -lt $script:DevicePickerEntries.Count) {
            $entry = $script:DevicePickerEntries[$script:DeviceComboBox.SelectedIndex]
            Set-TargetDevice -DeviceId $entry.PrimaryDeviceId -DeviceName $entry.DeviceName -HardwareId $entry.HardwareId
            Save-Profile -Profile $script:Profile
            Add-LogLine "Using selected device group [$($script:TargetDeviceName)]"
        }
    })
    [void]$deviceCard.Controls.Add($useSelectedDeviceButton)

    $deckPreviewPanel = New-Object System.Windows.Forms.Panel
    $deckPreviewPanel.Location = New-Object System.Drawing.Point(748, 86)
    $deckPreviewPanel.Size = New-Object System.Drawing.Size(92, 64)
    [void](Set-PanelSurface -Control $deckPreviewPanel -Variant 'alt')
    $deckPreviewPanel.Add_Paint({
        param($sender, $eventArgs)
        $g = $eventArgs.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($script:Theme.AccentSoft)
        $bodyBrush = New-Object System.Drawing.SolidBrush($script:Theme.Header)
        $keyBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $knobBrush = New-Object System.Drawing.SolidBrush($script:Theme.Accent)
        $pen = New-Object System.Drawing.Pen($script:Theme.StrongBorder, 1)
        $g.FillRectangle($bodyBrush, 10, 16, 52, 34)
        $g.DrawRectangle($pen, 10, 16, 52, 34)
        for ($row = 0; $row -lt 2; $row++) {
            for ($col = 0; $col -lt 3; $col++) {
                $x = 16 + ($col * 15)
                $y = 22 + ($row * 14)
                $g.FillRectangle($keyBrush, $x, $y, 9, 9)
                $g.DrawRectangle($pen, $x, $y, 9, 9)
            }
        }
        $g.FillEllipse($knobBrush, 62, 24, 18, 18)
        $g.DrawEllipse($pen, 62, 24, 18, 18)
        $bodyBrush.Dispose(); $keyBrush.Dispose(); $knobBrush.Dispose(); $pen.Dispose()
    })
    [void]$deviceCard.Controls.Add($deckPreviewPanel)

    $mainArea = New-Object System.Windows.Forms.TableLayoutPanel
    $mainArea.Dock = 'Fill'
    $mainArea.ColumnCount = 1
    $mainArea.RowCount = 4
    $mainArea.BackColor = $script:Theme.Background
    $mainArea.Padding = New-Object System.Windows.Forms.Padding(0, 18, 0, 0)
    [void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 68)))
    [void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))
    [void]$mainArea.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 32)))
    [void]$body.Controls.Add($mainArea)

    $gridSectionLabel = New-Object System.Windows.Forms.Label
    $gridSectionLabel.Text = 'Physical Controls  |  Click any tile below to configure it'
    $gridSectionLabel.Dock = 'Fill'
    $gridSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $gridSectionLabel.ForeColor = $script:Theme.Muted
    [void]$mainArea.Controls.Add($gridSectionLabel, 0, 0)
    $script:GridSectionLabel = $gridSectionLabel

    $gridPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $gridPanel.Dock = 'Fill'
    $gridPanel.ColumnCount = 3
    $gridPanel.RowCount = 3
    $gridPanel.BackColor = $script:Theme.Canvas
    $gridPanel.GrowStyle = 'FixedSize'
    $gridPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    $script:GridPanel = $gridPanel
    [void]$mainArea.Controls.Add($gridPanel, 0, 1)

    $activityHeader = New-Object System.Windows.Forms.Panel
    $activityHeader.Dock = 'Fill'
    $activityHeader.BackColor = $script:Theme.Background
    [void]$mainArea.Controls.Add($activityHeader, 0, 2)

    $activityTitle = New-Object System.Windows.Forms.Label
    $activityTitle.Text = 'Activity'
    $activityTitle.Location = New-Object System.Drawing.Point(0, 10)
    $activityTitle.AutoSize = $true
    $activityTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $activityTitle.ForeColor = $script:Theme.Ink
    $script:ActivityTitle = $activityTitle
    [void]$activityHeader.Controls.Add($activityTitle)

    $activityHintLabel = New-Object System.Windows.Forms.Label
    $activityHintLabel.Text = 'Captured keys, app launches, Spotify controls, and device lock status.'
    $activityHintLabel.Location = New-Object System.Drawing.Point(0, 38)
    $activityHintLabel.AutoSize = $true
    $activityHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $activityHintLabel.ForeColor = $script:Theme.Muted
    $script:ActivityHintLabel = $activityHintLabel
    [void]$activityHeader.Controls.Add($activityHintLabel)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Dock = 'Fill'
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.BackColor = $script:Theme.Panel
    $logBox.ForeColor = $script:Theme.Ink
    $logBox.BorderStyle = 'FixedSingle'
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    $script:LogBox = $logBox
    [void]$mainArea.Controls.Add($logBox, 0, 3)

    $editorHeader = New-Object System.Windows.Forms.Panel
    $editorHeader.Location = New-Object System.Drawing.Point(0, 0)
    $editorHeader.Size = New-Object System.Drawing.Size(430, 72)
    $editorHeader.Anchor = 'Top,Left,Right'
    $editorHeader.BackColor = [System.Drawing.Color]::FromArgb(247, 250, 255)
    $editorHeader.BorderStyle = 'FixedSingle'
    [void]$rightPanel.Controls.Add($editorHeader)

    $editorTitle = New-Object System.Windows.Forms.Label
    $editorTitle.Text = 'Configure Control'
    $editorTitle.Location = New-Object System.Drawing.Point(18, 12)
    $editorTitle.AutoSize = $true
    $editorTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $editorTitle.ForeColor = $script:Theme.Ink
    [void]$editorHeader.Controls.Add($editorTitle)

    $selectedBindingLabel = New-Object System.Windows.Forms.Label
    $selectedBindingLabel.Text = 'Editing Top Left'
    $selectedBindingLabel.Location = New-Object System.Drawing.Point(20, 44)
    $selectedBindingLabel.AutoSize = $true
    $selectedBindingLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $selectedBindingLabel.ForeColor = $script:Theme.Accent
    $script:SelectedBindingLabel = $selectedBindingLabel
    [void]$editorHeader.Controls.Add($selectedBindingLabel)

    $howToPanel = New-Object System.Windows.Forms.Panel
    $howToPanel.Location = New-Object System.Drawing.Point(18, 88)
    $howToPanel.Size = New-Object System.Drawing.Size(364, 80)
    $howToPanel.BackColor = $script:Theme.AccentSoft
    [void]$rightPanel.Controls.Add($howToPanel)

    $howToSteps = New-Object System.Windows.Forms.Label
    $howToSteps.Text = "Select a tile, capture the physical button, choose an action, then save."
    $howToSteps.Location = New-Object System.Drawing.Point(14, 14)
    $howToSteps.Size = New-Object System.Drawing.Size(334, 50)
    $howToSteps.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $howToSteps.ForeColor = $script:Theme.Ink
    [void]$howToPanel.Controls.Add($howToSteps)

    function New-CleanFieldLabel {
        param([string]$Text, [int]$Y)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point(20, $Y)
        $label.AutoSize = $true
        $label.ForeColor = $script:Theme.Muted
        $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        [void]$rightPanel.Controls.Add($label)
        return $label
    }

    function New-CleanTextBox {
        param([int]$Y, [int]$Height = 34)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Location = New-Object System.Drawing.Point(20, ($Y + 24))
        $box.Size = New-Object System.Drawing.Size(362, $Height)
        $box.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
        [void](Set-InputStyle -Control $box)
        [void]$rightPanel.Controls.Add($box)
        return $box
    }

    [void](New-CleanFieldLabel -Text 'Physical Control' -Y 188)
    $slotNameValue = New-Object System.Windows.Forms.Label
    $slotNameValue.Location = New-Object System.Drawing.Point(22, 212)
    $slotNameValue.AutoSize = $true
    $slotNameValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
    $slotNameValue.ForeColor = $script:Theme.Ink
    $script:SlotNameValue = $slotNameValue
    [void]$rightPanel.Controls.Add($slotNameValue)

    [void](New-CleanFieldLabel -Text 'Display Label' -Y 248)
    $script:LabelBox = New-CleanTextBox -Y 248

    [void](New-CleanFieldLabel -Text 'Trigger Key' -Y 312)
    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(20, 336)
    $keyBox.Size = New-Object System.Drawing.Size(174, 34)
    $keyBox.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $keyBox)
    $script:KeyBox = $keyBox
    [void]$rightPanel.Controls.Add($keyBox)

    $captureEditorButton = New-Object System.Windows.Forms.Button
    $captureEditorButton.Text = 'Capture Key'
    $captureEditorButton.Location = New-Object System.Drawing.Point(206, 334)
    $captureEditorButton.Size = New-Object System.Drawing.Size(176, 36)
    [void](Set-ButtonStyle -Button $captureEditorButton -Variant 'success')
    $captureEditorButton.Add_Click({
        $binding = Get-SelectedBinding
        if (-not $binding) {
            Add-LogLine 'Select a slot before capturing a key'
            return
        }
        if ($script:CaptureNextKey) {
            $script:CaptureNextKey = $false
            $script:CaptureEditorButton.Text = 'Capture Key'
            Add-LogLine 'Capture cancelled'
            return
        }
        $script:CaptureNextKey = $true
        $script:CaptureEditorButton.Text = 'Waiting...'
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    })
    $script:CaptureEditorButton = $captureEditorButton
    [void]$rightPanel.Controls.Add($captureEditorButton)

    $vkBox = New-Object System.Windows.Forms.TextBox
    $vkBox.Visible = $false
    $script:VkBox = $vkBox
    [void]$rightPanel.Controls.Add($vkBox)

    [void](New-CleanFieldLabel -Text 'Action Type' -Y 386)
    $actionTypeBox = New-Object System.Windows.Forms.ComboBox
    $actionTypeBox.Location = New-Object System.Drawing.Point(20, 410)
    $actionTypeBox.Size = New-Object System.Drawing.Size(362, 36)
    $actionTypeBox.DropDownStyle = 'DropDownList'
    [void](Set-InputStyle -Control $actionTypeBox)
    [void]$actionTypeBox.Items.AddRange(@(
        'focus_or_launch',
        'launch_app',
        'open_url',
        'type_text',
        'send_hotkey',
        'run_command',
        'spotify_volume_down',
        'spotify_play_pause',
        'spotify_previous_track',
        'spotify_next_track',
        'spotify_volume_up'
    ))
    $actionTypeBox.Add_SelectedIndexChanged({
        $script:ActionHintLabel.Text = Get-ActionTemplate -ActionType ([string]$script:ActionTypeBox.SelectedItem)
    })
    $script:ActionTypeBox = $actionTypeBox
    [void]$rightPanel.Controls.Add($actionTypeBox)

    $actionHintLabel = New-Object System.Windows.Forms.Label
    $actionHintLabel.Location = New-Object System.Drawing.Point(22, 450)
    $actionHintLabel.Size = New-Object System.Drawing.Size(360, 30)
    $actionHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $actionHintLabel.ForeColor = $script:Theme.Muted
    $script:ActionHintLabel = $actionHintLabel
    [void]$rightPanel.Controls.Add($actionHintLabel)

    [void](New-CleanFieldLabel -Text 'Action Value' -Y 486)
    $valueBox = New-Object System.Windows.Forms.TextBox
    $valueBox.Location = New-Object System.Drawing.Point(20, 510)
    $valueBox.Size = New-Object System.Drawing.Size(362, 92)
    $valueBox.Multiline = $true
    $valueBox.ScrollBars = 'Vertical'
    $valueBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $valueBox)
    $script:ValueBox = $valueBox
    [void]$rightPanel.Controls.Add($valueBox)

    $saveEditorButton = New-Object System.Windows.Forms.Button
    $saveEditorButton.Text = 'Save Slot'
    $saveEditorButton.Location = New-Object System.Drawing.Point(20, 618)
    $saveEditorButton.Size = New-Object System.Drawing.Size(140, 40)
    [void](Set-ButtonStyle -Button $saveEditorButton -Variant 'primary')
    $saveEditorButton.Add_Click({ Save-CurrentBinding })
    [void]$rightPanel.Controls.Add($saveEditorButton)

    $profileFolderButton = New-Object System.Windows.Forms.Button
    $profileFolderButton.Text = 'Profile Folder'
    $profileFolderButton.Location = New-Object System.Drawing.Point(170, 618)
    $profileFolderButton.Size = New-Object System.Drawing.Size(136, 40)
    [void](Set-ButtonStyle -Button $profileFolderButton -Variant 'secondary')
    $profileFolderButton.Add_Click({ Start-Process explorer.exe (Split-Path -Parent $script:ProfilePath) })
    [void]$rightPanel.Controls.Add($profileFolderButton)

    [void](New-CleanFieldLabel -Text 'Profile Name' -Y 674)
    $script:ProfileNameBox = New-CleanTextBox -Y 674

    $helperLabel = New-Object System.Windows.Forms.Label
    $helperLabel.Text = 'Tip: Lock the deck to your device first so only its keys trigger actions.'
    $helperLabel.Location = New-Object System.Drawing.Point(20, 742)
    $helperLabel.Size = New-Object System.Drawing.Size(364, 48)
    $helperLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Italic)
    $helperLabel.ForeColor = $script:Theme.Muted
    [void]$rightPanel.Controls.Add($helperLabel)
}

function Rebuild-ProfessionalLayout {
    $script:Content.Panel1.Controls.Clear()
    $script:Content.Panel2.Controls.Clear()
    $script:UsesCleanLayout = $true

    $left = New-Object System.Windows.Forms.TableLayoutPanel
    $left.Dock = 'Fill'
    $left.BackColor = $script:Theme.Background
    $left.Padding = New-Object System.Windows.Forms.Padding(24, 18, 24, 18)
    $left.ColumnCount = 1
    $left.RowCount = 7
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 62)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 138)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 58)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 42)))
    [void]$script:Content.Panel1.Controls.Add($left)

    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Fill'
    $right.BackColor = $script:Theme.Panel
    $right.AutoScroll = $true
    $right.Padding = New-Object System.Windows.Forms.Padding(24, 22, 24, 22)
    [void]$script:Content.Panel2.Controls.Add($right)

    $commandBar = New-Object System.Windows.Forms.TableLayoutPanel
    $commandBar.Dock = 'Fill'
    $commandBar.BackColor = [System.Drawing.Color]::FromArgb(226, 237, 252)
    $commandBar.ColumnCount = 10
    $commandBar.RowCount = 1
    $commandBar.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 10)
    foreach ($width in @(92, 84, 100, 78, 120, 106, 76)) {
        [void]$commandBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $width)))
    }
    [void]$commandBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$commandBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 112)))
    [void]$commandBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 4)))
    [void]$left.Controls.Add($commandBar, 0, 0)

    function New-CommandButton {
        param([string]$Text, [string]$Variant, [scriptblock]$OnClick)
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Dock = 'Fill'
        $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
        [void](Set-ButtonStyle -Button $button -Variant $Variant)
        $button.Add_Click($OnClick)
        return $button
    }

    [void]$commandBar.Controls.Add((New-CommandButton -Text 'Resume' -Variant 'primary' -OnClick { Set-ListeningState -Enabled $true; Add-LogLine 'Listening resumed' }), 0, 0)
    [void]$commandBar.Controls.Add((New-CommandButton -Text 'Pause' -Variant 'secondary' -OnClick { Set-ListeningState -Enabled $false; Add-LogLine 'Listening paused' }), 1, 0)
    [void]$commandBar.Controls.Add((New-CommandButton -Text 'Capture' -Variant 'success' -OnClick {
        $binding = Get-SelectedBinding
        if (-not $binding) { Add-LogLine 'Select a slot before capturing a key'; return }
        $script:CaptureNextKey = $true
        if ($script:CaptureEditorButton) { $script:CaptureEditorButton.Text = 'Waiting...' }
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    }), 2, 0)
    [void]$commandBar.Controls.Add((New-CommandButton -Text 'Save' -Variant 'primary' -OnClick { Save-CurrentBinding }), 3, 0)
    [void]$commandBar.Controls.Add((New-CommandButton -Text 'Lock Device' -Variant 'secondary' -OnClick { $script:DeviceLockArmed = $true; Add-LogLine 'Press any key on the mini pad to lock DeckPad to that device' }), 4, 0)
    $script:CompactButton = New-CommandButton -Text 'Compact' -Variant 'secondary' -OnClick { Toggle-CompactMode }
    [void]$commandBar.Controls.Add($script:CompactButton, 5, 0)
    $script:PinButton = New-CommandButton -Text 'Pin' -Variant 'secondary' -OnClick { Toggle-PinnedMode }
    [void]$commandBar.Controls.Add($script:PinButton, 6, 0)
    [void]$commandBar.Controls.Add((New-CommandButton -Text 'Settings' -Variant 'dark' -OnClick { Show-SettingsDialog }), 8, 0)

    $deviceCard = New-Object System.Windows.Forms.TableLayoutPanel
    $deviceCard.Dock = 'Fill'
    $deviceCard.ColumnCount = 3
    $deviceCard.RowCount = 1
    $deviceCard.Margin = New-Object System.Windows.Forms.Padding(0, 14, 0, 12)
    $deviceCard.Padding = New-Object System.Windows.Forms.Padding(20, 14, 20, 14)
    $deviceCard.BackColor = $script:Theme.Panel
    $deviceCard.CellBorderStyle = 'None'
    [void]$deviceCard.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 38)))
    [void]$deviceCard.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 42)))
    [void]$deviceCard.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 112)))
    $script:DeviceCard = $deviceCard
    [void]$left.Controls.Add($deviceCard, 0, 1)

    $deviceInfo = New-Object System.Windows.Forms.Panel
    $deviceInfo.Dock = 'Fill'
    $deviceInfo.BackColor = $script:Theme.Panel
    [void]$deviceCard.Controls.Add($deviceInfo, 0, 0)

    $deviceTitle = New-Object System.Windows.Forms.Label
    $deviceTitle.Text = 'Programmable Deck'
    $deviceTitle.Location = New-Object System.Drawing.Point(0, 0)
    $deviceTitle.AutoSize = $true
    $deviceTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $deviceTitle.ForeColor = $script:Theme.Muted
    [void]$deviceInfo.Controls.Add($deviceTitle)

    $deviceName = New-Object System.Windows.Forms.Label
    $deviceName.Text = '6 keys + 1 knob'
    $deviceName.Location = New-Object System.Drawing.Point(0, 24)
    $deviceName.AutoSize = $true
    $deviceName.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
    $deviceName.ForeColor = $script:Theme.Ink
    [void]$deviceInfo.Controls.Add($deviceName)

    $deviceStatusValueLabel = New-Object System.Windows.Forms.Label
    $deviceStatusValueLabel.Text = 'Not locked'
    $deviceStatusValueLabel.Location = New-Object System.Drawing.Point(0, 76)
    $deviceStatusValueLabel.Size = New-Object System.Drawing.Size(320, 22)
    $deviceStatusValueLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $deviceStatusValueLabel.ForeColor = $script:Theme.AccentWarm
    $script:DeviceStatusValueLabel = $deviceStatusValueLabel
    [void]$deviceInfo.Controls.Add($deviceStatusValueLabel)

    $deviceValueLabel = New-Object System.Windows.Forms.Label
    $deviceValueLabel.Text = $script:TargetDeviceName
    $deviceValueLabel.Location = New-Object System.Drawing.Point(0, 100)
    $deviceValueLabel.Size = New-Object System.Drawing.Size(340, 22)
    $deviceValueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $deviceValueLabel.ForeColor = $script:Theme.Accent
    $script:DeviceValueLabel = $deviceValueLabel
    [void]$deviceInfo.Controls.Add($deviceValueLabel)

    $devicePickerPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $devicePickerPanel.Dock = 'Fill'
    $devicePickerPanel.ColumnCount = 2
    $devicePickerPanel.RowCount = 3
    $devicePickerPanel.BackColor = $script:Theme.Panel
    [void]$devicePickerPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$devicePickerPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$devicePickerPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    [void]$devicePickerPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$devicePickerPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$deviceCard.Controls.Add($devicePickerPanel, 1, 0)

    $devicePickerLabel = New-Object System.Windows.Forms.Label
    $devicePickerLabel.Text = 'Input device'
    $devicePickerLabel.Dock = 'Fill'
    $devicePickerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $devicePickerLabel.ForeColor = $script:Theme.Muted
    [void]$devicePickerPanel.Controls.Add($devicePickerLabel, 0, 0)
    $devicePickerPanel.SetColumnSpan($devicePickerLabel, 2)

    $deviceComboBox = New-Object System.Windows.Forms.ComboBox
    $deviceComboBox.Dock = 'Fill'
    $deviceComboBox.DropDownStyle = 'DropDownList'
    $deviceComboBox.DropDownWidth = 520
    [void](Set-InputStyle -Control $deviceComboBox)
    $script:DeviceComboBox = $deviceComboBox
    [void]$devicePickerPanel.Controls.Add($deviceComboBox, 0, 1)
    $devicePickerPanel.SetColumnSpan($deviceComboBox, 2)

    $refreshDevicesButton = New-Object System.Windows.Forms.Button
    $refreshDevicesButton.Text = 'Refresh'
    $refreshDevicesButton.Dock = 'Fill'
    $refreshDevicesButton.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 0)
    [void](Set-ButtonStyle -Button $refreshDevicesButton -Variant 'secondary')
    $refreshDevicesButton.Add_Click({ Refresh-DevicePicker; Add-LogLine 'Refreshed keyboard device list' })
    [void]$devicePickerPanel.Controls.Add($refreshDevicesButton, 0, 2)

    $useSelectedDeviceButton = New-Object System.Windows.Forms.Button
    $useSelectedDeviceButton.Text = 'Use Selected'
    $useSelectedDeviceButton.Dock = 'Fill'
    $useSelectedDeviceButton.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    [void](Set-ButtonStyle -Button $useSelectedDeviceButton -Variant 'primary')
    $useSelectedDeviceButton.Add_Click({
        if ($script:DeviceComboBox.SelectedIndex -ge 0 -and $script:DeviceComboBox.SelectedIndex -lt $script:DevicePickerEntries.Count) {
            $entry = $script:DevicePickerEntries[$script:DeviceComboBox.SelectedIndex]
            Set-TargetDevice -DeviceId $entry.PrimaryDeviceId -DeviceName $entry.DeviceName -HardwareId $entry.HardwareId
            Save-Profile -Profile $script:Profile
            Add-LogLine "Using selected device group [$($script:TargetDeviceName)]"
        }
    })
    [void]$devicePickerPanel.Controls.Add($useSelectedDeviceButton, 1, 2)

    $deckPreviewPanel = New-Object System.Windows.Forms.Panel
    $deckPreviewPanel.Dock = 'Fill'
    $deckPreviewPanel.Margin = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
    [void](Set-PanelSurface -Control $deckPreviewPanel -Variant 'alt')
    $deckPreviewPanel.Add_Paint({
        param($sender, $eventArgs)
        $g = $eventArgs.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($script:Theme.AccentSoft)
        $bodyBrush = New-Object System.Drawing.SolidBrush($script:Theme.Header)
        $keyBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $knobBrush = New-Object System.Drawing.SolidBrush($script:Theme.Accent)
        $pen = New-Object System.Drawing.Pen($script:Theme.StrongBorder, 1)
        $g.FillRectangle($bodyBrush, 15, 36, 58, 42)
        $g.DrawRectangle($pen, 15, 36, 58, 42)
        for ($row = 0; $row -lt 2; $row++) {
            for ($col = 0; $col -lt 3; $col++) {
                $x = 24 + ($col * 16)
                $y = 44 + ($row * 16)
                $g.FillRectangle($keyBrush, $x, $y, 10, 10)
                $g.DrawRectangle($pen, $x, $y, 10, 10)
            }
        }
        $g.FillEllipse($knobBrush, 74, 48, 20, 20)
        $g.DrawEllipse($pen, 74, 48, 20, 20)
        $bodyBrush.Dispose(); $keyBrush.Dispose(); $knobBrush.Dispose(); $pen.Dispose()
    })
    [void]$deviceCard.Controls.Add($deckPreviewPanel, 2, 0)

    $gridSectionLabel = New-Object System.Windows.Forms.Label
    $gridSectionLabel.Text = 'Physical Controls  |  top row: 1-3, bottom row: 4-6, knob: left / press / right'
    $gridSectionLabel.Dock = 'Fill'
    $gridSectionLabel.TextAlign = 'BottomLeft'
    $gridSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $gridSectionLabel.ForeColor = $script:Theme.Muted
    $script:GridSectionLabel = $gridSectionLabel
    [void]$left.Controls.Add($gridSectionLabel, 0, 2)

    $gridPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $gridPanel.Dock = 'Fill'
    $gridPanel.ColumnCount = 3
    $gridPanel.RowCount = 3
    $gridPanel.BackColor = $script:Theme.Canvas
    $gridPanel.GrowStyle = 'FixedSize'
    $gridPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    $script:GridPanel = $gridPanel
    [void]$left.Controls.Add($gridPanel, 0, 3)

    $activityTitle = New-Object System.Windows.Forms.Label
    $activityTitle.Text = 'Activity'
    $activityTitle.Dock = 'Fill'
    $activityTitle.TextAlign = 'BottomLeft'
    $activityTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $activityTitle.ForeColor = $script:Theme.Ink
    $script:ActivityTitle = $activityTitle
    [void]$left.Controls.Add($activityTitle, 0, 4)

    $activityHintLabel = New-Object System.Windows.Forms.Label
    $activityHintLabel.Text = 'Captured keys, app launches, Spotify controls, and device lock status.'
    $activityHintLabel.Dock = 'Fill'
    $activityHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $activityHintLabel.ForeColor = $script:Theme.Muted
    $script:ActivityHintLabel = $activityHintLabel
    [void]$left.Controls.Add($activityHintLabel, 0, 5)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Dock = 'Fill'
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.BackColor = $script:Theme.Panel
    $logBox.ForeColor = $script:Theme.Ink
    $logBox.BorderStyle = 'FixedSingle'
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    $script:LogBox = $logBox
    [void]$left.Controls.Add($logBox, 0, 6)

    $editorTitle = New-Object System.Windows.Forms.Label
    $editorTitle.Text = 'Configure Control'
    $editorTitle.Location = New-Object System.Drawing.Point(24, 18)
    $editorTitle.AutoSize = $true
    $editorTitle.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $editorTitle.ForeColor = $script:Theme.Ink
    [void]$right.Controls.Add($editorTitle)

    $selectedBindingLabel = New-Object System.Windows.Forms.Label
    $selectedBindingLabel.Text = 'Editing Top Left'
    $selectedBindingLabel.Location = New-Object System.Drawing.Point(26, 54)
    $selectedBindingLabel.AutoSize = $true
    $selectedBindingLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $selectedBindingLabel.ForeColor = $script:Theme.Accent
    $script:SelectedBindingLabel = $selectedBindingLabel
    [void]$right.Controls.Add($selectedBindingLabel)

    $howToPanel = New-Object System.Windows.Forms.Panel
    $howToPanel.Location = New-Object System.Drawing.Point(24, 88)
    $howToPanel.Size = New-Object System.Drawing.Size(362, 74)
    $howToPanel.BackColor = $script:Theme.AccentSoft
    [void]$right.Controls.Add($howToPanel)
    $howToSteps = New-Object System.Windows.Forms.Label
    $howToSteps.Text = "1. Select a tile`r`n2. Click Capture Key and press the pad button`r`n3. Pick an action and Save Slot"
    $howToSteps.Location = New-Object System.Drawing.Point(14, 10)
    $howToSteps.Size = New-Object System.Drawing.Size(334, 56)
    $howToSteps.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $howToSteps.ForeColor = $script:Theme.Ink
    [void]$howToPanel.Controls.Add($howToSteps)

    function New-EditorLabel {
        param([string]$Text, [int]$Y)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point(24, $Y)
        $label.AutoSize = $true
        $label.ForeColor = $script:Theme.Muted
        $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        [void]$right.Controls.Add($label)
        return $label
    }

    function New-EditorBox {
        param([int]$Y, [int]$Height = 28)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Location = New-Object System.Drawing.Point(24, ($Y + 24))
        $box.Size = New-Object System.Drawing.Size(362, $Height)
        $box.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
        [void](Set-InputStyle -Control $box)
        [void]$right.Controls.Add($box)
        return $box
    }

    [void](New-EditorLabel -Text 'Physical Control' -Y 188)
    $slotNameValue = New-Object System.Windows.Forms.Label
    $slotNameValue.Location = New-Object System.Drawing.Point(26, 212)
    $slotNameValue.AutoSize = $true
    $slotNameValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
    $slotNameValue.ForeColor = $script:Theme.Ink
    $script:SlotNameValue = $slotNameValue
    [void]$right.Controls.Add($slotNameValue)

    [void](New-EditorLabel -Text 'Display Label' -Y 250)
    $script:LabelBox = New-EditorBox -Y 250

    [void](New-EditorLabel -Text 'Trigger Key' -Y 314)
    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(24, 338)
    $keyBox.Size = New-Object System.Drawing.Size(174, 28)
    $keyBox.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $keyBox)
    $script:KeyBox = $keyBox
    [void]$right.Controls.Add($keyBox)
    $captureEditorButton = New-Object System.Windows.Forms.Button
    $captureEditorButton.Text = 'Capture Key'
    $captureEditorButton.Location = New-Object System.Drawing.Point(210, 336)
    $captureEditorButton.Size = New-Object System.Drawing.Size(176, 32)
    [void](Set-ButtonStyle -Button $captureEditorButton -Variant 'success')
    $captureEditorButton.Add_Click({
        $binding = Get-SelectedBinding
        if (-not $binding) { Add-LogLine 'Select a slot before capturing a key'; return }
        if ($script:CaptureNextKey) {
            $script:CaptureNextKey = $false
            $script:CaptureEditorButton.Text = 'Capture Key'
            Add-LogLine 'Capture cancelled'
            return
        }
        $script:CaptureNextKey = $true
        $script:CaptureEditorButton.Text = 'Waiting...'
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    })
    $script:CaptureEditorButton = $captureEditorButton
    [void]$right.Controls.Add($captureEditorButton)

    $vkBox = New-Object System.Windows.Forms.TextBox
    $vkBox.Visible = $false
    $script:VkBox = $vkBox
    [void]$right.Controls.Add($vkBox)

    [void](New-EditorLabel -Text 'Action Type' -Y 390)
    $actionTypeBox = New-Object System.Windows.Forms.ComboBox
    $actionTypeBox.Location = New-Object System.Drawing.Point(24, 414)
    $actionTypeBox.Size = New-Object System.Drawing.Size(362, 30)
    $actionTypeBox.DropDownStyle = 'DropDownList'
    [void](Set-InputStyle -Control $actionTypeBox)
    [void]$actionTypeBox.Items.AddRange(@(
        'focus_or_launch',
        'launch_app',
        'open_url',
        'type_text',
        'send_hotkey',
        'run_command',
        'spotify_volume_down',
        'spotify_play_pause',
        'spotify_previous_track',
        'spotify_next_track',
        'spotify_volume_up'
    ))
    $actionTypeBox.Add_SelectedIndexChanged({ $script:ActionHintLabel.Text = Get-ActionTemplate -ActionType ([string]$script:ActionTypeBox.SelectedItem) })
    $script:ActionTypeBox = $actionTypeBox
    [void]$right.Controls.Add($actionTypeBox)

    $actionHintLabel = New-Object System.Windows.Forms.Label
    $actionHintLabel.Location = New-Object System.Drawing.Point(26, 450)
    $actionHintLabel.Size = New-Object System.Drawing.Size(360, 30)
    $actionHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $actionHintLabel.ForeColor = $script:Theme.Muted
    $script:ActionHintLabel = $actionHintLabel
    [void]$right.Controls.Add($actionHintLabel)

    [void](New-EditorLabel -Text 'Action Value' -Y 488)
    $valueBox = New-Object System.Windows.Forms.TextBox
    $valueBox.Location = New-Object System.Drawing.Point(24, 512)
    $valueBox.Size = New-Object System.Drawing.Size(362, 92)
    $valueBox.Multiline = $true
    $valueBox.ScrollBars = 'Vertical'
    $valueBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $valueBox)
    $script:ValueBox = $valueBox
    [void]$right.Controls.Add($valueBox)

    $saveEditorButton = New-Object System.Windows.Forms.Button
    $saveEditorButton.Text = 'Save Slot'
    $saveEditorButton.Location = New-Object System.Drawing.Point(24, 622)
    $saveEditorButton.Size = New-Object System.Drawing.Size(140, 40)
    [void](Set-ButtonStyle -Button $saveEditorButton -Variant 'primary')
    $saveEditorButton.Add_Click({ Save-CurrentBinding })
    [void]$right.Controls.Add($saveEditorButton)

    $profileFolderButton = New-Object System.Windows.Forms.Button
    $profileFolderButton.Text = 'Profile Folder'
    $profileFolderButton.Location = New-Object System.Drawing.Point(174, 622)
    $profileFolderButton.Size = New-Object System.Drawing.Size(136, 40)
    [void](Set-ButtonStyle -Button $profileFolderButton -Variant 'secondary')
    $profileFolderButton.Add_Click({ Start-Process explorer.exe (Split-Path -Parent $script:ProfilePath) })
    [void]$right.Controls.Add($profileFolderButton)

    [void](New-EditorLabel -Text 'Profile Name' -Y 682)
    $script:ProfileNameBox = New-EditorBox -Y 682

    $helperLabel = New-Object System.Windows.Forms.Label
    $helperLabel.Text = 'Tip: Lock the deck to your device first so only its keys trigger actions.'
    $helperLabel.Location = New-Object System.Drawing.Point(24, 750)
    $helperLabel.Size = New-Object System.Drawing.Size(364, 48)
    $helperLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Italic)
    $helperLabel.ForeColor = $script:Theme.Muted
    [void]$right.Controls.Add($helperLabel)
}

function Rebuild-StableMainLayout {
    $script:Content.Panel1.Controls.Clear()
    $script:Content.Panel2.Controls.Clear()
    $script:UsesCleanLayout = $true

    $left = New-Object System.Windows.Forms.Panel
    $left.Dock = 'Fill'
    $left.BackColor = $script:Theme.Background
    [void]$script:Content.Panel1.Controls.Add($left)

    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Fill'
    $right.BackColor = $script:Theme.Panel
    $right.AutoScroll = $true
    [void]$script:Content.Panel2.Controls.Add($right)

    function New-StableButton {
        param(
            [string]$Text,
            [int]$X,
            [int]$Y,
            [int]$W,
            [int]$H,
            [string]$Variant,
            [scriptblock]$OnClick,
            [System.Windows.Forms.Control]$Parent
        )

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, $Y)
        $button.Size = New-Object System.Drawing.Size($W, $H)
        [void](Set-ButtonStyle -Button $button -Variant $Variant)
        $button.Add_Click($OnClick)
        [void]$Parent.Controls.Add($button)
        return $button
    }

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Location = New-Object System.Drawing.Point(24, 18)
    $toolbar.Size = New-Object System.Drawing.Size(960, 56)
    $toolbar.Anchor = 'Top,Left,Right'
    $toolbar.BackColor = [System.Drawing.Color]::FromArgb(226, 237, 252)
    [void]$left.Controls.Add($toolbar)

    [void](New-StableButton -Text 'Resume' -X 14 -Y 11 -W 86 -H 34 -Variant 'primary' -Parent $toolbar -OnClick {
        Set-ListeningState -Enabled $true
        Add-LogLine 'Listening resumed'
    })
    [void](New-StableButton -Text 'Pause' -X 108 -Y 11 -W 78 -H 34 -Variant 'secondary' -Parent $toolbar -OnClick {
        Set-ListeningState -Enabled $false
        Add-LogLine 'Listening paused'
    })
    [void](New-StableButton -Text 'Capture' -X 194 -Y 11 -W 92 -H 34 -Variant 'success' -Parent $toolbar -OnClick {
        $binding = Get-SelectedBinding
        if (-not $binding) {
            Add-LogLine 'Select a slot before capturing a key'
            return
        }
        $script:CaptureNextKey = $true
        if ($script:CaptureEditorButton) { $script:CaptureEditorButton.Text = 'Waiting...' }
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    })
    [void](New-StableButton -Text 'Save' -X 294 -Y 11 -W 72 -H 34 -Variant 'primary' -Parent $toolbar -OnClick { Save-CurrentBinding })
    [void](New-StableButton -Text 'Lock Device' -X 374 -Y 11 -W 112 -H 34 -Variant 'secondary' -Parent $toolbar -OnClick {
        $script:DeviceLockArmed = $true
        Add-LogLine 'Press any key on the mini pad to lock DeckPad to that device'
    })
    $script:CompactButton = New-StableButton -Text 'Compact' -X 494 -Y 11 -W 98 -H 34 -Variant 'secondary' -Parent $toolbar -OnClick { Toggle-CompactMode }
    $script:PinButton = New-StableButton -Text 'Pin' -X 600 -Y 11 -W 68 -H 34 -Variant 'secondary' -Parent $toolbar -OnClick { Toggle-PinnedMode }
    $settingsButton = New-StableButton -Text 'Settings' -X 848 -Y 11 -W 98 -H 34 -Variant 'dark' -Parent $toolbar -OnClick { Show-SettingsDialog }
    $settingsButton.Anchor = 'Top,Right'

    $deviceCard = New-Object System.Windows.Forms.Panel
    $deviceCard.Location = New-Object System.Drawing.Point(24, 88)
    $deviceCard.Size = New-Object System.Drawing.Size(960, 154)
    $deviceCard.Anchor = 'Top,Left,Right'
    $deviceCard.BackColor = $script:Theme.Panel
    $deviceCard.BorderStyle = 'FixedSingle'
    $script:DeviceCard = $deviceCard
    [void]$left.Controls.Add($deviceCard)

    $deviceTitle = New-Object System.Windows.Forms.Label
    $deviceTitle.Text = 'Programmable Deck'
    $deviceTitle.Location = New-Object System.Drawing.Point(20, 16)
    $deviceTitle.AutoSize = $true
    $deviceTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $deviceTitle.ForeColor = $script:Theme.Muted
    [void]$deviceCard.Controls.Add($deviceTitle)

    $deviceName = New-Object System.Windows.Forms.Label
    $deviceName.Text = '6 keys + 1 knob'
    $deviceName.Location = New-Object System.Drawing.Point(20, 42)
    $deviceName.AutoSize = $true
    $deviceName.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
    $deviceName.ForeColor = $script:Theme.Ink
    [void]$deviceCard.Controls.Add($deviceName)

    $deviceStatusValueLabel = New-Object System.Windows.Forms.Label
    $deviceStatusValueLabel.Text = 'Not locked'
    $deviceStatusValueLabel.Location = New-Object System.Drawing.Point(22, 94)
    $deviceStatusValueLabel.Size = New-Object System.Drawing.Size(330, 22)
    $deviceStatusValueLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $deviceStatusValueLabel.ForeColor = $script:Theme.AccentWarm
    $script:DeviceStatusValueLabel = $deviceStatusValueLabel
    [void]$deviceCard.Controls.Add($deviceStatusValueLabel)

    $deviceValueLabel = New-Object System.Windows.Forms.Label
    $deviceValueLabel.Text = $script:TargetDeviceName
    $deviceValueLabel.Location = New-Object System.Drawing.Point(22, 120)
    $deviceValueLabel.Size = New-Object System.Drawing.Size(350, 22)
    $deviceValueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $deviceValueLabel.ForeColor = $script:Theme.Accent
    $script:DeviceValueLabel = $deviceValueLabel
    [void]$deviceCard.Controls.Add($deviceValueLabel)

    $devicePickerLabel = New-Object System.Windows.Forms.Label
    $devicePickerLabel.Text = 'Input device'
    $devicePickerLabel.Location = New-Object System.Drawing.Point(410, 20)
    $devicePickerLabel.AutoSize = $true
    $devicePickerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $devicePickerLabel.ForeColor = $script:Theme.Muted
    [void]$deviceCard.Controls.Add($devicePickerLabel)

    $deviceComboBox = New-Object System.Windows.Forms.ComboBox
    $deviceComboBox.Location = New-Object System.Drawing.Point(410, 44)
    $deviceComboBox.Size = New-Object System.Drawing.Size(390, 28)
    $deviceComboBox.DropDownStyle = 'DropDownList'
    $deviceComboBox.DropDownWidth = 540
    [void](Set-InputStyle -Control $deviceComboBox)
    $script:DeviceComboBox = $deviceComboBox
    [void]$deviceCard.Controls.Add($deviceComboBox)

    $refreshDevicesButton = New-StableButton -Text 'Refresh' -X 410 -Y 88 -W 142 -H 36 -Variant 'secondary' -Parent $deviceCard -OnClick {
        Refresh-DevicePicker
        Add-LogLine 'Refreshed keyboard device list'
    }
    $useSelectedDeviceButton = New-StableButton -Text 'Use Selected' -X 566 -Y 88 -W 142 -H 36 -Variant 'primary' -Parent $deviceCard -OnClick {
        if ($script:DeviceComboBox.SelectedIndex -ge 0 -and $script:DeviceComboBox.SelectedIndex -lt $script:DevicePickerEntries.Count) {
            $entry = $script:DevicePickerEntries[$script:DeviceComboBox.SelectedIndex]
            Set-TargetDevice -DeviceId $entry.PrimaryDeviceId -DeviceName $entry.DeviceName -HardwareId $entry.HardwareId
            Save-Profile -Profile $script:Profile
            Add-LogLine "Using selected device group [$($script:TargetDeviceName)]"
        }
    }

    $deckPreviewPanel = New-Object System.Windows.Forms.Panel
    $deckPreviewPanel.Location = New-Object System.Drawing.Point(824, 26)
    $deckPreviewPanel.Size = New-Object System.Drawing.Size(108, 98)
    $deckPreviewPanel.Anchor = 'Top,Right'
    [void](Set-PanelSurface -Control $deckPreviewPanel -Variant 'alt')
    $deckPreviewPanel.Add_Paint({
        param($sender, $eventArgs)
        $g = $eventArgs.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($script:Theme.AccentSoft)
        $bodyBrush = New-Object System.Drawing.SolidBrush($script:Theme.Header)
        $keyBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $knobBrush = New-Object System.Drawing.SolidBrush($script:Theme.Accent)
        $pen = New-Object System.Drawing.Pen($script:Theme.StrongBorder, 1)
        $g.FillRectangle($bodyBrush, 16, 30, 62, 48)
        $g.DrawRectangle($pen, 16, 30, 62, 48)
        for ($row = 0; $row -lt 2; $row++) {
            for ($col = 0; $col -lt 3; $col++) {
                $x = 26 + ($col * 17)
                $y = 40 + ($row * 17)
                $g.FillRectangle($keyBrush, $x, $y, 10, 10)
                $g.DrawRectangle($pen, $x, $y, 10, 10)
            }
        }
        $g.FillEllipse($knobBrush, 79, 44, 20, 20)
        $g.DrawEllipse($pen, 79, 44, 20, 20)
        $bodyBrush.Dispose(); $keyBrush.Dispose(); $knobBrush.Dispose(); $pen.Dispose()
    })
    [void]$deviceCard.Controls.Add($deckPreviewPanel)

    $gridSectionLabel = New-Object System.Windows.Forms.Label
    $gridSectionLabel.Text = 'Physical Controls  |  top row: 1-3, bottom row: 4-6, knob: left / press / right'
    $gridSectionLabel.Location = New-Object System.Drawing.Point(26, 258)
    $gridSectionLabel.Size = New-Object System.Drawing.Size(960, 22)
    $gridSectionLabel.Anchor = 'Top,Left,Right'
    $gridSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $gridSectionLabel.ForeColor = $script:Theme.Muted
    $script:GridSectionLabel = $gridSectionLabel
    [void]$left.Controls.Add($gridSectionLabel)

    $gridPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $gridPanel.Location = New-Object System.Drawing.Point(24, 286)
    $gridPanel.Size = New-Object System.Drawing.Size(960, 338)
    $gridPanel.Anchor = 'Top,Left,Right'
    $gridPanel.ColumnCount = 3
    $gridPanel.RowCount = 3
    $gridPanel.BackColor = $script:Theme.Canvas
    $gridPanel.GrowStyle = 'FixedSize'
    $gridPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    $script:GridPanel = $gridPanel
    [void]$left.Controls.Add($gridPanel)

    $activityTitle = New-Object System.Windows.Forms.Label
    $activityTitle.Text = 'Activity'
    $activityTitle.Location = New-Object System.Drawing.Point(26, 642)
    $activityTitle.AutoSize = $true
    $activityTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $activityTitle.ForeColor = $script:Theme.Ink
    $script:ActivityTitle = $activityTitle
    [void]$left.Controls.Add($activityTitle)

    $activityHintLabel = New-Object System.Windows.Forms.Label
    $activityHintLabel.Text = 'Captured keys, app launches, Spotify controls, and device lock status.'
    $activityHintLabel.Location = New-Object System.Drawing.Point(27, 672)
    $activityHintLabel.Size = New-Object System.Drawing.Size(960, 20)
    $activityHintLabel.Anchor = 'Top,Left,Right'
    $activityHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $activityHintLabel.ForeColor = $script:Theme.Muted
    $script:ActivityHintLabel = $activityHintLabel
    [void]$left.Controls.Add($activityHintLabel)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(24, 698)
    $logBox.Size = New-Object System.Drawing.Size(960, 200)
    $logBox.Anchor = 'Top,Left,Right,Bottom'
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.BackColor = $script:Theme.Panel
    $logBox.ForeColor = $script:Theme.Ink
    $logBox.BorderStyle = 'FixedSingle'
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    $script:LogBox = $logBox
    [void]$left.Controls.Add($logBox)

    $rightTitle = New-Object System.Windows.Forms.Label
    $rightTitle.Text = 'Configure Control'
    $rightTitle.Location = New-Object System.Drawing.Point(24, 22)
    $rightTitle.AutoSize = $true
    $rightTitle.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $rightTitle.ForeColor = $script:Theme.Ink
    [void]$right.Controls.Add($rightTitle)

    $selectedBindingLabel = New-Object System.Windows.Forms.Label
    $selectedBindingLabel.Text = 'Editing Top Left'
    $selectedBindingLabel.Location = New-Object System.Drawing.Point(26, 58)
    $selectedBindingLabel.AutoSize = $true
    $selectedBindingLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $selectedBindingLabel.ForeColor = $script:Theme.Accent
    $script:SelectedBindingLabel = $selectedBindingLabel
    [void]$right.Controls.Add($selectedBindingLabel)

    $howToPanel = New-Object System.Windows.Forms.Panel
    $howToPanel.Location = New-Object System.Drawing.Point(24, 92)
    $howToPanel.Size = New-Object System.Drawing.Size(362, 74)
    $howToPanel.BackColor = $script:Theme.AccentSoft
    [void]$right.Controls.Add($howToPanel)
    $howToSteps = New-Object System.Windows.Forms.Label
    $howToSteps.Text = "1. Select a tile`r`n2. Capture the pad button`r`n3. Pick an action and Save Slot"
    $howToSteps.Location = New-Object System.Drawing.Point(14, 10)
    $howToSteps.Size = New-Object System.Drawing.Size(334, 56)
    $howToSteps.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $howToSteps.ForeColor = $script:Theme.Ink
    [void]$howToPanel.Controls.Add($howToSteps)

    function New-EditorLabel {
        param([string]$Text, [int]$Y)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point(24, $Y)
        $label.AutoSize = $true
        $label.ForeColor = $script:Theme.Muted
        $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        [void]$right.Controls.Add($label)
        return $label
    }

    function New-EditorBox {
        param([int]$Y, [int]$Height = 28)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Location = New-Object System.Drawing.Point(24, ($Y + 24))
        $box.Size = New-Object System.Drawing.Size(362, $Height)
        $box.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
        [void](Set-InputStyle -Control $box)
        [void]$right.Controls.Add($box)
        return $box
    }

    [void](New-EditorLabel -Text 'Physical Control' -Y 192)
    $slotNameValue = New-Object System.Windows.Forms.Label
    $slotNameValue.Location = New-Object System.Drawing.Point(26, 216)
    $slotNameValue.AutoSize = $true
    $slotNameValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
    $slotNameValue.ForeColor = $script:Theme.Ink
    $script:SlotNameValue = $slotNameValue
    [void]$right.Controls.Add($slotNameValue)

    [void](New-EditorLabel -Text 'Display Label' -Y 254)
    $script:LabelBox = New-EditorBox -Y 254

    [void](New-EditorLabel -Text 'Trigger Key' -Y 318)
    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(24, 342)
    $keyBox.Size = New-Object System.Drawing.Size(174, 28)
    $keyBox.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $keyBox)
    $script:KeyBox = $keyBox
    [void]$right.Controls.Add($keyBox)
    $captureEditorButton = New-StableButton -Text 'Capture Key' -X 210 -Y 340 -W 176 -H 32 -Variant 'success' -Parent $right -OnClick {
        $binding = Get-SelectedBinding
        if (-not $binding) {
            Add-LogLine 'Select a slot before capturing a key'
            return
        }
        if ($script:CaptureNextKey) {
            $script:CaptureNextKey = $false
            $script:CaptureEditorButton.Text = 'Capture Key'
            Add-LogLine 'Capture cancelled'
            return
        }
        $script:CaptureNextKey = $true
        $script:CaptureEditorButton.Text = 'Waiting...'
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    }
    $script:CaptureEditorButton = $captureEditorButton

    $vkBox = New-Object System.Windows.Forms.TextBox
    $vkBox.Visible = $false
    $script:VkBox = $vkBox
    [void]$right.Controls.Add($vkBox)

    [void](New-EditorLabel -Text 'Action Type' -Y 394)
    $actionTypeBox = New-Object System.Windows.Forms.ComboBox
    $actionTypeBox.Location = New-Object System.Drawing.Point(24, 418)
    $actionTypeBox.Size = New-Object System.Drawing.Size(362, 30)
    $actionTypeBox.DropDownStyle = 'DropDownList'
    [void](Set-InputStyle -Control $actionTypeBox)
    [void]$actionTypeBox.Items.AddRange(@(
        'focus_or_launch',
        'launch_app',
        'open_url',
        'type_text',
        'send_hotkey',
        'run_command',
        'spotify_volume_down',
        'spotify_play_pause',
        'spotify_previous_track',
        'spotify_next_track',
        'spotify_volume_up'
    ))
    $actionTypeBox.Add_SelectedIndexChanged({ $script:ActionHintLabel.Text = Get-ActionTemplate -ActionType ([string]$script:ActionTypeBox.SelectedItem) })
    $script:ActionTypeBox = $actionTypeBox
    [void]$right.Controls.Add($actionTypeBox)

    $actionHintLabel = New-Object System.Windows.Forms.Label
    $actionHintLabel.Location = New-Object System.Drawing.Point(26, 454)
    $actionHintLabel.Size = New-Object System.Drawing.Size(360, 30)
    $actionHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $actionHintLabel.ForeColor = $script:Theme.Muted
    $script:ActionHintLabel = $actionHintLabel
    [void]$right.Controls.Add($actionHintLabel)

    [void](New-EditorLabel -Text 'Action Value' -Y 492)
    $valueBox = New-Object System.Windows.Forms.TextBox
    $valueBox.Location = New-Object System.Drawing.Point(24, 516)
    $valueBox.Size = New-Object System.Drawing.Size(362, 92)
    $valueBox.Multiline = $true
    $valueBox.ScrollBars = 'Vertical'
    $valueBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $valueBox)
    $script:ValueBox = $valueBox
    [void]$right.Controls.Add($valueBox)

    [void](New-StableButton -Text 'Save Slot' -X 24 -Y 626 -W 140 -H 40 -Variant 'primary' -Parent $right -OnClick { Save-CurrentBinding })
    [void](New-StableButton -Text 'Profile Folder' -X 174 -Y 626 -W 136 -H 40 -Variant 'secondary' -Parent $right -OnClick {
        Start-Process explorer.exe (Split-Path -Parent $script:ProfilePath)
    })

    [void](New-EditorLabel -Text 'Profile Name' -Y 686)
    $script:ProfileNameBox = New-EditorBox -Y 686

    $helperLabel = New-Object System.Windows.Forms.Label
    $helperLabel.Text = 'Tip: Lock the deck to your device first so only its keys trigger actions.'
    $helperLabel.Location = New-Object System.Drawing.Point(24, 754)
    $helperLabel.Size = New-Object System.Drawing.Size(364, 48)
    $helperLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Italic)
    $helperLabel.ForeColor = $script:Theme.Muted
    [void]$right.Controls.Add($helperLabel)
}

function Rebuild-DeckPadShell {
    $script:Form.Controls.Clear()
    $script:UsesCleanLayout = $true
    $script:StatusPill = $null
    $script:StatusValue = $null
    $script:CompactButton = $null
    $script:PinButton = $null

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 2
    $root.BackColor = $script:Theme.Background
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 116)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$script:Form.Controls.Add($root)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Fill'
    $header.BackColor = $script:Theme.Header
    [void]$root.Controls.Add($header, 0, 0)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'DeckPad'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::White
    $title.BackColor = $script:Theme.Header
    $title.Location = New-Object System.Drawing.Point(28, 14)
    $title.AutoSize = $true
    [void]$header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Map 6 keys and 1 knob to apps, Spotify controls, hotkeys, URLs, and commands.'
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
    $subtitle.ForeColor = $script:Theme.HeaderSoft
    $subtitle.BackColor = $script:Theme.Header
    $subtitle.Location = New-Object System.Drawing.Point(32, 72)
    $subtitle.Size = New-Object System.Drawing.Size(760, 24)
    $script:SubtitleLabel = $subtitle
    [void]$header.Controls.Add($subtitle)

    function New-ShellButton {
        param(
            [string]$Text,
            [int]$X,
            [int]$W,
            [string]$Variant,
            [scriptblock]$OnClick
        )

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, 42)
        $button.Size = New-Object System.Drawing.Size($W, 32)
        [void](Set-ButtonStyle -Button $button -Variant $Variant)
        $button.Add_Click($OnClick)
        [void]$header.Controls.Add($button)
        return $button
    }

    $settingsButton = New-ShellButton -Text 'Settings' -X 1284 -W 116 -Variant 'primary' -OnClick { Show-SettingsDialog }
    $settingsButton.Anchor = 'Top,Right'

    $content = New-Object System.Windows.Forms.SplitContainer
    $content.Dock = 'Fill'
    $content.IsSplitterFixed = $false
    try {
        $content.Panel1MinSize = 880
        $content.Panel2MinSize = 390
    } catch {
    }
    $content.SplitterWidth = 8
    $content.BackColor = $script:Theme.Canvas
    $script:Content = $content
    [void]$root.Controls.Add($content, 0, 1)

    $left = New-Object System.Windows.Forms.Panel
    $left.Dock = 'Fill'
    $left.BackColor = $script:Theme.Background
    [void]$content.Panel1.Controls.Add($left)

    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Fill'
    $right.BackColor = $script:Theme.Panel
    $right.AutoScroll = $true
    [void]$content.Panel2.Controls.Add($right)

    $deviceCard = New-Object System.Windows.Forms.Panel
    $deviceCard.Location = New-Object System.Drawing.Point(24, 18)
    $deviceCard.Size = New-Object System.Drawing.Size(960, 148)
    $deviceCard.Anchor = 'Top,Left,Right'
    $deviceCard.BackColor = $script:Theme.Panel
    $deviceCard.BorderStyle = 'FixedSingle'
    $script:DeviceCard = $deviceCard
    [void]$left.Controls.Add($deviceCard)

    $deviceTitle = New-Object System.Windows.Forms.Label
    $deviceTitle.Text = 'Programmable Deck'
    $deviceTitle.Location = New-Object System.Drawing.Point(20, 14)
    $deviceTitle.AutoSize = $true
    $deviceTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $deviceTitle.ForeColor = $script:Theme.Muted
    [void]$deviceCard.Controls.Add($deviceTitle)

    $deviceName = New-Object System.Windows.Forms.Label
    $deviceName.Text = '6 keys + 1 knob'
    $deviceName.Location = New-Object System.Drawing.Point(20, 38)
    $deviceName.AutoSize = $true
    $deviceName.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
    $deviceName.ForeColor = $script:Theme.Ink
    [void]$deviceCard.Controls.Add($deviceName)

    $deviceStatusValueLabel = New-Object System.Windows.Forms.Label
    $deviceStatusValueLabel.Text = 'Not locked'
    $deviceStatusValueLabel.Location = New-Object System.Drawing.Point(22, 90)
    $deviceStatusValueLabel.Size = New-Object System.Drawing.Size(330, 22)
    $deviceStatusValueLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $deviceStatusValueLabel.ForeColor = $script:Theme.AccentWarm
    $script:DeviceStatusValueLabel = $deviceStatusValueLabel
    [void]$deviceCard.Controls.Add($deviceStatusValueLabel)

    $deviceValueLabel = New-Object System.Windows.Forms.Label
    $deviceValueLabel.Text = $script:TargetDeviceName
    $deviceValueLabel.Location = New-Object System.Drawing.Point(22, 114)
    $deviceValueLabel.Size = New-Object System.Drawing.Size(350, 22)
    $deviceValueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $deviceValueLabel.ForeColor = $script:Theme.Accent
    $script:DeviceValueLabel = $deviceValueLabel
    [void]$deviceCard.Controls.Add($deviceValueLabel)

    $deviceHintLabel = New-Object System.Windows.Forms.Label
    $deviceHintLabel.Text = 'Choose the 6-key pad, or click Lock Device and press a key on it.'
    $deviceHintLabel.Location = New-Object System.Drawing.Point(410, 14)
    $deviceHintLabel.Size = New-Object System.Drawing.Size(390, 22)
    $deviceHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $deviceHintLabel.ForeColor = $script:Theme.Muted
    $script:DeviceHintLabel = $deviceHintLabel
    [void]$deviceCard.Controls.Add($deviceHintLabel)

    $deviceComboBox = New-Object System.Windows.Forms.ComboBox
    $deviceComboBox.Location = New-Object System.Drawing.Point(410, 40)
    $deviceComboBox.Size = New-Object System.Drawing.Size(500, 28)
    $deviceComboBox.DropDownStyle = 'DropDownList'
    $deviceComboBox.DropDownWidth = 540
    [void](Set-InputStyle -Control $deviceComboBox)
    $script:DeviceComboBox = $deviceComboBox
    [void]$deviceCard.Controls.Add($deviceComboBox)

    function New-CardButton {
        param([string]$Text, [int]$X, [string]$Variant, [scriptblock]$OnClick)
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, 82)
        $button.Size = New-Object System.Drawing.Size(142, 36)
        [void](Set-ButtonStyle -Button $button -Variant $Variant)
        $button.Add_Click($OnClick)
        [void]$deviceCard.Controls.Add($button)
        return $button
    }

    [void](New-CardButton -Text 'Refresh' -X 410 -Variant 'secondary' -OnClick { Refresh-DevicePicker; Add-LogLine 'Refreshed keyboard device list' })
    [void](New-CardButton -Text 'Use Selected' -X 566 -Variant 'primary' -OnClick {
        if ($script:DeviceComboBox.SelectedIndex -ge 0 -and $script:DeviceComboBox.SelectedIndex -lt $script:DevicePickerEntries.Count) {
            $entry = $script:DevicePickerEntries[$script:DeviceComboBox.SelectedIndex]
            Set-TargetDevice -DeviceId $entry.PrimaryDeviceId -DeviceName $entry.DeviceName -HardwareId $entry.HardwareId
            Save-Profile -Profile $script:Profile
            Add-LogLine "Using selected device group [$($script:TargetDeviceName)]"
        }
    })
    [void](New-CardButton -Text 'Lock Device' -X 722 -Variant 'secondary' -OnClick {
        $script:DeviceLockArmed = $true
        Add-LogLine 'Press any key on the mini pad to lock DeckPad to that device'
    })

    $gridSectionLabel = New-Object System.Windows.Forms.Label
    $gridSectionLabel.Text = 'Physical Controls  |  top row: 1-3, bottom row: 4-6, knob: left / press / right'
    $gridSectionLabel.Location = New-Object System.Drawing.Point(26, 184)
    $gridSectionLabel.Size = New-Object System.Drawing.Size(960, 22)
    $gridSectionLabel.Anchor = 'Top,Left,Right'
    $gridSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $gridSectionLabel.ForeColor = $script:Theme.Muted
    $script:GridSectionLabel = $gridSectionLabel
    [void]$left.Controls.Add($gridSectionLabel)

    $gridPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $gridPanel.Location = New-Object System.Drawing.Point(24, 212)
    $gridPanel.Size = New-Object System.Drawing.Size(960, 338)
    $gridPanel.Anchor = 'Top,Left,Right'
    $gridPanel.ColumnCount = 3
    $gridPanel.RowCount = 3
    $gridPanel.BackColor = $script:Theme.Canvas
    $gridPanel.GrowStyle = 'FixedSize'
    $gridPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
    $script:GridPanel = $gridPanel
    [void]$left.Controls.Add($gridPanel)

    $activityTitle = New-Object System.Windows.Forms.Label
    $activityTitle.Text = 'Activity'
    $activityTitle.Location = New-Object System.Drawing.Point(26, 562)
    $activityTitle.AutoSize = $true
    $activityTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $activityTitle.ForeColor = $script:Theme.Ink
    $script:ActivityTitle = $activityTitle
    [void]$left.Controls.Add($activityTitle)

    $activityHintLabel = New-Object System.Windows.Forms.Label
    $activityHintLabel.Text = 'Captured keys, app launches, Spotify controls, and device lock status.'
    $activityHintLabel.Location = New-Object System.Drawing.Point(27, 592)
    $activityHintLabel.Size = New-Object System.Drawing.Size(960, 20)
    $activityHintLabel.Anchor = 'Top,Left,Right'
    $activityHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $activityHintLabel.ForeColor = $script:Theme.Muted
    $script:ActivityHintLabel = $activityHintLabel
    [void]$left.Controls.Add($activityHintLabel)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(24, 618)
    $logBox.Size = New-Object System.Drawing.Size(960, 164)
    $logBox.Anchor = 'Top,Left,Right,Bottom'
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.BackColor = $script:Theme.Panel
    $logBox.ForeColor = $script:Theme.Ink
    $logBox.BorderStyle = 'FixedSingle'
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    $script:LogBox = $logBox
    [void]$left.Controls.Add($logBox)

    $rightTitle = New-Object System.Windows.Forms.Label
    $rightTitle.Text = 'Configure Control'
    $rightTitle.Location = New-Object System.Drawing.Point(24, 22)
    $rightTitle.AutoSize = $true
    $rightTitle.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $rightTitle.ForeColor = $script:Theme.Ink
    [void]$right.Controls.Add($rightTitle)

    $selectedBindingLabel = New-Object System.Windows.Forms.Label
    $selectedBindingLabel.Text = 'Editing Top Left'
    $selectedBindingLabel.Location = New-Object System.Drawing.Point(26, 58)
    $selectedBindingLabel.AutoSize = $true
    $selectedBindingLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
    $selectedBindingLabel.ForeColor = $script:Theme.Accent
    $script:SelectedBindingLabel = $selectedBindingLabel
    [void]$right.Controls.Add($selectedBindingLabel)

    $howToPanel = New-Object System.Windows.Forms.Panel
    $howToPanel.Location = New-Object System.Drawing.Point(24, 92)
    $howToPanel.Size = New-Object System.Drawing.Size(362, 74)
    $howToPanel.BackColor = $script:Theme.AccentSoft
    [void]$right.Controls.Add($howToPanel)
    $howToSteps = New-Object System.Windows.Forms.Label
    $howToSteps.Text = "1. Select a tile`r`n2. Capture the pad button`r`n3. Pick an action and Save Slot"
    $howToSteps.Location = New-Object System.Drawing.Point(14, 10)
    $howToSteps.Size = New-Object System.Drawing.Size(334, 56)
    $howToSteps.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $howToSteps.ForeColor = $script:Theme.Ink
    [void]$howToPanel.Controls.Add($howToSteps)

    function New-EditorLabel {
        param([string]$Text, [int]$Y)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point(24, $Y)
        $label.AutoSize = $true
        $label.ForeColor = $script:Theme.Muted
        $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        [void]$right.Controls.Add($label)
        return $label
    }

    function New-EditorBox {
        param([int]$Y, [int]$Height = 28)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Location = New-Object System.Drawing.Point(24, ($Y + 24))
        $box.Size = New-Object System.Drawing.Size(362, $Height)
        $box.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
        [void](Set-InputStyle -Control $box)
        [void]$right.Controls.Add($box)
        return $box
    }

    [void](New-EditorLabel -Text 'Physical Control' -Y 192)
    $slotNameValue = New-Object System.Windows.Forms.Label
    $slotNameValue.Location = New-Object System.Drawing.Point(26, 216)
    $slotNameValue.AutoSize = $true
    $slotNameValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
    $slotNameValue.ForeColor = $script:Theme.Ink
    $script:SlotNameValue = $slotNameValue
    [void]$right.Controls.Add($slotNameValue)

    [void](New-EditorLabel -Text 'Display Label' -Y 254)
    $script:LabelBox = New-EditorBox -Y 254

    [void](New-EditorLabel -Text 'Trigger Key' -Y 318)
    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(24, 342)
    $keyBox.Size = New-Object System.Drawing.Size(174, 28)
    $keyBox.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $keyBox)
    $script:KeyBox = $keyBox
    [void]$right.Controls.Add($keyBox)

    $captureEditorButton = New-Object System.Windows.Forms.Button
    $captureEditorButton.Text = 'Capture Key'
    $captureEditorButton.Location = New-Object System.Drawing.Point(210, 340)
    $captureEditorButton.Size = New-Object System.Drawing.Size(176, 32)
    [void](Set-ButtonStyle -Button $captureEditorButton -Variant 'success')
    $captureEditorButton.Add_Click({
        $binding = Get-SelectedBinding
        if (-not $binding) {
            Add-LogLine 'Select a slot before capturing a key'
            return
        }
        if ($script:CaptureNextKey) {
            $script:CaptureNextKey = $false
            $script:CaptureEditorButton.Text = 'Capture Key'
            Add-LogLine 'Capture cancelled'
            return
        }
        $script:CaptureNextKey = $true
        $script:CaptureEditorButton.Text = 'Waiting...'
        Add-LogLine "Press the physical control for [$($binding.displayName)]"
    })
    $script:CaptureEditorButton = $captureEditorButton
    [void]$right.Controls.Add($captureEditorButton)

    $triggerDetailLabel = New-Object System.Windows.Forms.Label
    $triggerDetailLabel.Text = 'Raw ID: not captured'
    $triggerDetailLabel.Location = New-Object System.Drawing.Point(26, 374)
    $triggerDetailLabel.Size = New-Object System.Drawing.Size(360, 18)
    $triggerDetailLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Regular)
    $triggerDetailLabel.ForeColor = $script:Theme.Muted
    $script:TriggerDetailLabel = $triggerDetailLabel
    [void]$right.Controls.Add($triggerDetailLabel)

    $vkBox = New-Object System.Windows.Forms.TextBox
    $vkBox.Visible = $false
    $script:VkBox = $vkBox
    [void]$right.Controls.Add($vkBox)

    [void](New-EditorLabel -Text 'Action Type' -Y 394)
    $actionTypeBox = New-Object System.Windows.Forms.ComboBox
    $actionTypeBox.Location = New-Object System.Drawing.Point(24, 418)
    $actionTypeBox.Size = New-Object System.Drawing.Size(362, 30)
    $actionTypeBox.DropDownStyle = 'DropDownList'
    [void](Set-InputStyle -Control $actionTypeBox)
    [void]$actionTypeBox.Items.AddRange(@(
        'focus_or_launch',
        'launch_app',
        'open_url',
        'type_text',
        'send_hotkey',
        'run_command',
        'spotify_volume_down',
        'spotify_play_pause',
        'spotify_previous_track',
        'spotify_next_track',
        'spotify_volume_up'
    ))
    $actionTypeBox.Add_SelectedIndexChanged({ $script:ActionHintLabel.Text = Get-ActionTemplate -ActionType ([string]$script:ActionTypeBox.SelectedItem) })
    $script:ActionTypeBox = $actionTypeBox
    [void]$right.Controls.Add($actionTypeBox)

    $actionHintLabel = New-Object System.Windows.Forms.Label
    $actionHintLabel.Location = New-Object System.Drawing.Point(26, 454)
    $actionHintLabel.Size = New-Object System.Drawing.Size(360, 30)
    $actionHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $actionHintLabel.ForeColor = $script:Theme.Muted
    $script:ActionHintLabel = $actionHintLabel
    [void]$right.Controls.Add($actionHintLabel)

    [void](New-EditorLabel -Text 'Action Value' -Y 492)
    $valueBox = New-Object System.Windows.Forms.TextBox
    $valueBox.Location = New-Object System.Drawing.Point(24, 516)
    $valueBox.Size = New-Object System.Drawing.Size(362, 92)
    $valueBox.Multiline = $true
    $valueBox.ScrollBars = 'Vertical'
    $valueBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $valueBox)
    $script:ValueBox = $valueBox
    [void]$right.Controls.Add($valueBox)

    $saveEditorButton = New-Object System.Windows.Forms.Button
    $saveEditorButton.Text = 'Save Slot'
    $saveEditorButton.Location = New-Object System.Drawing.Point(24, 626)
    $saveEditorButton.Size = New-Object System.Drawing.Size(140, 40)
    [void](Set-ButtonStyle -Button $saveEditorButton -Variant 'primary')
    $saveEditorButton.Add_Click({ Save-CurrentBinding })
    [void]$right.Controls.Add($saveEditorButton)

    $createProfileButton = New-Object System.Windows.Forms.Button
    $createProfileButton.Text = 'Create Profile'
    $createProfileButton.Location = New-Object System.Drawing.Point(174, 626)
    $createProfileButton.Size = New-Object System.Drawing.Size(136, 40)
    [void](Set-ButtonStyle -Button $createProfileButton -Variant 'secondary')
    $createProfileButton.Add_Click({ New-DeckPadProfileFromCurrent })
    [void]$right.Controls.Add($createProfileButton)

    $profileFolderButton = New-Object System.Windows.Forms.Button
    $profileFolderButton.Text = 'Profile Folder'
    $profileFolderButton.Location = New-Object System.Drawing.Point(24, 674)
    $profileFolderButton.Size = New-Object System.Drawing.Size(140, 36)
    [void](Set-ButtonStyle -Button $profileFolderButton -Variant 'secondary')
    $profileFolderButton.Add_Click({ Start-Process explorer.exe (Split-Path -Parent $script:ProfilePath) })
    [void]$right.Controls.Add($profileFolderButton)

    [void](New-EditorLabel -Text 'Profile Name' -Y 724)
    $script:ProfileNameBox = New-EditorBox -Y 724

    $helperLabel = New-Object System.Windows.Forms.Label
    $helperLabel.Text = 'Tip: Lock the deck to your device first so only its keys trigger actions.'
    $helperLabel.Location = New-Object System.Drawing.Point(24, 792)
    $helperLabel.Size = New-Object System.Drawing.Size(364, 48)
    $helperLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Italic)
    $helperLabel.ForeColor = $script:Theme.Muted
    [void]$right.Controls.Add($helperLabel)
}

$script:Settings = Load-Settings
Apply-AppSettings
Initialize-DeckPadShellIdentity
Initialize-SingleInstanceGuard

if ($script:Settings.startupProfilePath) {
    $script:ProfilePath = Join-Path $script:AppRoot ([string]$script:Settings.startupProfilePath)
    if (-not (Test-Path -LiteralPath $script:ProfilePath)) {
        $script:ProfilePath = Join-Path $script:AppRoot 'profiles\default-profile.json'
        $script:Settings.startupProfilePath = 'profiles\default-profile.json'
        Save-Settings -Settings $script:Settings
    }
}

if ([bool]$script:Settings.loadDefaultProfileOnStartup) {
    $script:Profile = Load-Profile
} else {
    $script:Profile = New-DefaultProfile
}
$script:TargetDeviceId = $script:Profile.targetDeviceId
$script:TargetDeviceName = if ($script:Profile.targetDeviceName -and $script:Profile.targetDeviceName -notmatch '^[\\/\s]+$') { $script:Profile.targetDeviceName } else { 'Not locked' }
$script:TargetDeviceHardwareId = ''

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DeckPad'
$form.Width = 1480
$form.Height = 960
$form.MinimumSize = New-Object System.Drawing.Size(1380, 920)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:Theme.Background
$form.ForeColor = $script:Theme.Ink
$form.Padding = New-Object System.Windows.Forms.Padding(0)
$form.ShowIcon = $true
$form.ShowInTaskbar = $true
$form.Icon = Get-DeckPadIcon
$script:Form = $form

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem
$showTrayItem.Text = 'Show DeckPad'
$showTrayItem.Add_Click({ Show-DeckPadFromTray })
[void]$trayMenu.Items.Add($showTrayItem)
$settingsTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem
$settingsTrayItem.Text = 'Settings'
$settingsTrayItem.Add_Click({
    Show-DeckPadFromTray
    Show-SettingsDialog
})
[void]$trayMenu.Items.Add($settingsTrayItem)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitTrayItem.Text = 'Exit DeckPad'
$exitTrayItem.Add_Click({
    $script:AllowExit = $true
    $script:Form.Close()
})
[void]$trayMenu.Items.Add($exitTrayItem)

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Text = 'DeckPad'
$notifyIcon.Icon = Get-DeckPadIcon
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Visible = $true
$notifyIcon.Add_DoubleClick({ Show-DeckPadFromTray })
$script:NotifyIcon = $notifyIcon

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 104
$header.BackColor = $script:Theme.Header
Add-GradientPaint -Control $header -TopColor ([System.Drawing.Color]::FromArgb(15, 23, 42)) -BottomColor ([System.Drawing.Color]::FromArgb(30, 58, 138))
[void]$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'DeckPad'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 30, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Location = New-Object System.Drawing.Point(28, 12)
$title.AutoSize = $true
[void]$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Programmable deck controller - map 6 keys and 1 knob to apps, hotkeys, URLs, and more.'
$subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
$subtitle.ForeColor = $script:Theme.HeaderSoft
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Location = New-Object System.Drawing.Point(32, 62)
$subtitle.Size = New-Object System.Drawing.Size(820, 28)
$script:SubtitleLabel = $subtitle
[void]$header.Controls.Add($subtitle)

$statusDot = New-Object System.Windows.Forms.Panel
$statusDot.Size = New-Object System.Drawing.Size(10, 10)
$statusDot.Location = New-Object System.Drawing.Point(1358, 43)
$statusDot.BackColor = $script:Theme.Good
$statusDot.Anchor = 'Top,Right'
$script:StatusPill = $statusDot
[void]$header.Controls.Add($statusDot)

$statusValue = New-Object System.Windows.Forms.Label
$statusValue.Text = 'Live'
$statusValue.Location = New-Object System.Drawing.Point(1374, 34)
$statusValue.Size = New-Object System.Drawing.Size(56, 28)
$statusValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
$statusValue.ForeColor = [System.Drawing.Color]::White
$statusValue.BackColor = [System.Drawing.Color]::Transparent
$statusValue.Anchor = 'Top,Right'
$script:StatusValue = $statusValue
[void]$header.Controls.Add($statusValue)

$content = New-Object System.Windows.Forms.SplitContainer
$content.Dock = 'Fill'
$content.IsSplitterFixed = $false
try {
    $content.Panel1MinSize = 200
    $content.Panel2MinSize = 200
} catch {
}
$content.SplitterWidth = 8
$content.BackColor = $script:Theme.Canvas
$script:Content = $content
[void]$form.Controls.Add($content)

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = 'Fill'
$leftPanel.BackColor = $script:Theme.Background
[void]$content.Panel1.Controls.Add($leftPanel)

$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = 'Fill'
$rightPanel.BackColor = $script:Theme.Panel
$rightPanel.AutoScroll = $true
[void]$content.Panel2.Controls.Add($rightPanel)

$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = 'Top'
$toolbar.Height = 60
$toolbar.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 80)
[void]$leftPanel.Controls.Add($toolbar)

function New-HeaderButton {
    param(
        [string]$Text,
        [scriptblock]$OnClick,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size(96, 36)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5, [System.Drawing.FontStyle]::Bold)
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatAppearance.BorderColor = $BackColor
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $BackColor.R - 22),
        [Math]::Max(0, $BackColor.G - 22),
        [Math]::Max(0, $BackColor.B - 22))
    $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $BackColor.R - 44),
        [Math]::Max(0, $BackColor.G - 44),
        [Math]::Max(0, $BackColor.B - 44))
    $button.Add_Click($OnClick)
    return $button
}

$resumeButton = New-HeaderButton -Text 'Resume' -BackColor $script:Theme.Accent -OnClick {
    Set-ListeningState -Enabled $true
    Add-LogLine 'Listening resumed'
}
$resumeButton.Size = New-Object System.Drawing.Size(86, 34)
$resumeButton.Location = New-Object System.Drawing.Point(24, 15)
[void]$toolbar.Controls.Add($resumeButton)

$pauseButton = New-HeaderButton -Text 'Pause' -BackColor $script:Theme.AccentWarm -OnClick {
    Set-ListeningState -Enabled $false
    Add-LogLine 'Listening paused'
}
$pauseButton.Size = New-Object System.Drawing.Size(78, 34)
$pauseButton.Location = New-Object System.Drawing.Point(118, 15)
[void]$toolbar.Controls.Add($pauseButton)

$captureButton = New-HeaderButton -Text 'Capture' -BackColor $script:Theme.Good -OnClick {
    $binding = Get-SelectedBinding
    if (-not $binding) {
        Add-LogLine 'Select a slot before capturing a key'
        return
    }

    $script:CaptureNextKey = $true
    if ($script:CaptureEditorButton) { $script:CaptureEditorButton.Text = 'Waiting...' }
    Add-LogLine "Press the physical control for [$($binding.displayName)]"
}
$captureButton.Size = New-Object System.Drawing.Size(92, 34)
$captureButton.Location = New-Object System.Drawing.Point(204, 15)
[void]$toolbar.Controls.Add($captureButton)

$saveButton = New-HeaderButton -Text 'Save' -BackColor $script:Theme.Accent -OnClick {
    Save-CurrentBinding
}
$saveButton.Size = New-Object System.Drawing.Size(72, 34)
$saveButton.Location = New-Object System.Drawing.Point(304, 15)
[void]$toolbar.Controls.Add($saveButton)

$lockDeviceButton = New-HeaderButton -Text 'Lock Device' -BackColor $script:Theme.Shadow -ForeColor $script:Theme.Ink -OnClick {
    $script:DeviceLockArmed = $true
    Add-LogLine 'Press any key on the mini pad to lock DeckPad to that device'
}
$lockDeviceButton.Size = New-Object System.Drawing.Size(104, 34)
$lockDeviceButton.Location = New-Object System.Drawing.Point(384, 15)
[void]$toolbar.Controls.Add($lockDeviceButton)

$compactButton = New-HeaderButton -Text 'Compact' -BackColor $script:Theme.Shadow -ForeColor $script:Theme.Ink -OnClick {
    Toggle-CompactMode
}
$compactButton.Size = New-Object System.Drawing.Size(104, 34)
$compactButton.Location = New-Object System.Drawing.Point(496, 15)
$script:CompactButton = $compactButton
[void]$toolbar.Controls.Add($compactButton)

$pinButton = New-HeaderButton -Text 'Pin' -BackColor $script:Theme.Shadow -ForeColor $script:Theme.Ink -OnClick {
    Toggle-PinnedMode
}
$pinButton.Size = New-Object System.Drawing.Size(70, 34)
$pinButton.Location = New-Object System.Drawing.Point(608, 15)
$script:PinButton = $pinButton
[void]$toolbar.Controls.Add($pinButton)

$settingsButton = New-HeaderButton -Text 'Settings' -BackColor $script:Theme.AccentWarm -OnClick {
    Show-SettingsDialog
}
$settingsButton.Size = New-Object System.Drawing.Size(96, 34)
$settingsButton.Location = New-Object System.Drawing.Point(686, 15)
[void]$toolbar.Controls.Add($settingsButton)

$deviceCard = New-Object System.Windows.Forms.Panel
$deviceCard.Location = New-Object System.Drawing.Point(24, 76)
$deviceCard.Size = New-Object System.Drawing.Size(990, 184)
[void](Set-PanelSurface -Control $deviceCard)
$deviceCard.Anchor = 'Top,Left,Right'
$script:DeviceCard = $deviceCard
[void]$leftPanel.Controls.Add($deviceCard)

$deviceTitle = New-Object System.Windows.Forms.Label
$deviceTitle.Text = 'Programmable Deck'
$deviceTitle.Location = New-Object System.Drawing.Point(18, 14)
$deviceTitle.AutoSize = $true
$deviceTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$deviceTitle.ForeColor = $script:Theme.Muted
[void]$deviceCard.Controls.Add($deviceTitle)

$deviceName = New-Object System.Windows.Forms.Label
$deviceName.Text = '6 keys + 1 knob'
$deviceName.Location = New-Object System.Drawing.Point(18, 36)
$deviceName.AutoSize = $true
$deviceName.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$deviceName.ForeColor = $script:Theme.Ink
[void]$deviceCard.Controls.Add($deviceName)

$deviceStatusLabel = New-Object System.Windows.Forms.Label
$deviceStatusLabel.Text = 'Connection'
$deviceStatusLabel.Location = New-Object System.Drawing.Point(18, 78)
$deviceStatusLabel.AutoSize = $true
$deviceStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$deviceStatusLabel.ForeColor = $script:Theme.Muted
[void]$deviceCard.Controls.Add($deviceStatusLabel)

$deviceStatusValueLabel = New-Object System.Windows.Forms.Label
$deviceStatusValueLabel.Text = 'Not locked'
$deviceStatusValueLabel.Location = New-Object System.Drawing.Point(18, 98)
$deviceStatusValueLabel.AutoSize = $true
$deviceStatusValueLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
$deviceStatusValueLabel.ForeColor = $script:Theme.AccentWarm
$script:DeviceStatusValueLabel = $deviceStatusValueLabel
[void]$deviceCard.Controls.Add($deviceStatusValueLabel)

$deviceValueLabel = New-Object System.Windows.Forms.Label
$deviceValueLabel.Text = $script:TargetDeviceName
$deviceValueLabel.Location = New-Object System.Drawing.Point(18, 124)
$deviceValueLabel.Size = New-Object System.Drawing.Size(470, 28)
$deviceValueLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$deviceValueLabel.ForeColor = $script:Theme.Accent
$script:DeviceValueLabel = $deviceValueLabel
[void]$deviceCard.Controls.Add($deviceValueLabel)

$deviceHint = New-Object System.Windows.Forms.Label
$deviceHint.Text = 'Pick the mini pad from the list or use Lock To Device, then map every control however you want.'
$deviceHint.Location = New-Object System.Drawing.Point(20, 150)
$deviceHint.Size = New-Object System.Drawing.Size(500, 28)
$deviceHint.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
$deviceHint.ForeColor = $script:Theme.Muted
$script:DeviceHintLabel = $deviceHint
[void]$deviceCard.Controls.Add($deviceHint)

$devicePickerLabel = New-Object System.Windows.Forms.Label
$devicePickerLabel.Text = 'Choose Input Device'
$devicePickerLabel.Location = New-Object System.Drawing.Point(600, 16)
$devicePickerLabel.AutoSize = $true
$devicePickerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$devicePickerLabel.ForeColor = $script:Theme.Muted
$devicePickerLabel.Anchor = 'Top,Right'
[void]$deviceCard.Controls.Add($devicePickerLabel)

$deviceComboBox = New-Object System.Windows.Forms.ComboBox
$deviceComboBox.Location = New-Object System.Drawing.Point(600, 42)
$deviceComboBox.Size = New-Object System.Drawing.Size(344, 30)
$deviceComboBox.DropDownStyle = 'DropDownList'
$deviceComboBox.DropDownWidth = 420
$deviceComboBox.FlatStyle = 'Flat'
$deviceComboBox.Anchor = 'Top,Right'
[void](Set-InputStyle -Control $deviceComboBox)
$script:DeviceComboBox = $deviceComboBox
[void]$deviceCard.Controls.Add($deviceComboBox)

$refreshDevicesButton = New-Object System.Windows.Forms.Button
$refreshDevicesButton.Text = 'Refresh'
$refreshDevicesButton.Location = New-Object System.Drawing.Point(600, 84)
$refreshDevicesButton.Size = New-Object System.Drawing.Size(108, 34)
$refreshDevicesButton.Anchor = 'Top,Right'
[void](Set-ButtonStyle -Button $refreshDevicesButton -Variant 'secondary')
$refreshDevicesButton.Add_Click({
    Refresh-DevicePicker
    Add-LogLine 'Refreshed keyboard device list'
})
[void]$deviceCard.Controls.Add($refreshDevicesButton)

$useSelectedDeviceButton = New-Object System.Windows.Forms.Button
$useSelectedDeviceButton.Text = 'Use Selected'
$useSelectedDeviceButton.Location = New-Object System.Drawing.Point(718, 84)
$useSelectedDeviceButton.Size = New-Object System.Drawing.Size(112, 34)
$useSelectedDeviceButton.Anchor = 'Top,Right'
[void](Set-ButtonStyle -Button $useSelectedDeviceButton -Variant 'primary')
$useSelectedDeviceButton.Add_Click({
    if ($script:DeviceComboBox.SelectedIndex -ge 0 -and $script:DeviceComboBox.SelectedIndex -lt $script:DevicePickerEntries.Count) {
        $entry = $script:DevicePickerEntries[$script:DeviceComboBox.SelectedIndex]
        Set-TargetDevice -DeviceId $entry.PrimaryDeviceId -DeviceName $entry.DeviceName -HardwareId $entry.HardwareId
        Save-Profile -Profile $script:Profile
        Add-LogLine "Using selected device group [$($script:TargetDeviceName)]"
    }
})
[void]$deviceCard.Controls.Add($useSelectedDeviceButton)

$deckPreviewPanel = New-Object System.Windows.Forms.Panel
$deckPreviewPanel.Location = New-Object System.Drawing.Point(842, 84)
$deckPreviewPanel.Size = New-Object System.Drawing.Size(102, 86)
[void](Set-PanelSurface -Control $deckPreviewPanel -Variant 'alt')
$deckPreviewPanel.Anchor = 'Top,Right'
$deckPreviewPanel.Add_Paint({
    param($sender, $eventArgs)

    $g = $eventArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($script:Theme.AccentSoft)

    $bodyBrush = New-Object System.Drawing.SolidBrush($script:Theme.Header)
    $shadowPen = New-Object System.Drawing.Pen($script:Theme.StrongBorder, 2)
    $keyBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $knobBrush = New-Object System.Drawing.SolidBrush($script:Theme.Accent)
    $inkBrush = New-Object System.Drawing.SolidBrush($script:Theme.Ink)
    $smallFont = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)

    $g.FillRectangle($bodyBrush, 12, 18, 62, 46)
    $g.DrawRectangle($shadowPen, 12, 18, 62, 46)

    for ($row = 0; $row -lt 2; $row++) {
        for ($col = 0; $col -lt 3; $col++) {
            $x = 20 + ($col * 18)
            $y = 26 + ($row * 18)
            $g.FillRectangle($keyBrush, $x, $y, 12, 12)
            $g.DrawRectangle($shadowPen, $x, $y, 12, 12)
        }
    }

    $g.FillEllipse($knobBrush, 70, 30, 20, 20)
    $g.DrawEllipse($shadowPen, 70, 30, 20, 20)
    $g.DrawString('Deck', $smallFont, $inkBrush, 66, 58)

    $bodyBrush.Dispose()
    $shadowPen.Dispose()
    $keyBrush.Dispose()
    $knobBrush.Dispose()
    $inkBrush.Dispose()
    $smallFont.Dispose()
})
[void]$deviceCard.Controls.Add($deckPreviewPanel)

$gridPanel = New-Object System.Windows.Forms.TableLayoutPanel
$gridPanel.Location = New-Object System.Drawing.Point(24, 300)
$gridPanel.Size = New-Object System.Drawing.Size(990, 374)
$gridPanel.ColumnCount = 3
$gridPanel.RowCount = 3
$gridPanel.BackColor = $script:Theme.Canvas
$gridPanel.GrowStyle = 'FixedSize'
$gridPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$gridPanel.Anchor = 'Top,Left,Right'
[void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$gridPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$gridPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))

$gridSectionLabel = New-Object System.Windows.Forms.Label
$gridSectionLabel.Text = 'Physical Controls  |  Click any tile below to configure it'
$gridSectionLabel.Location = New-Object System.Drawing.Point(24, 278)
$gridSectionLabel.AutoSize = $true
$gridSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
$gridSectionLabel.ForeColor = $script:Theme.Muted
[void]$leftPanel.Controls.Add($gridSectionLabel)

$script:GridPanel = $gridPanel
[void]$leftPanel.Controls.Add($gridPanel)
$script:GridSectionLabel = $gridSectionLabel

$activityTitle = New-Object System.Windows.Forms.Label
$activityTitle.Text = 'Activity'
$activityTitle.Location = New-Object System.Drawing.Point(24, 696)
$activityTitle.AutoSize = $true
$activityTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$activityTitle.ForeColor = $script:Theme.Ink
$script:ActivityTitle = $activityTitle
[void]$leftPanel.Controls.Add($activityTitle)

$activityHintLabel = New-Object System.Windows.Forms.Label
$activityHintLabel.Text = 'Use this to see captured keys, app launches, Spotify volume changes, and device lock status.'
$activityHintLabel.Location = New-Object System.Drawing.Point(24, 724)
$activityHintLabel.AutoSize = $true
$activityHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
$activityHintLabel.ForeColor = $script:Theme.Muted
$script:ActivityHintLabel = $activityHintLabel
[void]$leftPanel.Controls.Add($activityHintLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(24, 750)
$logBox.Size = New-Object System.Drawing.Size(990, 128)
$logBox.BackColor = $script:Theme.Panel
$logBox.ForeColor = $script:Theme.Ink
$logBox.BorderStyle = 'FixedSingle'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
$logBox.Anchor = 'Top,Left,Right,Bottom'
$script:LogBox = $logBox
[void]$leftPanel.Controls.Add($logBox)

$rightPanelHeader = New-Object System.Windows.Forms.Panel
$rightPanelHeader.Location = New-Object System.Drawing.Point(0, 0)
$rightPanelHeader.Size = New-Object System.Drawing.Size(430, 72)
$rightPanelHeader.Anchor = 'Top,Left,Right'
$rightPanelHeader.Height = 72
$rightPanelHeader.BackColor = [System.Drawing.Color]::FromArgb(247, 250, 255)
$rightPanelHeader.BorderStyle = 'FixedSingle'
[void]$rightPanel.Controls.Add($rightPanelHeader)

$editorTitle = New-Object System.Windows.Forms.Label
$editorTitle.Text = 'Configure Control'
$editorTitle.Location = New-Object System.Drawing.Point(18, 12)
$editorTitle.AutoSize = $true
$editorTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$editorTitle.ForeColor = $script:Theme.Ink
[void]$rightPanelHeader.Controls.Add($editorTitle)

$selectedBindingLabel = New-Object System.Windows.Forms.Label
$selectedBindingLabel.Text = 'Editing Key 1'
$selectedBindingLabel.Location = New-Object System.Drawing.Point(20, 46)
$selectedBindingLabel.AutoSize = $true
$selectedBindingLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10, [System.Drawing.FontStyle]::Bold)
$selectedBindingLabel.ForeColor = $script:Theme.Accent
$script:SelectedBindingLabel = $selectedBindingLabel
[void]$rightPanelHeader.Controls.Add($selectedBindingLabel)

$howToPanel = New-Object System.Windows.Forms.Panel
$howToPanel.Location = New-Object System.Drawing.Point(18, 78)
$howToPanel.Size = New-Object System.Drawing.Size(364, 88)
$howToPanel.BackColor = $script:Theme.AccentSoft
$howToPanel.BorderStyle = 'None'
[void]$rightPanel.Controls.Add($howToPanel)

$howToTitle = New-Object System.Windows.Forms.Label
$howToTitle.Text = 'HOW TO MAP'
$howToTitle.Location = New-Object System.Drawing.Point(14, 9)
$howToTitle.AutoSize = $true
$howToTitle.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$howToTitle.ForeColor = $script:Theme.Accent
[void]$howToPanel.Controls.Add($howToTitle)

$howToSteps = New-Object System.Windows.Forms.Label
$howToSteps.Text = "1  Select a tile on the left`r`n2  Click Capture Key then press the physical button`r`n3  Choose action type, fill in value, Save Slot"
$howToSteps.Location = New-Object System.Drawing.Point(14, 28)
$howToSteps.Size = New-Object System.Drawing.Size(340, 54)
$howToSteps.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$howToSteps.ForeColor = $script:Theme.Ink
[void]$howToPanel.Controls.Add($howToSteps)

function New-FieldLabel {
    param([string]$Text, [int]$Y)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(20, $Y)
    $label.AutoSize = $true
    $label.ForeColor = $script:Theme.Muted
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    return $label
}

function New-FieldBox {
    param([int]$Y, [int]$Height = 34)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(20, ($Y + 24))
    $box.Size = New-Object System.Drawing.Size(362, $Height)
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
    [void](Set-InputStyle -Control $box)
    return $box
}

$slotNameLabel = New-FieldLabel -Text 'Physical Control' -Y 178
[void]$rightPanel.Controls.Add($slotNameLabel)
$slotNameValue = New-Object System.Windows.Forms.Label
$slotNameValue.Location = New-Object System.Drawing.Point(22, 202)
$slotNameValue.AutoSize = $true
$slotNameValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12, [System.Drawing.FontStyle]::Bold)
$slotNameValue.ForeColor = $script:Theme.Ink
$script:SlotNameValue = $slotNameValue
[void]$rightPanel.Controls.Add($slotNameValue)

$labelLabel = New-FieldLabel -Text 'Display Label' -Y 236
[void]$rightPanel.Controls.Add($labelLabel)
$labelBox = New-FieldBox -Y 236
$script:LabelBox = $labelBox
[void]$rightPanel.Controls.Add($labelBox)

$keyLabel = New-FieldLabel -Text 'Trigger Key' -Y 300
[void]$rightPanel.Controls.Add($keyLabel)

$keyBox = New-Object System.Windows.Forms.TextBox
$keyBox.Location = New-Object System.Drawing.Point(20, 324)
$keyBox.Size = New-Object System.Drawing.Size(176, 34)
$keyBox.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
[void](Set-InputStyle -Control $keyBox)
$script:KeyBox = $keyBox
[void]$rightPanel.Controls.Add($keyBox)

$captureEditorButton = New-Object System.Windows.Forms.Button
$captureEditorButton.Text = 'Capture Key'
$captureEditorButton.Location = New-Object System.Drawing.Point(206, 322)
$captureEditorButton.Size = New-Object System.Drawing.Size(176, 36)
[void](Set-ButtonStyle -Button $captureEditorButton -Variant 'success')
$captureEditorButton.Add_Click({
    $binding = Get-SelectedBinding
    if (-not $binding) {
        Add-LogLine 'Select a slot before capturing a key'
        return
    }
    if ($script:CaptureNextKey) {
        $script:CaptureNextKey = $false
        $script:CaptureEditorButton.Text = 'Capture Key'
        Add-LogLine 'Capture cancelled'
        return
    }
    $script:CaptureNextKey = $true
    $script:CaptureEditorButton.Text = 'Waiting...'
    Add-LogLine "Press the physical control for [$($binding.displayName)]"
})
$script:CaptureEditorButton = $captureEditorButton
[void]$rightPanel.Controls.Add($captureEditorButton)

$vkBox = New-Object System.Windows.Forms.TextBox
$vkBox.Visible = $false
$script:VkBox = $vkBox
[void]$rightPanel.Controls.Add($vkBox)

$actionTypeLabel = New-FieldLabel -Text 'Action Type' -Y 372
[void]$rightPanel.Controls.Add($actionTypeLabel)
$actionTypeBox = New-Object System.Windows.Forms.ComboBox
$actionTypeBox.Location = New-Object System.Drawing.Point(20, 396)
$actionTypeBox.Size = New-Object System.Drawing.Size(362, 36)
$actionTypeBox.DropDownStyle = 'DropDownList'
$actionTypeBox.FlatStyle = 'Flat'
$actionTypeBox.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
[void](Set-InputStyle -Control $actionTypeBox)
[void]$actionTypeBox.Items.AddRange(@(
    'focus_or_launch',
    'launch_app',
    'open_url',
    'type_text',
    'send_hotkey',
    'run_command',
    'spotify_volume_down',
    'spotify_play_pause',
    'spotify_previous_track',
    'spotify_next_track',
    'spotify_volume_up'
))
$actionTypeBox.Add_SelectedIndexChanged({
    $script:ActionHintLabel.Text = Get-ActionTemplate -ActionType ([string]$script:ActionTypeBox.SelectedItem)
})
$script:ActionTypeBox = $actionTypeBox
[void]$rightPanel.Controls.Add($actionTypeBox)

$actionHintLabel = New-Object System.Windows.Forms.Label
$actionHintLabel.Location = New-Object System.Drawing.Point(22, 436)
$actionHintLabel.Size = New-Object System.Drawing.Size(360, 30)
$actionHintLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$actionHintLabel.ForeColor = $script:Theme.Muted
$script:ActionHintLabel = $actionHintLabel
[void]$rightPanel.Controls.Add($actionHintLabel)

$valueLabel = New-FieldLabel -Text 'Action Value' -Y 470
[void]$rightPanel.Controls.Add($valueLabel)
$valueBox = New-Object System.Windows.Forms.TextBox
$valueBox.Location = New-Object System.Drawing.Point(20, 494)
$valueBox.Size = New-Object System.Drawing.Size(362, 92)
$valueBox.Multiline = $true
$valueBox.ScrollBars = 'Vertical'
$valueBox.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
[void](Set-InputStyle -Control $valueBox)
$script:ValueBox = $valueBox
[void]$rightPanel.Controls.Add($valueBox)

$saveEditorButton = New-Object System.Windows.Forms.Button
$saveEditorButton.Text = 'Save Slot'
$saveEditorButton.Location = New-Object System.Drawing.Point(20, 602)
$saveEditorButton.Size = New-Object System.Drawing.Size(140, 40)
[void](Set-ButtonStyle -Button $saveEditorButton -Variant 'primary')
$saveEditorButton.Add_Click({ Save-CurrentBinding })
[void]$rightPanel.Controls.Add($saveEditorButton)

$profileFolderButton = New-Object System.Windows.Forms.Button
$profileFolderButton.Text = 'Profile Folder'
$profileFolderButton.Location = New-Object System.Drawing.Point(170, 602)
$profileFolderButton.Size = New-Object System.Drawing.Size(136, 40)
[void](Set-ButtonStyle -Button $profileFolderButton -Variant 'secondary')
$profileFolderButton.Add_Click({
    Start-Process explorer.exe (Split-Path -Parent $script:ProfilePath)
})
[void]$rightPanel.Controls.Add($profileFolderButton)

$profileNameLabel = New-FieldLabel -Text 'Profile Name' -Y 660
[void]$rightPanel.Controls.Add($profileNameLabel)
$profileNameBox = New-FieldBox -Y 660
$script:ProfileNameBox = $profileNameBox
[void]$rightPanel.Controls.Add($profileNameBox)

$helperLabel = New-Object System.Windows.Forms.Label
$helperLabel.Text = 'Tip: Lock the deck to your device first so only its keys trigger actions.'
$helperLabel.Location = New-Object System.Drawing.Point(20, 728)
$helperLabel.Size = New-Object System.Drawing.Size(364, 48)
$helperLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Italic)
$helperLabel.ForeColor = $script:Theme.Muted
[void]$rightPanel.Controls.Add($helperLabel)

Rebuild-DeckPadShell
Build-TileGrid
Refresh-Tiles
Refresh-DevicePicker
foreach ($device in $script:DeviceOptions) {
    if (
        $device.DeviceId -eq $script:TargetDeviceId -or
        ($script:TargetDeviceHardwareId -and $device.PSObject.Properties['HardwareId'] -and $device.HardwareId -eq $script:TargetDeviceHardwareId)
    ) {
        $script:TargetDeviceHardwareId = if ($device.PSObject.Properties['HardwareId']) { $device.HardwareId } else { '' }
        if (-not $script:TargetDeviceId) {
            $script:TargetDeviceId = $device.DeviceId
        }
        break
    }
}
Set-TargetDevice -DeviceId $script:TargetDeviceId -DeviceName $script:TargetDeviceName -HardwareId $script:TargetDeviceHardwareId
Report-BindingConflicts

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    Clear-ExpiredCorrelationWindows

    $globalEvent = $null
    while ([DeckPadNative.RawInputMonitor]::TryDequeueGlobal([ref]$globalEvent)) {
        if (Test-IsModifierVk -VkCode $globalEvent.VirtualKey) {
            continue
        }

        $globalKeyName = Get-KeyName -VkCode $globalEvent.VirtualKey

        if ($script:CaptureNextKey -and (Test-IsMediaVk -VkCode $globalEvent.VirtualKey)) {
            $binding = Get-SelectedBinding
            if ($binding) {
                Set-BindingTriggerFromGlobalKey -Binding $binding -VkCode $globalEvent.VirtualKey -KeyName $globalKeyName
                $script:KeyBox.Text = $binding.keyName
                $script:VkBox.Text = [string]$binding.vkCode
                if ($script:TriggerDetailLabel) { $script:TriggerDetailLabel.Text = Get-BindingTriggerSummary -Binding $binding }
                $script:CaptureNextKey = $false
                if ($script:CaptureEditorButton) { $script:CaptureEditorButton.Text = 'Capture Key' }
                $script:PendingCorrelatedCapture = $null
                Refresh-Tiles
                Add-LogLine "Captured media key [$globalKeyName] for [$($binding.displayName)] - $(Get-BindingTriggerSummary -Binding $binding)"
            }
            continue
        }

        if ($script:PendingCorrelatedCapture -and ([Environment]::TickCount -le $script:PendingCorrelatedCapture.Deadline)) {
            $binding = Get-SelectedBinding
            if ($binding) {
                Set-BindingTriggerFromGlobalKey -Binding $binding -VkCode $globalEvent.VirtualKey -KeyName $globalKeyName
                $script:KeyBox.Text = $binding.keyName
                $script:VkBox.Text = [string]$binding.vkCode
                if ($script:TriggerDetailLabel) { $script:TriggerDetailLabel.Text = Get-BindingTriggerSummary -Binding $binding }
                $script:CaptureNextKey = $false
                $script:CaptureEditorButton.Text = 'Capture Key'
                $script:PendingCorrelatedCapture = $null
                Refresh-Tiles
                Add-LogLine "Captured correlated key [$globalKeyName] for [$($binding.displayName)] - $(Get-BindingTriggerSummary -Binding $binding)"
            }
            continue
        }

        if ($script:PendingCorrelatedTrigger -and ([Environment]::TickCount -le $script:PendingCorrelatedTrigger.Deadline)) {
            $binding = Get-BindingForGlobalKey -VkCode $globalEvent.VirtualKey
            $script:PendingCorrelatedTrigger = $null
            if ($null -ne $binding) {
                Add-LogLine "Triggered [$($binding.displayName)] from correlated key [$globalKeyName]"
                try {
                    Invoke-DeckAction -Binding $binding
                } catch {
                    Add-LogLine "Action failed: $($_.Exception.Message)"
                }
            } else {
                Add-LogLine "Correlated unmapped key detected: [$globalKeyName] VK=$($globalEvent.VirtualKey)"
            }
        }

    }

    $rawEvent = $null
    while ([DeckPadNative.RawInputMonitor]::TryDequeue([ref]$rawEvent)) {
        $vkCode = $rawEvent.VirtualKey
        $keyName = Get-KeyName -VkCode $vkCode
        $isModifier = Test-IsModifierVk -VkCode $vkCode

        if ($script:DeviceLockArmed) {
            $hardwareId = if ($rawEvent.PSObject.Properties['HardwareId']) { [string]$rawEvent.HardwareId } else { '' }
            Set-TargetDevice -DeviceId $rawEvent.DeviceId -DeviceName $rawEvent.DeviceName -HardwareId $hardwareId
            Save-Profile -Profile $script:Profile
            Refresh-DevicePicker
            $script:DeviceLockArmed = $false
            Add-LogLine "Locked DeckPad to device group [$($script:TargetDeviceName)]"
            continue
        }

        if ($script:CaptureNextKey) {
            if (-not $script:TargetDeviceId) {
                $hardwareId = if ($rawEvent.PSObject.Properties['HardwareId']) { [string]$rawEvent.HardwareId } else { '' }
                Set-TargetDevice -DeviceId $rawEvent.DeviceId -DeviceName $rawEvent.DeviceName -HardwareId $hardwareId
                Save-Profile -Profile $script:Profile
                Refresh-DevicePicker
                Add-LogLine "Locked DeckPad to device group [$($script:TargetDeviceName)]"
            }

            if (-not (Device-MatchesTarget -RawEvent $rawEvent)) {
                continue
            }

            if ($isModifier) {
                Start-CorrelatedCaptureWindow -RawEvent $rawEvent
                Add-LogLine "Saw modifier [$keyName] during capture; waiting for the correlated trigger key"
                continue
            }

            $binding = Get-SelectedBinding
            if ($binding) {
                $captureModifiers = if ($script:PendingCorrelatedCapture) { @($script:PendingCorrelatedCapture.ModifierVks) } else { @() }
                Set-BindingTriggerFromRawEvent -Binding $binding -RawEvent $rawEvent -KeyName $keyName -ModifierVks $captureModifiers
                $script:KeyBox.Text = $binding.keyName
                $script:VkBox.Text = [string]$binding.vkCode
                if ($script:TriggerDetailLabel) { $script:TriggerDetailLabel.Text = Get-BindingTriggerSummary -Binding $binding }
                $script:CaptureNextKey = $false
                $script:PendingCorrelatedCapture = $null
                if ($script:CaptureEditorButton) { $script:CaptureEditorButton.Text = 'Capture Key' }
                Refresh-Tiles
                Add-LogLine "Captured [$keyName] for [$($binding.displayName)] - $(Get-BindingTriggerSummary -Binding $binding)"
            }
            continue
        }

        if (-not $script:Listening) {
            continue
        }

        if (-not $script:TargetDeviceId -and -not $script:TargetDeviceHardwareId) {
            continue
        }

        if (-not (Device-MatchesTarget -RawEvent $rawEvent)) {
            continue
        }

        if ($isModifier) {
            Start-CorrelatedTriggerWindow -RawEvent $rawEvent
            continue
        }

        $triggerModifiers = if ($script:PendingCorrelatedTrigger) { @($script:PendingCorrelatedTrigger.ModifierVks) } else { @() }
        $binding = Get-BindingForRawEvent -RawEvent $rawEvent -ModifierVks $triggerModifiers
        $script:PendingCorrelatedTrigger = $null
        if ($null -ne $binding) {
            Add-LogLine "Triggered [$($binding.displayName)] from [$keyName]"
            try {
                Invoke-DeckAction -Binding $binding
            } catch {
                Add-LogLine "Action failed: $($_.Exception.Message)"
            }
        } else {
            Add-LogLine "Unmapped key detected: [$keyName] VK=$vkCode"
        }
    }
})

if (-not [DeckPadNative.RawInputMonitor]::Start()) {
    [System.Windows.Forms.MessageBox]::Show(
        'DeckPad could not start raw keyboard input monitoring.',
        'DeckPad',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$script:SelectedIndex = 0
Populate-Editor
Set-ListeningState -Enabled ([bool]$script:Settings.resumeListeningOnStartup)
$timer.Start()
Update-ModeVisuals

Add-LogLine 'DeckPad is ready'
Add-LogLine 'This build is tuned for 6 keys and 1 knob'
Add-LogLine 'Choose the mini pad from the device list or click Lock Device'

$form.Add_SizeChanged({
    if (
        $script:Settings -and
        [bool]$script:Settings.minimizeToTray -and
        $script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized
    ) {
        Hide-DeckPadToTray
    }
})

$form.Add_Shown({
    Apply-StableLayout
    if ($script:StartInTray) {
        Hide-DeckPadToTray
    }
})

$form.Add_ResizeEnd({
    Apply-StableLayout
})

$form.Add_FormClosing({
    if (
        -not $script:AllowExit -and
        $script:Settings -and
        [bool]$script:Settings.closeToTray
    ) {
        $_.Cancel = $true
        Hide-DeckPadToTray
        return
    }

    $timer.Stop()
    [DeckPadNative.RawInputMonitor]::Stop()
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    Release-SingleInstanceGuard
})

[void][System.Windows.Forms.Application]::Run($form)
