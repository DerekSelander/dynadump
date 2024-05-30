//
//  ViewController.m
//  Dynamic Dump
//
//  Created by Derek Selander on 3/14/24.
//

#import "ViewController.h"
#import <dlfcn.h>
@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    void dump_dsc_images(void);
    
    dlopen("/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard", RTLD_NOW);
//    dump_dsc_images();
    
//    void dlopen_n_dump_objc_classes(const char *arg, bool do_classlist);
    void dlopen_n_dump_objc_classes(const char *arg, const char*clsName, bool do_classlist);
    dlopen_n_dump_objc_classes("/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard", NULL, false);
    NSLog(@"fuck yeah done");
//    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard", RTLD_NOW);
    // Do any additional setup after loading the view.
}


@end
