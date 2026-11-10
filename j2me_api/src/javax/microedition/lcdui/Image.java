```java
package javax.microedition.lcdui;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import javax.microedition.io.Connector;

/**
 * J2ME Image compatibility layer.
 *
 * Missing, corrupted, empty, or failed image resources are replaced with
 * a transparent 1x1 image so that optional graphics do not stop the MIDlet.
 *
 * IMPORTANT:
 * Remote HTTP/HTTPS image failures are intentionally isolated from the
 * MIDlet. One failed icon must not stop subsequent icon/resource loads.
 */
public class Image {

    public long nativeHandle;

    private int width;
    private int height;
    private boolean mutable;

    private Graphics cachedGraphics;

    public Image(long nativeHandle, int width, int height, boolean mutable) {
        this.nativeHandle = nativeHandle;
        this.width = width;
        this.height = height;
        this.mutable = mutable;
    }

    public static Image createImage(int width, int height) {

        long handle = NativeBridge.createMutableImage(width, height);

        if (handle == 0) {
            System.out.println(
                "[Image] ERROR: createMutableImage returned 0 for "
                + width + "x" + height
            );
        }

        return new Image(handle, width, height, true);
    }

    public static Image createImage(int width, int height, int argb) {

        Image img = createImage(width, height);

        if (img.nativeHandle == 0) {
            return img;
        }

        try {
            int[] fill = new int[width * height];

            if (argb != 0) {
                java.util.Arrays.fill(fill, argb);
            }

            Graphics g = img.getGraphics();

            g.drawRGB(
                fill,
                0,
                width,
                0,
                0,
                width,
                height,
                true
            );

        } catch (RuntimeException e) {

            System.out.println(
                "[Image] Unable to initialize image: " + e
            );
        }

        return img;
    }

    /**
     * Creates a transparent 1x1 fallback image.
     *
     * Used when an optional image/resource is missing, invalid,
     * corrupted, empty, or cannot be downloaded.
     */
    private static Image createTransparentPlaceholder() {

        long handle = 0;

        try {

            handle = NativeBridge.createMutableImage(1, 1);

            if (handle == 0) {

                System.out.println(
                    "[Image] COMPAT: unable to allocate placeholder"
                );

                return new Image(0, 1, 1, false);
            }

            long context =
                NativeBridge.getImageContext(handle);

            if (context != 0) {

                NativeBridge.drawRGB(
                    context,
                    new int[] { 0x00000000 },
                    0,
                    1,
                    0,
                    0,
                    1,
                    1,
                    1
                );
            }

            return new Image(
                handle,
                1,
                1,
                false
            );

        } catch (RuntimeException e) {

            if (handle != 0) {

                try {
                    NativeBridge.destroyImage(handle);
                } catch (RuntimeException ignored) {
                }
            }

            System.out.println(
                "[Image] COMPAT: placeholder creation failed: "
                + e
            );

            return new Image(
                0,
                1,
                1,
                false
            );
        }
    }

    private static void logFallback(
        String name,
        String reason
    ) {

        System.out.println(
            "[Image] COMPAT: "
            + reason
            + ": "
            + name
            + " (using transparent placeholder)"
        );
    }

    /**
     * Creates an image from a JAR resource name.
     *
     * Local missing/corrupted resources are replaced with a transparent
     * placeholder.
     *
     * HTTP/HTTPS resources are also isolated:
     *
     *     request A -> OK
     *     request B -> FAILED -> placeholder
     *     request C -> still allowed to continue
     *
     * A failed remote icon must never be allowed to kill the resource
     * loading chain by propagating its IOException.
     */
    public static Image createImage(String name)
        throws IOException {

        if (name == null || name.length() == 0) {

            logFallback(
                String.valueOf(name),
                "invalid resource name"
            );

            return createTransparentPlaceholder();
        }

        /*
         * ------------------------------------------------------------
         * Remote HTTP/HTTPS image
         * ------------------------------------------------------------
         */
        if (isRemoteURL(name)) {

            InputStream remote = null;

            try {

                System.out.println(
                    "[Image] REMOTE: loading " + name
                );

                remote =
                    Connector.openInputStream(
                        name,
                        Connector.READ
                    );

                if (remote == null) {

                    logFallback(
                        name,
                        "remote connection returned null stream"
                    );

                    return createTransparentPlaceholder();
                }

                /*
                 * IMPORTANT:
                 *
                 * createImage(InputStream) already reads and closes
                 * the stream. Do not throw the remote IOException here.
                 *
                 * A broken icon is treated as an optional resource.
                 */
                return createImage(remote);

            } catch (IOException e) {

                /*
                 * THIS is the important compatibility behavior.
                 *
                 * Previously this code did:
                 *
                 *     throw e;
                 *
                 * That allowed one failed server icon to propagate
                 * into the game and potentially terminate its loader.
                 *
                 * Now the failed icon is replaced by a transparent
                 * placeholder and the Java game is allowed to continue.
                 */
                logFallback(
                    name,
                    "remote image request failed: " + e
                );

                return createTransparentPlaceholder();

            } catch (RuntimeException e) {

                /*
                 * Protect the MIDlet from native/network runtime errors
                 * caused by one optional image.
                 */
                logFallback(
                    name,
                    "remote image runtime failure: " + e
                );

                return createTransparentPlaceholder();

            } finally {

                /*
                 * Defensive close.
                 *
                 * Some InputStream implementations may already have
                 * been closed by createImage(InputStream). Calling close()
                 * again is intentionally ignored.
                 */
                if (remote != null) {

                    try {
                        remote.close();
                    } catch (IOException ignored) {
                    } catch (RuntimeException ignored) {
                    }
                }
            }
        }

        /*
         * ------------------------------------------------------------
         * Local JAR resource
         * ------------------------------------------------------------
         */
        try {

            InputStream is =
                findResource(name);

            if (is == null) {

                logFallback(
                    name,
                    "local resource not found"
                );

                return createTransparentPlaceholder();
            }

            return createImage(is);

        } catch (IOException e) {

            logFallback(
                name,
                "local resource read failed: " + e
            );

            return createTransparentPlaceholder();

        } catch (RuntimeException e) {

            logFallback(
                name,
                "local resource loader failed: " + e
            );

            return createTransparentPlaceholder();
        }
    }

    private static boolean isRemoteURL(String name) {

        return startsWithIgnoreCase(
            name,
            "http://"
        )
        || startsWithIgnoreCase(
            name,
            "https://"
        );
    }

    private static boolean startsWithIgnoreCase(
        String value,
        String prefix
    ) {

        if (
            value == null
            || prefix == null
        ) {
            return false;
        }

        if (
            value.length()
            < prefix.length()
        ) {
            return false;
        }

        for (
            int i = 0;
            i < prefix.length();
            i++
        ) {

            char a =
                value.charAt(i);

            char b =
                prefix.charAt(i);

            if (
                a >= 'A'
                && a <= 'Z'
            ) {
                a =
                    (char)(
                        a
                        + ('a' - 'A')
                    );
            }

            if (
                b >= 'A'
                && b <= 'Z'
            ) {
                b =
                    (char)(
                        b
                        + ('a' - 'A')
                    );
            }

            if (a != b) {
                return false;
            }
        }

        return true;
    }

    private static InputStream findResource(
        String name
    ) {

        if (
            name == null
            || name.length() == 0
        ) {
            return null;
        }

        InputStream is =
            tryLoadResource(name);

        if (is != null) {
            return is;
        }

        if (
            name.lastIndexOf('.')
            <= name.lastIndexOf('/')
        ) {

            String searchName =
                name.startsWith("/")
                    ? name.substring(1)
                    : name;

            String match =
                findEntryByPrefix(searchName);

            if (match != null) {

                is =
                    tryLoadResource(
                        "/" + match
                    );

                if (is != null) {
                    return is;
                }
            }
        }

        return null;
    }

    private static String findEntryByPrefix(
        String name
    ) {

        String cp =
            System.getProperty(
                "java.class.path"
            );

        if (
            cp == null
            || cp.length() == 0
        ) {
            return null;
        }

        String[] paths =
            cp.split(
                File.pathSeparator
            );

        for (String path : paths) {

            if (
                path == null
                || path.length() == 0
            ) {
                continue;
            }

            File f =
                new File(path);

            if (!f.isFile()) {
                continue;
            }

            ZipFile zf = null;

            try {

                zf =
                    new ZipFile(f);

                Enumeration entries =
                    zf.entries();

                while (
                    entries.hasMoreElements()
                ) {

                    ZipEntry entry =
                        (ZipEntry)
                            entries.nextElement();

                    String entryName =
                        entry.getName();

                    int dotIdx =
                        entryName.lastIndexOf(
                            '.'
                        );

                    if (dotIdx > 0) {

                        String baseName =
                            entryName.substring(
                                0,
                                dotIdx
                            );

                        if (
                            baseName.equals(name)
                        ) {

                            /*
                             * The stream itself will be opened separately.
                             * Close this ZIP immediately.
                             */
                            zf.close();

                            zf = null;

                            return entryName;
                        }
                    }
                }

            } catch (IOException e) {

                /*
                 * One unreadable JAR must not affect
                 * resource loading from other paths.
                 */

            } catch (RuntimeException e) {

                /*
                 * Malformed/unsupported JAR is also isolated.
                 */

            } finally {

                if (zf != null) {

                    try {
                        zf.close();
                    } catch (IOException ignored) {
                    }
                }
            }
        }

        return null;
    }

    private static InputStream tryLoadResource(
        String name
    ) {

        try {

            InputStream is =
                Image.class.getResourceAsStream(
                    name
                );

            if (is != null) {
                return is;
            }

            if (!name.startsWith("/")) {

                is =
                    Image.class.getResourceAsStream(
                        "/" + name
                    );

                if (is != null) {
                    return is;
                }
            }

            ClassLoader cl =
                Thread.currentThread()
                    .getContextClassLoader();

            if (cl != null) {

                is =
                    cl.getResourceAsStream(
                        name
                    );

                if (is != null) {
                    return is;
                }

                if (name.startsWith("/")) {

                    is =
                        cl.getResourceAsStream(
                            name.substring(1)
                        );

                    if (is != null) {
                        return is;
                    }
                }
            }

        } catch (RuntimeException e) {

            System.out.println(
                "[Image] COMPAT: resource lookup failed for "
                + name
                + ": "
                + e
            );
        }

        return null;
    }

    /**
     * Creates an image from an InputStream.
     *
     * Any failure while reading/decoding an optional image is converted
     * into a transparent placeholder.
     */
    public static Image createImage(
        InputStream stream
    ) throws IOException {

        if (stream == null) {

            logFallback(
                "InputStream",
                "null input stream"
            );

            return createTransparentPlaceholder();
        }

        try {

            byte[] data =
                readAllBytes(stream);

            /*
             * Empty response body is treated as a missing/broken image,
             * not as a fatal MIDlet error.
             */
            if (
                data == null
                || data.length == 0
            ) {

                logFallback(
                    "InputStream",
                    "empty image data"
                );

                return createTransparentPlaceholder();
            }

            return createImage(
                data,
                0,
                data.length
            );

        } catch (IOException e) {

            logFallback(
                "InputStream",
                "image read failed: " + e
            );

            return createTransparentPlaceholder();

        } catch (RuntimeException e) {

            logFallback(
                "InputStream",
                "image decoding failed: " + e
            );

            return createTransparentPlaceholder();
        }
    }

    public static Image createImage(
        byte[] imageData,
        int imageOffset,
        int imageLength
    ) {

        if (imageData == null) {

            logFallback(
                "byte[]",
                "null image data"
            );

            return createTransparentPlaceholder();
        }

        if (
            imageOffset < 0
            || imageLength <= 0
            || imageOffset
                > imageData.length
                    - imageLength
        ) {

            logFallback(
                "byte[]",
                "invalid or empty image data"
            );

            return createTransparentPlaceholder();
        }

        long handle = 0;

        try {

            handle =
                NativeBridge.createImageFromData(
                    imageData,
                    imageOffset,
                    imageLength
                );

            if (handle == 0) {

                logFallback(
                    "byte[]",
                    "native image decoder failed"
                );

                return createTransparentPlaceholder();
            }

            int w =
                NativeBridge.getImageWidth(
                    handle
                );

            int h =
                NativeBridge.getImageHeight(
                    handle
                );

            if (
                w <= 0
                || h <= 0
            ) {

                try {
                    NativeBridge.destroyImage(
                        handle
                    );
                } catch (RuntimeException ignored) {
                }

                handle = 0;

                logFallback(
                    "byte[]",
                    "invalid image dimensions"
                );

                return createTransparentPlaceholder();
            }

            return new Image(
                handle,
                w,
                h,
                false
            );

        } catch (RuntimeException e) {

            if (handle != 0) {

                try {
                    NativeBridge.destroyImage(
                        handle
                    );
                } catch (RuntimeException ignored) {
                }
            }

            logFallback(
                "byte[]",
                "image decoding exception: " + e
            );

            return createTransparentPlaceholder();
        }
    }

    public static Image createImage(
        Image source,
        int x,
        int y,
        int width,
        int height,
        int transform
    ) {

        int outW = width;
        int outH = height;

        if (
            transform == 5
            || transform == 6
            || transform == 7
            || transform == 4
        ) {

            outW = height;
            outH = width;
        }

        Image result =
            createImage(
                outW,
                outH
            );

        Graphics g =
            result.getGraphics();

        g.drawRegion(
            source,
            x,
            y,
            width,
            height,
            transform,
            0,
            0,
            Graphics.LEFT
                | Graphics.TOP
        );

        result.mutable = false;

        return result;
    }

    public static Image createImage(
        Image source
    ) {

        Image copy =
            createImage(
                source.width,
                source.height
            );

        Graphics g =
            copy.getGraphics();

        g.drawImage(
            source,
            0,
            0,
            Graphics.LEFT
                | Graphics.TOP
        );

        return copy;
    }

    public static Image createRGBImage(
        int[] rgb,
        int width,
        int height,
        boolean processAlpha
    ) {

        Image img =
            createImage(
                width,
                height
            );

        Graphics g =
            img.getGraphics();

        g.drawRGB(
            rgb,
            0,
            width,
            0,
            0,
            width,
            height,
            processAlpha
        );

        return img;
    }

    public Graphics getGraphics() {

        if (!mutable) {

            throw new IllegalStateException(
                "Image is not mutable"
            );
        }

        if (cachedGraphics == null) {

            long ctx =
                NativeBridge.getImageContext(
                    nativeHandle
                );

            cachedGraphics =
                new Graphics(
                    ctx,
                    width,
                    height
                );

            cachedGraphics.ownsContext =
                true;
        }

        return cachedGraphics;
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }

    public boolean isMutable() {
        return mutable;
    }

    public void getRGB(
        int[] rgbData,
        int offset,
        int scanlength,
        int x,
        int y,
        int w,
        int h
    ) {

        NativeBridge.getImageRGB(
            nativeHandle,
            rgbData,
            offset,
            scanlength,
            x,
            y,
            w,
            h
        );
    }

    /**
     * Reads the complete stream.
     *
     * The stream is ALWAYS closed here, including when read() fails.
     */
    private static byte[] readAllBytes(
        InputStream is
    ) throws IOException {

        if (is == null) {

            throw new IOException(
                "InputStream is null"
            );
        }

        ByteArrayOutputStream bos =
            new ByteArrayOutputStream(
                4096
            );

        byte[] buf =
            new byte[4096];

        try {

            while (true) {

                int n =
                    is.read(buf);

                if (n < 0) {
                    break;
                }

                /*
                 * Some broken HTTP/InputStream implementations
                 * may return 0. Do not treat that as EOF.
                 */
                if (n == 0) {
                    continue;
                }

                bos.write(
                    buf,
                    0,
                    n
                );
            }

            return bos.toByteArray();

        } finally {

            try {
                is.close();
            } catch (IOException ignored) {
            } catch (RuntimeException ignored) {
            }
        }
    }

    protected void finalize()
        throws Throwable {

        cachedGraphics = null;

        if (nativeHandle != 0) {

            try {
                NativeBridge.destroyImage(
                    nativeHandle
                );
            } catch (RuntimeException ignored) {
            }

            nativeHandle = 0;
        }

        super.finalize();
    }
}
```
