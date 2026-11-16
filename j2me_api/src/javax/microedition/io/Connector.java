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

/**
 * J2ME Connector implementation for JarBox.
 *
 * HTTP/HTTPS are backed by the platform Java URL connection so MIDlets can
 * download remote icons, images and other game data.
 *
 * Resources that are actually missing from a JAR are handled separately by
 * the resource/image compatibility layer. A remote URL is never treated as
 * a local JAR resource.
 */
public final class Connector {

    public static final int READ = 1;
    public static final int WRITE = 2;
    public static final int READ_WRITE = 3;

    private static final int DEFAULT_CONNECT_TIMEOUT = 8000;
    private static final int DEFAULT_READ_TIMEOUT = 10000;
    private static final int MAX_HTTP_RETRIES = 1;

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

        IOException lastError = null;

        for (int attempt = 0; attempt <= MAX_HTTP_RETRIES; attempt++) {
            Connection connection = null;

            try {
                connection = open(name, mode, false);

                if (!(connection instanceof InputConnection)) {
                    throw new IOException("Connection does not support input");
                }

                // Important for J2ME games which request many remote icons:
                // fully detach the response from HttpURLConnection before
                // returning it. The HTTP connection is then closed even if
                // Image.createImage() later fails while decoding the bytes.
                InputStream source = ((InputConnection) connection).openInputStream();
                if (source == null) {
                    throw new IOException("HTTP input stream is null");
                }

                byte[] data = readAllAndClose(source, connection);
                return new ByteArrayInputStream(data);

            } catch (IOException e) {
                lastError = e;

                if (connection != null) {
                    try {
                        connection.close();
                    } catch (IOException ignored) {
                    } catch (RuntimeException ignored) {
                    }
                }

                // Retry once with a completely new HTTP connection.
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
                throw e;
            }
        }

        throw lastError != null
            ? lastError
            : new IOException("HTTP request failed: " + name);
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
                try {
                    connection.close();
                } catch (IOException ignored) {
                } catch (RuntimeException ignored) {
                }
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
            // Do not keep a broken server socket alive between icon requests.
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
                        "HTTP " + responseCode
                        + " " + message
                    );
                }

                InputStream input = connection.getInputStream();

                if (input == null) {
                    throw new IOException("HTTP input stream is null");
                }

                return new ConnectionInputStream(
                    input,
                    this
                );
            } catch (IOException e) {
                // A failed request must not poison the following image
                // requests. Disconnect immediately before propagating
                // the error to the J2ME caller.
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
