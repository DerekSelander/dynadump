//
//  misc.h
//  dynadump
//
//  Created by Derek Selander on 5/28/24.
//

#ifndef misc_h
#define misc_h

#include <stdio.h>
#include <mach/message.h>
#include <mach/mach.h>

extern bool g_debug;
extern bool g_color;
extern int g_verbose;
/// Use SHARED_DYNAMIC_DUMP to make a shared library
#ifndef SHARED_DYNAMIC_DUMP
#define DYNAMIC_DUMP_VISIBILITY static
#else
#define DYNAMIC_DUMP_VISIBILITY __attribute__((visibility("default")))
#endif

#define DYLD_LOADER_CLASS_MAGIC 'l4yd'

#define GOOD_E_NUFF_BUFSIZE 1000

#define do_copy_n_return(STR) { strcpy(buffer, (STR)); return 0; }
#define append_content(FORMAT, ...) { buff_offset += snprintf(buffer + buff_offset, GOOD_E_NUFF_BUFSIZE - buff_offset, FORMAT, ##__VA_ARGS__); }
#define ARM64_OPCODE_SIZE sizeof(uint32_t)

// error handling
#define HANDLE_ERR(E) {if ((E)) { log_error("Error: %d, %s \n", (E), mach_error_string((E)));}}

// stolen from objc4
# if __arm64__
// ARM64 simulators have a larger address space, so use the ARM64e
// scheme even when simulators build for ARM64-not-e.
#   if __has_feature(ptrauth_calls) || defined(TARGET_OS_SIMULATOR)
#     define ISA_MASK        0x007ffffffffffff8ULL
#   else
#     define ISA_MASK        0x0000000ffffffff8ULL
#   endif
# elif __x86_64__
#   define ISA_MASK        0x00007ffffffffff8ULL
# else
#   error unknown architecture for packed isa
# endif

/// -DUSE_CONSOLE for NSLog, else fprintf
#ifdef USE_CONSOLE
#define log_out(S, ...)   NSLog(@ S, ##__VA_ARGS__);
#define log_error(S, ...)  { NSLog(@  "ERR: %5d", __LINE__);} NSLog(@  S, ##__VA_ARGS__);
#define log_debug(S, ...) if (g_debug) {NSLog(@ "dbg %4d: " S, __LINE__, ##__VA_ARGS__); }
#else
#define log_out(S, ...)   fprintf(stdout, S, ##__VA_ARGS__);
#define log_out_verbose(S, ...)  if (g_verbose) { fprintf(stdout, S, ##__VA_ARGS__); }
#define log_error(S, ...)  { fprintf(stderr, "ERR: %s:%5d", __FILE__, __LINE__);} fprintf(stderr, S, ##__VA_ARGS__);
#define log_debug(S, ...) if (g_debug) { fprintf(stdout, "FILE:%s,%4d: " S, __FILE__, __LINE__, ##__VA_ARGS__); }
#endif

/// arm64 debug stuff
#define S_USER                  ((uint32_t)(2u << 1))
#define BCR_ENABLE              ((uint32_t)(1u))
#define SS_ENABLE               ((uint32_t)(1u))
#define BCR_BAS                 ((uint32_t)(15u << 5))

#define DCYAN  (g_color ? "\e[36m" : "")
#define DYELLOW   (g_color ? "\e[33m" : "")
#define DMAGENTA   (g_color ? "\e[95m" : "")
#define DRED   (g_color ? "\e[91m" : "")
#define DPURPLE   (g_color ? "\e[35m" : "")
#define DBLUE   (g_color ? "\e[34m" : "")
#define DGRAY   (g_color ? "\e[90m" : "")
#define DGREEN   (g_color ? "\e[92m" : "")
#define DDARK_GREEN    (g_color ? "\e[32m" : "")
#define DBOLD   (g_color ? "\e[1m" : "")
#define DCYAN_UNDERLINE   (g_color ? "\033[36;1;4m" : "")
#define DPURPLE_BOLD  (g_color ? "\e[35;1m" : "")
#define DCYAN_LIGHT   (g_color ? "\e[96m" : "")
#define DYELLOW_LIGHT (g_color ? "\e[93m" : "")
#define DSTRONG_RED   (g_color ? "\e[31;4m" : "")
#define DLIGHT_BLUE  (g_color ? "\e[94m" : "")
#define DCOLOR_END  (g_color ? "\e[0m" : "")
#define DMETHOD_COLOR DCYAN
#define DPUNC_COLOR DGRAY
#define DPARAM_COLOR DYELLOW


#if __has_feature(ptrauth_calls)
#define DO_SIGN(X) (void*)__builtin_ptrauth_sign_unauthenticated((X), ptrauth_key_asia, 0)
#define DO_PROC_SIGN(X) (void*)__builtin_ptrauth_sign_unauthenticated((X), ptrauth_key_asib, 0)
#define DO_STRIP(X) X = (__typeof__((X)))ptrauth_strip((void*)(X), 0);
#define DO_STRIP_OBJC(X)  X = (__bridge id)ptrauth_strip((__bridge void*)(X), 0);
#else
#define DO_SIGN(X) (X)
#define DO_PROC_SIGN(X) (X)
#define DO_STRIP(X)
#define DO_STRIP_OBJC(X)
#endif



/*********************************************************************/
# pragma mark - dyld declarations -
/*********************************************************************/

typedef struct dyld_shared_cache_s*         dyld_shared_cache_t;
typedef struct dyld_image_s*                dyld_image_t;

// Exists in Mac OS X 10.6 and later
extern __attribute__((weak)) const char* dyld_image_path_containing_address(const void* addr);

// DYLD_MACOS_12_ALIGNED_SPI
extern __attribute__((weak)) void dyld_shared_cache_for_each_image(dyld_shared_cache_t cache, void (^block)(dyld_image_t image));

 // Exists in Mac OS X 10.11 and later
extern __attribute__((weak)) const char* dyld_shared_cache_file_path(void);

// DYLD_MACOS_12_ALIGNED_SPI
extern __attribute__((weak)) bool dyld_shared_cache_for_file(const char* filePath, void (^block)(dyld_shared_cache_t cache));

// DYLD_MACOS_12_ALIGNED_SPI
const char* my_dyld_image_get_installname(dyld_image_t image);

// Exists in Mac OS X 10.11 and later
extern __attribute__((weak)) const struct mach_header* dyld_image_header_containing_address(const void* addr);



/*********************************************************************/
# pragma mark - struct declarations / globals -
/*********************************************************************/

/// For unwinding stack frames in an exception handler
struct fp_ptr {
    struct fp_ptr *next;
    void* address;
};

/// mig generated structs
#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t Head;
    /* start of the kernel processed data */
    mach_msg_body_t msgh_body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    /* end of the kernel processed data */
    NDR_record_t NDR;
    exception_type_t exception;
    mach_msg_type_number_t codeCnt;
    int64_t code[2];
} exc_req;

typedef struct {
    mach_msg_header_t Head;
    NDR_record_t NDR;
    kern_return_t RetCode;
} exc_resp;
#pragma pack(pop)

void* strip_pac(void* addr);

#endif /* misc_h */
