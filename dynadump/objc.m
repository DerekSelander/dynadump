//
//  objc.c
//  dynadump
//
//  Created by Derek Selander on 5/29/24.
//

@import Foundation;
@import MachO;
@import ObjectiveC;
#include "objc.h"
extern Class objc_opt_class(id _Nullable obj);

/*********************************************************************/
# pragma mark - private -
/*********************************************************************/
__attribute__((always_inline))
static uintptr_t get_cls_isa(Class cls) {
    if (!cls) {
        return 0;
    }
    uintptr_t *isa_packed =  (__bridge void*)cls;
    uintptr_t isa = (*isa_packed) & ISA_MASK;
    return (uintptr_t)strip_pac((void*)isa);
}


void extract_and_print_method(Method method, const char *name, uintptr_t image_start, BOOL isClassMethod, BOOL pretendMethod) {
    char buffer[GOOD_E_NUFF_BUFSIZE];
    buffer[0] = '\0';
#if __has_feature(ptrauth_calls)
    if (pretendMethod) {
        method = ptrauth_sign_unauthenticated(method, ptrauth_key_process_dependent_data,  ptrauth_string_discriminator("method_t"));
    }
#endif
    const char* returnType = method_copyReturnType(method);
    if (get_object_type_description(returnType, buffer)) {
        log_error("\nerror!\n failed to parse \"%s\"", returnType);
    }
    free((void*)returnType);
    
    // ugly hack eeeeeeeeeeek
    // pretendMethod means the method param is actually a objc_method_description* that
    // is masquerading as a Method_t. objc_method_description are missing the IMP, but are
    // identical to a "large" Method_t. So... if we ignore any IMP APIs, we get the same
    // helpful APIs for pulling out type encodings
    
    if (g_verbose && !pretendMethod) {
        uintptr_t implementation = (uintptr_t)strip_pac((void*)method_getImplementation(method));
        log_out( "  %s/* +0x%08lx 0x%016lx %s */%s", DGRAY, implementation - image_start, implementation, name, DCOLOR_END);
    }
    
    log_out("  %s%c(%s%s%s%s%s)%s", DGRAY, isClassMethod ? '+' : '-', DCOLOR_END, DPARAM_COLOR, buffer, DCOLOR_END, DPUNC_COLOR, DCOLOR_END);
    const char* method_name = sel_getName(method_getName(method));
    char *cur_param = strchr(method_name, ':');
    if (cur_param) {
        char *prev_param = (char*)method_name;
        int index = 0;
        char tmp[GOOD_E_NUFF_BUFSIZE];
        do {
            log_out( "%s%.*s:%s",  DMETHOD_COLOR, (int)(cur_param - prev_param), prev_param, DCOLOR_END);
            // method_copyArgumentType 0 == self, 1 == SEL, 2... actual methods
            char *argType = method_copyArgumentType(method, index + 2);
            if (get_object_type_description(argType, tmp)) {
                log_error("\nerror!\n failed to parse \"%s\"", argType);
            }
            free(argType);
            // printts a type and param ie. (id)a2
            log_out( "%s(%s%s%s%s%s)%s%sa%d%s", DGRAY, DCOLOR_END, DPARAM_COLOR, tmp, DCOLOR_END, DGRAY, DCOLOR_END, DGRAY, index + 1, DCOLOR_END);
            prev_param = cur_param + 1;
            cur_param = strchr(cur_param + 1, ':');
            
            if (cur_param) {
                log_out( " ");
            }
            index++;
        } while (cur_param);
        log_out( "%s;%s\n", DPUNC_COLOR, DCOLOR_END);
    } else {
        log_out( "%s%s%s%s;%s\n", DMETHOD_COLOR, method_name, DCOLOR_END, DPUNC_COLOR, DCOLOR_END);
    }
}



