package com.wigzell.sudoku_zig;

public final class JniHost {
    private static final int READY_POLL_INTERVAL_MS = 50;
    private static final int READY_TIMEOUT_MS = 8000;

    public interface ReadyCallback {
        void onReady(String url);

        void onError(String message);
    }

    static {
        System.loadLibrary("sudoku_zig");
    }

    private JniHost() {}

    public static void startHost(String dataDir, ReadyCallback callback) {
        Thread bootThread = new Thread(() -> {
            startHostNative(dataDir);
            int elapsedMs = 0;
            while (elapsedMs < READY_TIMEOUT_MS) {
                int state = bootState();
                if (state > 0) {
                    callback.onReady("http://127.0.0.1:" + state + "/");
                    return;
                }
                if (state < 0) {
                    callback.onError(startupFailureMessage());
                    return;
                }
                try {
                    Thread.sleep(READY_POLL_INTERVAL_MS);
                } catch (InterruptedException err) {
                    Thread.currentThread().interrupt();
                    callback.onError("Host startup interrupted: " + err);
                    return;
                }
                elapsedMs += READY_POLL_INTERVAL_MS;
            }
            callback.onError("Timed out waiting for loopback host");
        }, "sudoku-host-boot");
        bootThread.setDaemon(true);
        bootThread.start();
    }

    /** Core's sentence for a boot that refused its settings; empty when startup did not fail. */
    public static String startupFailureMessage() {
        final String value = startupFailureMessageNative();
        return value == null ? "" : value;
    }

    private static native void startHostNative(String dataDir);

    /** Where the boot stands: 0 while starting, -1 when it refused its settings, otherwise the port. */
    private static native int bootState();
    private static native String startupFailureMessageNative();

    public static native void stopHost();

    private static native String logIdentityNative();

    private static native String defaultFolderNameNative();

    /** Core's default folder name; the caller chooses the parent folder. */
    public static String defaultFolderName() {
        return defaultFolderNameNative();
    }

    public static String logIdentity() {
        final String value = logIdentityNative();
        if (value == null || value.isEmpty()) return "sudoku-zig";
        return value;
    }
}
