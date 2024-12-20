//
//  MIT License
//
//  Copyright (c) 2024 Derek Selander
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software. Attribution is requested but not
//  required if Software is public facing
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
// dynadump:
// Quick'n'Dirty imp of an ObjC class-dump primarily for inspecting dyld shared
// cache libraries on the host machine done via dlopen and public ObjC APIs. So hopefully,
// this code will better withstand breaking changes to objc/dyld internal changes.
// On ARM64, this will use hardware breakpoints to prevent the constructors from firing
// which will sometimes crash the process. On x86_64, this is disabled.
//
// to compile for jb'd iOS:
// xcrun -sdk iphoneos clang -fmodules -arch arm64 -Wl,-U,_dyld_shared_cache_for_each_image,-U,_dyld_image_path_containing_address -o /tmp/dynadump  /Users/meow/code/dyno_dump/dynadump/main.m
// echo "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz48IURPQ1RZUEUgcGxpc3QgUFVCTElDICItLy9BcHBsZS8vRFREIFBMSVNUIDEuMC8vRU4iICJodHRwczovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+PHBsaXN0IHZlcnNpb249IjEuMCI+PGRpY3Q+CjxrZXk+Y29tLmFwcGxlLnByaXZhdGUuY3MuZGVidWdnZXI8L2tleT48dHJ1ZS8+CjxrZXk+Y29tLmFwcGxlLnByaXZhdGUudGhyZWFkLXNldC1zdGF0ZTwva2V5Pjx0cnVlLz4KPGtleT5jb20uYXBwbGUucHJpdmF0ZS5zZXQtZXhjZXB0aW9uLXBvcnQ8L2tleT48dHJ1ZS8+CjwvZGljdD48L3BsaXN0PgoK" | base64 -D > /tmp/entitlements
// codesign -f -s - --entitlements /tmp/entitlement /tmp/dynadump
//
// to compile for macOS
// xcrun -sdk macos clang -arch arm64 -arch x86_64 -fmodules -o /usr/local/bin/dynadump /path/to/this/file/main.m -Wl,-U,_dyld_shared_cache_for_each_image,-U,_dyld_image_path_containing_address
// codesign -f -s - /usr/local/bin/dynadump
//
// to compile as a shared framework
// xcrun -sdk iphoneos clang -fmodules -o /tmp/dynadump.dylib /path/to/this/file/main.m -shared -DSHARED_DYNAMIC_DUMP

// full ios
// xcrun -sdk iphoneos clang -fmodules -arch arm64 -Wl,-U,_dyld_shared_cache_for_each_image,-U,_dyld_image_path_containing_address -o /tmp/dynadump  /Users/meow/code/dyno_dump/dynadump/main.m  && echo "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz48IURPQ1RZUEUgcGxpc3QgUFVCTElDICItLy9BcHBsZS8vRFREIFBMSVNUIDEuMC8vRU4iICJodHRwczovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+PHBsaXN0IHZlcnNpb249IjEuMCI+PGRpY3Q+CjxrZXk+Y29tLmFwcGxlLnByaXZhdGUuY3MuZGVidWdnZXI8L2tleT48dHJ1ZS8+CjxrZXk+Y29tLmFwcGxlLnByaXZhdGUudGhyZWFkLXNldC1zdGF0ZTwva2V5Pjx0cnVlLz4KPGtleT5jb20uYXBwbGUucHJpdmF0ZS5zZXQtZXhjZXB0aW9uLXBvcnQ8L2tleT48dHJ1ZS8+CjwvZGljdD48L3BsaXN0PgoK" | base64 -D > /tmp/entitlements && codesign -f -s - --entitlements /tmp/entitlements /tmp/dynadump &&  ssh root@localhost  -p 2323 -o "StrictHostKeyChecking=no" "rm -rf /var/jb/usr/local/bin/dynadump" &&   scp -O -P 2323 /tmp/dynadump root@localhost:/var/jb/usr/local/bin/

@import ObjectiveC;
@import Foundation;
@import Darwin;
@import OSLog;
@import MachO;
@import Security;

#include <mach-o/dyld_images.h>
#import "misc.h"
#import "codesigning.h"
#import "objc.h"
#import "dyld.h"
#import "exception_handler.h"

/*********************************************************************/
# pragma mark - internal testing
/*********************************************************************/

#if 0
@interface TestInterface : NSObject
@property (nonatomic, strong) NSURL *someURL;
@end

@implementation TestInterface (MyCategory)
- (void)categoryMethod {}
@end

@implementation TestInterface
- (void)booopbeepbop{}
@end
#endif


/*
 We need to find all the locations that constructors are called and map them so we can catch them if we need to use the safe dlopen
 */
__attribute__((constructor)) static void grab_caller_address(void) {
    void* return_address = strip_pac((void*)__builtin_return_address(0)) - ARM64_OPCODE_SIZE;
    exception_add_stepover_address(return_address);
    if (getenv("DEBUG")) {
        Dl_info info;
        dladdr((void*)return_address, &info);
        log_out("patching load address 0x%012lx %s\n",  (uintptr_t)return_address, info.dli_sname);
    }
}

