#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JBClipboardManager : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) NSArray<NSString *> *items;
- (void)captureSystemPasteboard;
- (void)addText:(NSString *)text;
- (void)copyText:(NSString *)text;
- (void)pasteInto:(void (^)(NSString *text))completion;
- (void)removeAtIndex:(NSUInteger)index;
- (void)clear;
- (void)pinAtIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
