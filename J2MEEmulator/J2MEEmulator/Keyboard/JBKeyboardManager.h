#import <UIKit/UIKit.h>
#import "JBKeyboardView.h"

NS_ASSUME_NONNULL_BEGIN

@interface JBKeyboardManager : NSObject <JBKeyboardViewDelegate>
+ (instancetype)shared;

@property(nonatomic, strong, readonly) JBKeyboardView *keyboardView;
@property(nonatomic, assign) CGFloat keyboardHeight;
@property(nonatomic, weak) UIViewController *hostViewController;

// The host supplies the current JAR text and receives committed text.
// These callbacks are the only bridge needed by the existing JAR UI.
@property(nonatomic, copy) NSString *(^currentTextProvider)(void);
@property(nonatomic, copy) void (^insertTextHandler)(NSString *text);
@property(nonatomic, copy) void (^deleteBackwardHandler)(void);
@property(nonatomic, copy) void (^returnHandler)(void);

- (void)attachToView:(UIView *)hostView;
- (void)show;
- (void)hide;
- (void)setKeyboardHeight:(CGFloat)height animated:(BOOL)animated;
@end

NS_ASSUME_NONNULL_END
