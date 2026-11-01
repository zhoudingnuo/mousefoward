/*
 * USBFS 口: 本端控制的 CDC 虚拟串口。
 *
 * 本端往这个虚拟串口写协议字节, 收到的字节逐字节交给 rx_byte()。
 * 只有 CDC, 没有 HID。
 *
 *   EP0  控制
 *   EP1  IN  通知 (描述符里有, 从不发)
 *   EP2  OUT 数据: 本端 → 板
 *   EP3  IN  数据: 板 → 本端 (状态行)
 */

#include "fw.h"

#define EP0_SZ 64
#define EP_SZ  64

/* ---- 描述符 ---- */

static const uint8_t dev_descr[ ] =
{
    0x12, 0x01,                 /* bLength, Device */
    0x10, 0x01,                 /* bcdUSB 1.10 */
    0x00, 0x00, 0x00,           /* 类由 IAD 说明 */
    EP0_SZ,                     /* EP0 最大包 */
    0x86, 0x1A,                 /* VID 0x1A86 */
    0x0D, 0x00,                 /* PID 0x000D */
    0x01, 0x00,                 /* bcdDevice */
    0x01, 0x02, 0x03, 0x01      /* 厂商 / 产品 / 序列号 / 配置数 */
};

/* 配置描述符, wTotalLength = 75 */
static const uint8_t cfg_descr[ ] =
{
    /* 配置头 9 */
    0x09, 0x02, 75, 0x00, 0x02, 0x01, 0x00, 0x80, 0x32,

    /* IAD 8 */
    0x08, 0x0B, 0x00, 0x02, 0x02, 0x02, 0x01, 0x00,

    /* IF0: CDC 控制接口 9 */
    0x09, 0x04, 0x00, 0x00, 0x01, 0x02, 0x02, 0x01, 0x00,
    /* 功能描述 5 */  0x05, 0x24, 0x00, 0x10, 0x01,
    /* ACM 管理 5 */  0x05, 0x24, 0x01, 0x00, 0x01,
    /* 呼叫特性 4 */  0x04, 0x24, 0x02, 0x02,
    /* 线编码 5 */    0x05, 0x24, 0x06, 0x00, 0x01,
    /* EP1 IN 通知 7 */ 0x07, 0x05, 0x81, 0x03, EP_SZ, 0x00, 0x01,

    /* IF1: CDC 数据接口 9 */
    0x09, 0x04, 0x01, 0x00, 0x02, 0x0A, 0x00, 0x00, 0x00,
    /* EP2 OUT 数据 7 */ 0x07, 0x05, 0x02, 0x02, EP_SZ, 0x00, 0x00,
    /* EP3 IN 数据 7 */  0x07, 0x05, 0x83, 0x02, EP_SZ, 0x00, 0x00,
};

/* ---- 状态 ---- */

static const uint8_t *p_descr;

static volatile uint8_t  setup_type, setup_req;
static volatile uint16_t setup_value, setup_index, setup_len;
static volatile uint8_t  dev_addr, dev_config;

volatile uint8_t cdc_enum;
volatile uint8_t fs_seen;

static uint8_t ep0_buf[ EP0_SZ ];
static uint8_t ep1_buf[ EP_SZ ];
static uint8_t ep2_buf[ EP_SZ ];
static uint8_t ep3_buf[ EP_SZ ];
static uint8_t ep_busy[ 8 ];

/* 默认 115200 8N1 */
static uint8_t line_coding[ 7 ] = { 0x00, 0xC2, 0x01, 0x00, 0x00, 0x00, 0x08 };

static const char *str_manu = "zcode";
static const char *str_prod = "CDC Control";
static const char *str_sn   = "0001";

/* 把字符串描述符拼进 EP0 缓冲区, 返回长度 */
static uint8_t build_string( uint8_t idx )
{
    const char *s;
    uint8_t i;

    if( idx == 0 )
    {
        ep0_buf[ 0 ] = 4; ep0_buf[ 1 ] = 0x03;
        ep0_buf[ 2 ] = 0x09; ep0_buf[ 3 ] = 0x04;      /* 语言 0x0409 */
        return 4;
    }

    s = ( idx == 1 ) ? str_manu : ( ( idx == 2 ) ? str_prod : str_sn );

    ep0_buf[ 0 ] = (uint8_t)( 2 + 2 * strlen( s ) );
    ep0_buf[ 1 ] = 0x03;
    for( i = 0; s[ i ]; i++ )
    {
        ep0_buf[ 2 + 2 * i ] = (uint8_t)s[ i ];
        ep0_buf[ 3 + 2 * i ] = 0;
    }

    return ep0_buf[ 0 ];
}

