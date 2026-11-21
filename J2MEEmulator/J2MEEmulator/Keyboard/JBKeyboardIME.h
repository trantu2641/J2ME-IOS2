#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JBKeyboardIME : NSObject
@property(nonatomic, copy) NSString *language; // vi / en
@property(nonatomic, assign) BOOL telexEnabled;

- (NSString *)insertText:(NSString *)text into:(NSString *)currentText;
- (NSString *)deleteBackwardFrom:(NSString *)currentText;
- (NSString *)commitComposition:(NSString *)currentText;
- (NSArray<NSString *> *)suggestionsForText:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
