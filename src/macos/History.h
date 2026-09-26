#import <Cocoa/Cocoa.h>

@interface ATSessionInfo : NSObject
@property (nonatomic, copy) NSString *agentId;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *cwd;
@property (nonatomic, copy) NSArray<NSString *> *folders;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSDate *updated;
@end

@interface ATHistoryView : NSView
@property (nonatomic, copy) void (^onOpen)(ATSessionInfo *session);
- (void)reload;
@end
