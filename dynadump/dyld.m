//
//  dsc.c
//  dynadump
//
//  Created by Derek Selander on 5/29/24.
//

@import Foundation;
@import Darwin.POSIX;
@import MachO;
#include "dyld.h"
#include "misc.h"
#include "codesigning.h"

static bool can_use_dyld_apis = true;

static int copy_file(const char *sourceFile, const char *destFile) {
    FILE *src, *dst;
    int ch;
    
    log_debug("attempting to write %s -> %s\n", sourceFile, destFile);
    
    // Open source file for reading
    src = fopen(sourceFile, "r");
    if (src == NULL) {
        perror("Error opening source file");
        return 1;
    }
    
    // Open destination file for writing
    dst = fopen(destFile, "w");
    if (dst == NULL) {
        perror("Error opening destination file");
        fclose(src);
        return 1;
    }
    
    // Copy the contents from source to destination
    while ((ch = fgetc(src)) != EOF) {
        fputc(ch, dst);
    }
    
    // Close the files
    fclose(src);
    fclose(dst);
    
    return 0;
}


static int extract_architecture(const char *input_filename, const char *output_filename, cpu_type_t cpu_type, cpu_subtype_t cpu_subtype) {
    int fd = open(input_filename, O_RDONLY);
    if (fd == -1) {
        perror("open");
        return -1;
    }
    
    struct stat st;
    if (fstat(fd, &st) == -1) {
        perror("fstat");
        close(fd);
        return -1;
    }
    
    void *file = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (file == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }
    
    struct fat_header *fat = (struct fat_header *)file;
    if (fat->magic != FAT_MAGIC && fat->magic != FAT_CIGAM) {
        log_debug("not a fat file, using normal copy\n");
        munmap(file, st.st_size);
        close(fd);
        return copy_file(input_filename, output_filename);
    }
    
    uint32_t nfat_arch = ntohl(fat->nfat_arch);
    struct fat_arch *archs = (struct fat_arch *)(fat + 1);
    bool success = false;
    for (uint32_t i = 0; i < nfat_arch; i++) {
        cpu_type_t arch_cpu_type = ntohl(archs[i].cputype);
        cpu_subtype_t arch_cpu_subtype = ntohl(archs[i].cpusubtype);
        
        if (arch_cpu_type == cpu_type && arch_cpu_subtype == cpu_subtype) {
            uint32_t offset = ntohl(archs[i].offset);
            uint32_t size = ntohl(archs[i].size);
            
            int out_fd = open(output_filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (out_fd == -1) {
                perror("open output file");
                munmap(file, st.st_size);
                close(fd);
                return -1;
            }
            
            if (write(out_fd, (char *)file + offset, size) != size) {
                perror("write");
                close(out_fd);
                munmap(file, st.st_size);
                close(fd);
                return -1;
            }
            
            close(out_fd);
            success = true;
            break;
        }
    }
    
    munmap(file, st.st_size);
    close(fd);
    return success ? 0 : -1;
}


/// some code could be in a different platform, so we are gonna convert it to our currently running platform
static struct build_version_command* get_exe_platform(void) {
    struct mach_header_64 *header = (void*)&_mh_execute_header;
    int ncmds = header->ncmds;
    char *lc_ptr = (char*)&_mh_execute_header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *lc = (struct load_command *)lc_ptr;
        if (lc->cmd == LC_BUILD_VERSION) {
            return (void*)lc_ptr;
        }
        lc_ptr += lc->cmdsize;
    }
    return NULL;
}

uint32_t parseFat(struct fat_header* header) {
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    
    
    //current fat_arch
    struct fat_arch* currentArch = NULL;
    
    //local architecture
    const NXArchInfo *localArch = NULL;
    
    //best matching slice
    struct fat_arch *bestSlice = NULL;
    
    //get local architecture
    localArch = NXGetLocalArchInfo();
    
    //swap?
    if(FAT_CIGAM == header->magic)
    {
        //swap fat header
        swap_fat_header(header, localArch->byteorder);
        
        //swap (all) fat arch
        swap_fat_arch((struct fat_arch*)((unsigned char*)header
                                         + sizeof(struct fat_header)), header->nfat_arch, localArch->byteorder);
    }
    
    //first arch, starts right after fat_header
    currentArch = (struct fat_arch*)((unsigned char*)header + sizeof(struct fat_header));
    
    bestSlice = NXFindBestFatArch(localArch->cputype,
                                  localArch->cpusubtype, (void*)((uintptr_t)header + sizeof(struct fat_header)), header->nfat_arch);
    if (!bestSlice) {
        log_error("Couldn't find a suitable slice in a FAT binary\n");
    }
    
#if __has_feature(ptrauth_calls)
    struct mach_header_64 *my_header = &_mh_execute_header;
    bestSlice->cpusubtype = my_header->cpusubtype;
    bestSlice->cputype = my_header->cputype;
#endif
    
    uint32_t offset = bestSlice->offset;
    swap_fat_arch((struct fat_arch*)((unsigned char*)header
                                     + sizeof(struct fat_header)), header->nfat_arch, localArch->byteorder);
    swap_fat_header(header, localArch->byteorder);
    
#pragma clang diagnostic pop
    
    return offset;
}


