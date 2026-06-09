#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "hardware/adc.h"
#include "hardware/spi.h"
#include "FreeRTOS.h"
#include "task.h"

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
#define PIN_SCK 18
#define PIN_MOSI 19
#define PIN_CS 17

#define MSG_NOTE_ON(step) ((uint8_t)(0x80 | ((step) & 0x0F)))  //   NOTE_ON:  0x80 | step
#define MSG_NOTE_OFF ((uint8_t)0x00)                           //   NOTE_OFF: 0x00  

static volatile uint32_t g_bpm = 120;

// Always sends 2 bytes: command + payload
static void spi_send(uint8_t cmd, uint8_t payload) {
    uint8_t buf[2] = {cmd, payload};
    gpio_put(PIN_CS, 0);
    spi_write_blocking(SPI_PORT, buf, 2);
    gpio_put(PIN_CS, 1);
}

// ADC Task: reads potentiometer and updates g_bpm
void adc_task(void *pvParameters) {
    adc_init();
    adc_gpio_init(ADC_GPIO);
    adc_select_input(0);

    while (1) {
        uint16_t raw = adc_read();   // 0 – 4095
        g_bpm = BPM_MIN + ((uint32_t)raw * (BPM_MAX - BPM_MIN)) / 4095;
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// Tick Task: advances the sequencer and sends NOTE_ON/OFF to FPGA via SPI
typedef enum {
    TICK_NOTE_ON,
    TICK_NOTE_OFF,
} TickState;

void tick_task(void *pvParameters) {
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

    xTaskCreate(adc_task,  "ADC",  512, NULL, 2, NULL);
    xTaskCreate(tick_task, "Tick", 512, NULL, 2, NULL);
    xTaskCreate(led_task,  "LED",  512, NULL, 1, NULL);

    vTaskStartScheduler();
    while (1);
}
