/*
 * MIDlet
 *
 * CLDC-compatible MIDlet base class.
 */

package javax.microedition.midlet;

import javax.microedition.io.ConnectionNotFoundException;
import java.util.Hashtable;

public abstract class MIDlet {

    private static Hashtable properties;

    private static volatile boolean destroyRequested = false;
    private static volatile boolean resumeRequested = false;
    private static volatile boolean paused = false;

    protected MIDlet() {
    }

    /*
     * Initialize application properties from MANIFEST.MF.
     */

    public static void initProps(Hashtable values) {
        properties = values;
    }

    /*
     * Read a MIDlet manifest property.
     */

    public String getAppProperty(String key) {

        if (properties == null || key == null) {
            return null;
        }

        Object value = properties.get(key);

        if (value == null) {
            return null;
        }

        return value.toString();
    }

    public final void notifyPaused() {
        paused = true;
    }

    public final void notifyDestroyed() {
        destroyRequested = true;
    }

    public final void resumeRequest() {

        if (paused) {
            paused = false;
            resumeRequested = true;
        }
    }

    public static boolean isDestroyRequested() {
        return destroyRequested;
    }

    public static void requestDestroy() {
        destroyRequested = true;
    }

    public static boolean isResumeRequested() {

        if (resumeRequested) {
            resumeRequested = false;
            return true;
        }

        return false;
    }

    public static boolean isPaused() {
        return paused;
    }

    public static void resetDestroyRequest() {
        destroyRequested = false;
        paused = false;
        resumeRequested = false;
    }

    /*
     * MIDlet lifecycle methods.
     */

    protected abstract void startApp()
        throws MIDletStateChangeException;

    protected abstract void pauseApp();

    protected abstract void destroyApp(boolean unconditional)
        throws MIDletStateChangeException;

    /*
     * Internal lifecycle dispatch.
     */

    public final void callStartApp()
        throws MIDletStateChangeException {

        paused = false;
        startApp();
    }

    public final void callPauseApp() {
        pauseApp();
    }

    public final void callDestroyApp(boolean unconditional)
        throws MIDletStateChangeException {

        destroyApp(unconditional);
    }

    /*
     * Platform request.
     */

    public boolean platformRequest(String url)
        throws ConnectionNotFoundException {

        if (url == null || url.length() == 0) {
            return false;
        }

        System.out.println(
            "[MIDlet] platformRequest: " + url
        );

        javax.microedition.lcdui.NativeBridge.platformRequest(url);

        return false;
    }

    /*
     * iOS runtime permission compatibility.
     */

    public final int checkPermission(String permission) {
        return 1;
    }
}
