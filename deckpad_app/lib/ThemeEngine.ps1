function Get-SlotPalette {
    param([string]$SlotId)

    switch ($SlotId) {
        'key1' { return @{ Fill = [System.Drawing.Color]::FromArgb(233, 241, 255); Hover = [System.Drawing.Color]::FromArgb(219, 233, 252); Border = [System.Drawing.Color]::FromArgb(91, 137, 214) } }
        'key2' { return @{ Fill = [System.Drawing.Color]::FromArgb(236, 244, 255); Hover = [System.Drawing.Color]::FromArgb(223, 235, 252); Border = [System.Drawing.Color]::FromArgb(102, 146, 218) } }
        'key3' { return @{ Fill = [System.Drawing.Color]::FromArgb(240, 246, 255); Hover = [System.Drawing.Color]::FromArgb(227, 238, 253); Border = [System.Drawing.Color]::FromArgb(111, 152, 219) } }
        'key4' { return @{ Fill = [System.Drawing.Color]::FromArgb(242, 247, 255); Hover = [System.Drawing.Color]::FromArgb(230, 239, 253); Border = [System.Drawing.Color]::FromArgb(118, 157, 220) } }
        'key5' { return @{ Fill = [System.Drawing.Color]::FromArgb(237, 244, 255); Hover = [System.Drawing.Color]::FromArgb(224, 236, 252); Border = [System.Drawing.Color]::FromArgb(104, 147, 215) } }
        'key6' { return @{ Fill = [System.Drawing.Color]::FromArgb(239, 245, 255); Hover = [System.Drawing.Color]::FromArgb(228, 238, 253); Border = [System.Drawing.Color]::FromArgb(114, 154, 219) } }
        'knob_left' { return @{ Fill = [System.Drawing.Color]::FromArgb(229, 239, 255); Hover = [System.Drawing.Color]::FromArgb(214, 230, 252); Border = [System.Drawing.Color]::FromArgb(77, 128, 209) } }
        'knob_press' { return @{ Fill = [System.Drawing.Color]::FromArgb(222, 234, 255); Hover = [System.Drawing.Color]::FromArgb(208, 225, 252); Border = [System.Drawing.Color]::FromArgb(64, 118, 203) } }
        'knob_right' { return @{ Fill = [System.Drawing.Color]::FromArgb(231, 240, 255); Hover = [System.Drawing.Color]::FromArgb(216, 231, 252); Border = [System.Drawing.Color]::FromArgb(84, 132, 211) } }
        default { return @{ Fill = $script:Theme.Panel; Hover = $script:Theme.PanelAlt; Border = $script:Theme.Border } }
    }
}
