# capture_window.ps1: starts a PC build, waits, optionally sends keys, saves its window as a PNG, then stops it.
# Used to measure what the PC renderer draws (G2 L4-4 onwards): read the PNG's pixels with Python (PIL).
# The PC framebuffer is sRGB, so a value worked out in linear light is converted before comparing.
#   powershell -NoProfile -File tools/capture_window.ps1 -exe build/model_check.exe -out shot.png [-wait 4] [-keys l]
# -keys goes through SendKeys after the window is brought forward ("l" presses L once).
param([string]$exe, [string]$out, [int]$wait = 4, [string]$keys = "")
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
"@
$p = Start-Process $exe -PassThru -WorkingDirectory (Get-Location)
Start-Sleep $wait
$p.Refresh()
$h = $p.MainWindowHandle
if ($keys -ne "") { Add-Type -AssemblyName System.Windows.Forms; [Win]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait($keys); Start-Sleep 1 }
$r = New-Object Win+RECT
[Win]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R - $r.L; $hgt = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
[Win]::PrintWindow($h, $dc, 2) | Out-Null
$g.ReleaseHdc($dc)
$bmp.Save($out)
$g.Dispose(); $bmp.Dispose()
Stop-Process -Id $p.Id -Force
"saved $w x $hgt"