static void write_load_command_rpath(struct mach_header_64 *header64, char **ptr, NSString *resolvedPath) {
    unsigned long alignedSize = sizeof(struct rpath_command) +  strlen(resolvedPath.UTF8String) + 1;
    alignedSize += (4 - alignedSize % 4 );
    struct rpath_command rpath = {
        .cmd = LC_RPATH,
        .cmdsize = (uint32_t)alignedSize,
        .path.offset = sizeof(struct rpath_command),
    };
    memcpy(*ptr, &rpath, sizeof(struct rpath_command));
    strcpy(*ptr + sizeof(struct rpath_command), [resolvedPath UTF8String]);
    *ptr += alignedSize;
    header64->sizeofcmds += alignedSize;
    header64->ncmds++;
}

// On iOS (but not macOS!) dlopen will fail on an executable, so copy the file, if present, flip a bit,
// then resign it as an adhoc framework and then try again
const char* generate_dlopen_path_backup_plan(const char* arg) {
    NSString *originalExecutable = [NSString stringWithCString:dirname((char*)arg) encoding:NSUTF8StringEncoding];
    char buffer[1024] = {};
#if TARGET_OS_IPHONE
    snprintf(buffer, 1024, "/private/var/tmp/%d_%s", arc4random_uniform(0x1000000), basename((char*)arg));
#else
    snprintf(buffer, 1024, "/private/tmp/%d_%s", arc4random_uniform(0x1000000), basename((char*)arg));
#endif
    struct mach_header_64 *header = (void*)&_mh_execute_header;
    log_debug("generating patched image for dlopen @ %s -> %s\n", arg, buffer);
    
    if (extract_architecture(arg, buffer, header->cputype, header->cpusubtype)) {
        log_error("couldn't extract architecutre\n");
        return NULL;
    }
#pragma clang diagnostic pop
    
    int fd = open(buffer, O_RDWR|S_IXUSR);
    if (fd < 0) {
        perror("open");
        exit(EXIT_FAILURE);
    }
    
    struct stat st;
    if (fstat(fd, &st) < 0) {
        perror("fstat");
        close(fd);
        exit(EXIT_FAILURE);
    }
    
    void *mapped = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) {
        perror("mmap");
        close(fd);
        exit(EXIT_FAILURE);
    }
    
    struct mach_header_64 *header64 = (struct mach_header_64 *)mapped;
    uint32_t ncmds;
    
restart:
    if (header64->magic == MH_MAGIC_64) {
        ncmds = header64->ncmds;
        if (header64->filetype != MH_DYLIB) {
            header64->filetype = MH_DYLIB;
        }
#if __has_feature(ptrauth_calls)
        // we could be building for arm64e that knocks out Apple, but then we'd need to pull
        // in arm64 executables as well
        struct mach_header_64 *my_header = (void*)&_mh_execute_header;
        header64->cpusubtype = my_header->cpusubtype;
        header64->cputype = my_header->cputype;
#endif
        if (getenv("FORCE_EXE")) {
            header64->filetype = MH_EXECUTE;
        }
        
    } else if (header64->magic == FAT_CIGAM) {
        
        uint32_t offset = parseFat((void*)header64);
        header64 = mapped + offset;
        
        goto restart;
        
    } else {
        fprintf(stderr, "Not a valid Mach-O file\n");
        munmap(mapped, st.st_size);
        close(fd);
        exit(EXIT_FAILURE);
    }
    
    NSMutableArray <NSString *>* rpaths = [NSMutableArray array];
    char *lc_ptr = (char*)header64 + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *lc = (struct load_command *)lc_ptr;
        if (lc->cmd == LC_BUILD_VERSION) {
            struct build_version_command* my_platform = get_exe_platform();
            log_debug("changed LC_BUILD_VERSION to match executable %p\n", my_platform);
            memcpy(lc_ptr, my_platform, sizeof(struct build_version_command));
        }
        if (lc->cmd == LC_RPATH) {
            struct rpath_command *p = (void*)lc;
            NSString *rpathStr = [NSString stringWithCString:(char*)p + p->path.offset encoding:NSUTF8StringEncoding];
            [rpaths addObject:rpathStr];
            printf("");
        }
        lc_ptr += lc->cmdsize;
    }
    
    char* end_of_lc = (char*)header64 + sizeof(struct mach_header_64) + header64->sizeofcmds;
    char *ptr = end_of_lc;
    // attempt to add a LC_RPATH at the end that points to the OG spot
    
    NSMutableSet *set = [NSMutableSet set];
    for (NSString *rpathStr in rpaths) {
        if (![rpathStr containsString:@"@executable_path"] && ![rpathStr containsString:@"@loader_path"]) {
            continue;
        }
        NSString *resolvedPath = [[rpathStr stringByReplacingOccurrencesOfString:@"@executable_path" withString:originalExecutable] stringByReplacingOccurrencesOfString:@"@loader_path" withString:originalExecutable];
        if ([set containsObject:resolvedPath]) {
            continue;;
        }
        [set addObject:resolvedPath];
        write_load_command_rpath(header64, &ptr, resolvedPath);
    }
    
    // if we are opening a framework, it could be dependent on other frameworks
    // with an rpath so add that crap in
    //    NSString *originalPath = @"/Users/username/Library/Frameworks/MyFramework.framework";
    //         NSString *newBasePath = @"/New/Base/Directory";
    
    NSRange range = [originalExecutable rangeOfString:@"/Frameworks"];
    if (range.location != NSNotFound) {
        NSString *newPath = [originalExecutable stringByReplacingCharactersInRange:NSMakeRange(range.location + strlen("/Frameworks"), originalExecutable.length - range.length - range.location) withString:@""];
        write_load_command_rpath(header64, &ptr, newPath);
    }
    
    int projected_size = sizeof(struct dylib_command) + (uint32_t)strlen(arg) + 1;
    projected_size += (4 - (projected_size % 4)); // this lc needs to be 4 byte aligned
    struct dylib_command dylib = {
        .cmd = LC_ID_DYLIB,
        .cmdsize = projected_size,
        .dylib = {
            .name.offset = sizeof(struct dylib_command)
        }
    };
    memcpy(ptr, &dylib, sizeof(dylib));
    strcpy(ptr + sizeof(dylib), arg);
    header64->sizeofcmds += projected_size;
    header64->ncmds++;
    
    if (munmap(mapped, st.st_size) < 0) {
        perror("munmap");
    }
    
    close(fd);
    log_debug("writing to %s, about to codesign\n", buffer);
    ad_hoc_codesign_file(buffer);
    
    return strdup(buffer);
}


