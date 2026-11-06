/*
 * MIDletRunner
 *
 * CLDC-compatible MIDlet launcher.
 * Manifest is extracted by the native MiniJVM ZIP reader.
 */

package javax.microedition.shell;

import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Display;

import java.util.Hashtable;

public final class MIDletRunner {

    public static void main(String[] args) {

        if (args == null || args.length < 2) {
            throw new RuntimeException(
                "MIDletRunner requires JAR path and manifest text"
            );
        }

        String jarPath = args[0];
        String manifestText = args[1];

        System.out.println(
            "[MIDletRunner] JAR: " + jarPath
        );

        try {

            Hashtable manifest = parseManifest(manifestText);

            String midletName = (String) manifest.get("MIDlet-Name");
            String midletVersion = (String) manifest.get("MIDlet-Version");

            System.out.println(
                "[MIDletRunner] Name: " + midletName
            );

            System.out.println(
                "[MIDletRunner] Version: " + midletVersion
            );

            String className = getMidletClassName(manifest);

            if (className == null || className.length() == 0) {
                throw new RuntimeException(
                    "MIDlet-1 entry or MIDlet class is missing"
                );
            }

            System.out.println(
                "[MIDletRunner] Entry class: " + className
            );

            /*
             * Make all manifest properties available to the MIDlet.
             */

            MIDlet.initProps(manifest);
            MIDlet.resetDestroyRequest();

            /*
             * FPS limit.
             */

            String fps = System.getProperty("j2me.fps.limit");

            if (fps != null) {
                try {
                    Canvas.setLimitFps(
                        Integer.parseInt(fps)
                    );
                } catch (Exception e) {
                    System.out.println(
                        "[MIDletRunner] Invalid FPS value: " + fps
                    );
                }
            }

            /*
             * Load MIDlet class.
             */

            System.out.println(
                "[MIDletRunner] Loading " + className
            );

            Class clazz = Class.forName(className);

            Object instance = clazz.newInstance();

            if (!(instance instanceof MIDlet)) {
                throw new RuntimeException(
                    "Class does not extend MIDlet: " + className
                );
            }

            MIDlet midlet = (MIDlet) instance;

            runLifecycle(midlet);

        } catch (Throwable error) {

            System.out.println(
                "[MIDletRunner] FATAL: "
                + error.getClass().getName()
                + ": "
                + error.getMessage()
            );

            error.printStackTrace();

            if (error instanceof RuntimeException) {
                throw (RuntimeException) error;
            }

            throw new RuntimeException(
                "MIDlet launch failed: " + error.getMessage()
            );
        }
    }

    /*
     * Parse the main manifest section.
     *
     * Uses only CLDC-compatible String, StringBuffer and Hashtable.
     * Handles CRLF and manifest continuation lines.
     */

    private static Hashtable parseManifest(String text) {

        Hashtable result = new Hashtable();

        if (text == null) {
            return result;
        }

        String currentKey = null;
        StringBuffer currentValue = new StringBuffer();

        int position = 0;
        int length = text.length();

        while (position <= length) {

            int lineEnd = text.indexOf('\n', position);

            if (lineEnd < 0) {
                lineEnd = length;
            }

            String line = text.substring(position, lineEnd);

            if (line.length() > 0
                && line.charAt(line.length() - 1) == '\r') {

                line = line.substring(0, line.length() - 1);
            }

            position = lineEnd + 1;

            /*
             * A blank line ends the main manifest section.
             */

            if (line.length() == 0) {

                if (currentKey != null) {
                    result.put(
                        currentKey,
                        currentValue.toString().trim()
                    );
                }

                break;
            }

            /*
             * Continuation line.
             */

            if (line.charAt(0) == ' ') {

                if (currentKey != null) {
                    currentValue.append(
                        line.substring(1)
                    );
                }

                continue;
            }

            /*
             * Store the previous attribute.
             */

            if (currentKey != null) {

                result.put(
                    currentKey,
                    currentValue.toString().trim()
                );
            }

            currentKey = null;
            currentValue = new StringBuffer();

            int colon = line.indexOf(':');

            if (colon > 0) {

                currentKey = line.substring(0, colon).trim();

                String value = line.substring(colon + 1);

                /*
                 * Manifest format normally has one space after colon.
                 */

                if (value.length() > 0
                    && value.charAt(0) == ' ') {

                    value = value.substring(1);
                }

                currentValue.append(value);
            }

            if (position > length) {
                break;
            }
        }

        /*
         * Store final attribute if there was no trailing blank line.
         */

        if (currentKey != null
            && result.get(currentKey) == null) {

            result.put(
                currentKey,
                currentValue.toString().trim()
            );
        }

        return result;
    }

    /*
     * Read MIDlet-1, then MIDlet-2, and so on.
     *
     * Standard manifest format:
     * MIDlet-1: Name, icon.png, package.MainClass
     */

    private static String getMidletClassName(Hashtable manifest) {

        for (int index = 1; index <= 9; index++) {

            String key = "MIDlet-" + index;

            String entry = (String) manifest.get(key);

            if (entry == null || entry.length() == 0) {
                continue;
            }

            System.out.println(
                "[MIDletRunner] " + key + ": " + entry
            );

            int firstComma = entry.indexOf(',');

            if (firstComma < 0) {
                return entry.trim();
            }

            int secondComma = entry.indexOf(
                ',',
                firstComma + 1
            );

            if (secondComma < 0) {
                continue;
            }

            String className = entry.substring(
                secondComma + 1
            ).trim();

            if (className.length() > 0) {
                return className;
            }
        }

        return null;
    }

    /*
     * Run the MIDlet lifecycle.
     */

    private static void runLifecycle(MIDlet midlet) {

        try {

            System.out.println(
                "[MIDletRunner] Calling startApp()"
            );

            midlet.callStartApp();

            System.out.println(
                "[MIDletRunner] startApp() returned"
            );

            Display display = Display.getDisplay(midlet);

            System.out.println(
                "[MIDletRunner] Starting Display event loop"
            );

            display.runEventLoop();

            if (!MIDlet.isDestroyRequested()) {
                midlet.callPauseApp();
            }

            System.out.println(
                "[MIDletRunner] Calling destroyApp(true)"
            );

            midlet.callDestroyApp(true);

            System.out.println(
                "[MIDletRunner] MIDlet stopped normally"
            );

        } catch (Throwable error) {

            System.out.println(
                "[MIDletRunner] LIFECYCLE ERROR: "
                + error.getClass().getName()
                + ": "
                + error.getMessage()
            );

            error.printStackTrace();

            if (error instanceof RuntimeException) {
                throw (RuntimeException) error;
            }

            throw new RuntimeException(
                "MIDlet lifecycle failed: " + error.getMessage()
            );
        }
    }
}
