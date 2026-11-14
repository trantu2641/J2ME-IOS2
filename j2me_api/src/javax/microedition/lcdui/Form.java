package javax.microedition.lcdui;

import java.util.ArrayList;

public class Form extends Screen {
    private ArrayList<Item> items = new ArrayList<Item>();
    private ItemStateListener itemStateListener;

    public Form(String title) {
        setTitle(title);
    }

    public Form(String title, Item[] itemArray) {
        setTitle(title);
        if (itemArray != null) {
            for (Item item : itemArray) append(item);
        }
    }

    public int append(Item item) {
        if (item == null) throw new NullPointerException();
        item.owner = this;
        items.add(item);
        return items.size() - 1;
    }

    public int append(String str) {
        return append(new StringItem(null, str));
    }

    public int append(Image img) {
        return append(new ImageItem(null, img, ImageItem.LAYOUT_DEFAULT, ""));
    }

    public void insert(int index, Item item) { item.owner = this; items.add(index, item); }
    public void set(int index, Item item) { item.owner = this; items.set(index, item); }
    public void delete(int index) { items.remove(index); }
    public void deleteAll() { items.clear(); }
    public int size() { return items.size(); }
    public Item get(int index) { return items.get(index); }
    public void setItemStateListener(ItemStateListener listener) { itemStateListener = listener; }

    void notifyItemStateChanged(Item item) {
        if (itemStateListener != null) itemStateListener.itemStateChanged(item);
    }

    /** Apply edits made by the native UIKit form before serializing it again. */
    public void applyNativeEdits() {
        int nativeIndex = 0;

        for (Item item : items) {
            int type = item.getItemType();

            if (type == 1) { // TextField
                TextField tf = (TextField) item;
                if (NativeBridge.hasPendingFormItemText(nativeIndex)) {
                    tf.setString(NativeBridge.getPendingFormItemText(nativeIndex));
                }
                nativeIndex++;

            } else if (type == 2) { // ChoiceGroup
                ChoiceGroup cg = (ChoiceGroup) item;
                boolean[] flags = new boolean[cg.size()];
                boolean changed = false;

                for (int j = 0; j < cg.size(); j++) {
                    if (NativeBridge.hasPendingFormItemSelected(nativeIndex)) {
                        flags[j] = NativeBridge.getPendingFormItemSelected(nativeIndex);
                        changed = true;
                    } else {
                        flags[j] = cg.isSelected(j);
                    }
                    nativeIndex++;
                }

                if (changed) {
                    cg.setSelectedFlags(flags);
                    notifyItemStateChanged(cg);
                }

            } else {
                // StringItem and other fallback items do not currently accept
                // editable native state, but they still occupy one native
                // serialized item slot.
                nativeIndex++;
            }
        }

        NativeBridge.clearPendingFormEdits();
    }

    /** Serialize form to native bridge and show it. */
    public void showNative() {
        NativeBridge.formBegin(getTitle(), 0); // type 0 = form
        for (Item item : items) {
            int type = item.getItemType();
            if (type == 0) { // StringItem
                NativeBridge.formAddStringItem(item.getItemLabel(), item.getItemText(), 0);
            } else if (type == 1) { // TextField
                TextField tf = (TextField) item;
                NativeBridge.formAddTextField(item.getItemLabel(), item.getItemText(),
                        tf.getMaxSize(), tf.getConstraints());
            } else if (type == 2) { // ChoiceGroup
                ChoiceGroup cg = (ChoiceGroup) item;
                for (int j = 0; j < cg.size(); j++) {
                    NativeBridge.formAddChoiceItem(
                        item.getItemLabel(),
                        cg.getString(j),
                        cg.isSelected(j),
                        cg.getChoiceType()
                    );
                }
            } else {
                // Fallback: show as string
                NativeBridge.formAddStringItem(item.getItemLabel(), item.getItemText(), 0);
            }
        }
        // Commands
        ArrayList<Command> cmds = getCommands();
        for (int i = 0; i < cmds.size(); i++) {
            Command c = cmds.get(i);
            NativeBridge.formAddCommand(c.getLabel(), c.getCommandType(), c.getPriority(), i);
        }
        NativeBridge.formShow();
    }
}
