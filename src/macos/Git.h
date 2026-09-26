#import <Cocoa/Cocoa.h>

@interface ATGitInfo : NSObject
@property (nonatomic, copy) NSString *branch;
@property (nonatomic, copy) NSString *root;
@property (nonatomic, copy) NSString *worktree; /* last path component; nil if primary checkout */
@property (nonatomic, assign) BOOL dirty;
@property (nonatomic, readonly) NSString *shortLine;
@end

/* Cached ~2s per cwd. nil if not a repo or git missing. */
ATGitInfo *ATGitProbe(NSString *cwd);
