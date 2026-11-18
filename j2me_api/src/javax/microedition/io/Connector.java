package javax.microedition.io;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.util.concurrent.Semaphore;

/**
 * J2ME Connector implementation for JarBox.
 *
 * HTTP/HTTPS are backed by the platform Java URL connection so MIDlets can
 * download remote icons, images and other game data.
 *
 * Remote responses are streamed directly to the caller. They are NOT first
 * copied into a second byte[] by Connector.openInputStream().
 */
public final class Connector {

    public static final int READ = 1;
    public static final int WRITE = 2;
    public static final int READ_WRITE = 3;

    private static final int DEFAULT_CONNECT_TIMEOUT = 8000;
    private static final int DEFAULT_READ_TIMEOUT = 10000;
    private static final int MAX_HTTP_RETRIES = 1;

    // Large item lists can trigger hundreds/thousands of icon requests.
    // Queue excess requests instead of exhausting sockets/threads.
    // This limits concurrency, NOT the total number of item IDs.
    private static final int MAX_ACTIVE_HTTP_REQUESTS = 4;
    private static final Semaphore HTTP_REQUEST_SLOTS =
        new Semaphore(MAX_ACTIVE_HTTP_REQUESTS, true);

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

    /**
     * Opens an HTTP stream without buffering the complete response.
     *
     * This is important for games which load thousands of remote item icons.
     * The old implementation read the complete response into a byte[] here,
     * then Image.createImage(InputStream) copied it into another byte[].
     */
    public static InputStream openInputStream(String name, int mode)
        throws IOException {

        IOException lastError = null;

        for (int attempt = 0; attempt <= MAX_HTTP_RETRIES; attempt++) {
            Connection connection = null;
            boolean slotAcquired = false;

            try {
                HTTP_REQUEST_SLOTS.acquireUninterruptibly();
                slotAcquired = true;

                connection = open(name, mode, false);

                if (!(connection instanceof InputConnection)) {
                    throw new IOException("Connection does not support input");
                }

                InputStream source =
                    ((InputConnection) connection).openInputStream();

                if (source == null) {
                    throw new IOException("HTTP input stream is null");
                }

                return new ConnectionInputStream(
                    source,
                    (HTTPConnectionImpl) connection,
                    HTTP_REQUEST_SLOTS
                );

            } catch (IOException e) {
                lastError = e;

                if (connection != null) {
                    try {
                        connection.close();
                    } catch (IOException ignored) {
                    } catch (RuntimeException ignored) {
                    }
                }

                if (slotAcquired) {
                    HTTP_REQUEST_SLOTS.release();
                }

                if (attempt < MAX_HTTP_RETRIES) {
                    continue;
                }

            } catch (RuntimeException e) {

                if (connection != null) {
                    try {
                        connection.close();
                    } catch (IOException ignored) {
                    } catch (RuntimeException ignored) {
                    }
                }

                if (slotAcquired) {
                    HTTP_REQUEST_SLOTS.release();
                }

                throw e;
            }
        }

        throw lastError != null
            ? lastError
            : new IOException("HTTP request failed: " + name);
    }

    public static OutputStream openOutputStream(String name)
        throws IOException {
        return openOutputStream(name, WRITE);
    }

    public static OutputStream openOutputStream(String name, int mode)
        throws IOException {

        Connection connection = open(name, mode, false);

        if (!(connection instanceof OutputConnection)) {
            try {
                connection.close();
            } catch (IOException ignored) {
            }

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
            connection.setRequestProperty("Connection", "close");
            connection.setRequestProperty("Cache-Control", "no-cache");

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
        public InputStream openInputStream() throws IOException {
            ensureOpen();

            if ((mode & READ) == 0) {
                throw new IOException("Connection is not open for reading");
            }

            try {
                ensureConnected();

                int responseCode = connection.getResponseCode();

                if (responseCode >= 400) {
                    InputStream error = connection.getErrorStream();

                    if (error != null) {
                        try {
                            error.close();
                        } catch (IOException ignored) {
                        }
                    }

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

                return new ConnectionInputStream(
                    input,
                    this,
                    HTTP_REQUEST_SLOTS
                );

            } catch (IOException e) {
                close();
                throw e;

            } catch (RuntimeException e) {
                close();
                throw e;
            }
        }

        @Override
        public DataInputStream openDataInputStream() throws IOException {
            return new DataInputStream(openInputStream());
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
        private final Semaphore requestSlots;
        private boolean closed;

        ConnectionInputStream(
            InputStream delegate,
            HTTPConnectionImpl owner,
            Semaphore requestSlots
        ) {
            this.delegate = delegate;
            this.owner = owner;
            this.requestSlots = requestSlots;
        }

        @Override
        public int read() throws IOException {
            try {
                int value = delegate.read();

                if (value < 0) {
                    close();
                }

                return value;

            } catch (IOException e) {
                closeAfterFailure();
                throw e;
            }
        }

        @Override
        public int read(
            byte[] b,
            int off,
            int len
        ) throws IOException {

            try {
                int count = delegate.read(b, off, len);

                if (count < 0) {
                    close();
                }

                return count;

            } catch (IOException e) {
                closeAfterFailure();
                throw e;
            }
        }

        @Override
        public long skip(long n) throws IOException {
            try {
                return delegate.skip(n);
            } catch (IOException e) {
                closeAfterFailure();
                throw e;
            }
        }

        @Override
        public int available() throws IOException {
            try {
                return delegate.available();
            } catch (IOException e) {
                closeAfterFailure();
                throw e;
            }
        }

        @Override
        public void close() throws IOException {
            if (!closed) {
                closed = true;

                try {
                    delegate.close();
                } finally {
                    try {
                        owner.close();
                    } finally {
                        requestSlots.release();
                    }
                }
            }
        }

        private void closeAfterFailure() {
            try {
                close();
            } catch (IOException ignored) {
            } catch (RuntimeException ignored) {
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
