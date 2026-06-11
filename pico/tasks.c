#include "helpers.h"

task tasks[NUM_TASKS];

// Task 1  Input

enum JS_States { JS_Start, JS_Idle, JS_Moved };

int JS_Tick(int state) {
    static bool    btn_prev = true;
    static uint8_t last_joy = 0;

    adc_select_input(POT_CH);   uint16_t pot = adc_read();
    adc_select_input(JOY_X_CH); uint16_t x   = adc_read();
    adc_select_input(JOY_Y_CH); uint16_t y   = adc_read();
    bool btn = gpio_get(BTN_TOGGLE);

    uint8_t joy_now = 0;
    if      (x > JOY_HI) joy_now = 1;
    else if (x < JOY_LO) joy_now = 2;
    else if (y > JOY_HI) joy_now = 3;
    else if (y < JOY_LO) joy_now = 4;

    // transitions
    switch (state) {
        case JS_Start: state = JS_Idle;                        break;
        case JS_Idle:  if (joy_now != 0)  state = JS_Moved;   break;
        case JS_Moved: if (joy_now == 0)  state = JS_Idle;    break;
        default:       state = JS_Start;                       break;
    }

    // actions
    switch (state) {
        case JS_Idle:
            g_bpm = BPM_MIN + ((uint32_t)pot * (BPM_MAX - BPM_MIN)) / 4095;
            break;

        case JS_Moved:
            g_bpm = BPM_MIN + ((uint32_t)pot * (BPM_MAX - BPM_MIN)) / 4095;
            if (joy_now != last_joy) {
                if      (joy_now == 1) { cursor_col = (cursor_col + 1) % NUM_STEPS; }
                else if (joy_now == 2) { cursor_col = (cursor_col == 0) ? NUM_STEPS - 1 : cursor_col - 1; }
                else if (joy_now == 3) { cursor_row = (cursor_row == 0) ? GRID_ROWS - 1 : cursor_row - 1; }
                else if (joy_now == 4) { cursor_row = (cursor_row + 1) % GRID_ROWS; }
                spi_send(MSG_CURSOR(cursor_row), cursor_col);
            }
            break;
    }

    if (!btn && btn_prev) {
        grid[cursor_row][cursor_col] ^= 1;
        spi_send(MSG_GRID_UPDATE(cursor_col), get_row_mask(cursor_col));
    }
    btn_prev = btn;
    last_joy = joy_now;

    return state;
}

// Task 2 Sequencer
]enum Tick_States { TICK_Start, TICK_NOTE_ON, TICK_NOTE_OFF };

int Tick_Sequencer(int state) {
    static uint8_t  step      = 0;
    static uint32_t elapsed   = 0;
    static bool     fire      = true;

    uint32_t step_ms = (60000 / g_bpm) / 4;
    uint32_t on_ms   = step_ms * 2 / 3;
    uint32_t off_ms  = step_ms - on_ms;

    // transitions
    switch (state) {
        case TICK_Start:
            state = TICK_NOTE_ON;
            elapsed = 0;
            fire = true;
            break;

        case TICK_NOTE_ON:
            elapsed += TASK2_PERIOD;
            if (elapsed >= on_ms) { elapsed = 0; fire = true; state = TICK_NOTE_OFF; }
            break;

        case TICK_NOTE_OFF:
            elapsed += TASK2_PERIOD;
            if (elapsed >= off_ms) { elapsed = 0; fire = true; step = (step + 1) % NUM_STEPS; state = TICK_NOTE_ON; }
            break;

        default:
            state = TICK_Start;
            break;
    }

    // actions — only fire once on state entry
    if (fire) {
        fire = false;
        switch (state) {
            case TICK_NOTE_ON:
                spi_send(MSG_NOTE_ON(step), get_row_mask(step));
                printf("Step %2u ON  | BPM: %lu\n", step, g_bpm);
                break;
            case TICK_NOTE_OFF:
                spi_send(MSG_NOTE_OFF, 0x00);
                break;
        }
    }

    return state;
}

// Task 3 LED heartbeat
enum LED_States { LED_Start, LED_On, LED_Off };

int LED_Tick(int state) {
    static uint32_t elapsed = 0;
    static bool     fire    = true;

    uint32_t beat_ms = 60000 / g_bpm;

    // transitions
    switch (state) {
        case LED_Start:
            state = LED_On;
            elapsed = 0;
            fire = true;
            break;

        case LED_On:
            elapsed += TASK3_PERIOD;
            if (elapsed >= 50) { elapsed = 0; fire = true; state = LED_Off; }
            break;

        case LED_Off:
            elapsed += TASK3_PERIOD;
            if (elapsed >= beat_ms - 50) { elapsed = 0; fire = true; state = LED_On; }
            break;

        default:
            state = LED_Start;
            break;
    }

    // actions — only fire once on state entry
    if (fire) {
        fire = false;
        switch (state) {
            case LED_On:  cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 1); break;
            case LED_Off: cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 0); break;
        }
    }

    return state;
}

// calls all 3 tick functions pretty much a schelduler
void scheduler_task(void *pvParameters) {
    while (1) {
        for (unsigned int i = 0; i < NUM_TASKS; i++) {
            if (tasks[i].elapsedTime >= tasks[i].period) {
                tasks[i].state = tasks[i].TickFct(tasks[i].state);
                tasks[i].elapsedTime = 0;
            }
            tasks[i].elapsedTime += GCD_PERIOD;
        }
        vTaskDelay(pdMS_TO_TICKS(GCD_PERIOD));
    }
}
