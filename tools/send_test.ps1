# 往板子的虚拟串口直接发协议字节, 看另一台机器的光标动不动。
# 这一步只验证板子本身, 不需要上位机程序。
#
#   powershell -File tools/send_test.ps1 -Com COM5
#   powershell -File tools/send_test.ps1                      # 列出可用串口

param(
    [string]$Com = '',
    [int]$Count = 30,
    [int]$DelayMs = 50
)

$ports = [System.IO.Ports.SerialPort]::GetPortNames()
if( -not $Com )
{
    if( -not $ports )
    {
        Write-Output '没有可用串口。板子是否已枚举 (灯 3Hz)?'
        exit 1
    }
    Write-Output '可用串口:'
    $ports | ForEach-Object { Write-Output "  $_  (用 -Com 指定)" }
    exit 1
}

function Packet( [int[]]$bytes )
{
    $xor = 0
    foreach( $b in $bytes ) { $xor = $xor -bxor $b }
    return [byte[]]( $bytes + $xor )
}

function ReadAnswer( $p )
{
    $p.DiscardNull = $true
    $p.ReadTimeout = 1000
    try { return $p.ReadExisting() } catch { return '(读不到, 板子没回)' }
}

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
