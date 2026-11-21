#import <UIKit/UIKit.h>
#import "JBKeyboardManager.h"

/*
 Add this small adapter to the existing JarBox view controller.
 The JAR/runtime code remains unchanged for now.

 Example:
   JBKeyboardInstall(self.view, self);
   [JBKeyboardManager.shared show];

 Replace the four blocks below with calls into your existing J2ME
 TextField/TextBox bridge when you wire the runtime.
*/
static inline void JBKeyboardInstall(UIView *hostView,
                                     UIViewController *controller,
                                     NSString *(^ _Nullable currentText)(void),
                                     void (^ _Nullable insertText)(NSString *),
                                     void (^ _Nullable deleteBackward)(void),
                                     void (^ _Nullable returnPressed)(void)) {
    JBKeyboardManager *m = [JBKeyboardManager shared];
    m.hostViewController = controller;
    m.currentTextProvider = currentText;
    m.insertTextHandler = insertText;
    m.deleteBackwardHandler = deleteBackward;
    m.returnHandler = returnPressed;
    [m attachToView:hostView];
}
