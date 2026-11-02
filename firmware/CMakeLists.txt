cmake_minimum_required(VERSION 3.29)

# ---------------------------------------------------------------------------
# GBA-PICO-LINK / Game-Boy-Zero-Link-Board 用 Multiboot ファームウェア
#   アプリ本体 : Embedded Swift (src/*.swift + ../Sources/LinkCore/*.swift)
#   C シム     : TinyUSB ディスクリプタ (CDC-ACM)、静的バッファ、ブート ROM 呼び出し (src/c/*)
# ---------------------------------------------------------------------------

# pico-sdk: 既定はサブモジュール。環境変数 PICO_SDK_PATH で上書き可。
if(DEFINED ENV{PICO_SDK_PATH} AND NOT PICO_SDK_PATH)
    set(PICO_SDK_PATH $ENV{PICO_SDK_PATH})
elseif(NOT PICO_SDK_PATH)
    set(PICO_SDK_PATH ${CMAKE_CURRENT_LIST_DIR}/lib/pico-sdk)
endif()
# GBA-PICO-LINK は素の RP2040 基板。クリスタル 12MHz / 2MB フラッシュ想定で pico ボード定義を使う。
set(PICO_BOARD pico CACHE STRING "pico-sdk board")
include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)

set(CMAKE_Swift_COMPILATION_MODE wholemodule)
set(CMAKE_Swift_COMPILER_WORKS YES)

project(gba_link_firmware C CXX ASM)
pico_sdk_init()
enable_language(Swift)

# ---- 設定値 (cmake -D で上書き可) -------------------------------------------
set(FW_VERSION_MAJOR 0 CACHE STRING "")
set(FW_VERSION_MINOR 1 CACHE STRING "")
set(FW_VERSION_PATCH 0 CACHE STRING "")
# Raspberry Pi が RP2040 の CDC デバイス向けに公開している共通 VID/PID (pico-sdk stdio_usb と同じ)。
# CDC-ACM 専用デバイスなので専用 PID は不要。Web 側 serial/transport.ts のフィルタと合わせる。
set(USB_VID 0x2E8A CACHE STRING "USB Vendor ID")
set(USB_PID 0x000A CACHE STRING "USB Product ID")
# リンクポート配線 (GBA-PICO-LINK / Game-Boy-Zero-Link-Board 互換)
set(LINK_PIN_SC 0 CACHE STRING "GPIO: SC (clock, RP2040 出力)")
set(LINK_PIN_SI 1 CACHE STRING "GPIO: SI (RP2040 入力 = GBA の SO)")
set(LINK_PIN_SO 2 CACHE STRING "GPIO: SO (RP2040 出力 = GBA の SI)")
set(LINK_PIN_SD 3 CACHE STRING "GPIO: SD (未使用、プルアップ入力)")

configure_file(${CMAKE_CURRENT_LIST_DIR}/src/c/board_config.h.in ${CMAKE_CURRENT_BINARY_DIR}/generated/board_config.h @ONLY)

# ---- Swift ターゲット -----------------------------------------------------------
set(SWIFT_TARGET "armv6m-none-none-eabi")
set(CLANG_ARCH_ABI_FLAGS "-Xcc -mfloat-abi=soft")
if(NOT PICO_PLATFORM STREQUAL "rp2040")
    message(FATAL_ERROR "このファームウェアは RP2040 (GBA-PICO-LINK) 専用です: PICO_PLATFORM=${PICO_PLATFORM}")
endif()

