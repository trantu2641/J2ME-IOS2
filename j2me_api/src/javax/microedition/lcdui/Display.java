package javax.microedition.lcdui;

import javax.microedition.lcdui.event.EventQueue;
import javax.microedition.lcdui.event.Event;
import javax.microedition.lcdui.event.CanvasEvent;
import javax.microedition.lcdui.event.RunnableEvent;
import javax.microedition.midlet.MIDlet;

/**
 * J2ME Display — manages the current Displayable and render loop.
 */
public class Display {

    private static Display instance;
    private Displayable current;
    private volatile boolean running;
    private static final EventQueue eventQueue = new EventQueue();
    private MIDlet currentMIDlet;

    private static int screenWidth = 240;
    private static int screenHeight = 320;

    static {
        String w = System.getProperty("j2me.screen.width");
        String h = System.getProperty("j2me.screen.height");

        if (w != null) {
            try {
                screenWidth = Integer.parseInt(w);
            } catch (Exception e) {
            }
        }

        if (h != null) {
            try {
                screenHeight = Integer.parseInt(h);
            } catch (Exception e) {
            }
        }
    }

    private Display() {
    }

    public static Display getDisplay(MIDlet midlet) {
        if (instance == null) {
            instance = new Display();
        }

        if (midlet != null) {
            instance.currentMIDlet = midlet;
        }

        return instance;
    }

    public void setCurrent(Displayable d) {
        if (d == null) {
            return;
        }

        Displayable old = current;
        current = d;

        d.width = screenWidth;
        d.height = screenHeight;

        if (d instanceof Canvas) {

            java.util.ArrayList<Command> cmds = d.getCommands();

            NativeBridge.formBegin("", 0);

            for (int i = 0; i < cmds.size(); i++) {
                Command c = cmds.get(i);

                NativeBridge.formAddCommand(
                    c.getLabel(),
                    c.getCommandType(),
                    c.getPriority(),
                    i
                );
            }

            NativeBridge.showCanvas();

            Canvas canvas = (Canvas) d;

            canvas.initContext();
            canvas.repaintPending = true;
            canvas.showNotify();

        } else if (d instanceof Form) {

            ((Form) d).showNative();

        } else if (d instanceof List) {

            ((List) d).showNative();

        } else if (d instanceof Alert) {

            ((Alert) d).showNative();
        }

        if (old instanceof Canvas && old != d) {
            ((Canvas) old).hideNotify();
            ((Canvas) old).destroyContext();
        }
    }

    public void setCurrent(Alert alert, Displayable nextDisplayable) {
        alert.nextDisplayable = nextDisplayable;
        setCurrent(alert);
    }

    public Displayable getCurrent() {
        return current;
    }

    public void callSerially(Runnable r) {
        if (r != null) {
            Display.eventQueue.postEvent(
                RunnableEvent.getInstance(r)
            );
        }
    }

    public static void postEvent(Event event) {
        Display.eventQueue.postEvent(event);
    }

    // --- Display capabilities ---

    public boolean isColor() {
        return true;
    }

    public int numColors() {
        return 16777216;
    }

    public int numAlphaLevels() {
        return 256;
    }

    public boolean flashBacklight(int duration) {
        return false;
    }

    public int getBestImageHeight(int imageType) {
        return 0;
    }

    public int getBestImageWidth(int imageType) {
        return 0;
    }

    public int getBorderStyle(boolean highlighted) {
        return highlighted ? Graphics.SOLID : Graphics.DOTTED;
    }

    public int getColor(int colorSpecifier) {
        return 0;
    }

    // --- Vibration ---

    public boolean vibrate(int duration) {
        if (duration < 0) {
            throw new IllegalArgumentException();
        }

        NativeBridge.vibrate(duration);
        return true;
    }

    // --- Screen size ---

    public static int getScreenWidth() {
        return screenWidth;
    }

    public static int getScreenHeight() {
        return screenHeight;
    }

    // --- Performance diagnostics ---

    private static final long PERF_INTERVAL_MS = 5000;

    /**
     * Print event-loop performance once every five seconds.
     * This does not throttle or sleep the game.
     */
    private void printPerformance(
        long startTime,
        long loops,
        long inputEvents,
        long displayPaints,
        long idleLoops
    ) {

        long now = System.currentTimeMillis();
        long elapsed = now - startTime;

        if (elapsed < PERF_INTERVAL_MS) {
            return;
        }

        if (elapsed <= 0) {
            elapsed = 1;
        }

        long loopsPerSecond =
            loops * 1000L / elapsed;

        long inputPerSecond =
            inputEvents * 1000L / elapsed;

        long paintsPerSecond =
            displayPaints * 1000L / elapsed;

        long idlePerSecond =
            idleLoops * 1000L / elapsed;

        System.out.println(
            "[Display Perf] loop/s=" + loopsPerSecond
            + " input/s=" + inputPerSecond
            + " paint/s=" + paintsPerSecond
            + " idle/s=" + idlePerSecond
        );

        // Canvas has its own measurements for paint and flushBuffer.
        Canvas.printPerformanceStats();
    }

