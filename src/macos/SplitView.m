#import "SplitView.h"
#import "Theme.h"

@implementation ATSplitView {
    NSView *_first;
    NSView *_second;
    BOOL _drag;
    CGFloat _startRatio;
    CGFloat _startPos;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _ratio = 0.5;
    self.wantsLayer = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setFirst:(NSView *)first second:(NSView *)second {
    if (_first.superview == self) [_first removeFromSuperview];
    if (_second.superview == self) [_second removeFromSuperview];
    _first = first;
    _second = second;
    first.translatesAutoresizingMaskIntoConstraints = YES;
    second.translatesAutoresizingMaskIntoConstraints = YES;
    [self addSubview:first];
    [self addSubview:second];
    [self layout];
}

- (NSRect)dividerRect {
    CGFloat t = 5;
    NSRect b = self.bounds;
    if (self.vertical) {
        CGFloat x = floor((NSWidth(b) - t) * self.ratio);
        return NSMakeRect(x, 0, t, NSHeight(b));
    }
    CGFloat y = floor((NSHeight(b) - t) * self.ratio);
    return NSMakeRect(0, y, NSWidth(b), t);
}

- (void)layout {
    [super layout];
    if (!_first || !_second) return;
    NSRect d = [self dividerRect];
    NSRect b = self.bounds;
    if (self.vertical) {
        _first.frame = NSMakeRect(0, 0, d.origin.x, NSHeight(b));
        _second.frame = NSMakeRect(NSMaxX(d), 0, NSWidth(b) - NSMaxX(d), NSHeight(b));
    } else {
        _first.frame = NSMakeRect(0, 0, NSWidth(b), d.origin.y);
        _second.frame = NSMakeRect(0, NSMaxY(d), NSWidth(b), NSHeight(b) - NSMaxY(d));
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layout];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [ATColorBg() setFill];
    NSRectFill(self.bounds);
    NSColor *c = _drag ? ATColorAccent() : ATColorHair();
    [c setFill];
    NSRectFill([self dividerRect]);
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:[self dividerRect]
                 cursor:self.vertical ? [NSCursor resizeLeftRightCursor] : [NSCursor resizeUpDownCursor]];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, [self dividerRect])) return;
    _drag = YES;
    _startRatio = self.ratio;
    _startPos = self.vertical ? p.x : p.y;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_drag) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat span = self.vertical ? NSWidth(self.bounds) : NSHeight(self.bounds);
    if (span < 8) return;
    CGFloat pos = self.vertical ? p.x : p.y;
    CGFloat r = _startRatio + (pos - _startPos) / span;
    if (r < 0.2) r = 0.2;
    if (r > 0.8) r = 0.8;
    self.ratio = r;
    [self layout];
    [self setNeedsDisplay:YES];
    [self.window invalidateCursorRectsForView:self];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!_drag) return;
    _drag = NO;
    [self setNeedsDisplay:YES];
    if (self.onRatio) self.onRatio(self.nodeIndex, self.ratio);
}

@end
