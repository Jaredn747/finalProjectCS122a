#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "hardware/adc.h"
#include "hardware/spi.h"
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"

#define NUM_STEPS   16
#define GRID_ROWS   8
#define ADC_GPIO    26
#define BPM_MIN     60
#define BPM_MAX     200

// Sequencer grid: grid[row][col], 1 = note active
static uint8_t grid[GRID_ROWS][NUM_STEPS] = {0};

// Returns bitmask of active rows for a step column (bit 0 = row 0)
static uint8_t get_row_mask(uint8_t step) {
    uint8_t mask = 0;
    for (int row = 0; row < GRID_ROWS; row++) {
        if (grid[row][step])
            mask |= (1 << row);
    }
    return mask;
}

// SPI pins (SPI0)
#define SPI_PORT spi0
#define PIN_SCK  18
#define PIN_MOSI 19
#define PIN_CS   17

// Joystick and button pins
#define JOY_X_GPIO  27    // ADC1
#define JOY_Y_GPIO  28    // ADC2
#define BTN_TOGGLE  16

// Joystick movement thresholds (12-bit ADC, center ~2048)
#define JOY_HI  3000
#define JOY_LO  1000

// SPI message types:
//   0x80 | step  = NOTE_ON   — advance playhead, update grid column
//   0x60 | col   = GRID_UPDATE — update one grid column (no playhead change)
//   0x40 | row   = CURSOR    — move cursor to (row, payload=col)
//   0x00         = NOTE_OFF
#define MSG_NOTE_ON(step)      ((uint8_t)(0x80 | ((step) & 0x0F)))
#define MSG_NOTE_OFF           ((uint8_t)0x00)
#define MSG_GRID_UPDATE(col)   ((uint8_t)(0x60 | ((col)  & 0x0F)))
#define MSG_CURSOR(row)        ((uint8_t)(0x40 | ((row)  & 0x07)))

static volatile uint32_t g_bpm = 120;

static volatile uint8_t cursor_row = 0;
static volatile uint8_t cursor_col = 0;

static SemaphoreHandle_t spi_mutex;

// Always sends 2 bytes: command + payload
// Mutex-protected so tick_task and input_task don't collide on the SPI bus
static void spi_send(uint8_t cmd, uint8_t payload) {
    uint8_t buf[2] = {cmd, payload};
    xSemaphoreTake(spi_mutex, portMAX_DELAY);
    gpio_put(PIN_CS, 0);
    spi_write_blocking(SPI_PORT, buf, 2);
    gpio_put(PIN_CS, 1);
    xSemaphoreGive(spi_mutex);
}

// Joystick state machine states
typedef enum {
    JOY_IDLE,   // centered — ready for next move
    JOY_MOVED,  // tilted — waiting to return to center before moving again
} JoyState;

