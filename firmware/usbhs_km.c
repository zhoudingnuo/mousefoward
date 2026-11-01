/*
 * USBHS 口: 输出到另一台机器的 HID 复合键鼠。
 *
 *   EP0  控制
 *   EP1  IN  键盘, 8 字节 boot 报告
 *   EP2  IN  鼠标, 4 字节 boot 报告
 *
 * 另一台机器把这块板当成一个普通的复合键鼠。主循环把解析好的报告从这两个
 * IN 端点推出去; 端点忙就等下一次。
 */

#include "fw.h"

#define EP0_SZ 64

/* ---- 描述符 ---- */

static const uint8_t dev_descr[ ] =
{
    0x12, 0x01,                 /* Device */
    0x00, 0x02,                 /* bcdUSB 2.00 */
    0x00, 0x00, 0x00,
    EP0_SZ,
    0x86, 0x1A,                 /* VID 0x1A86 */
    0x00, 0xFE,                 /* PID 0xFE00 */
    0x00, 0x01,
    0x01, 0x02, 0x03, 0x01
};

/* 配置描述符, wTotalLength = 59 */
static const uint8_t cfg_descr[ ] =
{
    /* 配置头 9 */
    0x09, 0x02, 59, 0x00, 0x02, 0x01, 0x00, 0xA0, 0x32,

    /* 不给 IAD。加了 IAD 以后 Windows 把两个接口当成一个设备组, 类驱动只绑组里
     * 第一个接口, 第二个接口连报告描述符都不会被请求(实测 p0=1 p1=0)。
     * 没有 IAD 时 Windows 按接口分别建节点、分别绑, 两个都会被请求。
     * 参考实现 Dual_USB_v2 也没有 IAD。 */
    /* IF0: 键盘 9 */
    0x09, 0x04, 0x00, 0x00, 0x01, 0x03, 0x01, 0x01, 0x00,
    /* HID 描述 9 */  0x09, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 62, 0x00,
    /* EP1 IN 7 */    0x07, 0x05, 0x81, 0x03, 0x08, 0x00, 0x0A,

    /* IF1: 鼠标 9 */
    0x09, 0x04, 0x01, 0x00, 0x01, 0x03, 0x01, 0x02, 0x00,
    /* HID 描述 9 */  0x09, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 52, 0x00,
    /* EP2 IN 7 */    0x07, 0x05, 0x82, 0x03, 0x08, 0x00, 0x01
};

/* 上面两个 HID 类描述符在 cfg_descr 里的位置, 按布局算:
 *   配置头 9 + IF0 9                 = 18
 *   上一行 + HID 9 + 端点 7 + IF1 9  = 43
 * 写成常量而不是数字, 是为了以后描述符里插东西不会错位。 */
#define HID_DESC_0  ( 9 + 9 )
#define HID_DESC_1  ( 9 + 9 + 9 + 7 + 9 )

/* 键盘报告描述符 (62 字节) */
static const uint8_t kb_report[ ] =
{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x03, 0x75, 0x01,
    0x05, 0x08, 0x19, 0x01, 0x29, 0x03, 0x91, 0x02,
    0x95, 0x05, 0x75, 0x01, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x26, 0xFF, 0x00,
    0x05, 0x07, 0x19, 0x00, 0x29, 0x91, 0x81, 0x00,
    0xC0
};

/* 鼠标报告描述符 (52 字节) */
static const uint8_t ms_report[ ] =
{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
    0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x05, 0x81, 0x02,
    0x75, 0x03, 0x95, 0x01, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
    0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0xC0, 0xC0
};

/* ---- 状态 ---- */

static const uint8_t *p_descr;

static volatile uint8_t  setup_type, setup_req;
static volatile uint16_t setup_value, setup_index, setup_len;
static volatile uint8_t  dev_addr, dev_config;

volatile uint8_t km_enum;
volatile uint8_t kb_led;                 /* 另一台机器发来的键盘灯状态 */
volatile uint32_t n_rpt0, n_rpt1;        /* 两个接口的报告描述符各被请求了几次 */

static uint8_t ep0_buf[ EP0_SZ ];
static uint8_t kb_buf[ 64 ];
static uint8_t ms_buf[ 64 ];
static uint8_t ep_busy[ 16 ];

static const char *str_manu = "zcode";
static const char *str_prod = "HID Keyboard+Mouse";
static const char *str_sn   = "0002";