@interface MERPLERPBURPDERP : NSObject
@end
@implementation MERPLERPBURPDERP
+ (void)load {
    void* return_address = strip_pac((void*)__builtin_return_address(0)) - ARM64_OPCODE_SIZE;
    exception_add_stepover_address(return_address);
    if (getenv("DEBUG")) {
        Dl_info info;
        dladdr((void*)return_address, &info);
        log_out("patching load address 0x%012lx %s\n",  (uintptr_t)return_address, info.dli_sname);
    }
}
@end

@implementation NSObject (BOWMEOWYAYHEY)
+ (void)load {
    void* return_address = strip_pac((void*)__builtin_return_address(0)) - ARM64_OPCODE_SIZE;
    exception_add_stepover_address(return_address);
    if (getenv("DEBUG")) {
        Dl_info info;
        dladdr(return_address, &info);
        log_out("patching load address 0x%012lx %s\n", (uintptr_t)return_address, info.dli_sname);
    }
}
@end

void dlopen_n_dump_objc_classes(const char *_arg, const char*clsName, bool do_classlist) {
    
    void* handle = NULL;
    uint32_t dsc_num = strtod(_arg, NULL);
    const char *path = NULL;
    const struct mach_header_64* header = NULL;
    
    char arg[PATH_MAX] = {};
    realpath(_arg, arg);
    // can we even open this thing? i.e. for cases like dynadump dump Foundation
    log_debug("can we open this? %s", arg);
    handle = dlopen(arg, RTLD_NOLOAD);
    log_debug(", did we open this? %p\n", handle);
    
    if (dsc_num) {
        path = dsc_image_as_num(dsc_num);
    } else if (handle) {
        path = strdup(arg);
    } else {
        path = dsc_image_as_name(_arg);
        log_debug("changing arg %s -> %s\n", arg, path);
        // if we can't find a path we'll just start with the OG and fail later if needed
        if (!path) {
            path = strdup(arg);
        }
    }
    
    // use stderr, so everything else is still grep-able
    fprintf(stderr, "%s%s%s\n", DCYAN, path, DCOLOR_END);
#if 0
#warning you've got normal dlopen going, derek
    handle = dlopen(path, RTLD_NOW);
#else
    if (USE_EXECPTION_HANDLER()) {
        handle = safe_dlopen(path);
    } else {
        handle = dlopen(path, RTLD_NOW);
    }
#endif
    
    // we tried to dlopen but failed, potentially due to a different platform or an exe
    // since dlopen doesn't work on executables (on certain platforms)
    // so we will make a copy of this image and tweak the platform, arch type (if needed)
    // and the load commands, and then resign this with an ad-hoc signature
    if (!handle) {
        log_debug("couldn't open initial file %s, error %s\n\n...  falling back patching image\n", path, dlerror());
        const char *newPath = generate_dlopen_path_backup_plan(path);
        if (!newPath){
            log_error("couldn't generate patched dlopen file. bailing\n");
            exit(1);
        }
        log_debug("trying to open patched file at %s\n", newPath);
        
        // regardless of the safe or non-safe, the catch logic has been set, just use dlopen
        handle = dlopen(newPath, RTLD_NOW);
        
        // rewrite the `path` var so logic past this conditional block will work
        if (newPath) {
            if (path) {
                free((void*)path);
                path = strdup(newPath);
            }
            free((void*)newPath);
        }
        
        // keep the modified dylib around while debugging
        if (!g_debug) {
            remove(newPath);
        }
        // f it, I give up
        if (!handle) {
            log_error("couldn't open \"%s\", err: %s\n", arg, dlerror());
            return;
        }
    }
    
    // remove breakpoints
    safe_dlopen_cleanup();
    
    
    // iterate loaded images in process looking for the dlopen's start address
    task_dyld_info_data_t info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    HANDLE_ERR(task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&info, &count));
    struct dyld_all_image_infos *all_image_infos = (void*)info.all_image_info_addr;
    struct dyld_image_info *imageArray = (void*)all_image_infos->infoArray;
    
    char resolved[PATH_MAX] = {};
    realpath(path, resolved);
    for (uint i = 0; i < all_image_infos->infoArrayCount; i++) {
        struct dyld_image_info *info = &imageArray[i];
        log_debug("searching loaded image: %s\n", info->imageFilePath);
        if (!strcmp(info->imageFilePath, resolved)) {
            header = (void*)info->imageLoadAddress;
            log_debug("FOUND IMAGE! at %p\n", header);
            break;
        }
    }
    
    // Try again with a different path in the case dlopen views the lib as a different nmae
    if (!header) {
        for (uint i = 0; i < all_image_infos->infoArrayCount; i++) {
            struct dyld_image_info *info = &imageArray[i];
            if (!strcmp(basename((char *)info->imageFilePath), basename((char *)path))) {
                header = (void*)info->imageLoadAddress;
                break;
            }
        }
    }
    
    if (clsName) {
        Class cls = objc_getClass(clsName);
        dump_objc_class_info(cls);
    } else {
        dump_all_objc_classes(do_classlist, path, header);
    }
    
    // TODO potential leak for some cases
    //    if (path) {
    //        free((void*)path);
    //    }
}

