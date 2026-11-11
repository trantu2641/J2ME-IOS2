/*
 * Copyright 2017-2018 Nikita Shakarun
 * Licensed under Apache-2.0
 *
 * iOS/miniJVM GameCanvas compatibility layer.
 *
 * currentKeys  = keys currently held
 * latchedKeys  = keys pressed since the previous getKeyStates() call
 *
 * This preserves short taps for polling-based J2ME games while still
 * reporting keys that are physically held.
 */
package javax.microedition.lcdui.game;

import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Graphics;
import javax.microedition.lcdui.Image;

public class GameCanvas extends Canvas {

    public static final int UP_PRESSED = 1 << Canvas.UP;
    public static final int DOWN_PRESSED = 1 << Canvas.DOWN;
    public static final int LEFT_PRESSED = 1 << Canvas.LEFT;
    public static final int RIGHT_PRESSED = 1 << Canvas.RIGHT;
    public static final int FIRE_PRESSED = 1 << Canvas.FIRE;
    public static final int GAME_A_PRESSED = 1 << Canvas.GAME_A;
    public static final int GAME_B_PRESSED = 1 << Canvas.GAME_B;
    public static final int GAME_C_PRESSED = 1 << Canvas.GAME_C;
    public static final int GAME_D_PRESSED = 1 << Canvas.GAME_D;

    private Image image;

    /*
     * currentKeys:
     *   keys currently being held.
     *
     * latchedKeys:
     *   every key pressed since the previous getKeyStates().
     *
     * They are intentionally separate. Clearing a key on keyReleased()
     * would make a short tap disappear before the game's polling loop
     * sees it.
     */
    private volatile int currentKeys = 0;
    private volatile int latchedKeys = 0;

    private final boolean suppressCommands;

    public GameCanvas(boolean suppressCommands) {
        super();
        this.suppressCommands = suppressCommands;
        image = Image.createImage(width, height);
    }

    @Override
    public void paint(Graphics g) {
        g.drawImage(
                image,
                0,
                0,
                Graphics.LEFT | Graphics.TOP
        );
    }

    /*
     * Converts standard MIDP key codes and numeric keypad equivalents
     * into GameCanvas action bits.
     *
     * Supported:
     *   arrows / KEY_UP / KEY_DOWN / KEY_LEFT / KEY_RIGHT
     *   FIRE / 5
     *   2 / 4 / 6 / 8
     *   7 / 9 / * / #
     */
    private int convertGameKeyCode(int keyCode) {

        switch (keyCode) {

            case KEY_LEFT:
            case KEY_NUM4:
                return LEFT_PRESSED;

            case KEY_UP:
            case KEY_NUM2:
                return UP_PRESSED;

            case KEY_RIGHT:
            case KEY_NUM6:
                return RIGHT_PRESSED;

            case KEY_DOWN:
            case KEY_NUM8:
                return DOWN_PRESSED;

            case KEY_FIRE:
            case KEY_NUM5:
                return FIRE_PRESSED;

            case KEY_NUM7:
                return GAME_A_PRESSED;

            case KEY_NUM9:
                return GAME_B_PRESSED;

            case KEY_STAR:
                return GAME_C_PRESSED;

            case KEY_POUND:
                return GAME_D_PRESSED;

            default:
                return 0;
        }
    }

    /*
     * Key down.
     *
     * Add the bit to both the held state and the one-shot latch.
     * Therefore a quick press is still visible to getKeyStates()
     * even when keyReleased() happens before the game polls it.
     */
    @Override
    public synchronized void postKeyPressed(int keyCode) {

        int code = convertGameKeyCode(keyCode);

        if (code != 0) {
            currentKeys |= code;
            latchedKeys |= code;

            if (suppressCommands) {
                return;
            }
        }

        super.postKeyPressed(keyCode);
    }

    /*
     * Key up.
     *
     * Do NOT clear latchedKeys here.
     * The key remains visible to getKeyStates() until the next poll.
     */
    @Override
    public synchronized void postKeyReleased(int keyCode) {

        int code = convertGameKeyCode(keyCode);

        if (code != 0) {
            currentKeys &= ~code;

            if (suppressCommands) {
                return;
            }
        }

        super.postKeyReleased(keyCode);
    }

    /*
     * Repeated key event.
     *
     * A repeat is also latched so polling-based games can see it.
     */
    @Override
    public synchronized void postKeyRepeated(int keyCode) {

        int code = convertGameKeyCode(keyCode);

        if (code != 0) {
            currentKeys |= code;
            latchedKeys |= code;

            if (suppressCommands) {
                return;
            }
        }

        super.postKeyRepeated(keyCode);
    }

    /*
     * MIDP GameCanvas key polling.
     *
     * Returns currently-held keys OR keys pressed since the previous
     * poll, then clears only the one-shot latch.
     */
    public synchronized int getKeyStates() {

        int states = currentKeys | latchedKeys;

        latchedKeys = 0;

        return states;
    }

    public Graphics getGraphics() {

        if (
                image == null
                || image.getWidth() != width
                || image.getHeight() != height
        ) {
            image = Image.createImage(width, height);
        }

        return image.getGraphics();
    }

    public void flushGraphics() {
        flushGraphics(0, 0, width, height);
    }

    public void flushGraphics(
            int x,
            int y,
            int width,
            int height
    ) {
        flushBuffer(image, x, y, width, height);
    }

    @Override
    public synchronized void doShowNotify() {

        currentKeys = 0;
        latchedKeys = 0;

        super.doShowNotify();
    }

    @Override
    public synchronized void doHideNotify() {

        currentKeys = 0;
        latchedKeys = 0;

        super.doHideNotify();
    }
}
