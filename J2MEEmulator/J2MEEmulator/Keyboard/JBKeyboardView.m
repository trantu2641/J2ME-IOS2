#import "JBKeyboardView.h"
#import "JBClipboardManager.h"

@interface JBKeyButton : UIButton
@property(nonatomic, copy) NSString *output;
@end

@implementation JBKeyButton
@end

@interface JBKeyboardView ()
@property(nonatomic, strong) UIStackView *rootStack;
@property(nonatomic, strong) UIView *suggestionBar;
@property(nonatomic, strong) UIScrollView *suggestionScroll;
@property(nonatomic, strong) NSMutableArray<JBKeyButton *> *buttons;
@property(nonatomic, strong) UILabel *languageLabel;
@end

@implementation JBKeyboardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _keyboardHeight = 300.0;
        _ime = [JBKeyboardIME new];
        _vietnamese = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1.0];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    self.suggestionBar = [[UIView alloc] init];
    self.suggestionBar.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
    [self addSubview:self.suggestionBar];

    self.suggestionScroll = [[UIScrollView alloc] init];
    self.suggestionScroll.showsHorizontalScrollIndicator = NO;
    [self.suggestionBar addSubview:self.suggestionScroll];

    self.rootStack = [[UIStackView alloc] init];
    self.rootStack.axis = UILayoutConstraintAxisVertical;
    self.rootStack.spacing = 6;
    self.rootStack.distribution = UIStackViewDistributionFillEqually;
    [self addSubview:self.rootStack];

    [self reloadKeyboard];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat suggestionH = 40;
    self.suggestionBar.frame = CGRectMake(0, 0, self.bounds.size.width, suggestionH);
    self.suggestionScroll.frame = self.suggestionBar.bounds;
    self.rootStack.frame = CGRectMake(4, suggestionH + 4,
                                      self.bounds.size.width - 8,
                                      self.bounds.size.height - suggestionH - 8);
}

- (UIButton *)makeKey:(NSString *)title output:(NSString *)output {
    JBKeyButton *b = [JBKeyButton buttonWithType:UIButtonTypeSystem];
    b.output = output ?: title;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
    b.backgroundColor = UIColor.whiteColor;
    b.layer.cornerRadius = 7;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.08;
    b.layer.shadowRadius = 1.5;
    b.layer.shadowOffset = CGSizeMake(0, 1);
    [b addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchUpInside];

    // Long press shows alternate characters.
    NSArray *alts = [self alternatesForKey:output];
    if (alts.count) {
        UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
        lp.minimumPressDuration = 0.28;
        [b addGestureRecognizer:lp];
    }
    [self.buttons addObject:b];
    return b;
}

- (NSArray *)alternatesForKey:(NSString *)key {
    NSDictionary *d = @{
        @"a": @[@"á",@"à",@"ả",@"ã",@"ạ",@"â",@"ă",@"ä"],
        @"e": @[@"é",@"è",@"ẻ",@"ẽ",@"ẹ",@"ê",@"ë"],
        @"i": @[@"í",@"ì",@"ỉ",@"ĩ",@"ị",@"ï"],
        @"o": @[@"ó",@"ò",@"ỏ",@"õ",@"ọ",@"ô",@"ơ",@"ö"],
        @"u": @[@"ú",@"ù",@"ủ",@"ũ",@"ụ",@"ư",@"ü"],
        @"y": @[@"ý",@"ỳ",@"ỷ",@"ỹ",@"ỵ",@"ÿ"],
        @".": @[@"!",@"?",@",",@"-",@"_",@"…"],
        @"'": @[@"\"",@"`",@"´"]
    };
    return d[key.lowercaseString] ?: @[];
}

- (void)reloadKeyboard {
    for (UIView *v in self.rootStack.arrangedSubviews) {
        [self.rootStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.buttons removeAllObjects];
    if (!self.buttons) self.buttons = [NSMutableArray array];

    NSArray *rows = @[
        @[@"q",@"w",@"e",@"r",@"t",@"y",@"u",@"i",@"o",@"p"],
        @[@"a",@"s",@"d",@"f",@"g",@"h",@"j",@"k",@"l"],
        @[@"z",@"x",@"c",@"v",@"b",@"n",@"m"]
    ];

    for (NSArray *keys in rows) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 5;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSString *k in keys) {
            NSString *title = self.shift ? k.uppercaseString : k;
            [row addArrangedSubview:[self makeKey:title output:title]];
        }
        [self.rootStack addArrangedSubview:row];
    }

    UIStackView *bottom = [[UIStackView alloc] init];
    bottom.axis = UILayoutConstraintAxisHorizontal;
    bottom.spacing = 5;
    bottom.distribution = UIStackViewDistributionFillProportionally;

    NSArray *special = @[
        @"⇧", @"123", @"🌐", @"space", @"⌫", @"↵", @"⌄"
    ];
    NSArray *widths = @[@0.8,@0.9,@0.9,@2.8,@0.9,@0.9,@0.8];
    for (NSInteger i=0;i<special.count;i++) {
        UIButton *b = [self makeKey:special[i] output:special[i]];
        [bottom addArrangedSubview:b];
        b.tag = 1000+i;
        CGFloat w = [widths[i] doubleValue];
        [b.widthAnchor constraintEqualToAnchor:bottom.widthAnchor multiplier:w/8.0].active = YES;
    }
    [self.rootStack addArrangedSubview:bottom];
    [self updateSuggestions];
}

