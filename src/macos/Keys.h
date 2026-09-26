#import <Cocoa/Cocoa.h>
#import "TermView.h"

@interface NSWindowController (ATKeys)
- (BOOL)handleNavEvent:(NSEvent *)event;
/* The strips are declared before the controller; they ask through here. */
- (ATActivity)activityForTabId:(NSString *)tabId;
- (ATActivity)activityForWorkspaceId:(NSString *)wsId;
- (void)quickstart;
- (void)tabChrome:(BOOL)forward;
- (void)activateChrome;
- (void)escapeChrome;
- (void)cycleChrome:(BOOL)forward;
@end