static uint8_t build_string( uint8_t idx )
{
    const char *s;
    uint8_t i;

    if( idx == 0 )
    {
        ep0_buf[ 0 ] = 4; ep0_buf[ 1 ] = 0x03;
        ep0_buf[ 2 ] = 0x09; ep0_buf[ 3 ] = 0x04;
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

static void km_endp_init( void )
{
    USBHSD->ENDP_CONFIG = USBHS_UEP0_T_EN | USBHS_UEP0_R_EN | USBHS_UEP1_T_EN | USBHS_UEP2_T_EN;

    USBHSD->UEP0_MAX_LEN = EP0_SZ;
    USBHSD->UEP1_MAX_LEN = 8;
    USBHSD->UEP2_MAX_LEN = 8;                 /* 和描述符里声明的 wMaxPacketSize 一致 */

    USBHSD->UEP0_DMA    = (uint32_t)ep0_buf;
    USBHSD->UEP1_TX_DMA = (uint32_t)kb_buf;
    USBHSD->UEP2_TX_DMA = (uint32_t)ms_buf;

    USBHSD->UEP0_TX_CTRL = USBHS_UEP_T_RES_NAK;
    USBHSD->UEP0_RX_CTRL = USBHS_UEP_R_RES_ACK;
    USBHSD->UEP1_TX_CTRL = USBHS_UEP_T_RES_NAK;
    USBHSD->UEP2_TX_CTRL = USBHS_UEP_T_RES_NAK;

    for( uint8_t i = 0; i < 16; i++ ) ep_busy[ i ] = 0;
}

void km_init( void )
{
    RCC_USBCLK48MConfig( RCC_USBCLK48MCLKSource_USBPHY );
    RCC_USBHSPLLCLKConfig( RCC_HSBHSPLLCLKSource_HSE );
    RCC_USBHSConfig( RCC_USBPLL_Div2 );
    RCC_USBHSPLLCKREFCLKConfig( RCC_USBHSPLLCKREFCLK_4M );
    RCC_USBHSPHYPLLALIVEcmd( ENABLE );
    RCC_AHBPeriphClockCmd( RCC_AHBPeriph_USBHS, ENABLE );

    USBHSD->CONTROL = USBHS_UC_CLR_ALL | USBHS_UC_RESET_SIE;
    delay_us( 10 );
    USBHSD->CONTROL = 0;

    USBHSD->HOST_CTRL = USBHS_UH_PHY_SUSPENDM;
    USBHSD->CONTROL = USBHS_UC_DMA_EN | USBHS_UC_INT_BUSY | USBHS_UC_SPEED_HIGH;
    USBHSD->INT_EN = USBHS_UIE_SETUP_ACT | USBHS_UIE_TRANSFER | USBHS_UIE_DETECT;
    km_endp_init( );
    USBHSD->CONTROL |= USBHS_UC_DEV_PU_EN;

    NVIC_EnableIRQ( USBHS_IRQn );
}

/* 把一份 HID 报告推到 IN 端点。端点忙返回 0 */
uint8_t km_send( uint8_t ep, const uint8_t *data, uint16_t len )
{
    uint8_t *buf = ( ep == KM_EP_KB ) ? kb_buf : ms_buf;

    if( ep_busy[ ep ] ) return 0;

    memcpy( buf, data, len );
    ep_busy[ ep ] = 1;

    if( ep == KM_EP_KB )
    {
        USBHSD->UEP1_TX_LEN  = len;
        USBHSD->UEP1_TX_CTRL = ( USBHSD->UEP1_TX_CTRL & ~USBHS_UEP_T_RES_MASK ) | USBHS_UEP_T_RES_ACK;
    }
    else
    {
        USBHSD->UEP2_TX_LEN  = len;
        USBHSD->UEP2_TX_CTRL = ( USBHSD->UEP2_TX_CTRL & ~USBHS_UEP_T_RES_MASK ) | USBHS_UEP_T_RES_ACK;
    }

    return 1;
}

/* 请求阶段。HS 控制器上 SETUP 是独立标志(不在 transfer 里), 所以单独一个函数 */
static void hs_setup_stage( void )
{
    PUSB_SETUP_REQ req = (PUSB_SETUP_REQ)ep0_buf;
    uint16_t len;
    uint8_t err;

    USBHSD->UEP0_TX_CTRL = USBHS_UEP_T_TOG_DATA1 | USBHS_UEP_T_RES_NAK;
    USBHSD->UEP0_RX_CTRL = USBHS_UEP_R_TOG_DATA1 | USBHS_UEP_R_RES_NAK;

    setup_type  = req->bRequestType;
    setup_req   = req->bRequest;
    setup_len   = req->wLength;
    setup_value = req->wValue;
    setup_index = req->wIndex;
    len   = 0;
    err   = 0;

    if( ( setup_type & USB_REQ_TYP_MASK ) == USB_REQ_TYP_CLASS )
    {
        switch( setup_req )
        {
            case HID_SET_REPORT: break;                    /* 数据在 OUT 阶段 */
            case HID_SET_IDLE:   break;
            case HID_SET_PROTOCOL: break;
            case HID_GET_IDLE:   ep0_buf[ 0 ] = 0; len = 1; p_descr = ep0_buf; break;
            case HID_GET_PROTOCOL: ep0_buf[ 0 ] = 0; len = 1; p_descr = ep0_buf; break;
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
                    case USB_DESCR_TYP_REPORT:
                        /* wValue 低字节 = 接口号: 0 键盘, 1 鼠标。
                         * 计数是为了能看出 Windows 到底有没有为第二个接口取报告描述符:
                         * 绑定了就会取, 没绑定就不会取。 */
                        if( setup_index == 0 )      { n_rpt0++; p_descr = kb_report; len = sizeof( kb_report ); }
                        else if( setup_index == 1 ) { n_rpt1++; p_descr = ms_report; len = sizeof( ms_report ); }
                        else err = 0xFF;
                        break;
                    case USB_DESCR_TYP_HID:
                        /* 按接口号取配置描述符里的那 9 字节。不能写死数字:
                         * 插了 IAD 以后每个接口都往后挪 8 字节。 */
                        if( setup_index == 0 )      { p_descr = &cfg_descr[ HID_DESC_0 ]; len = 9; }
                        else if( setup_index == 1 ) { p_descr = &cfg_descr[ HID_DESC_1 ]; len = 9; }
                        else err = 0xFF;
                        break;
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
                km_enum    = 1;
                break;

            case USB_GET_CONFIGURATION:
            case USB_GET_INTERFACE:
                ep0_buf[ 0 ] = ( setup_req == USB_GET_CONFIGURATION ) ? dev_config : 0;
                len = 1;
                p_descr = ep0_buf;
                break;

            case USB_SET_INTERFACE:
                /* 没有备用设置, 接受就行。参考实现也是空处理; 之前这里落到
                 * default 被 stall, Windows 绑定接口时会发这条请求。 */
                break;

            case USB_GET_STATUS:
                ep0_buf[ 0 ] = 0;
                ep0_buf[ 1 ] = 0;
                len = 2;
                p_descr = ep0_buf;
                break;

            case USB_SET_FEATURE:
                if((uint8_t)( setup_value & 0xFF ) == USB_REQ_FEAT_ENDP_HALT )
                {
                    if((uint8_t)( setup_index & 0xFF ) == ( 0x80 | KM_EP_KB ) )
                        USBHSD->UEP1_TX_CTRL = USBHS_UEP_T_RES_STALL;
                    else if((uint8_t)( setup_index & 0xFF ) == ( 0x80 | KM_EP_MS ) )
                        USBHSD->UEP2_TX_CTRL = USBHS_UEP_T_RES_STALL;
                    else err = 0xFF;
                }
                break;

            case USB_CLEAR_FEATURE:
                if((uint8_t)( setup_value & 0xFF ) == USB_REQ_FEAT_ENDP_HALT )
                {
                    if((uint8_t)( setup_index & 0xFF ) == ( 0x80 | KM_EP_KB ) )
                        USBHSD->UEP1_TX_CTRL = USBHS_UEP_T_RES_NAK;
                    else if((uint8_t)( setup_index & 0xFF ) == ( 0x80 | KM_EP_MS ) )
                        USBHSD->UEP2_TX_CTRL = USBHS_UEP_T_RES_NAK;
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
        USBHSD->UEP0_TX_CTRL = USBHS_UEP_T_TOG_DATA1 | USBHS_UEP_T_RES_STALL;
        USBHSD->UEP0_RX_CTRL = USBHS_UEP_R_TOG_DATA1 | USBHS_UEP_R_RES_STALL;
    }
    else if( setup_type & USB_REQ_TYP_IN )
    {
        if( setup_len > len ) setup_len = len;
        len = ( setup_len > EP0_SZ ) ? EP0_SZ : setup_len;
        memcpy( ep0_buf, p_descr, len );
        p_descr += len;
        setup_len -= len;

        USBHSD->UEP0_TX_LEN  = len;
        USBHSD->UEP0_TX_CTRL = USBHS_UEP_T_TOG_DATA1 | USBHS_UEP_T_RES_ACK;
    }
    else
    {
        if( setup_len == 0 )
        {
            USBHSD->UEP0_TX_LEN  = 0;
            USBHSD->UEP0_TX_CTRL = USBHS_UEP_T_TOG_DATA1 | USBHS_UEP_T_RES_ACK;
        }
        else
        {
            USBHSD->UEP0_RX_CTRL = USBHS_UEP_R_TOG_DATA1 | USBHS_UEP_R_RES_ACK;
        }
    }
}

void USBHS_IRQHandler( void ) __attribute__((interrupt("machine")));

void USBHS_IRQHandler( void )
{
    uint8_t intflag = USBHSD->INT_FG;
    uint8_t intst   = USBHSD->INT_ST;

    if( intflag & USBHS_UIF_TRANSFER )
    {
        switch( intst & USBHS_UIS_TOKEN_MASK )
        {
            /* 数据 IN */
            case USBHS_UIS_TOKEN_IN:
                uint8_t ep = intst & USBHS_UIS_ENDP_MASK;

                if( ep == 0 )
                {
                    if( setup_len == 0 )
                        USBHSD->UEP0_RX_CTRL = USBHS_UEP_R_TOG_DATA1 | USBHS_UEP_R_RES_ACK;

                    /* 同上: 要用掩码比较。键鼠口的描述符都短于 64 字节, 所以这条
                     * 走不到, 之前才没暴露出来。 */
                    if( ( setup_type & USB_REQ_TYP_MASK ) == USB_REQ_TYP_STANDARD )
                    {
                        if( setup_req == USB_GET_DESCRIPTOR )
                        {
                            uint16_t len = ( setup_len > EP0_SZ ) ? EP0_SZ : setup_len;
                            memcpy( ep0_buf, p_descr, len );
                            setup_len -= len;
                            p_descr += len;
                            USBHSD->UEP0_TX_LEN = len;
                            USBHSD->UEP0_TX_CTRL ^= USBHS_UEP_T_TOG_DATA1;
                        }
                        else if( setup_req == USB_SET_ADDRESS )
                        {
                            USBHSD->DEV_AD = dev_addr;
                        }
                    }
                }
                else
                {
                    /* 报告发完了, 端点空出来 */
                    volatile uint8_t *ctrl = ( ep == KM_EP_KB ) ? &USBHSD->UEP1_TX_CTRL : &USBHSD->UEP2_TX_CTRL;

                    *ctrl = ( *ctrl & ~USBHS_UEP_T_RES_MASK ) | USBHS_UEP_T_RES_NAK;
                    *ctrl ^= USBHS_UEP_T_TOG_DATA1;
                    ep_busy[ ep ] = 0;
                }
                break;

            /* 数据 OUT */
            case USBHS_UIS_TOKEN_OUT:
                if(( intst & USBHS_UIS_ENDP_MASK ) == 0 )
                {
                    if(( intst & USBHS_UIS_TOG_OK ) && ( setup_type & USB_REQ_TYP_MASK ) == USB_REQ_TYP_CLASS )
                    {
                        if( setup_req == HID_SET_REPORT )
                            kb_led = ep0_buf[ 0 ];        /* 另一台机器的键盘灯 */
                    }

                    if( setup_len == 0 )
                    {
                        USBHSD->UEP0_TX_LEN  = 0;
                        USBHSD->UEP0_TX_CTRL = USBHS_UEP_T_TOG_DATA1 | USBHS_UEP_T_RES_ACK;
                    }
                }
                break;

            default:
                break;
        }

        USBHSD->INT_FG = USBHS_UIF_TRANSFER;
    }
    else if( intflag & USBHS_UIF_SETUP_ACT )
    {
        hs_setup_stage( );
        USBHSD->INT_FG = USBHS_UIF_SETUP_ACT;
    }
    else if( intflag & USBHS_UIF_BUS_RST )
    {
        dev_config = 0;
        dev_addr   = 0;
        km_enum    = 0;

        USBHSD->DEV_AD = 0;
        km_endp_init( );
        USBHSD->INT_FG = USBHS_UIF_BUS_RST;
    }
    else
    {
        USBHSD->INT_FG = intflag;
    }
}
