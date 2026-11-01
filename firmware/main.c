/*
 * CH32V305 最小转发固件 —— 闪灯固件长出来的下一步
 *
 *   本端 PC ──USBFS(CDC 虚拟串口)──▶ 板 ──USBHS(HID 复合键鼠)──▶ 另一台机器
 *
 * 本端往虚拟串口写协议字节, 板逐字节解析, 校验通过后从 USBHS 的 HID 端点发出去。
 * 整个固件只有: 时钟 + 灯 + 两个 USB 口 + 一个解析/转发循环。没有 UART, 没有打印。
 *
 * 协议 (字节流, 首字节区分包类型):
 *   鼠标 [0xAA][flags][dx][dy][wheel][xor]
 *   键盘 [0xAB][mod][0][key x6][xor]
 *   'S'  状态查询, 板从 CDC IN 回一行
 *
 * 灯 (和闪灯固件一样的脚)。板子上只有一个灯, 所以它报本端口走到哪一步:
 *   1Hz = 主循环在跑, 本端口一个请求都没收到
 *   2Hz = 本端口收到过请求, 但枚举没走完
 *   3Hz = 本端口已枚举 (COM 应该出现)
 *   4Hz = 键鼠口已枚举 —— 只有本端口没动静时才显示这个
 *   常亮 = HardFault
 */

#include "fw.h"

volatile uint8_t rx_pkt[ 12 ];
volatile uint8_t rx_ready;

static volatile uint8_t  stat_req;

static volatile uint32_t n_ok, n_err, n_drop, n_sent_ms, n_sent_kb;
static uint8_t idx;

/*********************************************************************
 * @fn      delay_us
 * @brief   两个 USB 口复位 SIE 时要等 10us。不用 debug.c 的 Delay_Us,
 *          那个会连带把 printf 的 USART 依赖拖进最小构建。
 */
void delay_us( uint32_t n )
{
    static uint8_t tick;
    uint32_t guard = 200000;

    if( tick == 0 ) tick = (uint8_t)( SystemCoreClock / 8000000 );

    SysTick->SR &= ~1u;
    SysTick->CMP = n * tick;
    SysTick->CTLR |= ( 1u << 4 );
    SysTick->CTLR |= ( 1u << 5 ) | 1u;

    while( !( SysTick->SR & 1u ) )
    {
        /* SysTick 不计数时这里会永久卡住 (tick 为 0 就要等计数器绕一整圈)。
         * 加个上限: 宁可这段延时短一点, 也不能让程序停死在这里。 */
        if( --guard == 0 )
        {
            SysTick->CTLR &= ~1u;
            return;
        }
    }
    SysTick->CTLR &= ~1u;
}

/*********************************************************************
 * @fn      rx_byte
 * @brief   逐字节解析本端发来的字节 (由 USBFS 中断调用)
 */
void rx_reset( void )
{
    idx = 0;
    rx_ready = 0;
}

void rx_byte( uint8_t b )
{
    if( rx_ready )
    {
        /* 主循环还没取走上一个包 */
        n_drop++;
        return;
    }

    if( idx == 0 )
    {
        if( b == PKG_MS || b == PKG_KB )
            rx_pkt[ idx++ ] = b;
        else if( b == CMD_STAT )
            stat_req = 1;
        return;
    }

    rx_pkt[ idx++ ] = b;

    uint8_t total = ( rx_pkt[ 0 ] == PKG_MS ) ? 6 : 10;
    if( idx >= total )
    {
        uint8_t sum = 0;
        for( uint8_t i = 0; i < total - 1; i++ )
            sum ^= rx_pkt[ i ];

        if( sum == rx_pkt[ total - 1 ] )
        {
            rx_ready = 1;
            n_ok++;
            idx = 0;                      /* 包取走以后必须回到包头, 否则下一个字节被当成正文 */
        }
        else
        {
            n_err++;
            idx = 0;
        }
    }
}

/*********************************************************************
 * @fn      put_u
 * @brief   十进制数写进缓冲区 (不能用 printf)
 */
static char *put_u( char *p, uint32_t v )
{
    char d[ 10 ];
    int  n = 0;

    if( v == 0 ) d[ n++ ] = '0';
    while( v ) { d[ n++ ] = (char)( '0' + v % 10 ); v /= 10; }
    while( n ) *p++ = d[ --n ];

    return p;
}

/*********************************************************************
 * @fn      status_line
 * @brief   回一行状态给本端
 */