int get_object_type_description(const char *typeEncoding, char *buffer) {
    int buff_offset = 0;
    if (!typeEncoding) {
        do_copy_n_return("void*");
    }
    
    if (!strcmp(typeEncoding, "@")) {
        do_copy_n_return("id");
    } else if (!strcmp(typeEncoding, "v")) {
        do_copy_n_return("void");
    } else if (!strcmp(typeEncoding, "^v")) {
        do_copy_n_return("void*");
    } else if (!strcmp(typeEncoding, ":")) {
        do_copy_n_return("SEL");
    } else if (!strcmp(typeEncoding, "B")) { // TODO there are 2 of these? B/b
        do_copy_n_return("BOOL");
    } else if (!strcmp(typeEncoding, "b")) {
        do_copy_n_return("BOOL");
    }  else if (!strcmp(typeEncoding, "c")) {
        do_copy_n_return("char");
    } else  if (!strcmp(typeEncoding, "i")) {
        do_copy_n_return("int");
    } else if (!strcmp(typeEncoding, "s")) {
        do_copy_n_return("short");
    } else if (!strcmp(typeEncoding, "q")) {
        do_copy_n_return("long");
    } else if (!strcmp(typeEncoding, "C")){
        do_copy_n_return("unsigned char");
    } else if (!strcmp(typeEncoding, "I")) {
        do_copy_n_return("unsigned int");
    } else if (!strcmp(typeEncoding, "S")) {
        do_copy_n_return("unsigned short");
    } else if (!strcmp(typeEncoding, "Q")) {
        do_copy_n_return("unsigned long");
    } else if (!strcmp(typeEncoding, "f")) {
        do_copy_n_return("float");
    } else if (!strcmp(typeEncoding, "d")) {
        do_copy_n_return("double");
    } else if (!strcmp(typeEncoding, "D")) {
        do_copy_n_return("unsigned double");
    } else if (!strcmp(typeEncoding, "*")) {
        do_copy_n_return("char*");
    } else if (!strcmp(typeEncoding, "#")) {
        do_copy_n_return("Class");
    } else if (!strcmp(typeEncoding, "@?")) {
        do_copy_n_return("^block");
    }
    
    size_t len = strlen(typeEncoding);
    
    // Normal C struct type {_NSZone=}  >>> NSZone*
    if (typeEncoding[0] == '{' && len >= 4 && typeEncoding[len -1] == '}') {
        if (g_verbose) { // print the complete struct if verbose else just the first name
            snprintf(buffer, GOOD_E_NUFF_BUFSIZE, "struct %.*s", (int)(len - 3), &typeEncoding[1]);
        } else {
            char* found = strchr(&typeEncoding[1], '=');
            snprintf(buffer, GOOD_E_NUFF_BUFSIZE, "struct %.*s", (int)(len - ((char*)&typeEncoding[1] - found)), &typeEncoding[1]);
        }
        return 0;
    }
    
    // handle objc instance @"some_objc_here"
    if (typeEncoding[0] == '@' && len >= 4) {
        if (typeEncoding[2] == '<') {
            snprintf(buffer, GOOD_E_NUFF_BUFSIZE, "id%.*s", (int)(len - 3), &typeEncoding[2]);
            return 0;
        }
        snprintf(buffer, GOOD_E_NUFF_BUFSIZE, "%.*s*", (int)(len - 3), &typeEncoding[2]);
        return 0;
    }
    
    // handle pointers
    if (typeEncoding[0] == '^') {
        if (len > 1) {
            char tmp[GOOD_E_NUFF_BUFSIZE];
            get_object_type_description(&typeEncoding[1], tmp);
            append_content("%s*", tmp);
            return 0;
        }
        return 1;
    }
    if ( len >= 2 )
    {
        if (typeEncoding[0] <= 'm')
        {
            switch (typeEncoding[0])
            {
                case 'N':
                    append_content("inout ");
                    break;
                case 'O':
                    append_content("bycopy ");
                    break;
                case 'R':
                    append_content("byref ");
                    break;
                case 'V':
                    append_content("oneway ");
                    break;
                default:
                    do_copy_n_return(typeEncoding);
            }
            
            get_object_type_description(&typeEncoding[1], buffer + buff_offset);
            return 0;
        }
        switch (typeEncoding[0])
        {
            case 'r':
                append_content("const ");
                break;
            case 'o':
                append_content("out ");
                break;
            case 'n':
                append_content("in ");
                break;
        }
        get_object_type_description(&typeEncoding[1], buffer + buff_offset);
        return 0;
    }
    return 1;
}

