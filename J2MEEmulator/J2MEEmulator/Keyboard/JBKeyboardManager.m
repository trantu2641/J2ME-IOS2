#import "JBKeyboardManager.h"

@interface JBKeyboardManager ()
@property(nonatomic, strong) JBKeyboardView *keyboardView;
@property(nonatomic, weak) UIView *hostView;
@property(nonatomic, assign) BOOL visible;
@end

@implementation JBKeyboardManager

+ (instancetype)shared {
    static JBKeyboardManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [JBKeyboardManager new]; });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _keyboardHeight = 300.0;
        _keyboardView = [[JBKeyboardView alloc] initWithFrame:CGRectZero];
        _keyboardView.delegate = self;
        _keyboardView.keyboardHeight = _keyboardHeight;
    }
    return self;
}

- (void)attachToView:(UIView *)hostView {
    self.hostView = hostView;
    if (!self.keyboardView.superview)
        [hostView addSubview:self.keyboardView];
    [self layoutKeyboardAnimated:NO];
}

- (void)layoutKeyboardAnimated:(BOOL)animated {
    if (!self.hostView) return;
    CGFloat h = self.visible ? self.keyboardHeight : 0;
    void (^changes)(void) = ^{
        CGRect f = self.keyboardView.frame;
        f.origin.x = 0;
        f.size.width = self.hostView.bounds.size.width;
        f.origin.y = self.hostView.bounds.size.height - h;
        f.size.height = h;
        self.keyboardView.frame = f;
    };
    if (animated) [UIView animateWithDuration:0.22 animations:changes];
    else changes();
}

- (void)show {
    self.visible = YES;
    self.keyboardView.hidden = NO;
    [self.keyboardView reloadKeyboard];
    [self layoutKeyboardAnimated:YES];
}

- (void)hide {
    self.visible = NO;
    [self layoutKeyboardAnimated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.23 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.visible) self.keyboardView.hidden = YES;
    });
}

- (void)setKeyboardHeight:(CGFloat)height animated:(BOOL)animated {
    self.keyboardHeight = MAX(180, MIN(420, height));
    self.keyboardView.keyboardHeight = self.keyboardHeight;
    [self layoutKeyboardAnimated:animated];
}

#pragma mark - JBKeyboardViewDelegate

- (void)keyboardView:(JBKeyboardView *)keyboard didInsertText:(NSString *)text {
    if (self.insertTextHandler) self.insertTextHandler(text);
}

- (void)keyboardViewDidDeleteBackward:(JBKeyboardView *)keyboard {
    if (self.deleteBackwardHandler) self.deleteBackwardHandler();
}

- (void)keyboardViewDidPressReturn:(JBKeyboardView *)keyboard {
    if (self.returnHandler) self.returnHandler();
}

- (void)keyboardViewDidDismiss:(JBKeyboardView *)keyboard {
    [self hide];
}

- (NSString *)keyboardViewCurrentText:(JBKeyboardView *)keyboard {
    return self.currentTextProvider ? self.currentTextProvider() : @"";
}

@end
