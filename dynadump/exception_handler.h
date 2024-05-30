//
//  exception_handler.h
//  dynadump
//
//  Created by Derek Selander on 5/29/24.
//

#ifndef exception_handler_h
#define exception_handler_h

#include <stdio.h>

void exception_add_stepover_address(void* address);
void* safe_dlopen(const char *image);
void safe_dlopen_cleanup(void);
#endif /* exception_handler_h */
