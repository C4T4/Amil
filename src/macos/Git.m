#import "Git.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

@implementation ATGitInfo
- (NSString *)shortLine {
    if (!self.branch.length) return nil;
    NSMutableString *s = [NSMutableString stringWithString:self.branch];
    if (self.dirty) [s appendString:@"*"];
    if (self.worktree.length) [s appendFormat:@" · %@", self.worktree];
    return s;
}
@end

@interface ATGitCache : NSObject
@property (nonatomic, strong) ATGitInfo *info;
@property (nonatomic, assign) NSTimeInterval at;
@end
@implementation ATGitCache
@end

static NSMutableDictionary<NSString *, ATGitCache *> *gGitMap;

static NSString *ATReadSmallFile(NSString *path) {
    if (!path.length) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    char buf[512];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return nil;
    buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ')) {
        buf[--n] = 0;
    }
    return [[NSString alloc] initWithUTF8String:buf];
}

static BOOL ATIsDir(NSString *path) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISDIR(st.st_mode);
}

static BOOL ATIsFile(NSString *path) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISREG(st.st_mode);
}

static NSString *ATGitDirForCwd(NSString *cwd, NSString **outRoot) {
    NSString *dir = cwd.stringByStandardizingPath;
    while (dir.length && ![dir isEqualToString:@"/"]) {
        NSString *dot = [dir stringByAppendingPathComponent:@".git"];
        if (ATIsDir(dot)) {
            if (outRoot) *outRoot = dir;
            return dot;
        }
        if (ATIsFile(dot)) {
            NSString *line = ATReadSmallFile(dot);
            if ([line hasPrefix:@"gitdir:"]) {
                NSString *rel = [[line substringFromIndex:7]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSString *gitdir = [rel hasPrefix:@"/"] ? rel
                    : [[dir stringByAppendingPathComponent:rel] stringByStandardizingPath];
                if (outRoot) *outRoot = dir;
                return gitdir;
            }
        }
        NSString *parent = dir.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:dir]) break;
        dir = parent;
    }
    return nil;
}

ATGitInfo *ATGitProbe(NSString *cwd) {
    if (!cwd.length) return nil;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (!gGitMap) gGitMap = [NSMutableDictionary new];
    ATGitCache *hit = gGitMap[cwd];
    if (hit && now - hit.at < 2.0) return hit.info;

    NSString *root = nil;
    NSString *gitdir = ATGitDirForCwd(cwd, &root);
    ATGitInfo *info = nil;
    if (gitdir.length) {
        NSString *head = ATReadSmallFile([gitdir stringByAppendingPathComponent:@"HEAD"]);
        NSString *branch = nil;
        if ([head hasPrefix:@"ref: "]) {
            NSString *ref = [head substringFromIndex:5];
            if ([ref hasPrefix:@"refs/heads/"])
                branch = [ref substringFromIndex:@"refs/heads/".length];
            else
                branch = ref.lastPathComponent;
        } else if (head.length >= 7) {
            branch = [head substringToIndex:7];
        }
        if (branch.length) {
            info = [ATGitInfo new];
            info.branch = branch;
            info.root = root;
            NSRange wt = [gitdir rangeOfString:@"/worktrees/"];
            if (wt.location != NSNotFound) info.worktree = gitdir.lastPathComponent;
            /* Index newer than HEAD file is a cheap dirty hint; skip if missing. */
            struct stat stIndex, stHead;
            NSString *indexPath = [gitdir stringByAppendingPathComponent:@"index"];
            NSString *headPath = [gitdir stringByAppendingPathComponent:@"HEAD"];
            if (stat(indexPath.fileSystemRepresentation, &stIndex) == 0 &&
                stat(headPath.fileSystemRepresentation, &stHead) == 0) {
                info.dirty = stIndex.st_mtime > stHead.st_mtime;
            }
        }
    }
    ATGitCache *c = [ATGitCache new];
    c.info = info;
    c.at = now;
    gGitMap[cwd] = c;
    return info;
}