    // --- Render loop ---

    public void runEventLoop() {

        running = true;

        eventQueue.startProcessing();

        System.out.println(
            "[Display] Event loop started ("
            + screenWidth + "x" + screenHeight + ")"
        );

        long perfStart = System.currentTimeMillis();

        long loopCount = 0;
        long nativeEventCount = 0;
        long displayPaintCount = 0;
        long idleLoopCount = 0;

        while (running && !MIDlet.isDestroyRequested()) {

            loopCount++;

            boolean receivedInput = false;
            boolean performedPaint = false;

            // 0. Check if native side requested stop.
            if (NativeBridge.isStopRequested()) {

                System.out.println(
                    "[Display] Native stop requested, exiting event loop"
                );

                MIDlet.requestDestroy();
                break;
            }

            // 1. Poll native input events.
            int[] nativeEvent;

            while ((nativeEvent = NativeBridge.pollInputEvent()) != null) {

                receivedInput = true;
                nativeEventCount++;

                int type = nativeEvent[0];

                if (type <= 2 && current instanceof Canvas) {

                    Canvas c = (Canvas) current;

                    int ceType =
                        type == 0 ? CanvasEvent.POINTER_PRESSED :
                        type == 1 ? CanvasEvent.POINTER_DRAGGED :
                                    CanvasEvent.POINTER_RELEASED;

                    Display.eventQueue.postEvent(
                        CanvasEvent.getInstance(
                            c,
                            ceType,
                            0,
                            (float) nativeEvent[1],
                            (float) nativeEvent[2]
                        )
                    );

                } else if (type >= 3 && type <= 5
                        && current instanceof Canvas) {

                    Canvas c = (Canvas) current;

                    int ceType =
                        type == 3 ? CanvasEvent.KEY_PRESSED :
                        type == 4 ? CanvasEvent.KEY_RELEASED :
                                    CanvasEvent.KEY_REPEATED;

                    Display.eventQueue.postEvent(
                        CanvasEvent.getInstance(
                            c,
                            ceType,
                            nativeEvent[3]
                        )
                    );

                } else if (type == 10) {

                    int cmdId = nativeEvent[3];

                    if (current != null) {
                        current.fireCommandAction(cmdId);
                    }

                } else if (type == 11 && current instanceof List) {

                    ((List) current).handleListSelect(nativeEvent[3]);

                } else if (type == 12 && current instanceof Alert) {

                    Alert alert = (Alert) current;

                    if (alert.nextDisplayable != null) {
                        setCurrent(alert.nextDisplayable);
                    }
                }
            }

            // 2. Handle resumeRequest.
            if (MIDlet.isResumeRequested() && currentMIDlet != null) {

                try {
                    currentMIDlet.callStartApp();

                } catch (Exception e) {

                    System.out.println(
                        "[Display] resumeRequest startApp error: "
                        + e.getMessage()
                    );
                }
            }

            // 3. Repaint if needed.
            if (current instanceof Canvas) {

                Canvas canvas = (Canvas) current;

                if (canvas.repaintPending) {
                    canvas.doPaint();
                    displayPaintCount++;
                    performedPaint = true;
                }
            }

            if (!receivedInput && !performedPaint) {
                idleLoopCount++;
            }

            // 4. Performance report.
            long now = System.currentTimeMillis();

            if (now - perfStart >= PERF_INTERVAL_MS) {

                printPerformance(
                    perfStart,
                    loopCount,
                    nativeEventCount,
                    displayPaintCount,
                    idleLoopCount
                );

                perfStart = now;

                loopCount = 0;
                nativeEventCount = 0;
                displayPaintCount = 0;
                idleLoopCount = 0;
            }

            // Preserve the original input polling interval.
            try {

                for (
                    int i = 0;
                    i < 4 && !MIDlet.isDestroyRequested();
                    i++
                ) {
                    Thread.sleep(4);
                }

            } catch (InterruptedException e) {
                break;
            }
        }

        eventQueue.stopProcessing();

        if (current instanceof Canvas) {
            ((Canvas) current).hideNotify();
            ((Canvas) current).destroyContext();
        }

        current = null;
        currentMIDlet = null;
        instance = null;

        System.out.println("[Display] Event loop stopped");
    }

    public void stopEventLoop() {
        running = false;
    }
}