// Input Task: reads potentiometer (BPM), joystick (cursor), and button (note toggle)
void input_task(void *pvParameters) {
    adc_init();
    adc_gpio_init(ADC_GPIO);    // GPIO 26 = potentiometer
    adc_gpio_init(JOY_X_GPIO);  // GPIO 27 = joystick X
    adc_gpio_init(JOY_Y_GPIO);  // GPIO 28 = joystick Y

    gpio_init(BTN_TOGGLE);
    gpio_set_dir(BTN_TOGGLE, GPIO_IN);
    gpio_pull_up(BTN_TOGGLE);   // active low: idle = high

    JoyState joy_state = JOY_IDLE;
    bool btn_prev = true;       // previous button state (true = not pressed)

    while (1) {
        // Read potentiometer (ADC0)
        adc_select_input(0);
        uint16_t pot = adc_read();
        g_bpm = BPM_MIN + ((uint32_t)pot * (BPM_MAX - BPM_MIN)) / 4095;

        // Read joystick axes (ADC1=VRY, ADC2=VRX — swapped to match physical orientation)
        adc_select_input(1);
        uint16_t y = adc_read();
        adc_select_input(2);
        uint16_t x = adc_read();

        // Joystick state machine
        switch (joy_state) {

            case JOY_IDLE:
                if (x > JOY_HI) {
                    cursor_col = (cursor_col + 1) % NUM_STEPS;
                    spi_send(MSG_CURSOR(cursor_row), cursor_col);
                    joy_state = JOY_MOVED;
                } else if (x < JOY_LO) {
                    cursor_col = (cursor_col == 0) ? NUM_STEPS - 1 : cursor_col - 1;
                    spi_send(MSG_CURSOR(cursor_row), cursor_col);
                    joy_state = JOY_MOVED;
                } else if (y > JOY_HI) {
                    cursor_row = (cursor_row == 0) ? GRID_ROWS - 1 : cursor_row - 1;
                    spi_send(MSG_CURSOR(cursor_row), cursor_col);
                    joy_state = JOY_MOVED;
                } else if (y < JOY_LO) {
                    cursor_row = (cursor_row + 1) % GRID_ROWS;
                    spi_send(MSG_CURSOR(cursor_row), cursor_col);
                    joy_state = JOY_MOVED;
                }
                break;

            case JOY_MOVED:
                // Wait for joystick to return to center before next move
                if (x >= JOY_LO && x <= JOY_HI && y >= JOY_LO && y <= JOY_HI)
                    joy_state = JOY_IDLE;
                break;
        }

        // Button: toggle note at cursor, immediately update FPGA display
        bool btn_now = gpio_get(BTN_TOGGLE);
        if (!btn_now && btn_prev) {
            grid[cursor_row][cursor_col] ^= 1;
            spi_send(MSG_GRID_UPDATE(cursor_col), get_row_mask(cursor_col));
        }
        btn_prev = btn_now;

        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// Tick Task: advances the sequencer and sends NOTE_ON/OFF to FPGA via SPI
typedef enum {
    TICK_NOTE_ON,
    TICK_NOTE_OFF,
} TickState;

void tick_task(void *pvParameters) {
    // Clear all FPGA grid columns at startup so stale Pico state doesn't show
    for (uint8_t col = 0; col < NUM_STEPS; col++)
        spi_send(MSG_GRID_UPDATE(col), 0x00);

    uint8_t   step  = 0;
    TickState state = TICK_NOTE_ON;

    while (1) {
        uint32_t beat_ms = 60000 / g_bpm;  // ms per quarter note
        uint32_t step_ms = beat_ms / 4;    // ms per 16th-note step
        uint32_t on_ms = step_ms * 2 / 3;
        uint32_t off_ms = step_ms - on_ms;

        switch (state) {
            case TICK_NOTE_ON:
                spi_send(MSG_NOTE_ON(step), get_row_mask(step));
                printf("Step %2u ON  | BPM: %lu\n", step, g_bpm);
                state = TICK_NOTE_OFF;
                vTaskDelay(pdMS_TO_TICKS(on_ms));
                break;

            case TICK_NOTE_OFF:
                spi_send(MSG_NOTE_OFF, 0x00);
                step = (step + 1) % NUM_STEPS;
                state = TICK_NOTE_ON;
                vTaskDelay(pdMS_TO_TICKS(off_ms));
                break;
        }
    }
}

// LED Heartbeat: flashes at BPM so you can verify timing visually
void led_task(void *pvParameters) {
    cyw43_arch_init();

    while (1) {
        uint32_t beat_ms = 60000 / g_bpm;
        cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 1);
        vTaskDelay(pdMS_TO_TICKS(50));
        cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 0);
        vTaskDelay(pdMS_TO_TICKS(beat_ms - 50));
    }
}

int main() {
    stdio_init_all();

    // SPI0 at 1 MHz, mode 0 (CPOL=0, CPHA=0)
    spi_init(SPI_PORT, 1000 * 1000);
    gpio_set_function(PIN_SCK,  GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);

    // CS is manual (active low), start idle high
    gpio_init(PIN_CS);
    gpio_set_dir(PIN_CS, GPIO_OUT);
    gpio_put(PIN_CS, 1);

    spi_mutex = xSemaphoreCreateMutex();

    xTaskCreate(input_task, "Input", 512, NULL, 2, NULL);
    xTaskCreate(tick_task,  "Tick",  512, NULL, 2, NULL);
    xTaskCreate(led_task,   "LED",   512, NULL, 1, NULL);

    vTaskStartScheduler();
    while (1);
}