__attribute__((constructor)) static void setup(void) {
    g_color = getenv("NOCOLOR") ? false : true;
    g_debug = getenv("DEBUG") ? true : false;
    g_use_exc = getenv("USEEXC") ? true : false;
    g_verbose = getenv("VERBOSE") ? 5 : 0;
    
    // if piping remove color
    if (isatty(STDOUT_FILENO) == 0) {
        g_color = false;
    }
    
    // but turn it on if specified
    if (getenv("COLOR")) {
        g_color = true;
    }
}

#ifndef SHARED_DYNAMIC_DUMP

void print_help(void) {
    log_out("\n  dynadump (built: %s, %s) - yet another class-dump done via dlopen & exception catching\n\n", __DATE__, __TIME__);
    log_out("\tParameters:\n")
    log_out("\tlist                list all the dylibs in the dyld shared cache (dsc)\n");
    log_out("\tlist  $DYLIB        list all the objc classes in a dylib $DYLIB\n");
    log_out("\tdump  $DYLIB        dump all the ObjC classes found in a dylib on disk\n");
    log_out("\tdump  $DYLIB $CLASS dump a specific ObjC class found in dylib $DYLIB\n");
    log_out("\tsig   $SIGSTR       prints the demangled objc signature\n");
    log_out("\tsign  $DYLIB        attempts to sign a dylib in place\n");
    log_out("\tlist  $DYLIB $CLASS Same cmd as above (convenience for listing then dumping)\n");
    
    
    log_out("\n\tEnvironment Variables:\n");
    log_out("\tNOCOLOR, (-c) - Forces no color, color will be on by default unless piped\n");
    log_out("\tCOLOR         - Forces color, regardless of stdout destination\n");
    log_out("\tVERBOSE  (-v) - Verbose output\n");
    log_out("\tUSEEXC   (-D) - Use an exception handler (off by default in x86_64)\n");
    log_out("\tDEBUG    (-g) - Used internally to hunt down f ups\n");
    
    exit(1);
}

int main(int argc, char * const  argv[]) {
    int opt;
    if (argc == 1) {
        print_help();
    }
    
    while ((opt = getopt(argc, argv, "vcgVD")) != -1) {
        switch (opt) {
            case 'v':
                g_verbose = 5;
                break;
            case 'g':
                g_debug = true;
                break;
            case 'c':
                g_color = false;
                break;
            case 'D':
                g_use_exc = true;
                break;
            case 'V':
                print_help();
                exit(1);
            default: /* '?' */
                log_error("bad argument\n");
                return 1;
        }
    }
    if (getenv("COLOR")) {
        g_color = true;
    }
    if (g_debug) {
        setenv("DYLD_PRINT_INITIALIZERS", "1", 1);
        setenv("DYLD_PRINT_BINDINGS", "1", 1);
    }
    
    // list the dsc images
    if (!strcmp("list", argv[1])) {
        if (argc == 2) {
            dump_dsc_images();
        } else {
            if (argc == 3) {
                dlopen_n_dump_objc_classes(argv[2], NULL, true);
            } else if (argc == 4) {
                dlopen_n_dump_objc_classes(argv[2], argv[3], true);
            }
        }
        exit(0);
    } else if (!strcmp("dump", argv[1])) {
        if (argc < 3) {
            log_error("dump <NUM|PATH_2_DYLIB\n");
            exit(1);
        }
        dlopen_n_dump_objc_classes(argv[2], argc > 2 ? argv[3] : NULL,  false);
    } else if (!strcmp("sign", argv[1])) {
        if (argc < 3) {
            log_error("sign /path/to/file\n");
            exit(1);
        }
        char buff[PATH_MAX];
        realpath(argv[2], buff);
        int fd = open(buff, O_RDWR|S_IXUSR);
        if (fd == -1) {
            log_error("couldn't open file \"%s\"\n", buff);
            exit(1);
        }
        ad_hoc_codesign_file(buff);
    } else if (!strcmp("sig", argv[1])) {
        if (argc < 3) {
            log_error("sig objc_signature_str\n");
            exit(1);
        }
        
        // hack just for debugging purposes
        struct big_method_t {
            SEL name;
            const char *types;
            void* imp;
        } m = {
            .types = argv[2],
            .name = sel_registerName(""),
        };
        
        char buffer[PATH_MAX] = {};
        method_getReturnType((Method)&m, buffer, PATH_MAX);
        get_object_type_description(buffer, buffer);
        log_out("ret: %s", buffer);
        int count = method_getNumberOfArguments((Method)&m);
        log_out(" function( ");
        for (int i = 0; i < count; i ++) {
            const char *arg = method_copyArgumentType((Method)&m, i);
            get_object_type_description(arg, buffer);
            log_out("%s arg%d", buffer, i+1);
            if (i < count - 1 && count > 1) {
                log_out(", ");
            }
            free((void*)arg);
        }
        log_out(")\n");
    } else {
        print_help();
    }
    
    return 0;
}

#endif
