# 只用来判断链路通不通: 发一段写死的轨迹(一个圆), 然后读一次状态行, 打印判断。
# 另一台机器上光标照着画出一个圆 = 整条通路是通的; 状态行把断在哪一段指出来。
#
#   powershell -File tools\capture.ps1              # 跑轨迹 + 打印判断
#   powershell -File tools\capture.ps1 -Live        # 改成转发真实鼠标(不判断)
#   powershell -File tools\capture.ps1 -Live -Debug # 转发 + 每包打印 + 每 20 包读一次状态行
#   powershell -File tools\capture.ps1 -DryRun      # 只打印包, 不开串口
#   powershell -File tools\capture.ps1 -Loops 10    # 跑 10 圈

param(
    [string]$Com = '',
    [int]$IntervalMs = 60,
    [int]$Loops = 3,
    [switch]$DryRun,
    [switch]$Live,
    [switch]$Debug,
    [int]$StatusEvery = 20,
    [int]$ReadTimeoutMs = 3000
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

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Port {
    [StructLayout(LayoutKind.Sequential)]
    public struct COMMTIMEOUTS {
        public uint ReadIntervalTimeout;
        public uint ReadTotalTimeoutMultiplier;
        public uint ReadTotalTimeoutConstant;
        public uint WriteTotalTimeoutMultiplier;
        public uint WriteTotalTimeoutConstant;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint mode, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetCommTimeouts(IntPtr h, ref COMMTIMEOUTS t);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteFile(IntPtr h, byte[] b, uint len, ref uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadFile(IntPtr h, byte[] b, uint len, ref uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
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

$h = [IntPtr]::Zero
if( -not $DryRun )
{
    if( -not $Com ) { $Com = FindCdcPort }
    if( -not $Com )
    {
        Write-Output '没找到板子的串口 (VID 1A86 的设备没有被 usbser.sys 绑定)。'
        exit 1
    }

    $h = [Port]::CreateFile( $Com, 3, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero )
    if( $h.ToInt64() -eq -1 )
    {
        # 卡在这里不返回 = 固件的状态阶段没 arm (analysis.md 第三节), 烧新 hex
        Write-Output ( '打不开 ' + $Com + ' (错误 ' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() + ')' )
        exit 1
    }

    $t = New-Object 'Port+COMMTIMEOUTS'
    # 必须用 ReadTotalTimeoutConstant。ReadIntervalTimeout 只在收到第一个字节以后起作用,
    # 一个字节都没有时 ReadFile 立刻返回 0, 驱动不会去取设备的 IN 数据 ——
    # SerialPort.ReadTimeout 映射的正是 ReadIntervalTimeout, 所以之前 ReadLine 永远超时。
    $t.ReadIntervalTimeout = 0
    $t.ReadTotalTimeoutMultiplier = 0
    $t.ReadTotalTimeoutConstant = [uint32]$ReadTimeoutMs
    $t.WriteTotalTimeoutMultiplier = 0
    $t.WriteTotalTimeoutConstant = 2000
    [Port]::SetCommTimeouts( $h, [ref]$t ) | Out-Null
}

function Send( [byte[]]$pk )
{
    if( $DryRun -or $Debug )
    {
        Write-Output ( '包: ' + (( $pk | ForEach-Object { $_.ToString('X2') }) -join ' ') )
    }

    if( -not $DryRun )
    {
        $w = [uint32]0
        [Port]::WriteFile( $h, $pk, [uint32]$pk.Length, [ref]$w, [IntPtr]::Zero ) | Out-Null
    }
}

# 状态行必须阻塞读: 驱动只有在有一个读请求挂着的时候才会去取设备的 IN 数据,
# ReadExisting() 只清驱动缓冲区, 永远读不到。
function ReadLine( $timeoutMs )
{
    $t = New-Object 'Port+COMMTIMEOUTS'
    $t.ReadIntervalTimeout = 0
    $t.ReadTotalTimeoutMultiplier = 0
    $t.ReadTotalTimeoutConstant = [uint32]$timeoutMs
    $t.WriteTotalTimeoutMultiplier = 0
    $t.WriteTotalTimeoutConstant = 2000
    [Port]::SetCommTimeouts( $h, [ref]$t ) | Out-Null

    $buf = New-Object byte[] 96
    $r = [uint32]0
    if( -not [Port]::ReadFile( $h, $buf, [uint32]96, [ref]$r, [IntPtr]::Zero ) ) { return '' }
    if( $r -eq 0 ) { return '' }
    return [System.Text.Encoding]::ASCII.GetString( $buf[0..($r-1)] )
}

$script:base = $null

function Query( [int]$sent )
{
    if( $DryRun ) { return }

    $w = [uint32]0
    [Port]::WriteFile( $h, [byte[]]( 0x53 ), [uint32]1, [ref]$w, [IntPtr]::Zero ) | Out-Null

    $line = ReadLine 1500
    if( -not $line )
    {
        Write-Output '读不到状态行。要先发一个 S 再阻塞读; 用 SerialPort.ReadTimeout 读不到(它映射的是 ReadIntervalTimeout, 没有数据时 ReadFile 立刻返回 0, 驱动不会去取 IN 数据)。'
        return
    }

    Write-Output ( '状态行: ' + $line.TrimEnd() )

    $now = Parse $line
    if( -not $now )
    {
        Write-Output '状态行读不全(计数器到 10 位会把 64 字节缓冲区写穿, 行被截)。'
        return
    }

    if( -not $script:base ) { $script:base = $now }
    Verdict $now $script:base $sent
}

function Parse( [string]$line )
{
    $m = [regex]::Match( $line, 'b=(\d+) cdc=(\d+) hs=(\d+) ok=(\d+) err=(\d+) drop=(\d+) ms=(\d+) kb=(\d+) p0=(\d+) p1=(\d+)' )
    if( -not $m.Success ) { return $null }

    return @{
        b    = [int]$m.Groups[1].Value; cdc = [int]$m.Groups[2].Value; hs = [int]$m.Groups[3].Value
        ok   = [int]$m.Groups[4].Value; err = [int]$m.Groups[5].Value; drop = [int]$m.Groups[6].Value
        ms   = [int]$m.Groups[7].Value; kb  = [int]$m.Groups[8].Value
        p0   = [int]$m.Groups[9].Value; p1  = [int]$m.Groups[10].Value
    }
}

# 计数器是累计的, 所以只能比两次状态行之间的差值, 不能拿本次发了多少包去比。
function Verdict( $now, $base, [int]$sent )
{
    $dok   = $now.ok   - $base.ok
    $derr  = $now.err  - $base.err
    $ddrop = $now.drop - $base.drop
    $dms   = $now.ms   - $base.ms
    $dkb   = $now.kb   - $base.kb

    if( $now.cdc -eq 0 ) { Write-Output '  本端口没被枚举: COM 口存在但枚举没走完。' }
    else { Write-Output '  本端口已枚举, 字节进得来。' }

    if( $now.hs -eq 0 ) { Write-Output '  另一台机器没枚举键鼠口: 那边不会动。' }
    else { Write-Output '  另一台机器已枚举键鼠口。' }

    # 报告描述符被请求过 = 那个接口被驱动绑定了。没请求过 = 没绑定。
    if( $now.p1 -eq 0 ) { Write-Output ( '  鼠标接口没被绑定: 那边从没为接口 1 取报告描述符 (p1=0, 接口 0 取了 ' + $now.p0 + ' 次)。' ) }
    else { Write-Output ( '  鼠标接口被绑定了 (p1=' + $now.p1 + '): 那边取过它的报告描述符。' ) }

    if( $dok -lt $sent )
    {
        Write-Output ( '  发了 ' + $sent + ' 包, 只解析到 ' + $dok + ' 个 (err=' + $derr + ' drop=' + $ddrop + '): 本端到板这一段断了。' )
    }
    elseif( $dms + $dkb -lt $dok )
    {
        Write-Output ( '  解析对了 ' + $dok + ' 个, 只有 ' + $dms + ' 个鼠标报告写进端点: 端点一直忙(主机没在轮询 EP2), 或者主循环取包慢(drop=' + $ddrop + ')。' )
    }
    else
    {
        Write-Output ( '  ' + $dok + ' 个包全部解析并写进端点。ms 只表示写进端点, 不表示主机取走 —— 那一段只能看那边画不画圆。' )
    }
}

$sent = 0

try
{
    # 基线: 计数器是累计的, 后面所有判断都比这一行的差值
    if( -not $DryRun ) { Query 0 }

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

            if( $Debug -and ( $sent % $StatusEvery -eq 0 ) ) { Query $sent }
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

    if( -not $DryRun )
    {
        Start-Sleep -Milliseconds 300
        Query $sent
    }
}
finally
{
    if( $h.ToInt64() -ne -1 ) { [Port]::CloseHandle( $h ) | Out-Null }
}