static
int get_property_description(objc_property_t *property, char *buffer) {
#define append_comma_if_needed() if (i != i) { append_content(", ") }
    uint buff_offset = 0;
    unsigned int attributeCount = 0;
    objc_property_attribute_t *attributes = property_copyAttributeList(*property, &attributeCount);
    
    append_content("%s@property ", DGREEN);
    if (attributeCount >= 2) {
        append_content("(")
    }
    for (int i = attributeCount - 1; i >= 0; i--) {
        const char *name = attributes[i].name;
        
        if (i == 0 && attributeCount >= 2) {
            append_content(")%s ", DCOLOR_END);
        }
        if (!strcmp(name, "R")) {
            append_content("readonly");
            append_comma_if_needed();
        } else if (!strcmp(name, "C")) {
            append_content("copy");
            append_comma_if_needed();
        } else if (!strcmp(name, "&")) {
            append_content("retain");
            append_comma_if_needed();
        } else if (!strcmp(name, "N")) {
            append_content("nonatomic");
            append_comma_if_needed();
        } else if (!strcmp(name, "G")) {
            append_content("getter=%s ", &name[2]);
            append_comma_if_needed();
        } else if (!strcmp(name, "S")) {
            append_content("setter=%s", &name[2]);
            append_comma_if_needed();
        } else if (!strcmp(name, "D")) {
            append_content("assign ");
            append_comma_if_needed();
        } else if (!strcmp(name, "W")) {
            append_content("weak ");
            append_comma_if_needed();
        } else if (!strcmp(name, "T")) {
            char tmp[GOOD_E_NUFF_BUFSIZE];
            get_object_type_description(attributes->value, tmp);
            append_content("%s%s%s ", DRED, tmp, DCOLOR_END);
        } else if (!strcmp(name, "V")) {
            // Ignore this one, it's called a 'oneway'
        } else {
            log_debug("/*  %d TODO DEREK S */ %s", __LINE__, &name[0])
        }
        
    }
    append_content("%s%s%s\n", DBOLD, property_getName(*property), DCOLOR_END);
    free(attributes);
    return 0;
}



/*********************************************************************/
# pragma mark - public -
/*********************************************************************/


