
package javax.microedition.lcdui;

/**
 * J2ME Canvas — the main class for custom rendering in MIDlets.
 * Uses offscreen CGBitmapContext via NativeBridge for double-buffered rendering.
 *
 * Rendering optimizations:
 * - Coalesce repeated repaint requests.
 * - Apply FPS limiting to actual rendering, not repaint requests.
 * - Apply the same frame limiter to serviceRepaints and flushBuffer.
 * - Prevent recursive painting.
 * - Keep a maximum of 60 screen updates per second when FPS is unlimited.
 */
public abstract class Canvas extends Displayable {

    public static final int UP = 1;
    public static final int DOWN = 6;
    public static final int LEFT = 2;
    public static final int RIGHT = 5;
    public static final int FIRE = 8;
    public static final int GAME_A = 9;
    public static final int GAME_B = 10;
    public static final int GAME_C = 11;
    public static final int GAME_D = 12;

    public static final int KEY_UP = -1;
    public static final int KEY_DOWN = -2;
    public static final int KEY_LEFT = -3;
    public static final int KEY_RIGHT = -4;
    public static final int KEY_FIRE = -5;
    public static final int KEY_SOFT_LEFT = -6;
    public static final int KEY_SOFT_RIGHT = -7;
    public static final int KEY_CLEAR = -8;
    public static final int KEY_SEND = -10;
    public static final int KEY_END = -11;

    public static final int KEY_NUM0 = 48;
    public static final int KEY_NUM1 = 49;
    public static final int KEY_NUM2 = 50;
    public static final int KEY_NUM3 = 51;
    public static final int KEY_NUM4 = 52;
    public static final int KEY_NUM5 = 53;
    public static final int KEY_NUM6 = 54;
    public static final int KEY_NUM7 = 55;
    public static final int KEY_NUM8 = 56;
    public static final int KEY_NUM9 = 57;
    public static final int KEY_STAR = 42;
    public static final int KEY_POUND = 35;

    protected Canvas() {
    }

    protected Canvas(boolean fullScreen) {
        this.fullScreen = fullScreen;
    }

    private long nativeContext;
    private Graphics graphics;

    public volatile boolean repaintPending = true;

    private boolean fullScreen = false;

    private int clipX, clipY, clipW, clipH;
    private boolean fullRepaint = true;

    private final Object paintLock = new Object();
    private final Object repaintLock = new Object();

    private boolean painting = false;

    // ============================================================
    // FPS limiter
    // ============================================================

    private static final int MAX_DISPLAY_FPS = 60;

    private static final Object frameRateLock = new Object();

    // 0 means automatic display refresh limit.
    private static volatile int fpsLimit = 0;

    private static long lastFrameTime = 0;

    public static void setLimitFps(int fps) {

        synchronized (frameRateLock) {

            if (fps < 0) {
                fps = 0;
            }

            if (fps > MAX_DISPLAY_FPS) {
                fps = MAX_DISPLAY_FPS;
            }

            fpsLimit = fps;

            // Reset frame timing after changing the setting.
            lastFrameTime = 0;
        }
    }

    public static int getLimitFps() {
        return fpsLimit;
    }

    /**
     * Limit actual screen rendering.
     *
     * This method must only be called when a frame is going to be rendered.
     * repaint() itself must never sleep because it can be called hundreds
     * of times per second by a game animation thread.
     *
     * FPS = 0 means automatic maximum display refresh (60 FPS).
     */
    private void limitFps() {

        synchronized (frameRateLock) {

            int configuredFps = fpsLimit;

            int targetFps;

            if (configuredFps <= 0) {
                targetFps = MAX_DISPLAY_FPS;
            } else {
                targetFps = Math.min(
                    configuredFps,
                    MAX_DISPLAY_FPS
                );
            }

            if (targetFps <= 0) {
                return;
            }

            // Round up to avoid exceeding the selected frame rate.
            long frameIntervalMs =
                (1000L + targetFps - 1L) / targetFps;

            long now = System.currentTimeMillis();

            if (lastFrameTime > 0) {

                long elapsed = now - lastFrameTime;

                long remaining = frameIntervalMs - elapsed;

                if (remaining > 0) {

                    try {

                        Thread.sleep(remaining);

                    } catch (InterruptedException e) {

                        Thread.currentThread().interrupt();
                    }
                }
            }

            // Use the actual completion time to avoid accumulating
            // timing errors or producing catch-up frame bursts.
            lastFrameTime = System.currentTimeMillis();
        }
    }

