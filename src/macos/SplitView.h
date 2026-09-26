#import <Cocoa/Cocoa.h>

@interface ATSplitView : NSView
@property (nonatomic, assign) BOOL vertical;
@property (nonatomic, assign) CGFloat ratio;
@property (nonatomic, assign) uint32_t nodeIndex;
@property (nonatomic, copy) void (^onRatio)(uint32_t nodeIndex, CGFloat ratio);
- (void)setFirst:(NSView *)first second:(NSView *)second;
@end
