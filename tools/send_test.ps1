# 往板子的虚拟串口直接发协议字节, 看另一台机器的光标动不动。
# 这一步只验证板子本身, 不需要上位机程序。
#
#   powershell -File tools/send_test.ps1                # 自己找板子的 COM 口
#   powershell -File tools/send_test.ps1 -Com COM5      # 指定
#   powershell -File tools/send_test.ps1 -List          # 列出可用串口

param(
    [string]$Com = '',
    [int]$Count = 30,
    [int]$DelayMs = 50,
    [switch]$List
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

if( $List )
{
    Write-Output '可用串口:'
    $p = [System.IO.Ports.SerialPort]::GetPortNames()
    if( -not $p ) { Write-Output '  (无)' }
    $p | ForEach-Object { Write-Output "  $_" }
    exit 0
}

if( -not $Com )
{
    $Com = FindCdcPort
    if( -not $Com )
    {
        Write-Output '没找到板子的串口 (VID 1A86 的设备没有被 usbser.sys 绑定)。'
        Write-Output '用 -List 看现有串口, 或 -Com 指定。'
        exit 1
    }
    Write-Output ( '板子的串口: ' + $Com )
}

function Packet( [int[]]$bytes )
{
    $xor = 0
    foreach( $b in $bytes ) { $xor = $xor -bxor $b }
    return [byte[]]( $bytes + $xor )
}

function ReadAnswer( $p )
{
    # 必须阻塞读: 驱动只有在有一个读请求挂着的时候才会去取设备的数据,
    # ReadExisting() 只清驱动缓冲区, 永远读不到板子的 IN 数据。
    $p.DiscardNull = $true
    $p.ReadTimeout = 2000
    try { return $p.ReadLine() } catch { return '(读不到, 板子没回)' }
}

# 如果这一行卡住不返回: 固件的状态阶段没 arm, 驱动打开端口时发的
# SET_LINE_CODING 走不完 (见 analysis.md 第三节)。
$p = New-Object System.IO.Ports.SerialPort $Com, 115200, None, 8, One
$p.Open()

Write-Output '--- 状态 (发之前) ---'
$p.Write([byte[]]( 0x53 ))
Start-Sleep -Milliseconds 400
Write-Output ( ReadAnswer $p )

Write-Output "--- 发 $Count 个向右移动的鼠标包 ---"
for( $i = 0; $i -lt $Count; $i++ )
{
    $p.Write(( Packet @( 0xAA, 0x00, 5, 0, 0) ))
    Start-Sleep -Milliseconds $DelayMs
}

Write-Output '--- 发一个 A 键的键盘包 (按下, 再松开) ---'
$p.Write(( Packet @( 0xAB, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0) ))
Start-Sleep -Milliseconds 200
$p.Write(( Packet @( 0xAB, 0x00, 0x00, 0, 0, 0, 0, 0, 0) ))
Start-Sleep -Milliseconds 400

Write-Output '--- 状态 (发之后: ok 应该涨, ms/kb 应该涨) ---'
$p.Write([byte[]]( 0x53 ))
Start-Sleep -Milliseconds 400
Write-Output ( ReadAnswer $p )

$p.Close()