static void cdc_endp_init( void )
{
    USBFSD->UEP4_1_MOD = USBFS_UEP1_TX_EN;
    USBFSD->UEP2_3_MOD = USBFS_UEP2_RX_EN | USBFS_UEP3_TX_EN;

    USBFSD->UEP0_DMA = (uint32_t)ep0_buf;
    USBFSD->UEP1_DMA = (uint32_t)ep1_buf;
    USBFSD->UEP2_DMA = (uint32_t)ep2_buf;
    USBFSD->UEP3_DMA = (uint32_t)ep3_buf;

    USBFSD->UEP0_RX_CTRL = USBFS_UEP_R_RES_ACK;
    USBFSD->UEP2_RX_CTRL = USBFS_UEP_R_RES_ACK;

    USBFSD->UEP1_TX_LEN = 0;
    USBFSD->UEP3_TX_LEN = 0;

    USBFSD->UEP0_TX_CTRL = USBFS_UEP_T_RES_NAK;
    USBFSD->UEP1_TX_CTRL = USBFS_UEP_T_RES_NAK;
    USBFSD->UEP3_TX_CTRL = USBFS_UEP_T_RES_NAK;

    for( uint8_t i = 0; i < 8; i++ ) ep_busy[ i ] = 0;
}

void cdc_init( void )
{
    /* USBFS 的 48MHz 来自 USBPHY PLL, 参考时钟是 HSE/2 = 4MHz —— 晶振不起振
     * PLL 永远锁不上, 这个口不可能被发现。 */
    RCC_USBCLK48MConfig( RCC_USBCLK48MCLKSource_USBPHY );
    RCC_USBHSPLLCLKConfig( RCC_HSBHSPLLCLKSource_HSE );
    RCC_USBHSConfig( RCC_USBPLL_Div2 );
    RCC_USBHSPLLCKREFCLKConfig( RCC_USBHSPLLCKREFCLK_4M );
    RCC_USBHSPHYPLLALIVEcmd( ENABLE );
    RCC_AHBPeriphClockCmd( RCC_AHBPeriph_USBFS, ENABLE );

    USBFSH->BASE_CTRL = USBFS_UC_RESET_SIE | USBFS_UC_CLR_ALL;
    delay_us( 10 );
    USBFSH->BASE_CTRL = 0;

    USBFSD->INT_EN = USBFS_UIE_SUSPEND | USBFS_UIE_BUS_RST | USBFS_UIE_TRANSFER;
    USBFSD->BASE_CTRL = USBFS_UC_DEV_PU_EN | USBFS_UC_INT_BUSY | USBFS_UC_DMA_EN;
    cdc_endp_init( );
    USBFSD->UDEV_CTRL = USBFS_UD_PD_DIS | USBFS_UD_PORT_EN;

    NVIC_EnableIRQ( USBFS_IRQn );
}

/* 从 EP3 发一段字节给本端 */
uint8_t cdc_send( const uint8_t *data, uint16_t len )
{
    if( len == 0 || len > EP_SZ ) return 0;
    if( ep_busy[ 3 ] ) return 0;

    memcpy( ep3_buf, data, len );
    ep_busy[ 3 ] = 1;

    USBFSD->UEP3_TX_LEN = len;
    USBFSD->UEP3_TX_CTRL = ( USBFSD->UEP3_TX_CTRL & ~USBFS_UEP_T_RES_MASK ) | USBFS_UEP_T_RES_ACK;

    return 1;
}

void USBFS_IRQHandler( void ) __attribute__((interrupt("machine")));

