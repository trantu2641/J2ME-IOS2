package javax.microedition.lcdui;

import java.util.ArrayList;

/**
 * Base class for all J2ME screens.
 *
 * Initialize width and height from the configured virtual device
 * before a MIDlet constructs its Canvas or Form.
 */
public abstract class Displayable {

    private static final int DEFAULT_SCREEN_WIDTH = 240;
    private static final int DEFAULT_SCREEN_HEIGHT = 320;
    private static final int MAX_SCREEN_DIMENSION = 4096;

    public int width;
    public int height;

    private String title;

    private ArrayList<Command> commands =
        new ArrayList<Command>();

    private CommandListener commandListener;
    private Ticker ticker;

    protected Displayable() {

        width = readScreenDimension(
            "j2me.screen.width",
            DEFAULT_SCREEN_WIDTH
        );

        height = readScreenDimension(
            "j2me.screen.height",
            DEFAULT_SCREEN_HEIGHT
        );
    }

    private static int readScreenDimension(
        String property,
        int fallback
    ) {

        try {
            String value = System.getProperty(property);

            if (value != null) {
                int dimension = Integer.parseInt(value.trim());

                if (dimension >= 1 &&
                    dimension <= MAX_SCREEN_DIMENSION) {

                    return dimension;
                }
            }

        } catch (Exception ignored) {
            // Use standard MIDP dimensions if property is invalid.
        }

        return fallback;
    }

    public void setTitle(String title) {
        this.title = title;
    }

    public String getTitle() {
        return title != null ? title : "";
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }

    public void addCommand(Command cmd) {
        if (cmd != null && !commands.contains(cmd)) {
            commands.add(cmd);
        }
    }

    public void removeCommand(Command cmd) {
        commands.remove(cmd);
    }

    public void setCommandListener(
        CommandListener listener
    ) {
        this.commandListener = listener;
    }

    public ArrayList<Command> getCommands() {
        return commands;
    }

    public CommandListener getCommandListener() {
        return commandListener;
    }

    public void setTicker(Ticker ticker) {
        this.ticker = ticker;
    }

    public Ticker getTicker() {
        return ticker;
    }

    public boolean isShown() {
        Display d = Display.getDisplay(null);

        return d != null && d.getCurrent() == this;
    }

    protected void sizeChanged(int w, int h) {
    }

    /** Fire command action from native UI event loop. */
    public void fireCommandAction(int commandIndex) {

        if (commandListener != null &&
            commandIndex >= 0 &&
            commandIndex < commands.size()) {

            commandListener.commandAction(
                commands.get(commandIndex),
                this
            );
        }
    }
}
