//
//  exception_handler.c
//  dynadump
//
//  Created by Derek Selander on 5/29/24.
//

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include "exception_handler.h"
#include "misc.h"

static dispatch_group_t g_dispatch_group = nil;
static uintptr_t constructor_addresses[10] = {};
static uint8_t constructor_addresses_count = 0;
static mach_port_t exc_port = MACH_PORT_NULL;
static uintptr_t dyld_header = 0;


static void thread_walkback_frames_to_safe_code(thread_t thread) {
#if defined(__arm64__)
    arm_thread_state64_t state = {};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    HANDLE_ERR(thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count));
    Dl_info pinfo, linfo;
    
#if __has_feature(ptrauth_calls)
    void* pc = (void*)(state.__opaque_pc);
    void* lr = (void*)(state.__opaque_lr);
    uintptr_t stripped_pc = (uintptr_t)strip_pac((void*)state.__opaque_pc);
    uintptr_t stripped_lr = (uintptr_t)strip_pac((void*)state.__opaque_lr);
#else
    void* pc = (void*)(state.__pc);
    void* lr = (void*)(state.__lr);
    uintptr_t stripped_pc = (uintptr_t)(void*)(state.__pc);
    uintptr_t stripped_lr = (uintptr_t)(void*)(state.__lr);
    
#endif
    dladdr((void*)stripped_pc, &pinfo);
    dladdr((void*)stripped_lr, &linfo);
    log_debug("caught message\n   pc: 0x%012lx %s\n   lr: 0x%012lx %s\n", (uintptr_t)pc, pinfo.dli_sname, (uintptr_t)lr, linfo.dli_sname);
#ifdef __arm64__
    
#elif __x86_64__
TODO: implement geriatric CPU arch
#endif
    
    arm_debug_state64_t dbg = {};
    mach_msg_type_number_t dbg_cnt = ARM_DEBUG_STATE64_COUNT;
    HANDLE_ERR(thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&dbg, &dbg_cnt));
    
    // lldb puts a breakpoint on _dyld_debugger_notification, so catch & release
    Dl_info info = {};
    
    if (dladdr((void*)pc, &info) != 0) {
        if (!strcmp(info.dli_sname, "_dyld_debugger_notification")) {
            log_debug("it's _dyld_debugger_notification\n");
#if __has_feature(ptrauth_calls)
            state.__opaque_pc = state.__opaque_lr;
#else
            state.__pc = state.__lr;
#endif
            HANDLE_ERR(thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, count));
            return;
        }
    }
    
    
    for (uint8_t i = 0; i < constructor_addresses_count; i++) {
        
        if (constructor_addresses[i] == stripped_pc) {
            if (g_debug) {
                log_out("found caller 0x%012lx\n", constructor_addresses[i])
            }
            stripped_pc += ARM64_OPCODE_SIZE;
#if __has_feature(ptrauth_calls)
            stripped_pc = (uintptr_t)ptrauth_sign_unauthenticated((void*)stripped_pc, ptrauth_key_process_independent_code, 0);
            state.__opaque_pc = (void*)stripped_pc;
#else
            state.__pc = stripped_pc;
#endif
            HANDLE_ERR(thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, count))
            return;
        }
    }
    
    // This is for all other code that I've missed
#if __has_feature(ptrauth_calls)
    void* sp = strip_pac((void*)state.__opaque_sp);
    struct fp_ptr *frame = strip_pac((void*)state.__opaque_fp);
#else
    uintptr_t sp = (uintptr_t)strip_pac((void*)state.__sp);
    struct fp_ptr *frame = strip_pac((void*)state.__fp);
#endif
    
    while (frame && frame->next != NULL) {
        
        off_t offset = ((uintptr_t)frame - (uintptr_t)sp) + sizeof(struct fp_ptr);
        sp += offset;
        
        // walk back the stack frames looking for libobjc / [lib]dyld
        const void* addr = strip_pac(frame->address);
        const char* path = dyld_image_path_containing_address(addr);
        
        if (!strcmp("/usr/lib/libobjc.A.dylib", path) ||
            !strcmp("/usr/lib/system/libdyld.dylib", path) ||
            !strcmp("/usr/lib/dyld", path)) {
            break;
        }
        frame = strip_pac(frame->next);
    }
    
#if __has_feature(ptrauth_calls)
    state.__opaque_lr = ptrauth_sign_unauthenticated(frame->address, ptrauth_key_return_address, 0);
    state.__opaque_pc = ptrauth_sign_unauthenticated(frame->address, ptrauth_key_return_address, 0);
    state.__opaque_fp = ptrauth_sign_unauthenticated(frame->next, ptrauth_key_frame_pointer, 0);
    state.__opaque_sp = ptrauth_sign_unauthenticated(sp, ptrauth_key_frame_pointer, 0);
#else
    state.__lr = (uintptr_t)strip_pac(frame->address);
    state.__pc = (uintptr_t)strip_pac(frame->address);
    state.__fp = (uintptr_t)strip_pac(frame->next);
    state.__sp = (uintptr_t)strip_pac((void*)sp);
    