static void status_line( void )
{
    /* 计数器都是 10 位时这行最长约 69 字节, 64 的缓冲区会被写穿 */
    char buf[ 96 ];
    char *p = buf;

    *p++ = 'S'; *p++ = ' ';
    /* 版本标记: 状态行本身就能确认板子上跑的是哪一版。
     * 9 = 加了两个接口报告描述符的请求计数 (p0/p1), 用来判断 Windows 绑了哪个接口 */
    *p++ = 'b'; *p++ = '='; *p++ = '9';
    *p++ = ' ';
    *p++ = 'c'; *p++ = 'd'; *p++ = 'c'; *p++ = '='; *p++ = (char)( '0' + ( cdc_enum ? 1 : 0 ) );
    *p++ = ' '; *p++ = 'h'; *p++ = 's'; *p++ = '='; *p++ = (char)( '0' + ( km_enum ? 1 : 0 ) );
    *p++ = ' ';

    *p++ = 'o'; *p++ = 'k'; *p++ = '='; p = put_u( p, n_ok );
    *p++ = ' '; *p++ = 'e'; *p++ = 'r'; *p++ = 'r'; *p++ = '='; p = put_u( p, n_err );
    *p++ = ' '; *p++ = 'd'; *p++ = 'r'; *p++ = 'o'; *p++ = 'p'; *p++ = '='; p = put_u( p, n_drop );
    *p++ = ' '; *p++ = 'm'; *p++ = 's'; *p++ = '='; p = put_u( p, n_sent_ms );
    *p++ = ' '; *p++ = 'k'; *p++ = 'b'; *p++ = '='; p = put_u( p, n_sent_kb );
    /* req= 去掉了: 一行最多 64 字节, 而 cdc=1 本身就说明收到过请求 */
    *p++ = ' '; *p++ = 'p'; *p++ = '0'; *p++ = '='; p = put_u( p, n_rpt0 );
    *p++ = ' '; *p++ = 'p'; *p++ = '1'; *p++ = '='; p = put_u( p, n_rpt1 );
    *p++ = '\r'; *p++ = '\n';

    uint16_t n = (uint16_t)( p - buf );
    if( n > 64 ) n = 64;                       /* 一个 IN 包最多 64 字节 */
    cdc_send( (uint8_t *)buf, n );
}

int main( void )
{
    uint8_t report[ 8 ];

    SystemCoreClockUpdate();

    /* 灯: 和闪灯固件一样, 由 TIM2 中断驱动 */
    RCC_APB2PeriphClockCmd( RCC_APB2Periph_GPIOA, ENABLE );
    RCC_APB1PeriphClockCmd( RCC_APB1Periph_TIM2, ENABLE );
    led_init();

    /* 两个 USB 口 */
    cdc_init();
    km_init();

    while( 1 )
    {
        if( stat_req )
        {
            stat_req = 0;
            status_line();
        }

        if( rx_ready )
        {
            if( rx_pkt[ 0 ] == PKG_MS )
            {
                report[ 0 ] = rx_pkt[ 1 ] & 0x3F;                              /* 按钮 */
                report[ 1 ] = rx_pkt[ 2 ];                                     /* X */
                report[ 2 ] = rx_pkt[ 3 ];                                     /* Y */
                report[ 3 ] = ( rx_pkt[ 1 ] & 0x40 ) ? rx_pkt[ 4 ] : 0;       /* 滚轮 */

                if( km_send( KM_EP_MS, report, 4 ) ) n_sent_ms++;
                else n_drop++;
            }
            else
            {
                report[ 0 ] = rx_pkt[ 1 ];                                    /* 修饰键 */
                report[ 1 ] = 0;
                for( uint8_t i = 0; i < 6; i++ )
                    report[ 2 + i ] = rx_pkt[ 3 + i ];                        /* 按键码 */

                if( km_send( KM_EP_KB, report, 8 ) ) n_sent_kb++;
                else n_drop++;
            }

            /* 包处理完就放手, 端点忙不能把解析器卡住 —— 卡住以后连状态行都读不到,
             * 那一段就完全没法判断了。 */
            rx_ready = 0;
        }

        /* 本端口的状态优先, 它没动静时才让键鼠口的状态盖过来 */
        if( cdc_enum )      led_rate( 3 );
        else if( fs_seen )  led_rate( 2 );
        else if( km_enum )  led_rate( 4 );
        else                led_rate( 1 );
    }
}
