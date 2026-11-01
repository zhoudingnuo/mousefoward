# 读状态行, 看计数器动不动。用 CreateFile + 阻塞读:
# ReadExisting 只把驱动缓冲区里已有的字节倒出来, 不会让驱动去读设备 ——
# 设备发的东西要有一次真正的读请求挂在那里才会被取走。
#
#   powershell -File tools/status_test.ps1

param(
    [string]$Com = '',
    [int]$WaitMs = 2000
)

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
using System.Text;

public class Com {
    [StructLayout(LayoutKind.Sequential)]
    public struct COMMTIMEOUTS {
        public uint ReadIntervalTimeout; public uint ReadTotalTimeoutMultiplier;
        public uint ReadTotalTimeoutConstant; public uint WriteTotalTimeoutMultiplier;
        public uint WriteTotalTimeoutConstant;
    }

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tpl);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetCommTimeouts(IntPtr h, ref COMMTIMEOUTS t);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteFile(IntPtr h, byte[] buf, uint len, out uint written, IntPtr ov);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadFile(IntPtr h, byte[] buf, uint len, out uint read, IntPtr ov);

    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@

if( -not $Com )
{
    $Com = FindCdcPort
    if( -not $Com ) { Write-Output '没找到板子的串口 (VID 1A86)。'; exit 1 }
    Write-Output ( '板子的串口: ' + $Com )
}

$access = [uint32]3221225472      # GENERIC_READ | GENERIC_WRITE
$h = [Com]::CreateFile( ( '\\.\' + $Com ), $access, [uint32]0, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero )
if( $h.ToInt64() -eq -1 ) { Write-Output '打不开 ' + $Com; exit 1 }

$t = New-Object 'Com+COMMTIMEOUTS'
$t.ReadIntervalTimeout = 1000
$t.ReadTotalTimeoutConstant = [uint32]$WaitMs
[Com]::SetCommTimeouts( $h, [ref]$t ) | Out-Null

function Packet( [int[]]$bytes )
{
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

function Query( $h, $tag )
{
    $w = [uint32]0
    $b = [byte[]]( 0x53 )
    if( -not [Com]::WriteFile( $h, $b, [uint32]1, [ref]$w, [IntPtr]::Zero ) )
    {
        Write-Output ( $tag + ': 写失败' )
        return
    }

    $buf = New-Object byte[] 96
    $r = [uint32]0
    if( [Com]::ReadFile( $h, $buf, [uint32]96, [ref]$r, [IntPtr]::Zero ) )
    {
        if( $r -eq 0 ) { Write-Output ( $tag + ': 没有回 (读请求挂满 ' + $WaitMs + 'ms)' ) }
        else { Write-Output ( $tag + ': ' + ( [System.Text.Encoding]::ASCII.GetString( $buf[0..($r-1)] ) ).TrimEnd() ) }
    }
    else { Write-Output ( $tag + ': 读失败' ) }
}

$w = [uint32]0
Query $h '发之前'

# 向右移动 5 像素的鼠标包
[Com]::WriteFile( $h, ( Packet @( 0xAA, 0x00, 5, 0, 0 ) ), [uint32]6, [ref]$w, [IntPtr]::Zero ) | Out-Null
Query $h '发一个鼠标包之后'

# A 键按下
[Com]::WriteFile( $h, ( Packet @( 0xAB, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0 ) ), [uint32]10, [ref]$w, [IntPtr]::Zero ) | Out-Null
Query $h '发一个键盘包之后'

[Com]::CloseHandle( $h ) | Out-Null
