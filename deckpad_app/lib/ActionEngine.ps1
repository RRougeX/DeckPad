function Get-ActionBadge {
    param([string]$ActionType)

    switch ($ActionType) {
        'focus_or_launch' { return 'APP' }
        'launch_app' { return 'RUN' }
        'open_url' { return 'WEB' }
        'type_text' { return 'TEXT' }
        'send_hotkey' { return 'KEY' }
        'run_command' { return 'CMD' }
        'spotify_volume_down' { return 'VOL-' }
        'spotify_play_pause' { return 'PLAY' }
        'spotify_previous_track' { return 'PREV' }
        'spotify_next_track' { return 'NEXT' }
        'spotify_volume_up' { return 'VOL+' }
        default { return 'ACT' }
    }
}

function Split-ExecutableSpec {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @('', '')
    }

    $parts = $Value -split '\|', 2
    if ($parts.Count -eq 1) {
        return @($parts[0].Trim(), $parts[0].Trim())
    }

    return @($parts[0].Trim(), $parts[1].Trim())
}

function Invoke-LaunchApp {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $parts = $Value -split '\s+', 2
    if ($parts.Count -eq 1) {
        Start-Process -FilePath $parts[0] | Out-Null
    } else {
        Start-Process -FilePath $parts[0] -ArgumentList $parts[1] | Out-Null
    }
}

function Invoke-SpotifyVolumeAction {
    param([float]$Delta)

    $volume = 0.0
    if ([DeckPadNative.AudioSessionActions]::AdjustProcessVolume('spotify', $Delta, [ref]$volume)) {
        Add-LogLine ("Spotify volume {0:N0}%" -f $volume)
        return
    }

    Add-LogLine 'Spotify audio session was not found; open Spotify and start playback once, then try again.'
}

function Invoke-DeckAction {
    param([object]$Binding)

    if (-not $Binding) {
        return
    }

    switch ($Binding.actionType) {
        'focus_or_launch' {
            $parts = Split-ExecutableSpec -Value $Binding.value
            $focused = [DeckPadNative.WindowActions]::FocusOrLaunch($parts[0], $parts[1])
            if ($focused) {
                Add-LogLine "Focused or launched [$($Binding.label)]"
            } else {
                Add-LogLine "Could not focus or launch [$($Binding.label)]"
            }
        }

        'launch_app' {
            Invoke-LaunchApp -Value $Binding.value
            Add-LogLine "Launched: $($Binding.value)"
        }

        'open_url' {
            if ([string]::IsNullOrWhiteSpace($Binding.value)) { return }
            Start-Process $Binding.value | Out-Null
            Add-LogLine "Opened URL: $($Binding.value)"
        }

        'type_text' {
            [System.Windows.Forms.SendKeys]::SendWait($Binding.value)
            Add-LogLine "Typed text from [$($Binding.label)]"
        }

        'send_hotkey' {
            [System.Windows.Forms.SendKeys]::SendWait($Binding.value)
            Add-LogLine "Sent hotkey: $($Binding.value)"
        }

        'run_command' {
            if ([string]::IsNullOrWhiteSpace($Binding.value)) { return }
            Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -WindowStyle Hidden -Command $($Binding.value)" | Out-Null
            Add-LogLine "Ran command from [$($Binding.label)]"
        }

        'spotify_volume_down' {
            Invoke-SpotifyVolumeAction -Delta (-0.05)
        }

        'spotify_volume_up' {
            Invoke-SpotifyVolumeAction -Delta 0.05
        }

        'spotify_play_pause' {
            [DeckPadNative.WindowActions]::SendMediaPlayPause()
            Add-LogLine 'Sent background media play/pause'
        }

        'spotify_previous_track' {
            [DeckPadNative.WindowActions]::SendMediaPreviousTrack()
            Add-LogLine 'Sent background media previous track'
        }

        'spotify_next_track' {
            [DeckPadNative.WindowActions]::SendMediaNextTrack()
            Add-LogLine 'Sent background media next track'
        }

        default {
            Add-LogLine "No action assigned to [$($Binding.label)]"
        }
    }
}

function Get-ActionTemplate {
    param([string]$ActionType)

    switch ($ActionType) {
        'focus_or_launch' { return 'Example: discord|discord or spotify|spotify' }
        'launch_app' { return 'Example: notepad.exe or explorer.exe shell:Videos' }
        'open_url' { return 'Example: https://discord.com/app' }
        'type_text' { return 'Example: Starting stream now' }
        'send_hotkey' { return 'Example: ^+1' }
        'run_command' { return 'Example: Start-Process calc.exe' }
        'spotify_volume_down' { return 'No value needed' }
        'spotify_volume_up' { return 'No value needed' }
        'spotify_play_pause' { return 'No value needed' }
        'spotify_previous_track' { return 'No value needed' }
        'spotify_next_track' { return 'No value needed' }
        default { return '' }
    }
}
