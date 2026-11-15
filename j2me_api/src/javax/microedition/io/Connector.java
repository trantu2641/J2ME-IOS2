package javax.microedition.io;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.util.Hashtable;
import java.util.Vector;

/**
 * J2ME Connector implementation for JarBox.
 *
 * HTTP/HTTPS are backed by the platform Java URL connection so MIDlets can
 * download remote icons, images and other game data.
 *
 * Remote resources are deliberately detached from the HTTP connection before
 * they are returned to the MIDlet. A small byte cache and same-URL request
 * coalescing are used because avatar/review screens can ask for the same
 * image many times while a large item list is being built.
 */
public final class Connector {

    public static final int READ = 1;
    public static final int WRITE = 2;
    public static final int READ_WRITE = 3;

    private static final int DEFAULT_CONNECT_TIMEOUT = 8000;
    private static final int DEFAULT_READ_TIMEOUT = 10000;
    private static final int MAX_HTTP_RETRIES = 1;

    /*
     * Remote image/resource cache.
     *
     * The cache stores raw response bytes, not Image objects. This keeps the
     * Connector independent from lcdui and lets Image.createImage(byte[],...)
     * perform the actual decoding.
     */
    private static final int MAX_REMOTE_CACHE_ENTRIES = 128;
    private static final long MAX_REMOTE_CACHE_BYTES = 16L * 1024L * 1024L;

    private static final Hashtable REMOTE_CACHE = new Hashtable();
    private static final Vector REMOTE_CACHE_ORDER = new Vector();
    private static long remoteCacheBytes = 0L;

    /* One in-flight request per exact URL. Other callers wait for its bytes. */
    private static final Hashtable REMOTE_IN_FLIGHT = new Hashtable();

    private static final class RemoteRequest {
        byte[] data;
        IOException error;
        boolean finished;
    }

    private Connector() {
    }

    public static Connection open(String name) throws IOException {
        return open(name, READ, false);
    }

    public static Connection open(String name, int mode) throws IOException {
        return open(name, mode, false);
    }

    public static Connection open(
        String name,
        int mode,
        boolean timeouts
    ) throws IOException {

        if (name == null || name.length() == 0) {
            throw new IllegalArgumentException("Connection URL is empty");
        }

        if (mode != READ && mode != WRITE && mode != READ_WRITE) {
            throw new IllegalArgumentException("Invalid connection mode: " + mode);
        }

        final URL url;

        try {
            url = new URL(name);
        } catch (Exception e) {
            throw new ConnectionNotFoundException("Invalid URL: " + name);
        }

        String protocol = url.getProtocol();

        if ("http".equalsIgnoreCase(protocol)
            || "https".equalsIgnoreCase(protocol)) {

            return new HTTPConnectionImpl(url, mode, timeouts);
        }

        throw new ConnectionNotFoundException(
            "Unsupported protocol: " + protocol
        );
    }

    public static DataInputStream openDataInputStream(String name)
        throws IOException {
        return new DataInputStream(openInputStream(name, READ));
    }

    public static DataOutputStream openDataOutputStream(String name)
        throws IOException {
        return new DataOutputStream(openOutputStream(name, WRITE));
    }

    public static InputStream openInputStream(String name) throws IOException {
        return openInputStream(name, READ);
    }

    public static InputStream openInputStream(String name, int mode)
        throws IOException {

        if (isHTTPURL(name) && (mode & READ) != 0) {
            return new ByteArrayInputStream(loadRemoteBytes(name));
        }

        IOException lastError = null;

        for (int attempt = 0; attempt <= MAX_HTTP_RETRIES; attempt++) {
            Connection connection = null;

            try {
                connection = open(name, mode, false);

                if (!(connection instanceof InputConnection)) {
                    throw new IOException("Connection does not support input");
                }

                InputStream source =
                    ((InputConnection) connection).openInputStream();

                if (source == null) {
                    throw new IOException("HTTP input stream is null");
                }

                byte[] data = readAllAndClose(source, connection);
                return new ByteArrayInputStream(data);

            } catch (IOException e) {
                lastError = e;

                closeQuietly(connection);

                if (attempt < MAX_HTTP_RETRIES) {
                    continue;
                }
            } catch (RuntimeException e) {
                closeQuietly(connection);
                throw e;
            }
        }

        throw lastError != null
            ? lastError
            : new IOException("HTTP request failed: " + name);
    }

