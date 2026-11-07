J2ME iOS fixes (iOS 16.4+)
==========================

This package contains two complete replacement source files and one verified
patch for GameViewController.swift. It does NOT edit GitHub automatically.

FAST APPLY ON LINUX
-------------------
1) Extract this ZIP.
2) Open a terminal in the extracted J2ME-iOS-fixes folder.
3) Run the script with the path to your cloned repository:

   ./apply.sh /path/to/J2ME-IOS2

The script copies the two complete files and applies the keyboard patch. It
checks the patch before applying it, so it stops rather than partially applying
if the GameViewController file does not match the expected version.

Then review and push:

   cd /path/to/J2ME-IOS2
   git diff --stat
   git add J2MEEmulator/UI/EmulatorView.swift \
           J2MEEmulator/UI/GameViewController.swift \
           j2me_api/src/javax/microedition/lcdui/Displayable.java
   git commit -m "Fix J2ME keyboard and screen scaling"
   git push origin main

WHAT IS FIXED
-------------
1) System keyboard Backspace
   The hidden keyboard responder is changed to a real UITextField. An
   invisible zero-width sentinel keeps Backspace enabled, deleteBackward()
   sends MIDP Canvas.KEY_CLEAR (-8), and the sentinel is restored so repeated
   Backspace works. Text is intercepted and sent as UTF-16 values to Java.
   Key release is delayed by 50 ms so MIDlets polling on a separate game thread
   do not miss a very short key pulse.

2) Resolution / DPI behavior
   EmulatorView keeps its UIImageView constrained to the full game viewport
   and uses uniform Aspect Fit. The whole framebuffer stays inside the screen,
   with no crop or stretch. Touches in the black letterbox areas are ignored;
   touches on the image are mapped back to the selected J2ME logical size.

   The key fix is Displayable's constructor. The native bridge already sets
   j2me.screen.width and j2me.screen.height before starting the MIDlet, but
   Displayable previously initialized every new screen to 240x320. Games such
   as Avatar 258 read getWidth()/getHeight() inside the Canvas constructor and
   cache those values before Display.setCurrent() changes them. The constructor
   now reads the configured virtual resolution immediately, so a custom size
   such as 500x600 is visible to the game from its first instruction.

3) Other JAR compatibility
   This package does not claim to make every JAR run. Different games can call
   missing MIDP/vendor methods, rely on unsupported native implementations, or
   use bytecode/runtime features that need separate handling. The two Avatar
   JARs inspected have most referenced Java/J2ME classes available in the
   bundled runtime/API, so their actual launch exception or NoSuchMethodError
   is needed before changing more runtime code.

For a JAR that still fails, open its launch error and use Copy Log. Send the
log from the first exception down through its Caused by lines, along with the
JAR filename. That identifies the exact class or method to implement next.
