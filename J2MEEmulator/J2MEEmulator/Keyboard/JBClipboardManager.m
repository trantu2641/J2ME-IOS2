#import "JBClipboardManager.h"

static NSString * const JBClipboardDefaultsKey = @"JarBoxKeyboardClipboard";

@interface JBClipboardManager ()
@property(nonatomic, strong) NSMutableArray<NSString *> *mutableItems;
@end

@implementation JBClipboardManager

+ (instancetype)shared {
    static JBClipboardManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [JBClipboardManager new]; });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:JBClipboardDefaultsKey];
        _mutableItems = saved ? [saved mutableCopy] : [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSString *> *)items {
    return [self.mutableItems copy];
}

- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:self.mutableItems forKey:JBClipboardDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)addText:(NSString *)text {
    if (!text.length) return;
    [self.mutableItems removeObject:text];
    [self.mutableItems insertObject:text atIndex:0];
    if (self.mutableItems.count > 30)
        [self.mutableItems removeObjectsInRange:NSMakeRange(30, self.mutableItems.count - 30)];
    [self save];
}

- (void)captureSystemPasteboard {
    UIPasteboard *p = UIPasteboard.generalPasteboard;
    NSString *s = p.string;
    if (s.length) [self addText:s];
}

- (void)copyText:(NSString *)text {
    if (!text.length) return;
    UIPasteboard.generalPasteboard.string = text;
    [self addText:text];
}

- (void)pasteInto:(void (^)(NSString *))completion {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (s.length) {
        [self addText:s];
        if (completion) completion(s);
    }
}

- (void)removeAtIndex:(NSUInteger)index {
    if (index >= self.mutableItems.count) return;
    [self.mutableItems removeObjectAtIndex:index];
    [self save];
}

- (void)clear {
    [self.mutableItems removeAllObjects];
    [self save];
}

- (void)pinAtIndex:(NSUInteger)index {
    // Pinned entries are kept at the top. A full pin model can be added later
    // without changing the public API.
    if (index >= self.mutableItems.count || index == 0) return;
    NSString *s = self.mutableItems[index];
    [self.mutableItems removeObjectAtIndex:index];
    [self.mutableItems insertObject:s atIndex:0];
    [self save];
}

@end
