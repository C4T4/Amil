#import <Cocoa/Cocoa.h>

/* What the agent in this pane is doing, inferred from pty output. */
typedef NS_ENUM(NSInteger, ATActivity) {
    ATActivityNone = 0,     /* no process: this workspace is not running */
    ATActivityStandby,      /* alive, TUI not up yet */
    ATActivityNeedsInput,   /* permission / approval prompt on screen */
    ATActivityWorking,      /* thinking or running a tool */
};

@interface ATTermView : NSView
@property (nonatomic, copy, readonly) NSString *cwd;
@property (nonatomic, copy, readonly) NSString *command;
/* Which session tab and workspace this pane belongs to, so both strips can
   summarise it — including workspaces you are not currently looking at. */
@property (nonatomic, copy) NSString *tabId;
@property (nonatomic, copy) NSString *workspaceId;
@property (nonatomic, readonly) ATActivity activity;
/* YES when the activity dot must repaint: still working (pulse), or the
   state just changed (green → copper → hollow). */
- (BOOL)activityNeedsPaint;
@property (nonatomic, copy, readonly) NSArray<NSString *> *folders;
@property (nonatomic, copy, readonly) NSString *workspaceName;
@property (nonatomic, copy) void (^onSession)(NSString *sessionId);
@property (nonatomic, copy) NSString *paneId;
@property (nonatomic, copy) void (^onFocus)(NSString *paneId);
@property (nonatomic, assign) BOOL keyboardHighlight;
- (instancetype)initWithCwd:(NSString *)cwd
                    command:(NSString *)command
                    folders:(NSArray<NSString *> *)folders
                  workspace:(NSString *)workspace
                    session:(NSString *)session
                     resume:(BOOL)resume;
- (void)killChild;
- (void)noteSeen;
- (void)writeBytes:(const void *)bytes length:(size_t)n;
- (uint64_t)childFootprint;
@end

NSString *ATMakeUUID(void);
NSString *ATFindSessionId(NSString *command, NSString *cwd);
BOOL ATSessionExists(NSString *command, NSString *cwd, NSString *sessionId);