    private static boolean isHTTPURL(String name) {
        if (name == null || name.length() < 7) {
            return false;
        }

        return name.regionMatches(true, 0, "http://", 0, 7)
            || name.regionMatches(true, 0, "https://", 0, 8);
    }

    /**
     * Loads a remote resource once and shares its bytes with simultaneous
     * callers. Different URLs remain independent and may download in
     * parallel; there is intentionally no global "2 requests" bottleneck.
     */
    private static byte[] loadRemoteBytes(String url) throws IOException {

        byte[] cached = getCachedRemote(url);
        if (cached != null) {
            return cached;
        }

        RemoteRequest request;
        boolean owner = false;

        synchronized (REMOTE_IN_FLIGHT) {
            request = (RemoteRequest) REMOTE_IN_FLIGHT.get(url);

            if (request == null) {
                request = new RemoteRequest();
                REMOTE_IN_FLIGHT.put(url, request);
                owner = true;
            }
        }

        if (owner) {
            try {
                byte[] data = fetchRemoteBytes(url);

                synchronized (request) {
                    request.data = data;
                    request.finished = true;
                    request.notifyAll();
                }

                if (data != null && data.length > 0) {
                    putCachedRemote(url, data);
                }

                return data;

            } catch (IOException e) {
                synchronized (request) {
                    request.error = e;
                    request.finished = true;
                    request.notifyAll();
                }

                throw e;

            } finally {
                synchronized (REMOTE_IN_FLIGHT) {
                    REMOTE_IN_FLIGHT.remove(url);
                }
            }
        }

        synchronized (request) {
            while (!request.finished) {
                try {
                    request.wait(10000L);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new IOException("Interrupted while loading: " + url);
                }
            }

            if (request.data != null) {
                return request.data;
            }

            if (request.error != null) {
                throw request.error;
            }

            throw new IOException("Remote request returned no data: " + url);
        }
    }

    private static byte[] fetchRemoteBytes(String url) throws IOException {

        IOException lastError = null;

        for (int attempt = 0; attempt <= MAX_HTTP_RETRIES; attempt++) {
            Connection connection = null;

            try {
                connection = open(url, READ, false);

                if (!(connection instanceof InputConnection)) {
                    throw new IOException("Connection does not support input");
                }

                InputStream source =
                    ((InputConnection) connection).openInputStream();

                if (source == null) {
                    throw new IOException("HTTP input stream is null");
                }

                byte[] data = readAllAndClose(source, connection);

                if (data == null || data.length == 0) {
                    throw new IOException("Empty HTTP response: " + url);
                }

                return data;

            } catch (IOException e) {
                lastError = e;
                closeQuietly(connection);

                if (attempt < MAX_HTTP_RETRIES) {
                    continue;
                }
            } catch (RuntimeException e) {
                closeQuietly(connection);
                throw e;
            }
        }

        throw lastError != null
            ? lastError
            : new IOException("HTTP request failed: " + url);
    }

    private static byte[] getCachedRemote(String url) {
        synchronized (REMOTE_CACHE) {
            byte[] data = (byte[]) REMOTE_CACHE.get(url);

            if (data != null) {
                REMOTE_CACHE_ORDER.remove(url);
                REMOTE_CACHE_ORDER.addElement(url);
            }

            return data;
        }
    }

    private static void putCachedRemote(String url, byte[] data) {
        if (url == null || data == null || data.length == 0) {
            return;
        }

        if (data.length > MAX_REMOTE_CACHE_BYTES) {
            return;
        }

        synchronized (REMOTE_CACHE) {
            byte[] old = (byte[]) REMOTE_CACHE.remove(url);

            if (old != null) {
                remoteCacheBytes -= old.length;
                REMOTE_CACHE_ORDER.remove(url);
            }

            REMOTE_CACHE.put(url, data);
            REMOTE_CACHE_ORDER.addElement(url);
            remoteCacheBytes += data.length;

            while (
                REMOTE_CACHE_ORDER.size() > MAX_REMOTE_CACHE_ENTRIES
                || remoteCacheBytes > MAX_REMOTE_CACHE_BYTES
            ) {
                if (REMOTE_CACHE_ORDER.size() == 0) {
                    break;
                }

                String oldest =
                    (String) REMOTE_CACHE_ORDER.elementAt(0);

                REMOTE_CACHE_ORDER.removeElementAt(0);

                byte[] removed =
                    (byte[]) REMOTE_CACHE.remove(oldest);

                if (removed != null) {
                    remoteCacheBytes -= removed.length;
                }
            }
        }
    }

