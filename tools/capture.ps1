# 把鼠标动作写成协议字节, 发到板子的 COM 口。
# 板子收到后从 USBHS 口当 HID 鼠标发到另一台机器。
#
# 默认跑下面写死的那段轨迹(一个圆)。另一台机器的光标照着画出一个圆,
# 就说明整条通路是通的; 画不出来就是某一段断了。要看真实鼠标动作加 -Live。
#
#   powershell -File tools\capture.ps1                # 跑内置轨迹
#   powershell -File tools\capture.ps1 -Live          # 转发真实鼠标
#   powershell -File tools\capture.ps1 -DryRun        # 只打印包, 不开串口
#   powershell -File tools\capture.ps1 -Loops 10      # 跑 10 圈

param(
    [string]$Com = '',
    [int]$IntervalMs = 60,
    [int]$Loops = 3,
    [switch]$DryRun,
    [switch]$Live
)

# 半径 60 像素的圆, 24 步。每步是相对上一次的增量(一个 HID 报告最多带 ±127,
# 这里最大 16)。y 正方向朝下, 和 HID 报告的符号一致。
# 这 24 步是 15° 一个点的坐标差, 加起来正好回到起点。
$Circle = @(
    @(  -2,  16), ( -6,  14), (-10,  12), (-12,  10), (-14,   6), (-16,   2),
    (-16,  -2), (-14,  -6), (-12, -10), (-10, -12), ( -6, -14), ( -2, -16),
    (  2, -16), (  6, -14), ( 10, -12), ( 12, -10), ( 14,  -6), ( 16,  -2),
    ( 16,   2), ( 14,   6), ( 12,  10), ( 10,  12), (  6,  14), (  2,  16)
)

# 板子的 CDC 口: VID 1A86, 被 usbser.sys 绑定后设备名里带 (COMx)
function FindCdcPort()
{
    $d = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_1A86' -and $_.Name -match 'COM\d+' }
    foreach( $e in $d )
    {
        $m = [regex]::Match( $e.Name, 'COM\d+' )
        if( $m.Success ) { return $m.Value }
    }
    return ''
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Host {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetKeyState(int vk);
}
"@

function Packet( [int[]]$bytes )
{
    # dx/dy 是带符号的: 取低 8 位再拼, 不能直接 [byte]
    $xor = 0
    $out = @()
    foreach( $b in $bytes )
    {
        $v = $b -band 0xFF
        $xor = $xor -bxor $v
        $out += $v
    }
    $out += $xor
    return [byte[]]$out
}

function Clamp127( [int]$v )
{
    if( $v -gt 127 ) { return 127 }
    if( $v -lt -127 ) { return -127 }
    return $v
}

$p = $null
if( -not $DryRun )
{
    if( -not $Com ) { $Com = FindCdcPort }
    if( -not $Com )
    {
        Write-Output '没找到板子的串口 (VID 1A86 的设备没有被 usbser.sys 绑定)。'
        exit 1
    }

    $p = New-Object System.IO.Ports.SerialPort $Com, 115200, None, 8, One
    try
    {
        $p.Open()
    }
    catch
    {
        # 卡在这里不返回 = 固件的状态阶段没 arm (analysis.md 第三节), 烧新 hex
        Write-Output ( '打不开 ' + $Com + ': ' + $_.Exception.Message )
        exit 1
    }
}

function Send( [byte[]]$pk )
{
    if( $DryRun )
    {
        Write-Output ( '包: ' + (( $pk | ForEach-Object { $_.ToString('X2') }) -join ' ') )
    }
    else
    {
        $p.Write( $pk )
    }
}

$sent = 0

try
{
    if( $Live )
    {
        $pt = New-Object 'Host+POINT'
        if( -not [Host]::GetCursorPos([ref]$pt) )
        {
            Write-Output '读不到光标位置。'
            exit 1
        }
        $px = $pt.X
        $py = $pt.Y
        $oldFlags = 0

        Write-Output ( '转发真实鼠标: ' + $Com + ' (Ctrl+C 退出)' )

        while( $true )
        {
            Start-Sleep -Milliseconds $IntervalMs

            if( -not [Host]::GetCursorPos([ref]$pt) ) { continue }

            $dx = Clamp127( $pt.X - $px )
            $dy = Clamp127( $pt.Y - $py )
            $px = $pt.X
            $py = $pt.Y

            $flags = 0
            if( [Host]::GetKeyState( 0x01 ) -band 0x8000 ) { $flags = $flags -bor 0x01 }
            if( [Host]::GetKeyState( 0x02 ) -band 0x8000 ) { $flags = $flags -bor 0x02 }
            if( [Host]::GetKeyState( 0x04 ) -band 0x8000 ) { $flags = $flags -bor 0x04 }

            if( $dx -eq 0 -and $dy -eq 0 -and $flags -eq $oldFlags ) { continue }
            $oldFlags = $flags

            Send ( Packet @( 0xAA, $flags, $dx, $dy, 0 ) )
            $sent++
        }
    }

    Write-Output ( '跑内置轨迹: ' + $Com + ', ' + $Loops + ' 圈, 每步 ' + $IntervalMs + 'ms' )

    for( $n = 0; $n -lt $Loops; $n++ )
    {
        foreach( $s in $Circle )
        {
            # flags 第 2 位是左键: 每圈开头按一下再松开, 那边好确认
            Send ( Packet @( 0xAA, 0x01, $s[0], $s[1], 0 ) )
            Start-Sleep -Milliseconds $IntervalMs
            $sent++
        }
        Send ( Packet @( 0xAA, 0x00, 0, 0, 0 ) )
        Start-Sleep -Milliseconds 400
        Write-Output ( '第 ' + ( $n + 1 ) + ' 圈完成 (累计 ' + $sent + ' 包)' )
    }
}
finally
{
    if( $p ) { $p.Close() }
}