void dump_all_objc_classes(bool do_classlist, const char *path, const struct mach_header_64* header_pac) {
    
    struct mach_header_64 *header = strip_pac((void*)header_pac);
    // if we have the mach header we don't have to iterate all classes
    if (header) {
        unsigned long size = 0;
        const char *segments[] = { "__DATA", "__DATA_CONST"};
        for (int z = 0; z < 2; z++) {
            // dirty knowledge of the layout but we need the protocol names
            struct objc_protocol_t {
                uintptr_t isa;
                const char* name;
                //.. more, but whatever
            };
            size = 0;
            if (!do_classlist) {
                struct objc_protocol_t** protocols = (void*)getsectiondata(header, segments[z], "__objc_protolist", &size);
                for (int i = 0; i < (size / sizeof(uintptr_t)); i++) {
                    struct objc_protocol_t *prot = protocols[i];
                    if (prot->name) {
                        Protocol *p = objc_getProtocol(prot->name);
                        if (!p) {
                            continue;
                        }
                        dump_objc_protocol_info(p);
                        log_out("\n");
                    }
                }
            }
        }
     
        // at runtime all implementations are realized so we'll capture all classes
        // and if there's a category that references the class, we'll note it.
        // if the class hasn't been dumped at the category stage, we'll dump it there
        NSMutableSet <Class>*classSet = [NSMutableSet set];
        for (int z = 0; z < 2; z++) {
            size = 0;
            Class *classes = (__unsafe_unretained Class*)(void*)getsectiondata(header, segments[z], "__objc_classlist", &size);
            for (int i = 0; i < size / sizeof(uintptr_t); i++) {
                Class cls = classes[i];
                if (class_respondsToSelector(cls, @selector(doesNotRecognizeSelector:))) {
                    [classSet addObject:cls];
                } else {
                    log_error("non-NSObject root class, \"%s\", skipping\n", class_getName(cls));
                    continue;
                }
                if (do_classlist) {
                    Class supercls =  class_getSuperclass(cls);
                    log_out("%s0x%016lx%s %s%s%s : %s%s%s\n", DGRAY, (uintptr_t)cls, DCOLOR_END, DYELLOW, class_getName(cls), DCOLOR_END, DGREEN, class_getName(supercls), DCOLOR_END);
                } else {
                    dump_objc_class_info(cls);
                }
            }
        }
        
        if (!do_classlist) {
            for (int z = 0; z < 2; z++) {
                size = 0;
                
                // Internal header eeeeeeeeek, but no APIs for categories : [
                struct category_t {
                    const char *name;
                    Class cls;
                    void* instanceMethods;
                    void* classMethods;
                    struct protocol_list_t *protocols;
                    struct property_list_t *instanceProperties;
                    // Fields below this point are not always present on disk.
                    struct property_list_t *_classProperties;
                };
                struct category_t **categories = (struct category_t**)getsectiondata(header, segments[z], "__objc_catlist", &size);
                for (int i = 0; i < size / sizeof(uintptr_t); i++) {
                    struct category_t *cat = categories[i];
                    // TODO: not quite accurate, think of a better way of describing this to user, objc categories don't have the APIs to show which category they
                    // are coming from, so check if we've printed the cls already or see if
                    // they are in the same image as we're inspecting
                    if (![classSet containsObject:cat->cls]) {
                        log_out("%s@interface%s %s%s (%s) %s// category%s\n", DMAGENTA, DCOLOR_END, DYELLOW, class_getName(cat->cls), cat->name, DGRAY, DCOLOR_END);
                        if (dyld_image_header_containing_address((__bridge const void *)(cat->cls)) != (void*)header) {
                            log_out("%s// category for %s, which is declared in \"%s\"%s\n", DRED, class_getName(cat->cls), dyld_image_path_containing_address((__bridge const void *)(cat->cls)), DCOLOR_END);
                        }
                        dump_method_description_constrained_to_header(cat->cls, (void*)header_pac);
                    } else {
                        log_out("%s@interface%s %s%s (%s) %s// category%s\n", DMAGENTA, DCOLOR_END, DYELLOW, class_getName(cat->cls), cat->name, DGRAY, DCOLOR_END);
                        log_out("%s@end%s\n", DYELLOW, DCOLOR_END);
                    }
                }
            }
        }
        
    } else { // plan B is to just load everything and dump it
        
        log_out("// Couldn't find header, dumping everything\n");
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        
        log_debug("found %d classes...\n", count);
        for (int i = 0; i < count; i++) {
            Class cls = classes[i];
            void* isa = (void*)get_cls_isa(cls);
            const char * curpath = dyld_image_path_containing_address(isa);
            log_debug("%s %s\n", class_getName(cls),  curpath);
            if (!curpath) {
                continue;
            }
            if (strcmp(curpath, path)) {
                continue;
            }
            
            if (do_classlist) {
                Class supercls = class_getSuperclass(cls);
                log_out("%s0x%016lx%s %s%s%s : %s%s%s\n", DGRAY, (uintptr_t)cls, DCOLOR_END, DYELLOW, class_getName(cls), DCOLOR_END, DGREEN, class_getName(supercls), DCOLOR_END);
            } else {
                dump_objc_class_info(cls);
            }
        }
    }
}


