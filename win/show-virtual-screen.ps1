# show-virtual-screen.ps1 - Shows the virtual screen window only
# This window's content gets captured by ffmpeg and sent to iPad

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$f = New-Object System.Windows.Forms.Form
$f.Text = "iPadVirtualScreen"
$f.Width = 960
$f.Height = 720
$f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$f.TopMost = $true
$f.StartPosition = "CenterScreen"
$f.FormBorderStyle = "Sizable"

$l = New-Object System.Windows.Forms.Label
$l.Text = "iPad Virtual Screen`n`nDrag app windows here`nThis area is shown on iPad"
$l.ForeColor = [System.Drawing.Color]::FromArgb(100, 200, 255)
$l.Font = New-Object System.Drawing.Font("Segoe UI", 16)
$l.AutoSize = $true
$l.Location = New-Object System.Drawing.Point(20, 20)
$f.Controls.Add($l)

[System.Windows.Forms.Application]::Run($f)
