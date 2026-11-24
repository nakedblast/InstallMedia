<#
.SYNOPSIS
    Full-screen colour test for dead/stuck pixels, OLED tint and banding.
.DESCRIPTION
    Shows solid colours full screen on the primary display. Click, Space or Right arrow: next colour.
    Left arrow: previous. Esc: quit. Read-only; changes nothing.
    -AutoAdvanceMs cycles automatically and closes after the last colour (for testing).
#>
param([int]$AutoAdvanceMs = 0)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$colors = @(
    @('White',     [System.Drawing.Color]::FromArgb(255, 255, 255)),
    @('Black',     [System.Drawing.Color]::FromArgb(0, 0, 0)),
    @('Red',       [System.Drawing.Color]::FromArgb(255, 0, 0)),
    @('Green',     [System.Drawing.Color]::FromArgb(0, 255, 0)),
    @('Blue',      [System.Drawing.Color]::FromArgb(0, 0, 255)),
    @('Mid grey',  [System.Drawing.Color]::FromArgb(128, 128, 128)),
    @('Dark grey', [System.Drawing.Color]::FromArgb(24, 24, 24))
)
$script:i = 0

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$form.TopMost = $true
$form.KeyPreview = $true
$form.Cursor = [System.Windows.Forms.Cursors]::None

$label = New-Object System.Windows.Forms.Label
$label.AutoSize = $true
$label.Font = New-Object System.Drawing.Font('Segoe UI', 14)
$label.Location = New-Object System.Drawing.Point(20, 20)
$label.Text = 'Click / Space = next colour   Left = back   Esc = quit'
$form.Controls.Add($label)

$hide = New-Object System.Windows.Forms.Timer
$hide.Interval = 2500
$hide.Add_Tick({ $label.Visible = $false; $hide.Stop() })

function Show-Colour {
    $c = $colors[$script:i][1]
    $form.BackColor = $c
    $label.ForeColor = if (($c.R + $c.G + $c.B) -gt 380) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
    $label.Text = "$($colors[$script:i][0])  ($($script:i + 1)/$($colors.Count))   Click / Space = next   Left = back   Esc = quit"
    $label.Visible = $true
    $hide.Stop(); $hide.Start()
}
function Step([int]$d) {
    $n = $script:i + $d
    if ($n -ge $colors.Count) { $form.Close(); return }
    if ($n -lt 0) { $n = 0 }
    $script:i = $n
    Show-Colour
}

$form.Add_KeyDown({
    switch ($_.KeyCode) {
        'Escape' { $form.Close() }
        'Left'   { Step -1 }
        'Right'  { Step 1 }
        'Space'  { Step 1 }
    }
})
$form.Add_MouseClick({ Step 1 })
$label.Add_MouseClick({ Step 1 })

if ($AutoAdvanceMs -gt 0) {
    $auto = New-Object System.Windows.Forms.Timer
    $auto.Interval = $AutoAdvanceMs
    $auto.Add_Tick({ Step 1 })
    $form.Add_Shown({ $auto.Start() })
}

Show-Colour
[void]$form.ShowDialog()
$form.Dispose()