void dump_objc_protocol_info(Protocol *p) {
    unsigned int count = 0;
    struct objc_method_description *descriptions = NULL;
    if (!p) {
        return;
    }
    Protocol *prot = (__bridge Protocol*)strip_pac((__bridge void *)(p));
    const char* name = protocol_getName(prot);
    log_out("  %s@protocol %s%s", DYELLOW_LIGHT, name, DCOLOR_END);
    log_out_verbose(" %s// 0x%012lx%s", DGRAY, (uintptr_t)prot, DCOLOR_END);
    log_out("\n");
    
    // required class
    descriptions = protocol_copyMethodDescriptionList(prot, YES, NO,  &count);
    for (uint i = 0; i < count; i++) {
        struct objc_method_description *desc = &descriptions[i];
        extract_and_print_method((Method)desc, name, 0, YES, YES);
    }
    free(descriptions);
    count = 0;
    
    // required instance
    descriptions = protocol_copyMethodDescriptionList(prot, YES, YES,  &count);
    for (uint i = 0; i < count; i++) {
        struct objc_method_description *desc = &descriptions[i];
        // we are cheating to pretend it's a method which ptrauth doesn't like so....
        extract_and_print_method((Method)desc, name, 0, NO, YES);
    }
    free(descriptions);
    count = 0;
    
    // optional class
    descriptions = protocol_copyMethodDescriptionList(prot, NO, NO, &count);
    bool did_print_optional = false;
    if (count) {
        did_print_optional = true;
        log_out("  %s@optional%s\n", DYELLOW_LIGHT, DCOLOR_END);
    }
    for (uint i = 0; i < count; i++) {
        struct objc_method_description *desc = &descriptions[i];
        extract_and_print_method((Method)desc, name, 0, YES, YES);
    }
    free(descriptions);
    count = 0;
    
    // optional instance
    descriptions = protocol_copyMethodDescriptionList(prot, NO, YES, &count);
    if (count && did_print_optional == false) {
        log_out("  %s@optional%s\n", DYELLOW_LIGHT, DCOLOR_END);
    }
    for (uint i = 0; i < count; i++) {
        struct objc_method_description *desc = &descriptions[i];
        extract_and_print_method((Method)desc, name, 0, NO, YES);
    }
    log_out("  %s@end%s\n", DYELLOW_LIGHT, DCOLOR_END);
    
}

static void _dump_ivar_description(id instanceOrCls, bool standaloneDescription) {
    const char *imagePath = dyld_image_path_containing_address((__bridge const void * _Nonnull)(instanceOrCls));
    Class cls = objc_opt_class(instanceOrCls);
    bool isClass = (instanceOrCls == cls) ? true: false;
    unsigned int ivarCount = 0;
    if (standaloneDescription) {
        if (isClass) {
            log_out("%s", class_getName(cls));
        } else {
            log_out("%s <%p>", class_getName(cls), instanceOrCls);
        }
        
        Class superCls = class_getSuperclass(cls);
        if (superCls) {
            log_out(": %s ", class_getName(superCls));
        }
        if (imagePath) {
            log_out(" %s(%s)%s\n", DYELLOW_LIGHT, imagePath, DCOLOR_END);
        } else {
            log_out(" %s(?)%s\n", DYELLOW_LIGHT, DCOLOR_END);
        }
    }
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    if (ivarCount) {
        log_out("\n {\n");
    }
    for (uint i = 0; i < ivarCount; i++) {
        const char *typeEncoding = ivar_getTypeEncoding(ivars[i]);
        typeEncoding = typeEncoding ? typeEncoding : "";
        const char *name = ivar_getName(ivars[i]);
        long int offset = ivar_getOffset(ivars[i]);
        char buffer[GOOD_E_NUFF_BUFSIZE];
        get_object_type_description(typeEncoding, buffer);
        if (isClass) {
            log_out("  %s/* +0x%04lx */%s  %s%s%s %s%s%s\n", DGRAY, offset, DCOLOR_END, DCYAN_LIGHT, buffer, DCOLOR_END, DCYAN, name, DCOLOR_END);
        } else {
            log_out("  %s/* +0x%04lx 0x%016lx */%s  %s%s%s %s%s%s \n", DGRAY, offset,  *(uintptr_t*)((uintptr_t)instanceOrCls + offset), DCOLOR_END, DCYAN_LIGHT, buffer, DCOLOR_END, DCYAN, name, DCOLOR_END);
        }
    }
    free(ivars);
    if (ivarCount) {
        log_out(" }\n");
    }
}

void dump_ivar_description(id instanceOrCls) {
    _dump_ivar_description(instanceOrCls, true);
}

