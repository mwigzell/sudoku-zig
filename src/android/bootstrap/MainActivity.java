package com.wigzell.sudoku_zig;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.provider.DocumentsContract;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.SystemClock;
import android.provider.OpenableColumns;
import android.util.Base64;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Toast;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.TextView;
import android.webkit.ConsoleMessage;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebChromeClient;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class MainActivity extends Activity {
    private static final String TAG = "SudokuAndroid";
    private static final int REQUEST_OPEN_DOCUMENT = 2001;
    private static final int REQUEST_CREATE_DOCUMENT = 2002;
    private static final int PICKER_TIMEOUT_SECONDS = 60;
    private static final long MIN_LAUNCH_SPLASH_MS = 2000L;
    private static final long SPLASH_BOOT_TIMEOUT_MS = 12000L;
    private static final String MIME_ANY = "*/*";
    private static final String BOOT_ERROR_HTML_PREFIX =
        "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>" +
        "<body style=\"margin:0;padding:16px;font-family:sans-serif;background:#16181d;color:#e6e6e6;\">" +
        "<h3 style=\"margin:0 0 8px;\">Sudoku startup failed</h3><pre style=\"white-space:pre-wrap;word-break:break-word;\">";
    private static final String BOOT_ERROR_HTML_SUFFIX = "</pre></body></html>";

    private WebView webView;
    private View launchSplashView;
    private long launchSplashShownAtMs;
    private boolean splashDismissed = false;
    private boolean bootErrorShown = false;
    private final Object pickerLock = new Object();
    private ActivityResultWaiter openWaiter;
    private ActivityResultWaiter saveWaiter;
    private Uri currentFileUri;
    private String currentFileName;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#16181d"));
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        webView.addJavascriptInterface(new AndroidFileBridge(), "__SudokuAndroidBridge");
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                injectBridgeShim();
                if (url != null && url.startsWith("http://127.0.0.1:")) {
                    dismissLaunchSplash();
                }
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                super.onReceivedError(view, request, error);
                if (request == null || !request.isForMainFrame()) return;
                final String msg = error != null ? String.valueOf(error.getDescription()) : "main frame load failed";
                showBootError("webview main-frame error: " + msg);
            }

            @Override
            public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                super.onReceivedHttpError(view, request, response);
                if (request == null || !request.isForMainFrame()) return;
                final int code = response != null ? response.getStatusCode() : -1;
                showBootError("webview main-frame http error: " + code);
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage message) {
                if (message == null) return true;
                Log.d(
                    TAG,
                    "JS console: " + message.message() + " @ " + message.sourceId() + ":" + message.lineNumber()
                );
                return true;
            }
        });

        launchSplashShownAtMs = SystemClock.elapsedRealtime();
        launchSplashView = makeLaunchSplashView();
        FrameLayout root = new FrameLayout(this);
        root.addView(
            webView,
            new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        );
        root.addView(
            launchSplashView,
            new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        );

        webView.loadUrl("about:blank");
        setContentView(root);

        JniHost.startHost(getFilesDir().getAbsolutePath(), new JniHost.ReadyCallback() {
            @Override
            public void onReady(String url) {
                runOnUiThread(() -> webView.loadUrl(url));
            }

            @Override
            public void onError(String message) {
                runOnUiThread(() -> showBootError(message));
            }
        });

        webView.postDelayed(() -> {
            if (splashDismissed) return;
            Log.w(TAG, "Boot-ready signal not received before timeout; dismissing splash");
            showBootError("Timed out waiting for web boot-ready signal");
        }, SPLASH_BOOT_TIMEOUT_MS);
    }

    private static String escapeHtml(String in) {
        if (in == null) return "";
        return in
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;");
    }

    private void showBootError(String message) {
        if (bootErrorShown) return;
        bootErrorShown = true;
        final String msg = message != null ? message : "unknown startup failure";
        Log.e(TAG, msg);
        Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
        webView.loadDataWithBaseURL(
            null,
            BOOT_ERROR_HTML_PREFIX + escapeHtml(msg) + BOOT_ERROR_HTML_SUFFIX,
            "text/html",
            "utf-8",
            null
        );
        dismissLaunchSplash();
    }

    @Override
    protected void onDestroy() {
        JniHost.stopHost();
        super.onDestroy();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        synchronized (pickerLock) {
            if (requestCode == REQUEST_OPEN_DOCUMENT && openWaiter != null) {
                openWaiter.complete(resultCode, data);
                openWaiter = null;
                return;
            }
            if (requestCode == REQUEST_CREATE_DOCUMENT && saveWaiter != null) {
                saveWaiter.complete(resultCode, data);
                saveWaiter = null;
            }
        }
    }

    private void injectBridgeShim() {
        final String shim = "window.AndroidFileBridge = {" +
            "saveSudokuFile:function(base64,suggestedName,saveAs){" +
            "return JSON.parse(window.__SudokuAndroidBridge.saveSudokuFile(String(base64||\"\"),String(suggestedName||\"\"),!!saveAs));" +
            "}," +
            "openSudokuFile:function(){" +
            "return JSON.parse(window.__SudokuAndroidBridge.openSudokuFile());" +
            "}," +
            "notifyWebBootReady:function(){" +
            "window.__SudokuAndroidBridge.notifyWebBootReady();" +
            "}" +
            "};" +
            "window.addEventListener('error',function(e){" +
            "window.__SudokuAndroidBridge.logJsError(String((e&&e.message)||'unknown js error'),String((e&&e.filename)||''),Number((e&&e.lineno)||0),Number((e&&e.colno)||0));" +
            "});" +
            "window.addEventListener('unhandledrejection',function(e){" +
            "var reason=(e&&e.reason!=null)?String(e.reason):'unhandled rejection';" +
            "window.__SudokuAndroidBridge.logJsError(reason,'promise',0,0);" +
            "});" +
            "if(window.__sudokuBootReady===true){window.__SudokuAndroidBridge.notifyWebBootReady();}";
        webView.evaluateJavascript(shim, null);
    }

    private int dpToPx(int dp) {
        return Math.round(TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp,
            getResources().getDisplayMetrics()
        ));
    }

    private View makeLaunchSplashView() {
        View overlay = new View(this);
        int splashBgResId = getResources().getIdentifier("splash_background", "drawable", getPackageName());
        if (splashBgResId != 0) {
            overlay.setBackgroundResource(splashBgResId);
        } else {
            overlay.setBackgroundColor(Color.parseColor("#16181d"));
        }
        return overlay;
    }

    private void dismissLaunchSplash() {
        splashDismissed = true;
        final View splash = launchSplashView;
        if (splash == null) return;
        long elapsed = SystemClock.elapsedRealtime() - launchSplashShownAtMs;
        long remaining = Math.max(0L, MIN_LAUNCH_SPLASH_MS - elapsed);
        splash.postDelayed(() -> {
            final View current = launchSplashView;
            if (current == null) return;
            current.animate()
                .alpha(0f)
                .setDuration(120)
                .withEndAction(() -> {
                    ViewGroup parent = (ViewGroup) current.getParent();
                    if (parent != null) parent.removeView(current);
                    launchSplashView = null;
                })
                .start();
        }, remaining);
    }

    private static String jsonCancelled() {
        try {
            return new JSONObject().put("ok", false).put("cancelled", true).toString();
        } catch (JSONException err) {
            return "{\"ok\":false,\"cancelled\":true}";
        }
    }

    private static String jsonError(String message) {
        try {
            return new JSONObject().put("ok", false).put("error", message).toString();
        } catch (JSONException err) {
            return "{\"ok\":false,\"error\":\"internal error\"}";
        }
    }

    private static String jsonSaveOk(String name) {
        try {
            return new JSONObject().put("ok", true).put("name", name).toString();
        } catch (JSONException err) {
            return "{\"ok\":true}";
        }
    }

    private static String jsonOpenOk(String name, String base64) {
        try {
            return new JSONObject().put("ok", true).put("name", name).put("base64", base64).toString();
        } catch (JSONException err) {
            return "{\"ok\":false,\"error\":\"invalid Android file payload\"}";
        }
    }

    private void rememberCurrentFile(Uri uri, String fallbackName) {
        synchronized (pickerLock) {
            currentFileUri = uri;
            currentFileName = displayNameOf(uri, fallbackName);
        }
    }

    private String currentNameOr(String fallback) {
        synchronized (pickerLock) {
            if (currentFileName != null && !currentFileName.isEmpty()) return currentFileName;
        }
        return fallback;
    }

    private Uri currentUri() {
        synchronized (pickerLock) {
            return currentFileUri;
        }
    }

    private ActivityResultWaiter beginWaiterFor(int requestCode) {
        final ActivityResultWaiter waiter = new ActivityResultWaiter();
        synchronized (pickerLock) {
            if (requestCode == REQUEST_OPEN_DOCUMENT) {
                openWaiter = waiter;
            } else if (requestCode == REQUEST_CREATE_DOCUMENT) {
                saveWaiter = waiter;
            }
        }
        return waiter;
    }

    private Intent awaitResultIntent(int requestCode, Intent intent) throws InterruptedException {
        final ActivityResultWaiter waiter = beginWaiterFor(requestCode);
        runOnUiThread(() -> startActivityForResult(intent, requestCode));
        final boolean finished = waiter.await(PICKER_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        if (!finished || waiter.resultCode != RESULT_OK || waiter.data == null) return null;
        return waiter.data;
    }

    private void rememberPersistedPermission(Intent data) {
        if (data == null || data.getData() == null) return;
        final int grantFlags = data.getFlags()
            & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        try {
            getContentResolver().takePersistableUriPermission(data.getData(), grantFlags);
        } catch (SecurityException ignored) {
            // Some providers do not offer persistable grants; runtime access can still work.
        }
    }

    private String displayNameOf(Uri uri, String fallback) {
        if (uri == null) return fallback;
        Cursor cursor = null;
        try {
            cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null);
            if (cursor != null && cursor.moveToFirst()) {
                final int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) {
                    final String name = cursor.getString(idx);
                    if (name != null && !name.isEmpty()) return name;
                }
            }
        } catch (RuntimeException ignored) {
            // Provider metadata failed; fallback name still gives usable UX.
        } finally {
            if (cursor != null) cursor.close();
        }
        try {
            final String docId = DocumentsContract.getDocumentId(uri);
            if (docId != null) {
                final int sep = docId.lastIndexOf(':');
                final String tail = sep >= 0 ? docId.substring(sep + 1) : docId;
                if (tail != null && !tail.isEmpty()) return tail;
            }
        } catch (RuntimeException ignored) {
            // Non-document URI or provider does not expose a document ID.
        }
        final String segment = uri.getLastPathSegment();
        if (segment != null && !segment.isEmpty()) return segment;
        return fallback;
    }

    private String openViaPicker() {
        final Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        pick.addCategory(Intent.CATEGORY_OPENABLE);
        pick.setType(MIME_ANY);
        pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);

        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_OPEN_DOCUMENT, pick);
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonError("open interrupted");
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        rememberPersistedPermission(result);
        final Uri uri = result.getData();
        final String name = displayNameOf(uri, "opened.sud");

        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) return jsonError("open failed");
            final ByteArrayOutputStream out = new ByteArrayOutputStream();
            final byte[] buf = new byte[8192];
            int read;
            while ((read = in.read(buf)) != -1) out.write(buf, 0, read);
            rememberCurrentFile(uri, name);
            final String base64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
            return jsonOpenOk(name, base64);
        } catch (IOException err) {
            return jsonError("open failed");
        }
    }

    private String saveBytesTo(Uri uri, byte[] bytes, String fallbackName) {
        try (OutputStream out = getContentResolver().openOutputStream(uri, "w")) {
            if (out == null) return jsonError("save failed");
            out.write(bytes);
            out.flush();
            rememberCurrentFile(uri, fallbackName);
            return jsonSaveOk(currentNameOr(fallbackName));
        } catch (IOException err) {
            return jsonError("save failed");
        }
    }

    private String saveViaCreateDocument(byte[] bytes, String suggestedName) {
        final Intent create = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        create.addCategory(Intent.CATEGORY_OPENABLE);
        create.setType("application/octet-stream");
        create.putExtra(Intent.EXTRA_TITLE, suggestedName);
        create.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        create.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        create.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);

        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_CREATE_DOCUMENT, create);
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonError("save interrupted");
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        rememberPersistedPermission(result);
        final Uri uri = result.getData();
        final String name = displayNameOf(uri, suggestedName);
        return saveBytesTo(uri, bytes, name);
    }

    private final class AndroidFileBridge {
        @JavascriptInterface
        public String saveSudokuFile(String base64, String suggestedName, boolean saveAs) {
            final byte[] bytes;
            try {
                bytes = Base64.decode(base64, Base64.DEFAULT);
            } catch (IllegalArgumentException err) {
                return jsonError("invalid save payload");
            }

            if (!saveAs) {
                final Uri uri = currentUri();
                if (uri != null) return saveBytesTo(uri, bytes, currentNameOr(suggestedName));
            }
            return saveViaCreateDocument(bytes, suggestedName);
        }

        @JavascriptInterface
        public String openSudokuFile() {
            return openViaPicker();
        }

        @JavascriptInterface
        public void logJsError(String message, String source, int line, int column) {
            Log.e(TAG, "JS error: " + message + " @ " + source + ":" + line + ":" + column);
        }

        @JavascriptInterface
        public void notifyWebBootReady() {
            runOnUiThread(() -> dismissLaunchSplash());
        }
    }

    private static final class ActivityResultWaiter {
        private final CountDownLatch done = new CountDownLatch(1);
        private int resultCode = Activity.RESULT_CANCELED;
        private Intent data = null;

        void complete(int code, Intent intent) {
            this.resultCode = code;
            this.data = intent;
            this.done.countDown();
        }

        boolean await(long timeout, TimeUnit unit) throws InterruptedException {
            return done.await(timeout, unit);
        }
    }
}
