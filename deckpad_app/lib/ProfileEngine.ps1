function New-Binding {
    param(
        [string]$SlotId,
        [string]$DisplayName,
        [string]$Label,
        [string]$KeyName,
        [int]$VkCode,
        [string]$ActionType,
        [string]$Value
    )

    [pscustomobject]@{
        slotId = $SlotId
        displayName = $DisplayName
        label = $Label
        keyName = $KeyName
        vkCode = $VkCode
        triggerSignature = ''
        actionType = $ActionType
        value = $Value
    }
}

function Get-DefaultBindings {
    @(
        New-Binding 'key1' 'Top Left' 'Discord' '' 0 'focus_or_launch' 'discord|discord'
        New-Binding 'key2' 'Top Middle' 'Spotify' '' 0 'focus_or_launch' 'spotify|spotify'
        New-Binding 'key3' 'Top Right' 'Browser' '' 0 'open_url' 'https://www.twitch.tv'
        New-Binding 'key4' 'Bottom Left' 'Scene 1' '' 0 'send_hotkey' '^+1'
        New-Binding 'key5' 'Bottom Middle' 'Notes' '' 0 'launch_app' 'notepad.exe'
        New-Binding 'key6' 'Bottom Right' 'Files' '' 0 'launch_app' 'explorer.exe'
        New-Binding 'knob_left' 'Knob Left' 'Spotify Previous' '' 0 'spotify_previous_track' ''
        New-Binding 'knob_press' 'Knob Press' 'Spotify Play/Pause' '' 0 'spotify_play_pause' ''
        New-Binding 'knob_right' 'Knob Right' 'Spotify Next' '' 0 'spotify_next_track' ''
    )
}

function New-DefaultProfile {
    [pscustomobject]@{
        name = '6-Key Stream Deck'
        deviceLayout = '6-keys-1-knob'
        targetDeviceId = $null
        targetDeviceName = 'Not locked'
        bindings = Get-DefaultBindings
    }
}

function Normalize-Profile {
    param([object]$Profile)

    $defaults = Get-DefaultBindings
    $normalized = @()

    foreach ($defaultBinding in $defaults) {
        $existing = $null
        if ($Profile -and $Profile.bindings) {
            $existing = $Profile.bindings | Where-Object { $_.slotId -eq $defaultBinding.slotId } | Select-Object -First 1
        }

        if ($existing) {
            if (-not $existing.displayName) { $existing.displayName = $defaultBinding.displayName }
            if (-not $existing.label) { $existing.label = $defaultBinding.label }
            if (-not $existing.keyName) { $existing.keyName = $defaultBinding.keyName }
            if (-not ($existing.PSObject.Properties.Name -contains 'triggerSignature')) { $existing | Add-Member -NotePropertyName triggerSignature -NotePropertyValue '' -Force }
            if (-not $existing.actionType) { $existing.actionType = $defaultBinding.actionType }
            if ($null -eq $existing.vkCode) { $existing.vkCode = $defaultBinding.vkCode }
            if ($null -eq $existing.value) { $existing.value = $defaultBinding.value }
            $normalized += $existing
        } else {
            $normalized += $defaultBinding
        }
    }

    if (-not $Profile) {
        $Profile = [pscustomobject]@{}
    }

    if (-not $Profile.name) {
        $Profile | Add-Member -NotePropertyName name -NotePropertyValue '6-Key Stream Deck' -Force
    }
    if (-not $Profile.deviceLayout) {
        $Profile | Add-Member -NotePropertyName deviceLayout -NotePropertyValue '6-keys-1-knob' -Force
    }
    if (-not ($Profile.PSObject.Properties.Name -contains 'targetDeviceId')) {
        $Profile | Add-Member -NotePropertyName targetDeviceId -NotePropertyValue $null -Force
    }
    if (-not $Profile.targetDeviceName) {
        $Profile | Add-Member -NotePropertyName targetDeviceName -NotePropertyValue 'Not locked' -Force
    }

    $Profile.bindings = $normalized
    return $Profile
}

function Load-Profile {
    if (-not (Test-Path -LiteralPath $script:ProfilePath)) {
        $defaultProfile = New-DefaultProfile
        Save-Profile -Profile $defaultProfile
        return $defaultProfile
    }

    $raw = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
    return Normalize-Profile -Profile $raw
}

function Save-Profile {
    param(
        [Parameter(Mandatory)]
        [object]$Profile
    )

    $profileDir = Split-Path -Parent $script:ProfilePath
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir | Out-Null
    }

    $Profile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ProfilePath
}