    // ============================================================
    // Performance counters
    // ============================================================

    private static long perfRepaintCount = 0;
    private static long perfPaintCount = 0;
    private static long perfPaintTotalMs = 0;
    private static long perfPaintMaxMs = 0;

    private static long perfFlushCount = 0;
    private static long perfFlushTotalMs = 0;
    private static long perfFlushMaxMs = 0;

    private static long perfWindowStart = System.currentTimeMillis();

    private static synchronized void recordRepaint() {
        perfRepaintCount++;
    }

    private static synchronized void recordPaint(long elapsedMs) {

        perfPaintCount++;
        perfPaintTotalMs += elapsedMs;

        if (elapsedMs > perfPaintMaxMs) {
            perfPaintMaxMs = elapsedMs;
        }
    }

    private static synchronized void recordFlush(long elapsedMs) {

        perfFlushCount++;
        perfFlushTotalMs += elapsedMs;

        if (elapsedMs > perfFlushMaxMs) {
            perfFlushMaxMs = elapsedMs;
        }
    }

    /**
     * Called by Display every five seconds.
     * Reports approximate render activity without changing frame timing.
     */
    public static synchronized void printPerformanceStats() {

        long now = System.currentTimeMillis();
        long elapsed = now - perfWindowStart;

        if (elapsed <= 0) {
            elapsed = 1;
        }

        long repaintRate =
            perfRepaintCount * 1000L / elapsed;

        long paintRate =
            perfPaintCount * 1000L / elapsed;

        long flushRate =
            perfFlushCount * 1000L / elapsed;

        long averagePaintMs =
            perfPaintCount > 0
            ? perfPaintTotalMs / perfPaintCount
            : 0;

        long averageFlushMs =
            perfFlushCount > 0
            ? perfFlushTotalMs / perfFlushCount
            : 0;

        System.out.println(
            "[Canvas Perf]"
            + " repaint/s=" + repaintRate
            + " paint/s=" + paintRate
            + " avgPaintMs=" + averagePaintMs
            + " maxPaintMs=" + perfPaintMaxMs
            + " flushBuffer/s=" + flushRate
            + " avgFlushMs=" + averageFlushMs
            + " maxFlushMs=" + perfFlushMaxMs
        );

        perfRepaintCount = 0;
        perfPaintCount = 0;
        perfPaintTotalMs = 0;
        perfPaintMaxMs = 0;

        perfFlushCount = 0;
        perfFlushTotalMs = 0;
        perfFlushMaxMs = 0;

        perfWindowStart = now;
    }

    protected abstract void paint(Graphics g);

    // ============================================================
    // Repaint
    // ============================================================

    public void repaint() {
        repaint(0, 0, width, height);
    }

    public void repaint(int x, int y, int w, int h) {

        recordRepaint();

        // Do not sleep here.
        // Multiple requests are combined into one pending repaint.
        synchronized (repaintLock) {

            if (!repaintPending) {

                clipX = x;
                clipY = y;
                clipW = w;
                clipH = h;

                fullRepaint = (
                    x == 0
                    && y == 0
                    && w >= width
                    && h >= height
                );

            } else {

                int newRight = Math.max(
                    clipX + clipW,
                    x + w
                );

                int newBottom = Math.max(
                    clipY + clipH,
                    y + h
                );

                clipX = Math.min(clipX, x);
                clipY = Math.min(clipY, y);

                clipW = newRight - clipX;
                clipH = newBottom - clipY;

                if (
                    clipX <= 0
                    && clipY <= 0
                    && clipW >= width
                    && clipH >= height
                ) {
                    fullRepaint = true;
                }
            }

            repaintPending = true;
        }
    }

    /**
     * Process pending repaint immediately, subject to the common FPS limit.
     *
     * Repeated serviceRepaints() calls cannot bypass the frame limiter.
     */
    public void serviceRepaints() {

        if (repaintPending) {
            doPaint();
        }
    }