file(GLOB LINKCORE_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_LIST_DIR}/../Sources/LinkCore/*.swift)

add_executable(gba_link
    ${LINKCORE_SOURCES}
    src/Main.swift
    src/Firmware.swift
    src/LinkPort.swift
    src/UsbLink.swift
    src/c/usb_descriptors.c
    src/c/usb_glue.c
)
set_target_properties(gba_link PROPERTIES LINKER_LANGUAGE CXX)
pico_set_program_name(gba_link "gba-multiboot-link")
pico_set_program_version(gba_link "${FW_VERSION_MAJOR}.${FW_VERSION_MINOR}.${FW_VERSION_PATCH}")

pico_generate_pio_header(gba_link ${CMAKE_CURRENT_LIST_DIR}/src/linkport.pio)

target_include_directories(gba_link PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src/c
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}/generated
)

target_link_libraries(gba_link
    pico_stdlib
    hardware_pio
    hardware_gpio
    hardware_clocks
    hardware_timer
    pico_unique_id
    pico_bootrom
    tinyusb_device
    tinyusb_board
)

# 独自の USB スタックを使うので stdio は無効
pico_enable_stdio_usb(gba_link 0)
pico_enable_stdio_uart(gba_link 0)

# ---- Embedded Swift と pico-sdk の接続 (swift-embedded-examples/rpi-pico-blink-sdk 方式) ----
# pico_standard_link の C 専用フラグは swiftc が受け付けないので C 言語限定にする
set_target_properties(pico_standard_link PROPERTIES INTERFACE_COMPILE_OPTIONS "")
target_compile_options(pico_standard_link INTERFACE "$<$<COMPILE_LANGUAGE:C>:SHELL: -ffunction-sections -fdata-sections>")

# 依存ライブラリの INTERFACE_COMPILE_DEFINITIONS を再帰的に集めて -Xcc -D に変換する
set_property(GLOBAL PROPERTY visited_targets "")
set_property(GLOBAL PROPERTY compilerdefs_list "")

function(gather_compile_definitions_recursive target)
    get_property(visited_targets GLOBAL PROPERTY visited_targets)
    if (${target} MATCHES "\\$<" OR ${target} MATCHES "::@" OR ${target} IN_LIST visited_targets)
        return()
    endif()
    list(APPEND visited_targets ${target})
    set_property(GLOBAL PROPERTY visited_targets "${visited_targets}")

    if (NOT TARGET ${target})
        return()
    endif()
    get_target_property(target_definitions ${target} INTERFACE_COMPILE_DEFINITIONS)
    if (target_definitions)
        get_property(compilerdefs_list GLOBAL PROPERTY compilerdefs_list)
        list(APPEND compilerdefs_list ${target_definitions})
        set_property(GLOBAL PROPERTY compilerdefs_list "${compilerdefs_list}")
    endif()
    get_target_property(target_linked_libs ${target} INTERFACE_LINK_LIBRARIES)
    if (target_linked_libs)
        foreach(linked_target ${target_linked_libs})
            gather_compile_definitions_recursive(${linked_target})
        endforeach()
    endif()
endfunction()

gather_compile_definitions_recursive(gba_link)
get_property(COMPILE_DEFINITIONS GLOBAL PROPERTY compilerdefs_list)
list(REMOVE_DUPLICATES COMPILE_DEFINITIONS)
list(PREPEND COMPILE_DEFINITIONS "")
string(REPLACE "$<TARGET_PROPERTY:PICO_TARGET_BINARY_TYPE>" "$<TARGET_PROPERTY:gba_link,PICO_TARGET_BINARY_TYPE>" COMPILE_DEFINITIONS "${COMPILE_DEFINITIONS}")
string(REPLACE ";" " -Xcc -D" COMPILE_DEFINITIONS "${COMPILE_DEFINITIONS}")

# C/C++ の暗黙インクルードパス (newlib 等) を Clang インポータへ渡す
set(IMPLICIT_INCLUDES)
foreach(dir ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
    string(APPEND IMPLICIT_INCLUDES "-Xcc -I${dir} ")
endforeach()
foreach(dir ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
    string(APPEND IMPLICIT_INCLUDES "-Xcc -I${dir} ")
endforeach()

target_compile_options(gba_link PUBLIC
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:
        -target ${SWIFT_TARGET}
        -enable-experimental-feature Embedded
        -parse-as-library
        -module-name gba_link
        -Osize
        ${CLANG_ARCH_ABI_FLAGS}
        -Xcc -fshort-enums
        -Xfrontend -function-sections
        -import-bridging-header ${CMAKE_CURRENT_LIST_DIR}/src/BridgingHeader.h
        ${COMPILE_DEFINITIONS}
        ${IMPLICIT_INCLUDES}
    >")

pico_add_extra_outputs(gba_link)
