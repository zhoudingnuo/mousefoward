/*
 * 灯 + 定时器。和闪灯固件一样: 灯由 TIM2 中断驱动, 主循环不参与。
 *
 * 板子上只有一个灯, 所以它报的是"本端口(USBFS)到底走到哪一步":
 *   1Hz = 主循环在跑, 本端口一个请求都没收到
 *   2Hz = 本端口收到过请求, 但枚举没走完
 *   3Hz = 本端口已枚举 (COM 应该出现)
 *   4Hz = 键鼠口已枚举 —— 只有本端口没动静时才让这个盖过来
 *   常亮 = HardFault
 *
 * 这里用 interrupt("machine"): xPack 的 GCC 不认识 WCH 的 "WCH-Interrupt-fast",
 * 会退化成普通函数, 结尾是 ret 而不是 mret —— 硬件直接跳进来的 ISR 用 ret 返回会跑飞。
 * 两个 USB 口的处理函数同样用 machine。
 */

#include "fw.h"

/* TIM2 每 100us 进一次 -> 10000 次 = 1s。1Hz 的半周期 = 5000 次。
 * 原来写成 500000, 半周期变成 50s —— 灯看起来就是常亮, 和崩了分不清。 */
volatile uint32_t blink_half = 5000;
volatile uint8_t  led_latched;

void NMI_Handler( void )       __attribute__((interrupt("machine")));
void HardFault_Handler( void ) __attribute__((interrupt("machine")));
void TIM2_IRQHandler( void )   __attribute__((interrupt("machine")));

void NMI_Handler( void )
{
    led_latched = 1;
    while( 1 ) { }
}

void HardFault_Handler( void )
{
    /* 崩了: 灯常亮。这里不能再靠 TIM2, 自己直接点亮 */
    led_latched = 1;
    GPIOA->BSHR = LED_PINS;
    while( 1 ) { }
}

void TIM2_IRQHandler( void )
{
    static uint32_t cnt;
    static uint8_t  tog;

    if( !( TIM2->INTFR & TIM_IT_Update ) )
        return;
    TIM2->INTFR = (uint16_t)~TIM_IT_Update;

    if( led_latched )
    {
        GPIOA->BSHR = LED_PINS;
        return;
    }

    if( ++cnt >= blink_half )
    {
        cnt = 0;
        tog ^= 1;
        if( tog )
            GPIOA->BSHR = LED_PINS;
        else
            GPIOA->BCR  = LED_PINS;
    }
}

/*********************************************************************
 * @fn      led_init
 * @brief   点亮灯脚 + 100us 的 TIM2, 和闪灯固件一样
 */
void led_init( void )
{
    GPIO_InitTypeDef gpio = {0};
    TIM_TimeBaseInitTypeDef tim = {0};

    gpio.GPIO_Pin   = LED_PINS;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init( GPIOA, &gpio );
    GPIOA->BCR = LED_PINS;

    tim.TIM_Period      = 100 - 1;
    tim.TIM_Prescaler   = SystemCoreClock / 1000000 - 1;
    tim.TIM_CounterMode = TIM_CounterMode_Up;
    TIM_TimeBaseInit( TIM2, &tim );
    TIM_ITConfig( TIM2, TIM_IT_Update, ENABLE );
    NVIC_EnableIRQ( TIM2_IRQn );
    TIM_Cmd( TIM2, ENABLE );
}

void led_rate( uint8_t hz )
{
    if( hz ) blink_half = 10000 / ( 2 * hz );     /* 10000 次中断 = 1s */
}

void led_fault( void )
{
    led_latched = 1;
}
