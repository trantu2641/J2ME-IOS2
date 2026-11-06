/*
 * MIDletRunner - Java MIDlet launcher for iOS / MiniJVM.
 * Reads MIDlet metadata, loads the entry class and executes the MIDlet lifecycle.
 */

package javax.microedition.shell;

import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Display;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;

import java.util.HashMap;
import java.util.Map;

import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public class MIDletRunner {

    public static void main(String[] args) {

        if (args == null || args.length < 1) {
            throw new RuntimeException(
                "Usage: MIDletRunner <midlet.jar> [ClassName]"
            );
        }

        String jarPath = args[0];

        String classNameOverride =
            (args.length > 1) ? args[1] : null;

        System.out.println(
            "[MIDletRunner] Loading MIDlet JAR: " + jarPath
        );

        try {

            Map<String, String> manifestAttrs =
                readManifest(jarPath);

            String midletName =
                manifestAttrs.get("MIDlet-Name");

            String midletVersion =
                manifestAttrs.get("MIDlet-Version");

            System.out.println(
                "[MIDletRunner] MIDlet-Name: " + midletName
            );

            System.out.println(
                "[MIDletRunner] MIDlet-Version: " + midletVersion
            );

            String className =
                (classNameOverride != null && !classNameOverride.isEmpty())
                ? classNameOverride
                : parseMIDletClassName(manifestAttrs);

            if (className == null || className.trim().isEmpty()) {
                throw new RuntimeException(
                    "No MIDlet class found in META-INF/MANIFEST.MF (MIDlet-1)"
                );
            }

            System.out.println(
                "[MIDletRunner] MIDlet class: " + className
            );

            MIDlet.initProps(manifestAttrs);
            MIDlet.resetDestroyRequest();

            String fpsStr =
                System.getProperty("j2me.fps.limit");

            if (fpsStr != null) {
                try {
                    Canvas.setLimitFps(Integer.parseInt(fpsStr));
                } catch (NumberFormatException ignored) {
                    System.out.println(
                        "[MIDletRunner] Invalid FPS property: " + fpsStr
                    );
                }
            }

            System.out.println(
                "[MIDletRunner] Loading class: " + className
            );

            Class<?> clazz = Class.forName(className);

            Object instance = clazz.newInstance();

            if (!(instance instanceof MIDlet)) {
                throw new RuntimeException(
                    "Entry class does not extend javax.microedition.midlet.MIDlet: "
                    + className
                );
            }

            runLifecycle((MIDlet) instance);

        } catch (Throwable error) {

            System.out.println(
                "[MIDletRunner] FATAL: "
                + error.getClass().getName()
                + ": "
                + error.getMessage()
            );

            error.printStackTrace();

            // Propagate the failure to MiniJVM.
            // The old implementation swallowed exceptions and returned normally.
            if (error instanceof RuntimeException) {
                throw (RuntimeException) error;
            }

            throw new RuntimeException(
                "MIDlet launch failed: " + error.getMessage()
            );
        }
    }

    private static Map<String, String> readManifest(
        String jarPath
    ) throws Exception {

        Map<String, String> result =
            new HashMap<String, String>();

        ZipFile zipFile = new ZipFile(jarPath);

        try {

            ZipEntry entry =
                zipFile.getEntry("META-INF/MANIFEST.MF");

            if (entry == null) {
                throw new RuntimeException(
                    "JAR does not contain META-INF/MANIFEST.MF"
                );
            }

            InputStream input =
                zipFile.getInputStream(entry);

            BufferedReader reader =
                new BufferedReader(
                    new InputStreamReader(input, "UTF-8")
                );

            String lastKey = null;
            String line;

            while ((line = reader.readLine()) != null) {

                if (line.length() == 0) {
                    continue;
                }

                // Manifest continuation line.
                if (line.charAt(0) == ' ' && lastKey != null) {

                    String previous = result.get(lastKey);

                    result.put(
                        lastKey,
                        (previous == null ? "" : previous)
                        + line.substring(1)
                    );

                    continue;
                }

                int colon = line.indexOf(':');

                if (colon > 0) {

                    String key =
                        line.substring(0, colon).trim();

                    String value =
                        line.substring(colon + 1).trim();

                    result.put(key, value);

                    lastKey = key;
                }
            }

            reader.close();

        } finally {
            zipFile.close();
        }

        return result;
    }

    private static String parseMIDletClassName(
        Map<String, String> attrs
    ) {

        String entry = attrs.get("MIDlet-1");

        if (entry == null) {

            for (Map.Entry<String, String> item : attrs.entrySet()) {

                String key = item.getKey();

                if (key.startsWith("MIDlet-")
                    && key.length() > 7
                    && !key.equals("MIDlet-Name")
                    && !key.equals("MIDlet-Version")
                    && !key.equals("MIDlet-Vendor")) {

                    entry = item.getValue();
                    break;
                }
            }
        }

        if (entry == null) {
            return null;
        }

        System.out.println(
            "[MIDletRunner] MIDlet entry: " + entry
        );

        String[] parts = entry.split(",", -1);

        if (parts.length >= 3) {
            return parts[2].trim();
        }

        if (parts.length == 1) {
            return parts[0].trim();
        }

        return null;
    }

    private static void runLifecycle(MIDlet midlet) {

        try {

            System.out.println(
                "[MIDletRunner] >>> startApp()"
            );

            midlet.callStartApp();

            System.out.println(
                "[MIDletRunner] <<< startApp() returned"
            );

            Display display =
                Display.getDisplay(midlet);

            display.runEventLoop();

            if (!MIDlet.isDestroyRequested()) {

                System.out.println(
                    "[MIDletRunner] >>> pauseApp()"
                );

                midlet.callPauseApp();
            }

            System.out.println(
                "[MIDletRunner] >>> destroyApp(true)"
            );

            midlet.callDestroyApp(true);

            System.out.println(
                "[MIDletRunner] MIDlet lifecycle complete"
            );

        } catch (Throwable error) {

            System.out.println(
                "[MIDletRunner] LIFECYCLE FATAL: "
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
