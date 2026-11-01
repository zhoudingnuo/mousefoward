# 只用来判断链路通不通: 发一段写死的轨迹(一个圆), 然后读一次状态行, 打印判断。
# 另一台机器上光标照着画出一个圆 = 整条通路是通的; 状态行把断在哪一段指出来。
#
#   powershell -File tools\capture.ps1              # 跑轨迹 + 打印判断
#   powershell -File tools\capture.ps1 -Live        # 改成转发真实鼠标(不判断)
#   powershell -File tools\capture.ps1 -DryRun      # 只打印包, 不开串口
#   powershell -File tools\capture.ps1 -Loops 10    # 跑 10 圈

param(
    [string]$Com = '',
    [int]$IntervalMs = 60,
    [int]$Loops = 3,
    [switch]$DryRun,
    [switch]$Live
)

# 半径 60 像素的圆, 24 步。每步是相对上一次的增量(一个 HID 报告最多带 ±127,
# 这里最大 16)。这 24 步是 15° 一个点的坐标差, 加起来正好回到起点。
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

# 状态行必须阻塞读: 驱动只有在有一个读请求挂着的时候才会去取设备的 IN 数据,
# ReadExisting() 只清驱动缓冲区, 永远读不到。
function ReadLine( $timeoutMs )
{
    $p.DiscardNull = $true
    $p.ReadTimeout = $timeoutMs
    try { return $p.ReadLine() } catch { return '' }
}

function Verdict( [string]$line, [int]$sent )
{
    if( $DryRun ) { return }

    if( -not $line )
    {
        Write-Output '读不到状态行。这一版板子只能读总线复位之后的第一行: 拔插一次再跑, 或者烧 firmware/firmware.hex(已经修了数据位)。'
        return
    }

    Write-Output ( '状态行: ' + $line.TrimEnd() )

    $m = [regex]::Match( $line, 'b=(\d+) cdc=(\d+) hs=(\d+) ok=(\d+) err=(\d+) drop=(\d+) ms=(\d+) kb=(\d+) p0=(\d+) p1=(\d+)' )
    if( -not $m.Success )
    {
        Write-Output '状态行读不全(计数器到 10 位会把 64 字节缓冲区写穿, 行被截)。'
        return
    }

    $cdc  = [int]$m.Groups[2].Value; $hs = [int]$m.Groups[3].Value
    $ok   = [int]$m.Groups[4].Value; $err = [int]$m.Groups[5].Value
    $drop = [int]$m.Groups[6].Value; $ms = [int]$m.Groups[7].Value
    $p0   = [int]$m.Groups[9].Value; $p1 = [int]$m.Groups[10].Value

    if( $cdc -eq 0 ) { Write-Output '  本端口没被枚举: COM 口存在但枚举没走完。' }
    else { Write-Output '  本端口已枚举, 字节进得来。' }

    if( $hs -eq 0 ) { Write-Output '  另一台机器没枚举键鼠口: 那边不会动。' }
    else { Write-Output '  另一台机器已枚举键鼠口。' }

    # 报告描述符被请求过 = 那个接口被驱动绑定了。没请求过 = 没绑定。
    if( $p1 -eq 0 ) { Write-Output ( '  鼠标接口没被绑定: 那边从没为接口 1 取报告描述符 (p1=0, 接口 0 取了 ' + $p0 + ' 次)。' ) }
    else { Write-Output ( '  鼠标接口被绑定了 (p1=' + $p1 + '): 那边取过它的报告描述符。' ) }

    if( $ok -lt $sent )
    {
        Write-Output ( '  发了 ' + $sent + ' 包, 只解析到 ' + $ok + ' 个 (err=' + $err + ' drop=' + $drop + '): 本端到板这一段断了。' )
    }
    elseif( $ms -lt $ok )
    {
        Write-Output ( '  解析对了 ' + $ok + ' 个, 只有 ' + $ms + ' 个写进端点: 端点一直忙(主机没在轮询 EP2), 或者主循环取包慢(drop=' + $drop + ')。' )
    }
    else
    {
        Write-Output ( '  ' + $ok + ' 个包全部解析并写进端点。ms 只表示写进端点, 不表示主机取走 —— 那一段只能看那边画不画圆。' )
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

    # 先发包再读状态行: 这一版只能读总线复位之后的第一行, 要让那一行里的
    # 计数器是发完包以后的值。
    for( $n = 0; $n -lt $Loops; $n++ )
    {
        foreach( $s in $Circle )
        {
            Send ( Packet @( 0xAA, 0x00, $s[0], $s[1], 0 ) )
            Start-Sleep -Milliseconds $IntervalMs
            $sent++
        }
    }

    if( -not $DryRun ) { Start-Sleep -Milliseconds 300 }

    Verdict ( ReadLine 3000 ) $sent
}
finally
{
    if( $p ) { $p.Close() }
}
