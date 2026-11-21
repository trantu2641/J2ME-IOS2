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
 * Missing, corrupted, empty, or failed image resources use a non-allocating
 * zero-handle Image sentinel so optional graphics do not stop the MIDlet.
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

            }

        return img;
    }

    /**
     * Creates a non-allocating zero-handle fallback image.
     *
     * Used when an optional image/resource is missing, invalid,
     * corrupted, empty, or cannot be downloaded.
     */
    /**
     * Non-allocating failure sentinel. No native bitmap is created.
     */
    private static Image failedImage() {
        return new Image(0, 1, 1, false);
    }

    /**
     * Creates an image from a JAR resource name.
     *
     * Local missing/corrupted resources are replaced with a non-allocating zero-handle Image sentinel.
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

            return failedImage();
        }

        /*
         * ------------------------------------------------------------
         * Remote HTTP/HTTPS image
         * ------------------------------------------------------------
         */
        if (isRemoteURL(name)) {

            InputStream remote = null;

            try {

                remote =
                    Connector.openInputStream(
                        name,
                        Connector.READ
                    );

                if (remote == null) {

                    return failedImage();
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
                return failedImage();

            } catch (RuntimeException e) {

                /*
                 * Protect the MIDlet from native/network runtime errors
                 * caused by one optional image.
                 */
                return failedImage();

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

                return failedImage();
            }

            return createImage(is);

        } catch (IOException e) {

            return failedImage();

        } catch (RuntimeException e) {

            return failedImage();
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

            }

        return null;
    }

    /**
     * Creates an image from an InputStream.
     *
     * Any failure while reading/decoding an optional image is converted
     * into a non-allocating Image sentinel.
     */
    public static Image createImage(
        InputStream stream
    ) throws IOException {

        if (stream == null) {

            return failedImage();
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

                return failedImage();
            }

            return createImage(
                data,
                0,
                data.length
            );

        } catch (IOException e) {

            return failedImage();

        } catch (RuntimeException e) {

            return failedImage();
        }
    }

    public static Image createImage(
        byte[] imageData,
        int imageOffset,
        int imageLength
    ) {

        if (imageData == null) {

            return failedImage();
        }

        if (
            imageOffset < 0
            || imageLength <= 0
            || imageOffset
                > imageData.length
                    - imageLength
        ) {

            return failedImage();
        }

        long handle = 0;

        try {

            /*
             * Restore the PNG compatibility normalization used by the
             * known-good runtime. In particular, keep tRNS so indexed PNG
             * transparency survives the native decode path.
             */
            byte[] decodeData =
                normalizePNGForNativeDecoder(
                    imageData,
                    imageOffset,
                    imageLength
                );

            handle =
                NativeBridge.createImageFromData(
                    decodeData,
                    0,
                    decodeData.length
                );

            if (handle == 0) {

                return failedImage();
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

                return failedImage();
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

            return failedImage();
        }
    }

    /**
     * Normalize PNG data before passing it to ImageIO/CoreGraphics.
     * Essential chunks are retained, including tRNS for PNG transparency.
     * Non-PNG data is returned unchanged.
     */
    private static byte[] normalizePNGForNativeDecoder(
        byte[] data,
        int offset,
        int length
    ) {
        if (data == null || length <= 0) {
            return new byte[0];
        }

        if (length < 8) {
            byte[] out = new byte[length];
            System.arraycopy(data, offset, out, 0, length);
            return out;
        }

        final byte[] PNG = {
            (byte) 0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A
        };

        for (int i = 0; i < PNG.length; i++) {
            if ((data[offset + i] & 0xFF) != (PNG[i] & 0xFF)) {
                byte[] out = new byte[length];
                System.arraycopy(data, offset, out, 0, length);
                return out;
            }
        }

        ByteArrayOutputStream out =
            new ByteArrayOutputStream(length);

        out.write(PNG, 0, PNG.length);

        int p = 8;

        while (p + 12 <= length) {
            int chunkLength =
                ((data[offset + p] & 0xFF) << 24)
                | ((data[offset + p + 1] & 0xFF) << 16)
                | ((data[offset + p + 2] & 0xFF) << 8)
                | (data[offset + p + 3] & 0xFF);

            if (chunkLength < 0 || chunkLength > length - p - 12) {
                byte[] raw = new byte[length];
                System.arraycopy(data, offset, raw, 0, length);
                return raw;
            }

            int type = offset + p + 4;

            boolean keep =
                isPNGChunk(type, data, "IHDR")
                || isPNGChunk(type, data, "PLTE")
                || isPNGChunk(type, data, "tRNS")
                || isPNGChunk(type, data, "gAMA")
                || isPNGChunk(type, data, "IDAT")
                || isPNGChunk(type, data, "IEND");

            int total = chunkLength + 12;

            if (keep) {
                out.write(data, offset + p, total);
            }

            p += total;

            if (isPNGChunk(type, data, "IEND")) {
                break;
            }
        }

        byte[] normalized = out.toByteArray();

        if (normalized.length < 33) {
            byte[] raw = new byte[length];
            System.arraycopy(data, offset, raw, 0, length);
            return raw;
        }

        return normalized;
    }

    private static boolean isPNGChunk(
        int typeOffset,
        byte[] data,
        String name
    ) {
        return
            data[typeOffset] == (byte) name.charAt(0)
            && data[typeOffset + 1] == (byte) name.charAt(1)
            && data[typeOffset + 2] == (byte) name.charAt(2)
            && data[typeOffset + 3] == (byte) name.charAt(3);
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
