#include "helpers.h"

uint8_t           grid[GRID_ROWS][NUM_STEPS] = {0};
volatile uint32_t g_bpm      = 120;
volatile uint8_t  cursor_row = 0;
volatile uint8_t  cursor_col = 0;

int main(void) {
    stdio_init_all();

    // SPI
    spi_init(SPI_PORT, 1000 * 1000);
    gpio_set_function(PIN_SCK,  GPIO_FUNC_SPI);
    gpio_set_function(PIN_MOSI, GPIO_FUNC_SPI);
    gpio_init(PIN_CS);
    gpio_set_dir(PIN_CS, GPIO_OUT);
    gpio_put(PIN_CS, 1);

    // ADC + button
    adc_init();
    adc_gpio_init(26);
    adc_gpio_init(27);
    adc_gpio_init(28);
    gpio_init(BTN_TOGGLE);
    gpio_set_dir(BTN_TOGGLE, GPIO_IN);
    gpio_pull_up(BTN_TOGGLE);

    // LED
    cyw43_arch_init();

    // clear FPGA grid, cursor, and note state
    for (uint8_t col = 0; col < NUM_STEPS; col++)
        spi_send(MSG_GRID_UPDATE(col), 0x00);
    spi_send(MSG_CURSOR(0), 0);
    spi_send(MSG_NOTE_OFF, 0x00);

    // register tasks
    unsigned char i = 0;
    tasks[i].period = TASK1_PERIOD; tasks[i].state = 0; tasks[i].elapsedTime = TASK1_PERIOD; tasks[i].TickFct = &JS_Tick;       i++;
    tasks[i].period = TASK2_PERIOD; tasks[i].state = 0; tasks[i].elapsedTime = TASK2_PERIOD; tasks[i].TickFct = &Tick_Sequencer; i++;
    tasks[i].period = TASK3_PERIOD; tasks[i].state = 0; tasks[i].elapsedTime = TASK3_PERIOD; tasks[i].TickFct = &LED_Tick;

    xTaskCreate(scheduler_task, "Scheduler", 1024, NULL, 1, NULL);
    vTaskStartScheduler();

    while (1);
}
