//
//  objc.h
//  dynadump
//
//  Created by Derek Selander on 5/29/24.
//

#ifndef objc_h
#define objc_h

#import <stdio.h>
#import "misc.h"

void dump_all_objc_classes(bool do_classlist, const char *path, const struct mach_header_64* header_pac);

void dump_objc_protocol_info(Protocol *p);

void dump_objc_class_info(Class cls);
int get_object_type_description(const char *typeEncoding, char *buffer);
void dump_method_description_constrained_to_header(id instanceOrCls, struct mach_header_64 *header);
#endif /* objc_h */