- (void)keyDown:(JBKeyButton *)b {
    NSString *o = b.output;
    if ([o isEqualToString:@"⌫"]) {
        [self.delegate keyboardViewDidDeleteBackward:self];
        [self updateSuggestions];
        return;
    }
    if ([o isEqualToString:@"↵"]) {
        [self.delegate keyboardViewDidPressReturn:self];
        return;
    }
    if ([o isEqualToString:@"⌄"]) {
        [self.delegate keyboardViewDidDismiss:self];
        return;
    }
    if ([o isEqualToString:@"⇧"]) {
        self.shift = !self.shift;
        [self reloadKeyboard];
        return;
    }
    if ([o isEqualToString:@"123"]) {
        [self showSymbols];
        return;
    }
    if ([o isEqualToString:@"🌐"]) {
        self.vietnamese = !self.vietnamese;
        self.ime.language = self.vietnamese ? @"vi" : @"en";
        self.ime.telexEnabled = self.vietnamese;
        [self updateSuggestions];
        return;
    }
    if ([o isEqualToString:@"space"]) {
        [self.delegate keyboardView:self didInsertText:@" "];
        [self updateSuggestions];
        return;
    }
    [self.delegate keyboardView:self didInsertText:o];
    if (self.shift) {
        self.shift = NO;
        [self reloadKeyboard];
    } else {
        [self updateSuggestions];
    }
}

- (void)showSymbols {
    // Rebuild with a compact symbol layout; tapping 123 again returns to letters.
    for (UIView *v in self.rootStack.arrangedSubviews) {
        [self.rootStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    self.buttons = [NSMutableArray array];
    NSArray *rows = @[
        @[@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@"0"],
        @[@"@",@"#",@"$",@"&",@"*",@"(",@")",@"\"",@"'",@"!"],
        @[@"-",@"_",@"=",@"+",@"[",@"]",@"{",@"}",@";",@":"]
    ];
    for (NSArray *keys in rows) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 5;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSString *k in keys) [row addArrangedSubview:[self makeKey:k output:k]];
        [self.rootStack addArrangedSubview:row];
    }
    UIStackView *bottom = [[UIStackView alloc] init];
    bottom.axis = UILayoutConstraintAxisHorizontal;
    bottom.spacing = 5;
    bottom.distribution = UIStackViewDistributionFillEqually;
    [bottom addArrangedSubview:[self makeKey:@"ABC" output:@"ABC"]];
    [bottom addArrangedSubview:[self makeKey:@"space" output:@"space"]];
    [bottom addArrangedSubview:[self makeKey:@"⌫" output:@"⌫"]];
    [bottom addArrangedSubview:[self makeKey:@"↵" output:@"↵"]];
    [self.rootStack addArrangedSubview:bottom];

    for (UIButton *b in self.buttons) {
        if ([b.currentTitle isEqualToString:@"ABC"]) {
            [b addTarget:self action:@selector(backToLetters:) forControlEvents:UIControlEventTouchUpInside];
        }
    }
}

- (void)backToLetters:(UIButton *)sender {
    [self reloadKeyboard];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    JBKeyButton *b = (JBKeyButton *)g.view;
    NSArray *alts = [self alternatesForKey:b.output];
    if (!alts.count) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *x in alts) {
        [a addAction:[UIAlertAction actionWithTitle:x style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
            [self.delegate keyboardView:self didInsertText:action.title];
            [self updateSuggestions];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (vc) {
        a.popoverPresentationController.sourceView = b;
        a.popoverPresentationController.sourceRect = b.bounds;
        [vc presentViewController:a animated:YES completion:nil];
    }
}

- (void)updateSuggestions {
    for (UIView *v in self.suggestionScroll.subviews) [v removeFromSuperview];
    NSString *text = [self.delegate keyboardViewCurrentText:self] ?: @"";
    NSArray *s = [self.ime suggestionsForText:text];
    CGFloat x = 8;
    for (NSString *word in s) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:word forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15];
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            NSString *w = word;
            [self.delegate keyboardView:self didInsertText:w];
            [self updateSuggestions];
        }] forControlEvents:UIControlEventTouchUpInside];
        [b sizeToFit];
        b.frame = CGRectMake(x, 4, MAX(60, b.bounds.size.width + 22), 32);
        x += b.bounds.size.width + 5;
        [self.suggestionScroll addSubview:b];
    }
}

@end
