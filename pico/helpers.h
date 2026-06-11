#pragma once
#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "hardware/adc.h"
#include "hardware/spi.h"
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"

//  grid 
#define NUM_STEPS   16
#define GRID_ROWS    8

// SPI pins 
#define SPI_PORT    spi0
#define PIN_SCK     18
#define PIN_MOSI    19
#define PIN_CS      17

//  ADC stuff
#define POT_CH      0   // GPIO26 potentiometer → BPM
#define JOY_X_CH    1   // GPIO27  joystick X
#define JOY_Y_CH    2   // GPIO28  joystick Y
#define BTN_TOGGLE  16  // active low

//  joystick limits 
#define JOY_HI  3000
#define JOY_LO  1000

// bpm range
#define BPM_MIN  40
#define BPM_MAX  140

// too fpga
#define MSG_NOTE_ON(step)    ((uint8_t)(0x80 | ((step) & 0x0F)))
#define MSG_NOTE_OFF         ((uint8_t)0x00)
#define MSG_GRID_UPDATE(col) ((uint8_t)(0x60 | ((col)  & 0x0F)))
#define MSG_CURSOR(row)      ((uint8_t)(0x40 | ((row)  & 0x07)))

//  task scheduler
#define NUM_TASKS    3
#define GCD_PERIOD   10   //  scheduler ticks every 10ms
#define TASK1_PERIOD 50   // input
#define TASK2_PERIOD 10   // sequencer
#define TASK3_PERIOD 10   // LED

typedef struct {
    signed char   state;
    unsigned long period;
    unsigned long elapsedTime;
    int (*TickFct)(int);
} task;

extern task tasks[NUM_TASKS];

// what varibles are being shared in other words
extern uint8_t           grid[GRID_ROWS][NUM_STEPS];
extern volatile uint32_t g_bpm;
extern volatile uint8_t  cursor_row;
extern volatile uint8_t  cursor_col;

// helpers functions 
static inline uint8_t get_row_mask(uint8_t step) {
    uint8_t mask = 0;
    for (int r = 0; r < GRID_ROWS; r++)
        if (grid[r][step]) mask |= (1 << r);
    return mask;
}

static inline void spi_send(uint8_t cmd, uint8_t payload) {
    uint8_t buf[2] = {cmd, payload};
    gpio_put(PIN_CS, 0);
    spi_write_blocking(SPI_PORT, buf, 2);
    gpio_put(PIN_CS, 1);
}

//  tick function 
int  JS_Tick(int state);
int  Tick_Sequencer(int state);
int  LED_Tick(int state);
void scheduler_task(void *pvParameters);