    private static void closeQuietly(Connection connection) {
        if (connection == null) {
            return;
        }

        try {
            connection.close();
        } catch (IOException ignored) {
        } catch (RuntimeException ignored) {
        }
    }

    private static byte[] readAllAndClose(
        InputStream source,
        Connection connection
    ) throws IOException {

        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];

        try {
            int count;
            while ((count = source.read(chunk)) != -1) {
                if (count > 0) {
                    buffer.write(chunk, 0, count);
                }
            }
            return buffer.toByteArray();
        } finally {
            try {
                source.close();
            } catch (IOException ignored) {
            } finally {
                closeQuietly(connection);
            }
        }
    }

    public static OutputStream openOutputStream(String name)
        throws IOException {
        return openOutputStream(name, WRITE);
    }

    public static OutputStream openOutputStream(String name, int mode)
        throws IOException {

        Connection connection = open(name, mode, false);

        if (!(connection instanceof OutputConnection)) {
            closeQuietly(connection);
            throw new IOException("Connection does not support output");
        }

        return ((OutputConnection) connection).openOutputStream();
    }

    private static final class HTTPConnectionImpl implements HttpConnection {

        private final URL url;
        private final int mode;
        private final HttpURLConnection connection;

        private boolean closed;
        private boolean connected;
        private String requestMethod = GET;

        HTTPConnectionImpl(URL url, int mode, boolean timeouts)
            throws IOException {

            this.url = url;
            this.mode = mode;

            URLConnection raw = url.openConnection();

            if (!(raw instanceof HttpURLConnection)) {
                throw new IOException("Not an HTTP connection: " + url);
            }

            connection = (HttpURLConnection) raw;

            connection.setInstanceFollowRedirects(true);
            connection.setUseCaches(false);

            /*
             * Do not force a new socket policy here. The resource cache above
             * already removes repeated icon requests. Keeping the individual
             * connection implementation simple also preserves normal J2ME
             * HTTP semantics for non-image data.
             */
            connection.setRequestProperty("Connection", "close");
            connection.setConnectTimeout(
                timeouts ? 0 : DEFAULT_CONNECT_TIMEOUT
            );
            connection.setReadTimeout(
                timeouts ? 0 : DEFAULT_READ_TIMEOUT
            );

            connection.setDoInput((mode & READ) != 0);
            connection.setDoOutput((mode & WRITE) != 0);
        }

        private void ensureOpen() throws IOException {
            if (closed) {
                throw new IOException("Connection is closed");
            }
        }

        private void ensureConnected() throws IOException {
            ensureOpen();

            if (!connected) {
                connection.setRequestMethod(requestMethod);
                connection.connect();
                connected = true;
            }
        }

        @Override
        public DataInputStream openDataInputStream() throws IOException {
            return new DataInputStream(openInputStream());
        }

        @Override
        public InputStream openInputStream() throws IOException {
            ensureConnected();

            int responseCode = connection.getResponseCode();

            if (responseCode < 200 || responseCode >= 400) {
                String message;
                try {
                    message = connection.getResponseMessage();
                } catch (IOException ignored) {
                    message = "";
                }

                throw new IOException(
                    "HTTP " + responseCode + " " + message
                );
            }

            InputStream input = connection.getInputStream();

            if (input == null) {
                throw new IOException("HTTP input stream is null");
            }

            return new ConnectionInputStream(input, this);
        }

        @Override
        public OutputStream openOutputStream() throws IOException {
            ensureOpen();

            if ((mode & WRITE) == 0) {
                throw new IOException("Connection is not open for writing");
            }

            connection.setDoOutput(true);

            return new ConnectionOutputStream(
                connection.getOutputStream(),
                this
            );
        }

        @Override
        public DataOutputStream openDataOutputStream() throws IOException {
            return new DataOutputStream(openOutputStream());
        }

        @Override
        public String getType() {
            try {
                ensureConnected();
                return connection.getContentType();
            } catch (IOException e) {
                return null;
            }
        }

        @Override
        public String getEncoding() {
            try {
                ensureConnected();
                return connection.getContentEncoding();
            } catch (IOException e) {
                return null;
            }
        }

        @Override
        public long getLength() {
            try {
                ensureConnected();
                return connection.getContentLengthLong();
            } catch (IOException e) {
                return -1;
            }
        }

        @Override
        public String getURL() {
            return connection.getURL().toString();
        }

        @Override
        public String getProtocol() {
            return url.getProtocol();
        }

        @Override
        public String getHost() {
            return url.getHost();
        }

        @Override
        public String getFile() {
            return url.getFile();
        }

        @Override
        public String getRef() {
            return url.getRef();
        }

        @Override
        public String getQuery() {
            return url.getQuery();
        }

        @Override
        public int getPort() {
            int port = url.getPort();
            return port >= 0 ? port : url.getDefaultPort();
        }

        @Override
        public String getRequestMethod() {
            return requestMethod;
        }

        @Override
        public void setRequestMethod(String method) throws IOException {
            ensureOpen();

            if (connected) {
                throw new IOException("Request already connected");
            }

            if (!HEAD.equals(method)
                && !GET.equals(method)
                && !POST.equals(method)) {
                throw new IOException(
                    "Unsupported HTTP method: " + method
                );
            }

            requestMethod = method;
        }

        @Override
        public String getRequestProperty(String key) {
            return connection.getRequestProperty(key);
        }

        @Override
        public void setRequestProperty(
            String key,
            String value
        ) throws IOException {
            ensureOpen();

            if (connected) {
                throw new IOException("Request already connected");
            }

            connection.setRequestProperty(key, value);
        }

        @Override
        public int getResponseCode() throws IOException {
            ensureConnected();
            return connection.getResponseCode();
        }

        @Override
        public String getResponseMessage() throws IOException {
            ensureConnected();
            return connection.getResponseMessage();
        }

        @Override
        public long getExpiration() throws IOException {
            ensureConnected();
            return connection.getExpiration();
        }

        @Override
        public long getDate() throws IOException {
            ensureConnected();
            return connection.getDate();
        }

        @Override
        public long getLastModified() throws IOException {
            ensureConnected();
            return connection.getLastModified();
        }

        @Override
        public String getHeaderField(String name) {
            return connection.getHeaderField(name);
        }

        @Override
        public int getHeaderFieldInt(String name, int def) {
            return connection.getHeaderFieldInt(name, def);
        }

        @Override
        public long getHeaderFieldDate(String name, long def) {
            return connection.getHeaderFieldDate(name, def);
        }

        @Override
        public String getHeaderField(int n) {
            return connection.getHeaderField(n);
        }

        @Override
        public String getHeaderFieldKey(int n) {
            return connection.getHeaderFieldKey(n);
        }

        @Override
        public void close() {
            if (!closed) {
                closed = true;
                connection.disconnect();
            }
        }
    }

    private static final class ConnectionInputStream extends InputStream {

        private final InputStream delegate;
        private final HTTPConnectionImpl owner;
        private boolean closed;

        ConnectionInputStream(
            InputStream delegate,
            HTTPConnectionImpl owner
        ) {
            this.delegate = delegate;
            this.owner = owner;
        }

        @Override
        public int read() throws IOException {
            return delegate.read();
        }

        @Override
        public int read(
            byte[] b,
            int off,
            int len
        ) throws IOException {
            return delegate.read(b, off, len);
        }

        @Override
        public long skip(long n) throws IOException {
            return delegate.skip(n);
        }

        @Override
        public int available() throws IOException {
            return delegate.available();
        }

        @Override
        public void close() throws IOException {
            if (!closed) {
                closed = true;

                try {
                    delegate.close();
                } finally {
                    owner.close();
                }
            }
        }
    }

    private static final class ConnectionOutputStream extends OutputStream {

        private final OutputStream delegate;
        private final HTTPConnectionImpl owner;
        private boolean closed;

        ConnectionOutputStream(
            OutputStream delegate,
            HTTPConnectionImpl owner
        ) {
            this.delegate = delegate;
            this.owner = owner;
        }

        @Override
        public void write(int b) throws IOException {
            delegate.write(b);
        }

        @Override
        public void write(
            byte[] b,
            int off,
            int len
        ) throws IOException {
            delegate.write(b, off, len);
        }

        @Override
        public void flush() throws IOException {
            delegate.flush();
        }

        @Override
        public void close() throws IOException {
            if (!closed) {
                closed = true;

                try {
                    delegate.close();
                } finally {
                    owner.close();
                }
            }
        }
    }
}