#endif
    
    HANDLE_ERR(thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, count))
#endif
}

void* server_thread(void *arg) {
    pthread_setname_np("Exception Handler");
    thread_t thread = (thread_t)(uintptr_t)arg;
#if defined(__arm64__)
    arm_debug_state64_t dbg = {};
    mach_msg_type_number_t cnt = ARM_DEBUG_STATE64_COUNT;
    HANDLE_ERR(thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&dbg, &cnt));
    for (int i = 0; i < constructor_addresses_count; i++) {
        dbg.__bvr[i] = (__int64_t)constructor_addresses[i];
        dbg.__bcr[i] = S_USER|BCR_ENABLE|BCR_BAS;
    }
    HANDLE_ERR(thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&dbg, ARM_DEBUG_STATE64_COUNT));
#elif defined(__x86_64__)
    
#else
#error "da fuck you compiling?"
#endif
    
    
    mach_port_options_t options = {.flags = MPO_INSERT_SEND_RIGHT};
    HANDLE_ERR(mach_port_construct(mach_task_self(), &options, 0, &exc_port));
    HANDLE_ERR(thread_set_exception_ports(thread, EXC_MASK_ALL, exc_port, EXCEPTION_DEFAULT|MACH_EXCEPTION_CODES, THREAD_STATE_NONE));
    
    dispatch_group_leave(g_dispatch_group);
    
    kern_return_t kr = KERN_SUCCESS;
    
    
    while(1) {
        char buffer[GOOD_E_NUFF_BUFSIZE];
        mach_msg_header_t *msg = (void*)buffer;
        msg->msgh_remote_port = MACH_PORT_NULL;
        msg->msgh_id = 2405;
        msg->msgh_local_port = exc_port;
        msg->msgh_size = GOOD_E_NUFF_BUFSIZE;
        
        if ((kr = mach_msg_receive(msg))) {
            // other thread will mod -1 the port so ignore MACH_RCV_PORT_CHANGED
            if (kr != MACH_RCV_PORT_CHANGED) {
                fprintf(stderr, "recv err %s %x\n", mach_error_string(kr), kr);
                HANDLE_ERR(kr);
            }
            break;
        }
        exc_req* req = ((exc_req*)msg);
        
        log_debug("exception: %d, subcode: 0x%016llx, 0x%016llx\n", req->exception, req->code[0], req->code[1]);
        thread_t thread = req->thread.name;
        thread_walkback_frames_to_safe_code(thread);
        msg->msgh_local_port = MACH_PORT_NULL;
        msg->msgh_bits = MACH_RCV_MSG | MACH_SEND_TIMEOUT;
        msg->msgh_id = 2505;
        msg->msgh_size = sizeof(exc_resp);
        exc_resp *resp = (exc_resp*)msg;
        resp->NDR = NDR_record;
        resp->RetCode = KERN_SUCCESS;
        if ((kr = mach_msg_send(msg))) {
            HANDLE_ERR(kr);
            break;
        }
    }
    return NULL;
}


void safe_dlopen_cleanup(void) {
    if (!USE_EXECPTION_HANDLER()) {
        return;
    }
#if defined(__arm64__)
    arm_debug_state64_t dbg = {};
    mach_msg_type_number_t cnt = ARM_DEBUG_STATE64_COUNT;
    HANDLE_ERR(thread_get_state(mach_thread_self(), ARM_DEBUG_STATE64, (thread_state_t)&dbg, &cnt));
    for (int i = 0; i < constructor_addresses_count; i++) {
        dbg.__bcr[i] &= ~BCR_ENABLE;
    }
    HANDLE_ERR(thread_set_state(mach_thread_self(), ARM_DEBUG_STATE64, (thread_state_t)&dbg, cnt));
    
    // remove the handler so debuggers can catch f ups better
    HANDLE_ERR(thread_set_exception_ports(mach_thread_self(), EXC_MASK_ALL, MACH_PORT_NULL, EXCEPTION_DEFAULT|MACH_EXCEPTION_CODES, THREAD_STATE_NONE));
    
    // yanking the port will break the while loop on in the server_thread
    mach_port_mod_refs(mach_task_self(), exc_port, MACH_PORT_RIGHT_RECEIVE, -1);
#endif
}

void* safe_dlopen(const char *image) {
#if defined(__arm64__)
    // setup a handler in case a constructor tries to take us down
    g_dispatch_group = dispatch_group_create();
    thread_t thread = mach_thread_self();
    dispatch_group_enter(g_dispatch_group);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        server_thread((void*)(uintptr_t)thread);
    });
    
    if (dispatch_group_wait(g_dispatch_group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)))) {
        log_out("timeout for exception handler setup, resuming...\n");
    }
    
    
    void* handle = dlopen(image, RTLD_NOW);
    
    return handle;
#else
    return NULL;
#endif
}



void exception_add_stepover_address(void* address) {
    address = strip_pac(address);
    constructor_addresses[constructor_addresses_count++] = (uintptr_t)address;
    
}