void dump_method_description_constrained_to_header(id instanceOrCls, struct mach_header_64 *header) {
    Class cls = objc_opt_class(instanceOrCls);
    const char* clsName = class_getName(cls);
    unsigned int metaMethodCount = 0;
    Class metaCls = objc_getMetaClass(clsName);
    Class superCls = class_getSuperclass(cls);
    bool has_done_newline = false;
    uintptr_t image_start = (uintptr_t)dyld_image_header_containing_address((__bridge const void * _Nonnull)(cls));
    
    // if we have a header then likely means we are dealing with a category
    if (!header) {
        
        if (!superCls) {
            log_out( "%sNS_ROOT_CLASS%s ", DYELLOW, DCOLOR_END);
        }
        log_out( "%s@interface%s %s%s%s ", DMAGENTA, DCOLOR_END, DYELLOW, clsName, DCOLOR_END);
        
        // superclass
        if (superCls) {
            const char* superClsName = class_getName(superCls);
            if (superClsName) {
                log_out( "%s: %s%s ", DYELLOW, superClsName, DCOLOR_END);
            }
        }
        
        // protocols
        unsigned int cnt = 0;
        Protocol * __unsafe_unretained _Nonnull * _Nullable protocols = class_copyProtocolList(cls, &cnt);
        for (int i = 0; i< cnt; i++) {
            if (i == 0) {
                log_out("%s<", DGREEN)
            }
            log_out("%s", protocol_getName(protocols[i]));
            if (cnt > 1 && i < cnt - 1) {
                log_out(", ")
            }
            
            if (i == cnt - 1) {
                log_out(">%s", DCOLOR_END);
            }
        }
        if (protocols) {
            free((void*)protocols);
        }
        
        // ivars
        _dump_ivar_description(cls, false);
        
        // Properties
        unsigned int propertyCount = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
        if (propertyCount) {
            log_out( "\n\n  %s// \"%s\" properties:%s\n", DGRAY, clsName, DCOLOR_END);
            has_done_newline = true;
        }
        for (uint i = 0; i < propertyCount; i++) {
            char buffer[GOOD_E_NUFF_BUFSIZE];
            if (get_property_description(&properties[i], buffer)) {
                log_error(  "\nfailed to parse \"%s\"", property_getName(properties[i]));
            }
            log_out( "  %s", buffer);
        }
        free(properties);
        if (propertyCount) {
            log_out( "\n");
        }
    }
    
    // Class methods
    if (metaCls) {
        Method *clsMethods = class_copyMethodList(metaCls, &metaMethodCount);
        if (!header) {
            if (has_done_newline == false) {
                has_done_newline = true;
                log_out("\n\n");
            }
            if (metaMethodCount) {
                log_out( "  %s// \"%s\" class methods:%s\n", DGRAY, clsName, DCOLOR_END);
            }
        }
        for (uint i = 0; i < metaMethodCount; i++) {
            if (header) {
                IMP implementation = method_getImplementation(clsMethods[i]);
                if (dyld_image_header_containing_address(implementation) != (void*)header) {
                    continue;
                }
            }
            extract_and_print_method(clsMethods[i], clsName, image_start, YES, NO);
        }
        if (metaMethodCount) {
            log_out( "\n");
        }
        free(clsMethods);
    }
    
    // Instance methods
    if (cls) {
        unsigned int methodCount = 0;
        Method *instanceMethods = class_copyMethodList(cls, &methodCount);
        if (!header) {
            if (has_done_newline == false) {
                log_out("\n\n");
                has_done_newline = true;
            }
            if (methodCount) {
                log_out( "  %s// \"%s\" instance methods:%s\n", DGRAY, clsName, DCOLOR_END);
            }
        }
        for (uint i = 0; i < methodCount; i++) {
            if (header) {
                IMP implementation = method_getImplementation(instanceMethods[i]);
                if (dyld_image_header_containing_address(implementation) != (void*)header) {
                    continue;
                }
            }
            extract_and_print_method(instanceMethods[i], clsName, header ? header : image_start, NO, NO);
        }
        free(instanceMethods);
    }
    if (has_done_newline) {
        log_out("\n");
    }
    
    log_out( "%s@end%s\n\n", DYELLOW, DCOLOR_END);
    log_debug("leaving %s:%d\n", __FUNCTION__, __LINE__);
    
}

DYNAMIC_DUMP_VISIBILITY
void dump_method_description(id instanceOrCls) {
    dump_method_description_constrained_to_header(instanceOrCls, NULL);
}

void dump_objc_class_info(Class cls) {
    uintptr_t isa = get_cls_isa(cls);
    const char* path = dyld_image_path_containing_address((const void*)isa);
    log_out("%s//> %s %s%s\n", DGRAY, class_getName(cls), path, DCOLOR_END);
    dump_method_description(cls);
}