    public void setFullScreenMode(boolean mode) {
        this.fullScreen = mode;
    }

    // ============================================================
    // Context
    // ============================================================

    void initContext() {

        if (nativeContext == 0) {

            nativeContext = NativeBridge.createContext(
                width,
                height
            );

            graphics = new Graphics(
                nativeContext,
                width,
                height
            );
        }
    }

    // ============================================================
    // GameCanvas flushBuffer
    // ============================================================

    public void flushBuffer(
        Image image,
        int x,
        int y,
        int width,
        int height
    ) {

        if (
            width <= 0
            || height <= 0
            || x + width < 0
            || y + height < 0
            || x >= this.width
            || y >= this.height
        ) {
            return;
        }

        long startTime = 0;

        try {

            synchronized (paintLock) {

                // Share the same limiter with Canvas.doPaint().
                limitFps();

                startTime = System.currentTimeMillis();

                if (nativeContext == 0) {
                    initContext();
                }

                graphics.reset(
                    0,
                    0,
                    this.width,
                    this.height
                );

                graphics.drawImage(
                    image,
                    0,
                    0,
                    Graphics.LEFT | Graphics.TOP
                );

                NativeBridge.flushToScreen(nativeContext);
            }

        } finally {

            if (startTime > 0) {
                recordFlush(
                    System.currentTimeMillis() - startTime
                );
            }
        }
    }

    // ExtendedImage (Siemens)
    public void flushBuffer(
        Image image,
        int x,
        int y
    ) {

        long startTime = 0;

        try {

            synchronized (paintLock) {

                // Share the same limiter with Canvas.doPaint().
                limitFps();

                startTime = System.currentTimeMillis();

                if (nativeContext == 0) {
                    initContext();
                }

                graphics.reset(
                    0,
                    0,
                    this.width,
                    this.height
                );

                graphics.drawImage(
                    image,
                    x,
                    y,
                    Graphics.LEFT | Graphics.TOP
                );

                NativeBridge.flushToScreen(nativeContext);
            }

        } finally {

            if (startTime > 0) {
                recordFlush(
                    System.currentTimeMillis() - startTime
                );
            }
        }
    }

    // ============================================================
    // Paint
    // ============================================================

    public void doPaint() {

        long startTime = 0;

        synchronized (paintLock) {

            // Avoid nested paint calls.
            if (painting) {
                return;
            }

            // No pending work means there is no reason to render.
            if (!repaintPending) {
                return;
            }

            painting = true;

            try {

                // Wait before consuming the pending repaint.
                // Requests arriving during this wait are coalesced.
                limitFps();

                int paintX;
                int paintY;
                int paintW;
                int paintH;

                synchronized (repaintLock) {

                    // Another rendering call may have consumed it.
                    if (!repaintPending) {
                        return;
                    }

                    paintX = clipX;
                    paintY = clipY;
                    paintW = clipW;
                    paintH = clipH;

                    // Use a full repaint if the clip is not initialized.
                    if (paintW <= 0 || paintH <= 0) {

                        paintX = 0;
                        paintY = 0;
                        paintW = width;
                        paintH = height;

                        fullRepaint = true;
                    }

                    // Consume this batch of repaint requests.
                    // New requests arriving during paint() will set it again.
                    repaintPending = false;

                    // Prepare a default full clip for the next repaint.
                    clipX = 0;
                    clipY = 0;
                    clipW = width;
                    clipH = height;

                    fullRepaint = true;
                }

                startTime = System.currentTimeMillis();

                if (nativeContext == 0) {
                    initContext();
                }

                graphics.reset(
                    paintX,
                    paintY,
                    paintW,
                    paintH
                );

                paint(graphics);

                NativeBridge.flushToScreen(nativeContext);

            } finally {

                painting = false;

                if (startTime > 0) {

                    recordPaint(
                        System.currentTimeMillis() - startTime
                    );
                }
            }
        }
    }

    // ============================================================
    // Destroy
    // ============================================================

