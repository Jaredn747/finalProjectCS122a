cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(PICO_BOARD pico2_w CACHE STRING "Board type")

if(WIN32)
    set(USERHOME $ENV{USERPROFILE})
else()
    set(USERHOME $ENV{HOME})
endif()
set(sdkVersion 2.2.0)
set(toolchainVersion 14_2_Rel1)
set(picotoolVersion 2.2.0-a4)
set(picoVscode ${USERHOME}/.pico-sdk/cmake/pico-vscode.cmake)
if (EXISTS "${picoVscode}")
    include("${picoVscode}")
endif()

# Pull in Raspberry Pi Pico SDK (must be before project)
include(pico_sdk_import.cmake)
project(pico C CXX ASM)

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

#FreeRTOS
set(FREERTOS_KERNEL_PATH "" CACHE PATH "Path to FreeRTOS-Kernel")
if (NOT FREERTOS_KERNEL_PATH OR NOT EXISTS "${FREERTOS_KERNEL_PATH}")
    message(FATAL_ERROR "FREERTOS_KERNEL_PATH is not set or does not exist. Pass -DFREERTOS_KERNEL_PATH=<path> to cmake.")
endif()
add_subdirectory("${FREERTOS_KERNEL_PATH}/portable/ThirdParty/GCC/RP2350_ARM_NTZ" FREERTOS_KERNEL)

# Add executable. Default name is the project name, version 0.1
add_executable(pico pico.c)

pico_set_program_name(pico "pico")
pico_set_program_version(pico "0.1")

pico_enable_stdio_uart(pico 0)
pico_enable_stdio_usb(pico 1)

# Add the standard library to the build
target_link_libraries(pico
    pico_stdlib
    pico_cyw43_arch_none
    hardware_adc
    hardware_spi
    FreeRTOS-Kernel
    FreeRTOS-Kernel-Heap4
)

# Add the standard include files to the build
target_include_directories(pico PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}
)

pico_add_extra_outputs(pico)
