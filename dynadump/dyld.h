//
//  dsc.h
//  dynadump
//
//  Created by Derek Selander on 5/29/24.
//

#ifndef my_dyld_h
#define my_dyld_h

#include <stdio.h>

const char* generate_dlopen_path_backup_plan(const char* arg);
const char* dsc_image_as_num(uint32_t num);
const char* dsc_image_as_path(const char *path);
const char* dsc_image_as_name(const char *name);
void dump_dsc_images(void);
uint32_t dsc_images_count(void);
#endif /* dsc_h */

