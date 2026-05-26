#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "hardware/adc.h"
#include "FreeRTOS.h"
#include "task.h"

#define NUM_STEPS 16
#define ADC_GPIO 26      
#define BPM_MIN 60
#define BPM_MAX 200

static volatile uint32_t g_bpm = 120;

// ADC Task
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

// Tick Task
typedef enum {
    TICK_NOTE_ON,
    TICK_NOTE_OFF,
} TickState;

void tick_task(void *pvParameters) {
    uint8_t step  = 0;
    TickState state = TICK_NOTE_ON;

    while (1) {
        uint32_t beat_ms = 60000 / g_bpm;   // ms per quarter note
        uint32_t step_ms = beat_ms / 4;     // ms per 16th-note step
        uint32_t on_ms = step_ms * 2 / 3;
        uint32_t off_ms  = step_ms - on_ms;

        switch (state) {
            case TICK_NOTE_ON:
                printf("Step %2u ON  | BPM: %lu\n", step, g_bpm);
                // TODO: send note-on + step index to FPGA via SPI
                state = TICK_NOTE_OFF;
                vTaskDelay(pdMS_TO_TICKS(on_ms));
                break;

            case TICK_NOTE_OFF:
                // TODO: send note-off to FPGA via SPI
                step  = (step + 1) % NUM_STEPS;
                state = TICK_NOTE_ON;
                vTaskDelay(pdMS_TO_TICKS(off_ms));
                break;
        }
    }
}

// LED Heartbeat to show that BPM is working
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

// main
int main() {
    stdio_init_all();

    xTaskCreate(adc_task, "ADC", 512, NULL, 2, NULL);
    xTaskCreate(tick_task, "Tick", 512, NULL, 2, NULL);
    xTaskCreate(led_task, "LED", 512, NULL, 1, NULL);

    vTaskStartScheduler();
    while (1);
}
