//
//  main.m
//  Dynamic Dump
//
//  Created by Derek Selander on 3/14/24.
//

#import <UIKit/UIKit.h>

int main(int argc, char * argv[]) {
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass(NSClassFromString(@"AppDelegate"));
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