void USBFS_IRQHandler( void )
{
    uint8_t  intflag = USBFSD->INT_FG;
    uint8_t  intst   = USBFSD->INT_ST;
    uint8_t  ep;
    uint16_t len;
    uint8_t  err;

    if( intflag & USBFS_UIF_TRANSFER )
    {
        switch( intst & USBFS_UIS_TOKEN_MASK )
        {
            /* 数据 IN */
            case USBFS_UIS_TOKEN_IN:
                ep = intst & USBFS_UIS_ENDP_MASK;

                if( ep == 0 )
                {
                    if( setup_len == 0 )
                        USBFSD->UEP0_RX_CTRL = USBFS_UEP_R_TOG | USBFS_UEP_R_RES_ACK;

                    /* bRequestType 的 bit7 是方向: GET_DESCRIPTOR 是 0x80, 不是 0x00。
                     * 直接 == USB_REQ_TYP_STANDARD 永远不成立, 描述符超过 64 字节时
                     * 第二包发不出去 —— 配置描述符 75 字节正好踩这条。 */
                    if( ( setup_type & USB_REQ_TYP_MASK ) == USB_REQ_TYP_STANDARD )
                    {
                        if( setup_req == USB_GET_DESCRIPTOR )
                        {
                            len = ( setup_len > EP0_SZ ) ? EP0_SZ : setup_len;
                            memcpy( ep0_buf, p_descr, len );
                            setup_len -= len;
                            p_descr += len;
                            USBFSD->UEP0_TX_LEN = len;
                            USBFSD->UEP0_TX_CTRL ^= USBFS_UEP_T_TOG;
                        }
                        else if( setup_req == USB_SET_ADDRESS )
                        {
                            USBFSD->DEV_ADDR = dev_addr;
                        }
                    }
                }
                else
                {
                    /* 发完必须重新置 NAK 并翻转数据位。不翻转的话下一包还是同一个
                     * 数据位, 主机把它当成重复包丢掉 —— 第一条状态行能读, 后面的读不到。 */
                    volatile uint8_t *ctrl = ( ep == 1 ) ? &USBFSD->UEP1_TX_CTRL : &USBFSD->UEP3_TX_CTRL;

                    *ctrl = ( *ctrl & ~USBFS_UEP_T_RES_MASK ) | USBFS_UEP_T_RES_NAK;
                    *ctrl ^= USBFS_UEP_T_TOG;
                    ep_busy[ ep ] = 0;
                }
                break;

            /* 数据 OUT */
            case USBFS_UIS_TOKEN_OUT:
                ep = intst & USBFS_UIS_ENDP_MASK;

                if( ep == 0 )
                {
                    if( USBFSD->RX_LEN > 0 )
                    {
                        if(( intst & USBFS_UIS_TOG_OK ) && ( setup_type & USB_REQ_TYP_MASK ) == USB_REQ_TYP_CLASS )
                        {
                            if( setup_req == CDC_SET_LINE_CODING )
                                memcpy( line_coding, ep0_buf, 7 );
                        }

                        /* 数据阶段到这里就结束了。setup_len 不清零的话, 下面那个分支
                         * 永远轮不到, 状态阶段发不出去 —— 串口驱动打开端口时发的
                         * SET_LINE_CODING 就卡在这里, COM 口存在但打不开。 */
                        setup_len = 0;
                    }

                    if( setup_len == 0 )
                    {
                        USBFSD->UEP0_TX_LEN  = 0;
                        USBFSD->UEP0_TX_CTRL = USBFS_UEP_T_TOG | USBFS_UEP_T_RES_ACK;
                    }
                }
                else if( ep == 2 )
                {
                    /* 本端 → 板 */
                    USBFSD->UEP2_RX_CTRL ^= USBFS_UEP_R_TOG;

                    uint16_t n = USBFSD->RX_LEN;
                    for( uint16_t i = 0; i < n; i++ )
                        rx_byte( ep2_buf[ i ] );
                }
                break;

            /* 请求 */
            case USBFS_UIS_TOKEN_SETUP:
                PUSB_SETUP_REQ req = (PUSB_SETUP_REQ)ep0_buf;

                fs_seen = 1;          /* 这个口至少被主机说过话了, 灯上报出去 */

                USBFSD->UEP0_TX_CTRL = USBFS_UEP_T_TOG | USBFS_UEP_T_RES_NAK;
                USBFSD->UEP0_RX_CTRL = USBFS_UEP_R_TOG | USBFS_UEP_R_RES_NAK;

                setup_type  = req->bRequestType;
                setup_req   = req->bRequest;
                setup_len   = req->wLength;
                setup_value = req->wValue;
                setup_index = req->wIndex;
                len   = 0;
                err   = 0;

                if( ( setup_type & USB_REQ_TYP_MASK ) != USB_REQ_TYP_STANDARD )
                {
                    /* CDC 类请求 */
                    switch( setup_req )
                    {
                        case CDC_SET_LINE_CODING: break;              /* 数据在 OUT 阶段 */
                        case CDC_GET_LINE_CODING: p_descr = line_coding; len = 7; break;
                        case CDC_SET_LINE_CTLSTE: break;
                        default: err = 0xFF; break;
                    }
                }
                else
                {
                    switch( setup_req )
                    {
                        case USB_GET_DESCRIPTOR:
                            switch((uint8_t)( setup_value >> 8 ) )
                            {
                                case USB_DESCR_TYP_DEVICE: p_descr = dev_descr; len = sizeof( dev_descr ); break;
                                case USB_DESCR_TYP_CONFIG: p_descr = cfg_descr; len = sizeof( cfg_descr ); break;
                                case USB_DESCR_TYP_STRING:
                                    len = build_string((uint8_t)( setup_value & 0xFF ) );
                                    p_descr = ep0_buf;
                                    break;
                                default: err = 0xFF; break;
                            }
                            break;

                        case USB_SET_ADDRESS:
                            dev_addr = (uint8_t)( setup_value & 0xFF );
                            break;

                        case USB_SET_CONFIGURATION:
                            dev_config = (uint8_t)( setup_value & 0xFF );
                            cdc_enum   = 1;
                            break;

                        case USB_GET_CONFIGURATION:
                            ep0_buf[ 0 ] = dev_config;
                            len = 1;
                            p_descr = ep0_buf;
                            break;

                        case USB_GET_INTERFACE:
                            ep0_buf[ 0 ] = 0;
                            len = 1;
                            p_descr = ep0_buf;
                            break;

                        case USB_SET_INTERFACE:
                            break;                          /* 只有一个 alt setting, 空状态阶段即可 */

                        case USB_GET_STATUS:
                            ep0_buf[ 0 ] = 0;
                            ep0_buf[ 1 ] = 0;
                            len = 2;
                            p_descr = ep0_buf;
                            break;

                        case USB_SET_FEATURE:
                            if((uint8_t)( setup_value & 0xFF ) == USB_REQ_FEAT_ENDP_HALT )
                            {
                                if((uint8_t)( setup_index & 0xFF ) == 0x83 )
                                    USBFSD->UEP3_TX_CTRL = USBFS_UEP_T_RES_STALL;
                                else if((uint8_t)( setup_index & 0xFF ) == 0x81 )
                                    USBFSD->UEP1_TX_CTRL = USBFS_UEP_T_RES_STALL;
                                else err = 0xFF;
                            }
                            break;

                        case USB_CLEAR_FEATURE:
                            if((uint8_t)( setup_value & 0xFF ) == USB_REQ_FEAT_ENDP_HALT )
                            {
                                if((uint8_t)( setup_index & 0xFF ) == 0x83 )
                                    USBFSD->UEP3_TX_CTRL = USBFS_UEP_T_RES_NAK;
                                else if((uint8_t)( setup_index & 0xFF ) == 0x81 )
                                    USBFSD->UEP1_TX_CTRL = USBFS_UEP_T_RES_NAK;
                                else if((uint8_t)( setup_index & 0xFF ) == 0x02 )
                                    USBFSD->UEP2_RX_CTRL = USBFS_UEP_R_RES_ACK;
                                else err = 0xFF;
                            }
                            break;

                        default:
                            err = 0xFF;
                            break;
                    }
                }

                if( err )
                {
                    USBFSD->UEP0_TX_CTRL = USBFS_UEP_T_TOG | USBFS_UEP_T_RES_STALL;
                    USBFSD->UEP0_RX_CTRL = USBFS_UEP_R_TOG | USBFS_UEP_R_RES_STALL;
                }
                else if( setup_type & USB_REQ_TYP_IN )
                {
                    /* 要回的数据先进 EP0 缓冲区; 超过 64 字节的描述符剩下的
                     * 在后续 IN 阶段继续发 (那时 setup_len 是剩余长度) */
                    if( setup_len > len ) setup_len = len;
                    len = ( setup_len > EP0_SZ ) ? EP0_SZ : setup_len;
                    memcpy( ep0_buf, p_descr, len );
                    p_descr += len;
                    setup_len -= len;

                    USBFSD->UEP0_TX_LEN  = len;
                    USBFSD->UEP0_TX_CTRL = USBFS_UEP_T_TOG | USBFS_UEP_T_RES_ACK;
                }
                else
                {
                    if( setup_len == 0 )
                    {
                        USBFSD->UEP0_TX_LEN  = 0;
                        USBFSD->UEP0_TX_CTRL = USBFS_UEP_T_TOG | USBFS_UEP_T_RES_ACK;
                    }
                    else
                    {
                        USBFSD->UEP0_RX_CTRL = USBFS_UEP_R_TOG | USBFS_UEP_R_RES_ACK;
                    }
                }
                break;

            default:
                break;
        }

        USBFSD->INT_FG = USBFS_UIF_TRANSFER;
    }
    else if( intflag & USBFS_UIF_BUS_RST )
    {
        dev_config = 0;
        dev_addr   = 0;
        cdc_enum   = 0;

        USBFSD->DEV_ADDR = 0;
        cdc_endp_init( );
        USBFSD->INT_FG = USBFS_UIF_BUS_RST;
    }
    else
    {
        USBFSD->INT_FG = intflag;
    }
}
