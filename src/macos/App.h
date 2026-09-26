#import <Cocoa/Cocoa.h>
#import "aterminal.h"

@interface ATAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, assign) ATStore *store;
@end

void at_macos_main(void);
