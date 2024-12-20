//
//  misc.c
//  dynadump
//
//  Created by Derek Selander on 5/28/24.
//

#include <stdlib.h>
#include <stdbool.h>
#include <sys/sysctl.h>
#include "misc.h"

bool g_debug = false;
bool g_color = true;
bool g_use_exc = false;
int g_verbose = 0;

// DYLD_MACOS_12_ALIGNED_SPI
const char* my_dyld_image_get_installname(dyld_image_t image) {
    extern __attribute__((weak)) const char* dyld_image_get_installname(dyld_image_t image);
    if (dyld_image_get_installname) {
        return dyld_image_get_installname(image);
    }
    return "???";
}

void* strip_pac(void* addr) {
#if defined(__arm64__)
    static uint32_t g_addressing_bits = 0;
    if (g_addressing_bits == 0) {
        size_t len = sizeof(uint32_t);
        if (sysctlbyname("machdep.virtual_address_size", &g_addressing_bits, &len,
                         NULL, 0) != 0) {
            g_addressing_bits = -1; // if err, f it, just assume anything goes
        }
    }
    uintptr_t mask = ((1UL << g_addressing_bits) - 1) ;
    return (void*)((uintptr_t)addr & mask);
#else
    return addr;
#endif
}
