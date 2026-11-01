/*
 * fw.h — 共享定义
 *
 * 板子两头:
 *   USBFS = 本端控制的 CDC 虚拟串口   (本端 → 板)
 *   USBHS = 输出到另一台机器的 HID 复合键鼠 (板 → 另一台)
 */

#ifndef __FW_H
#define __FW_H

#include "debug.h"
#include "string.h"

/* 指示灯脚, 和闪灯固件一样 */
#define LED_PINS ( GPIO_Pin_2 | GPIO_Pin_3 )

/* 本端在 CDC 字节流上发的包 */
#define PKG_MS   0xAA      /* 鼠标: [0xAA][flags][dx][dy][wheel][xor] */
#define PKG_KB   0xAB      /* 键盘: [0xAB][mod][0][key x6][xor] */
#define CMD_STAT 'S'       /* 状态查询 */

/* 输出到另一台机器的 HID 端点 */
#define KM_EP_KB  1        /* IN 1 = 键盘, 8 字节 boot 报告 */
#define KM_EP_MS  2        /* IN 2 = 鼠标, 4 字节 boot 报告 */

/* 一个校验通过的完整包放在 rx_pkt, rx_ready 置 1, 由主循环取走 */
extern volatile uint8_t  rx_pkt[ 12 ];
extern volatile uint8_t  rx_ready;
void rx_byte( uint8_t b );          /* 由 USBFS 中断调用 */
void rx_reset( void );              /* 总线复位时把解析器放回去 */

void delay_us( uint32_t n );

/* 灯语 (板子上只有一个灯): 报本端口走到哪一步
 *   1Hz = 主循环在跑, 本端口一个请求都没收到
 *   2Hz = 本端口收到过请求, 但枚举没走完
 *   3Hz = 本端口已枚举
 *   4Hz = 键鼠口已枚举 (本端口没动静时才显示这个)
 *   常亮 = HardFault */
void led_init( void );
void led_rate( uint8_t hz );
void led_fault( void );
extern volatile uint32_t blink_half;
extern volatile uint8_t  led_latched;

/* USBFS: 本端的 CDC 虚拟串口 */
void    cdc_init( void );
uint8_t cdc_send( const uint8_t *data, uint16_t len );
extern volatile uint8_t cdc_enum;
extern volatile uint8_t fs_seen;      /* 本端口收到过第一个 SETUP 请求 */

/* USBHS: 输出到另一台机器的复合键鼠 */
void    km_init( void );
uint8_t km_send( uint8_t ep, const uint8_t *data, uint16_t len );
extern volatile uint8_t km_enum;
extern volatile uint8_t kb_led;     /* 另一台机器发来的键盘灯状态 */

#endif
