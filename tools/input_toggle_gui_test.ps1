param([Parameter(Mandatory=$true)][string]$Exe)
$ErrorActionPreference = 'Stop'
# Upstream's normal tray startup/exit may adopt/detach an installed MTT head.
# Run this smoke test only on a disposable CI machine without that driver.
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run on the disposable GitHub Windows runner' }
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class InputGuiTest {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public struct Rect { public int L,T,R,B; }
    public static IntPtr Find(uint pid, string className) {
        IntPtr result=IntPtr.Zero;
        EnumWindows((h,p)=>{ uint id; GetWindowThreadProcessId(h,out id); var s=new StringBuilder(256); GetClassName(h,s,256);
            if(id==pid && s.ToString()==className) result=h; return true; },IntPtr.Zero);
        return result;
    }
}
'@
$data = Join-Path $env:RUNNER_TEMP ('od-gui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $data | Out-Null
$previousAppData = $env:APPDATA
$env:APPDATA = $data
$settings = Join-Path $data 'opendisplay-win/config.json'
$process = $null
function Wait-Window([string]$Class) {
    for ($i=0; $i -lt 100; $i++) {
        $h=[InputGuiTest]::Find($script:process.Id,$Class)
        if($h -ne [IntPtr]::Zero) { return $h }
        if($script:process.HasExited) { throw "App exited: $($script:process.ExitCode)" }
        Start-Sleep -Milliseconds 100
    }
    throw "Missing window: $Class"
}
function Wait-Policy([bool]$Disabled) {
    for($i=0;$i -lt 100;$i++) {
        if(Test-Path -LiteralPath $settings) {
            try { $value=Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
                if($value.disableReceiverInput -eq $Disabled){return}
            } catch {}
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Saved disabled state did not become $Disabled"
}
function Open-Advanced([IntPtr]$Main) {
    [void][InputGuiTest]::PostMessage($Main,0x111,[IntPtr]40003,[IntPtr]::Zero)
    $dlg=Wait-Window '#32770'
    $tab=[InputGuiTest]::GetDlgItem($dlg,1035)
    [void][InputGuiTest]::SendMessage($tab,0x100,[IntPtr]0x27,[IntPtr]::Zero)
    [void][InputGuiTest]::SendMessage($tab,0x101,[IntPtr]0x27,[IntPtr]::Zero)
    $checkbox=[InputGuiTest]::GetDlgItem($dlg,1043)
    if(-not [InputGuiTest]::IsWindowVisible($checkbox)) {
        # Native tab controls also accept a direct click on their second item.
        [void][InputGuiTest]::SendMessage($tab,0x201,[IntPtr]1,[IntPtr](90 -bor (10 -shl 16)))
        [void][InputGuiTest]::SendMessage($tab,0x202,[IntPtr]::Zero,[IntPtr](90 -bor (10 -shl 16)))
    }
    for($i=0;$i -lt 30 -and -not [InputGuiTest]::IsWindowVisible($checkbox);$i++){Start-Sleep -Milliseconds 100}
    if(-not [InputGuiTest]::IsWindowVisible($checkbox)){throw 'Advanced input checkbox is hidden'}
    return $dlg
}
try {
    $process=Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru
    $main=Wait-Window 'opendisplay-win-tray'
    [void][InputGuiTest]::PostMessage($main,0x111,[IntPtr]40005,[IntPtr]::Zero)
    Wait-Policy $true
    'PASS: tray switch saves disabled input without a sender restart'
    $dlg=Open-Advanced $main
    $checkbox=[InputGuiTest]::GetDlgItem($dlg,1043)
    if([InputGuiTest]::SendMessage($checkbox,0xf0,[IntPtr]::Zero,[IntPtr]::Zero) -ne 1){throw 'Settings did not reflect tray state'}
    'PASS: Advanced settings reflect the tray switch'

    $dpi=[InputGuiTest]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    [void][InputGuiTest]::SetWindowPos($dlg,[IntPtr]::Zero,-30000,-30000,0,0,0x15)
    [void][InputGuiTest]::ShowWindow($dlg,4)
    $r=New-Object InputGuiTest+Rect
    [void][InputGuiTest]::GetWindowRect($dlg,[ref]$r)
    $bitmap=[System.Drawing.Bitmap]::new($r.R-$r.L,$r.B-$r.T)
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    $dc=$graphics.GetHdc()
    try{[void][InputGuiTest]::PrintWindow($dlg,$dc,2)}finally{$graphics.ReleaseHdc($dc)}
    $bitmap.Save((Join-Path (Get-Location) 'build/settings-input-preview.png'),[System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose();$bitmap.Dispose()
    # The option must fit between the original Wi-Fi fields and admin button.
    $cr=New-Object InputGuiTest+Rect
    $wr=New-Object InputGuiTest+Rect
    $ar=New-Object InputGuiTest+Rect
    [void][InputGuiTest]::GetWindowRect($checkbox,[ref]$cr)
    [void][InputGuiTest]::GetWindowRect([InputGuiTest]::GetDlgItem($dlg,1007),[ref]$wr)
    [void][InputGuiTest]::GetWindowRect([InputGuiTest]::GetDlgItem($dlg,1017),[ref]$ar)
    if($cr.T -lt $wr.B -or $cr.B -gt $ar.T){throw 'New checkbox overlaps an existing control'}
    [void][InputGuiTest]::SetThreadDpiAwarenessContext($dpi)
    'PASS: added option fits without moving existing settings controls'

    [void][InputGuiTest]::SendMessage($checkbox,0xf5,[IntPtr]::Zero,[IntPtr]::Zero)
    [void][InputGuiTest]::PostMessage($dlg,0x111,[IntPtr]2,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    Wait-Policy $true
    'PASS: Cancel leaves the saved input policy unchanged'
    $dlg=Open-Advanced $main
    $checkbox=[InputGuiTest]::GetDlgItem($dlg,1043)
    [void][InputGuiTest]::SendMessage($checkbox,0xf5,[IntPtr]::Zero,[IntPtr]::Zero)
    [void][InputGuiTest]::PostMessage($dlg,0x111,[IntPtr]1,[IntPtr]::Zero)
    Wait-Policy $false
    'PASS: settings OK saves the updated policy'
    [void][InputGuiTest]::PostMessage($main,0x111,[IntPtr]40005,[IntPtr]::Zero)
    Wait-Policy $true
    [void][InputGuiTest]::PostMessage($main,0x111,[IntPtr]40004,[IntPtr]::Zero)
    if(-not $process.WaitForExit(15000)){throw 'Quit did not exit'}
    $process=Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru
    $main=Wait-Window 'opendisplay-win-tray'
    $dlg=Open-Advanced $main
    $checkbox=[InputGuiTest]::GetDlgItem($dlg,1043)
    if([InputGuiTest]::SendMessage($checkbox,0xf0,[IntPtr]::Zero,[IntPtr]::Zero) -ne 1){throw 'Policy was lost on restart'}
    [void][InputGuiTest]::PostMessage($dlg,0x111,[IntPtr]2,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    [void][InputGuiTest]::PostMessage($main,0x111,[IntPtr]40004,[IntPtr]::Zero)
    if(-not $process.WaitForExit(15000)){throw 'Quit did not exit'}
    'PASS: disabled state survives process restart'
} finally {
    if($process -and -not $process.HasExited){Stop-Process -Id $process.Id -Force}
    $env:APPDATA=$previousAppData
}
