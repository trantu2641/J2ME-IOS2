#import <UIKit/UIKit.h>
#import "JBKeyboardIME.h"

NS_ASSUME_NONNULL_BEGIN

@class JBKeyboardView;

@protocol JBKeyboardViewDelegate <NSObject>
- (void)keyboardView:(JBKeyboardView *)keyboard didInsertText:(NSString *)text;
- (void)keyboardViewDidDeleteBackward:(JBKeyboardView *)keyboard;
- (void)keyboardViewDidPressReturn:(JBKeyboardView *)keyboard;
- (void)keyboardViewDidDismiss:(JBKeyboardView *)keyboard;
- (NSString *)keyboardViewCurrentText:(JBKeyboardView *)keyboard;
@end

@interface JBKeyboardView : UIView
@property(nonatomic, weak) id<JBKeyboardViewDelegate> delegate;
@property(nonatomic, assign) CGFloat keyboardHeight;
@property(nonatomic, strong) JBKeyboardIME *ime;
@property(nonatomic, assign) BOOL vietnamese;
@property(nonatomic, assign) BOOL shift;
- (void)reloadKeyboard;
@end

NS_ASSUME_NONNULL_END
