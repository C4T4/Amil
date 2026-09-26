#import <Cocoa/Cocoa.h>
#import "at_agents.h"

NSImage *ATAgentImage(NSString *agentId);
NSString *ATAgentDisplayName(NSString *agentId);
NSString *ATAgentCommand(NSString *agentId);
NSArray<NSString *> *ATAgentFlagsForCommand(NSString *command);
void ATFillAgentPopup(NSPopUpButton *popup, NSString *selectedId);
NSString *ATSelectedAgentId(NSPopUpButton *popup);

@interface ATQuickstartView : NSView
@property (nonatomic, copy) NSString *selectedAgentId;
@property (nonatomic, copy) NSString *homePath;
@property (nonatomic, copy) void (^onStart)(NSString *agentId);
@property (nonatomic, copy) void (^onChangeHome)(void);
- (void)reloadHome;
@end