    void destroyContext() {

        synchronized (paintLock) {

            if (nativeContext != 0) {

                NativeBridge.destroyContext(nativeContext);

                nativeContext = 0;
                graphics = null;
            }

            painting = false;
        }

        synchronized (repaintLock) {

            repaintPending = false;

            clipX = 0;
            clipY = 0;
            clipW = width;
            clipH = height;

            fullRepaint = true;
        }
    }

    // ============================================================
    // Capabilities
    // ============================================================

    public boolean hasPointerEvents() {
        return true;
    }

    public boolean hasPointerMotionEvents() {
        return true;
    }

    public boolean hasRepeatEvents() {
        return true;
    }

    public boolean isDoubleBuffered() {
        return true;
    }

    // ============================================================
    // Input
    // ============================================================

    protected void keyPressed(int keyCode) {
    }

    protected void keyReleased(int keyCode) {
    }

    protected void keyRepeated(int keyCode) {
    }

    protected void pointerPressed(int x, int y) {
    }

    protected void pointerReleased(int x, int y) {
    }

    protected void pointerDragged(int x, int y) {
    }

    protected void showNotify() {
    }

    protected void hideNotify() {
    }

    public void doKeyPressed(int keyCode) {
        postKeyPressed(keyCode);
    }

    public void doKeyReleased(int keyCode) {
        postKeyReleased(keyCode);
    }

    public void doKeyRepeated(int keyCode) {
        postKeyRepeated(keyCode);
    }

    public void postKeyPressed(int keyCode) {
        keyPressed(keyCode);
    }

    public void postKeyReleased(int keyCode) {
        keyReleased(keyCode);
    }

    public void postKeyRepeated(int keyCode) {
        keyRepeated(keyCode);
    }

    public void pointerPressed(
        int pointer,
        float x,
        float y
    ) {
        pointerPressed(
            Math.round(x),
            Math.round(y)
        );
    }

    public void pointerDragged(
        int pointer,
        float x,
        float y
    ) {
        pointerDragged(
            Math.round(x),
            Math.round(y)
        );
    }

    public void pointerReleased(
        int pointer,
        float x,
        float y
    ) {
        pointerReleased(
            Math.round(x),
            Math.round(y)
        );
    }

    public void doShowNotify() {
        showNotify();
    }

    public void doHideNotify() {
        hideNotify();
    }

    public void doSizeChanged(int w, int h) {
        sizeChanged(w, h);
    }

    // ============================================================
    // Event dispatch
    // ============================================================

    public void dispatchPointerEvent(
        int type,
        int x,
        int y
    ) {

        switch (type) {

            case 0:
                pointerPressed(x, y);
                break;

            case 1:
                pointerDragged(x, y);
                break;

            case 2:
                pointerReleased(x, y);
                break;
        }
    }

    public void dispatchKeyEvent(
        int type,
        int keyCode
    ) {

        switch (type) {

            case 3:
                keyPressed(keyCode);
                break;

            case 4:
                keyReleased(keyCode);
                break;

            case 5:
                keyRepeated(keyCode);
                break;
        }
    }

    // ============================================================
    // Game actions
    // ============================================================

    public int getGameAction(int keyCode) {

        switch (keyCode) {

            case KEY_UP:
            case KEY_NUM2:
                return UP;

            case KEY_DOWN:
            case KEY_NUM8:
                return DOWN;

            case KEY_LEFT:
            case KEY_NUM4:
                return LEFT;

            case KEY_RIGHT:
            case KEY_NUM6:
                return RIGHT;

            case KEY_FIRE:
            case KEY_NUM5:
                return FIRE;

            case KEY_NUM7:
                return GAME_A;

            case KEY_NUM9:
                return GAME_B;

            case KEY_STAR:
                return GAME_C;

            case KEY_POUND:
                return GAME_D;

            default:
                return 0;
        }
    }

    public int getKeyCode(int gameAction) {

        switch (gameAction) {

            case UP:
                return KEY_NUM2;

            case DOWN:
                return KEY_NUM8;

            case LEFT:
                return KEY_NUM4;

            case RIGHT:
                return KEY_NUM6;

            case FIRE:
                return KEY_NUM5;

            default:
                return 0;
        }
    }

    public String getKeyName(int keyCode) {
        return "KEY_" + keyCode;
    }
}