__attribute__((constructor)) static void init(void) {
    if (!dyld_shared_cache_for_each_image || !dyld_image_path_containing_address) {
        can_use_dyld_apis = false;
    }
}

typedef void(^dsc_image_callback) (int idx, dyld_image_t image, bool *stop);
static void dsc_iterate_images(dsc_image_callback callback) {
    if (!can_use_dyld_apis) {
        return;
    }
    const char *dsc_path = dyld_shared_cache_file_path();
    __block int counter = 0;
    __block bool stop = false;
    dyld_shared_cache_for_file(dsc_path, ^(dyld_shared_cache_t cache) {
        dyld_shared_cache_for_each_image(cache, ^(dyld_image_t image) {
            if (stop) {
                return;
            }
            if (callback) {
                callback(++counter, image, &stop);
            }
        });
    });
    
}

const char* dsc_image_as_num(uint32_t num) {
    if (!can_use_dyld_apis) {
        return NULL;
    }
    
    
    
    __block const char *str = NULL;
    dsc_iterate_images(^(int idx, dyld_image_t image, bool *stop) {
        if (num == idx) {
            str = strdup(my_dyld_image_get_installname(image));
            *stop = true;
        }
    });
    
    return str;
}

const char* dsc_image_as_path(const char *path) {
    if (!can_use_dyld_apis) {
        return NULL;
    }
    __block const char *outparam = NULL;
    dsc_iterate_images(^(int idx, dyld_image_t image, bool *stop) {
        const char * cur = my_dyld_image_get_installname(image);
        if (!strcmp(path, cur)) {
            outparam = cur;
            *stop = true;
        }
    });
    
    return outparam;
}

const char* dsc_image_as_name(const char *name) {
    if (!can_use_dyld_apis) {
        return NULL;
    }
    __block const char *outparam = NULL;
    dsc_iterate_images(^(int idx, dyld_image_t image, bool *stop) {
        const char * cur = my_dyld_image_get_installname(image);
        //    log_debug("image is: \"%s\"\n", basename((char*)cur));
        if (!strcmp(name, basename((char*)cur))) {
            outparam = cur;
            *stop = true;
        }
    });
    
    return outparam;
}

void dump_dsc_images(void) {
    if (!can_use_dyld_apis) {
        return;
    }
    dsc_iterate_images(^(int idx, dyld_image_t image, bool *stop) {
        log_out("%s%5lu%s %s%s%s\n", DYELLOW, (unsigned long)idx, DCOLOR_END, DCYAN, my_dyld_image_get_installname(image), DCOLOR_END);
    });
}

uint32_t dsc_images_count(void) {
    if (!can_use_dyld_apis) {
        return 0;
    }
    __block uint32_t counter = 0;
    dsc_iterate_images(^(int idx, dyld_image_t image, bool *stop) {
        counter++;
    });
    return counter;
}

