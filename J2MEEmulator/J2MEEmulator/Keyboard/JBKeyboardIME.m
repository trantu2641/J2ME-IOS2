#import "JBKeyboardIME.h"

@implementation JBKeyboardIME

- (instancetype)init {
    self = [super init];
    if (self) {
        _language = @"vi";
        _telexEnabled = YES;
    }
    return self;
}

static BOOL JBIsVowel(unichar c) {
    return [[NSCharacterSet characterSetWithCharactersInString:@"aeiouyAEIOUY"] characterIsMember:c];
}

static NSString *JBReplaceLastBase(NSString *s, NSString *base, NSString *replacement) {
    NSRange r = [s rangeOfString:base options:NSBackwardsSearch];
    if (r.location == NSNotFound) return s;
    return [s stringByReplacingCharactersInRange:r withString:replacement];
}

- (NSString *)applyTelexToWord:(NSString *)word {
    if (!self.telexEnabled || ![self.language isEqualToString:@"vi"] || word.length < 2)
        return word;

    NSString *w = word;
    NSArray *pairs = @[
        @[@"aa",@"â"], @[@"AA",@"Â"],
        @[@"aw",@"ă"], @[@"AW",@"Ă"],
        @[@"ee",@"ê"], @[@"EE",@"Ê"],
        @[@"oo",@"ô"], @[@"OO",@"Ô"],
        @[@"ow",@"ơ"], @[@"OW",@"Ơ"],
        @[@"uw",@"ư"], @[@"UW",@"Ư"]
    ];

    for (NSArray *p in pairs) {
        if ([w hasSuffix:p[0]]) {
            w = [w substringToIndex:w.length - p[0].length];
            w = [w stringByAppendingString:p[1]];
            break;
        }
    }

    if (w.length >= 2) {
        unichar mark = [w characterAtIndex:w.length - 1];
        NSString *markMap = @"sfrxj";
        NSRange mr = [markMap rangeOfString:[NSString stringWithCharacters:&mark length:1]
                                   options:NSCaseInsensitiveSearch];
        if (mr.location != NSNotFound) {
            NSString *base = [w substringToIndex:w.length - 1];
            NSArray *toneTables = @[
                @[@"á",@"à",@"ả",@"ã",@"ạ"],
                @[@"é",@"è",@"ẻ",@"ẽ",@"ẹ"],
                @[@"í",@"ì",@"ỉ",@"ĩ",@"ị"],
                @[@"ó",@"ò",@"ỏ",@"õ",@"ọ"],
                @[@"ú",@"ù",@"ủ",@"ũ",@"ụ"],
                @[@"ý",@"ỳ",@"ỷ",@"ỹ",@"ỵ"],
                @[@"ắ",@"ằ",@"ẳ",@"ẵ",@"ặ"],
                @[@"ấ",@"ầ",@"ẩ",@"ẫ",@"ậ"],
                @[@"ế",@"ề",@"ể",@"ễ",@"ệ"],
                @[@"ố",@"ồ",@"ổ",@"ỗ",@"ộ"],
                @[@"ớ",@"ờ",@"ở",@"ỡ",@"ợ"],
                @[@"ứ",@"ừ",@"ử",@"ữ",@"ự"],
                @[@"ố",@"ồ",@"ổ",@"ỗ",@"ộ"]
            ];
            // Find the last vowel in the word and replace its accented form.
            for (NSInteger i = base.length - 1; i >= 0; i--) {
                unichar c = [base characterAtIndex:i];
                if (JBIsVowel(c)) {
                    NSString *v = [NSString stringWithCharacters:&c length:1];
                    NSInteger idx = NSNotFound;
                    NSArray *mapBase = @[@"a",@"e",@"i",@"o",@"u",@"y",@"ă",@"â",@"ê",@"ô",@"ơ",@"ư",@"O"];
                    for (NSInteger k=0;k<mapBase.count;k++) {
                        if ([v lowercaseString].length && [[v lowercaseString] isEqualToString:[mapBase[k] lowercaseString]]) {
                            idx = k; break;
                        }
                    }
                    if (idx != NSNotFound && idx < toneTables.count) {
                        NSString *rep = toneTables[idx][mr.location];
                        if ([[v uppercaseString] isEqualToString:v]) rep = [rep uppercaseString];
                        base = [base stringByReplacingCharactersInRange:NSMakeRange(i,1) withString:rep];
                    }
                    break;
                }
            }
            w = base;
        }
    }
    return w;
}

- (NSString *)insertText:(NSString *)text into:(NSString *)currentText {
    if (!text.length) return currentText ?: @"";
    NSString *s = [NSString stringWithFormat:@"%@%@", currentText ?: @"", text];
    if (![self.language isEqualToString:@"vi"] || !self.telexEnabled) return s;

    NSRange r = [s rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] options:NSBackwardsSearch];
    NSUInteger start = (r.location == NSNotFound) ? 0 : r.location + 1;
    NSString *prefix = [s substringToIndex:start];
    NSString *word = [s substringFromIndex:start];

    if (word.length > 0) {
        word = [self applyTelexToWord:word];
        return [prefix stringByAppendingString:word];
    }
    return s;
}

- (NSString *)deleteBackwardFrom:(NSString *)currentText {
    if (!currentText.length) return @"";
    return [currentText substringToIndex:currentText.length - 1];
}

- (NSString *)commitComposition:(NSString *)currentText {
    return currentText ?: @"";
}

- (NSArray<NSString *> *)suggestionsForText:(NSString *)text {
    if (!text.length) return @[];
    // Lightweight local suggestions. This is intentionally offline and can be
    // replaced later by a larger dictionary without changing the keyboard UI.
    NSDictionary *dict = @{
        @"xin": @[@"xin", @"xinh", @"xin chào"],
        @"chao": @[@"chào", @"chào bạn"],
        @"toi": @[@"tôi", @"tới"],
        @"ban": @[@"bạn", @"bàn", @"bản"],
        @"khong": @[@"không"],
        @"duoc": @[@"được"],
        @"viet": @[@"viết", @"Việt"],
        @"anh": @[@"anh", @"ảnh", @"ánh"],
        @"em": @[@"em", @"êm"],
        @"game": @[@"game"],
        @"jar": @[@"JAR"],
    };
    NSString *key = text.lowercaseString;
    return dict[key] ?: @[text];
}

@end
