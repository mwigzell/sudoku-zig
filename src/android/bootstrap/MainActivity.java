package com.wigzell.sudoku_zig;

import android.app.Activity;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.database.Cursor;
import android.provider.DocumentsContract;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.os.SystemClock;
import android.provider.OpenableColumns;
import android.util.Base64;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
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
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.function.Function;

public final class MainActivity extends Activity {
    private static final String LOG_IDENTITY = JniHost.logIdentity();
    private static final int REQUEST_OPEN_DOCUMENT = 2001;
    private static final int REQUEST_CREATE_DOCUMENT = 2002;
    private static final long MIN_LAUNCH_SPLASH_MS = 2000L;
    private static final long SPLASH_BOOT_TIMEOUT_MS = 12000L;
    private static final String MIME_OCTET_STREAM = "application/octet-stream";
    private static final String MIME_TEXT_PLAIN = "text/plain";
    private static final String[] OPEN_MIME_TYPES = new String[] {
        MIME_OCTET_STREAM,
        MIME_TEXT_PLAIN,
    };
    private static final String[] PUZZLE_MIME_TYPES = new String[] { MIME_TEXT_PLAIN };
    private static final String DEFAULT_SAVE_FILENAME = "sudoku.sud";
    private static final String OPENED_FALLBACK_NAME = "opened.sud";
    /** The page's flush hook (`flows/autosave.js`); the WebView fires no page hide when the app closes. */
    private static final String FLUSH_ON_CLOSE_JS = "window.__sudokuFlushOnClose && window.__sudokuFlushOnClose();";
    private static final String DISMISS_PROMPT_JS = "window.__sudokuDismissPrompt && window.__sudokuDismissPrompt();";
    private static final String DEFAULT_VISIBLE_SAVE_DIR = Environment.DIRECTORY_DOWNLOADS + "/" + JniHost.defaultFolderName();
    /** Bridge reason: this install may not write the file (an earlier install created it, or its permission is gone). */
    private static final String CLIENT_LOG_SCRIPT = "/client_log.js";
    private static final String REASON_TAKEN = "taken";
    /** Bridge result keys, read by `flows/android_steps.js`. */
    private static final String KEY_OK = "ok";
    private static final String KEY_CANCELLED = "cancelled";
    private static final String KEY_ERROR = "error";
    private static final String KEY_REASON = "reason";
    private static final String KEY_NAME = "name";
    private static final String KEY_BASE64 = "base64";
    private static final String JSON_FAILED_FALLBACK = "{\"" + KEY_OK + "\":false}";
    /** Failure kinds the bridge reports to JS; core words what the user sees, the kind and detail are logged. */
    private static final String FAILED_SAVE = "save_failed";
    private static final String FAILED_OPEN = "open_failed";
    private static final String FAILED_INTERRUPTED = "interrupted";
    private static final String FAILED_PAYLOAD = "invalid_payload";
    private static final String EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY = "com.android.externalstorage.documents";
    private static final String PRIMARY_VOLUME_DOC_PREFIX = "primary:";
    private static final String FILE_BIND_PREFS = "sudoku_file_binding";
    private static final String FILE_BIND_URI_KEY = "current_uri";
    private static final String FILE_BIND_NAME_KEY = "current_name";
    private static final String THEME_LIGHT = "light";
    private static final String THEME_DARK = "dark";
    private static final int CHROME_LIGHT = Color.parseColor("#eef0f4");
    private static final int CHROME_DARK = Color.parseColor("#16181d");
    private static final int ANDROID_UID_PER_USER_RANGE = 100000;
    /** Shown when the page never came up, so the game could not word it; the reason goes to logcat. */
    private static final String BOOT_FAILED_MSG = "The game could not start. Close the app and open it again.";
    private static final String BOOT_ERROR_HTML =
        "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>" +
        "<body style=\"margin:0;padding:16px;font-family:sans-serif;background:#16181d;color:#e6e6e6;\">" +
        "<p>" + BOOT_FAILED_MSG + "</p></body></html>";

    private FrameLayout root;
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
    private String pendingSystemBarsTheme;
    private boolean webBootReady;
    /** While a prompt is open Back dismisses it instead of leaving the app. */
    private boolean promptOpen;
    private OnBackInvokedCallback promptBackCallback;
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        restoreCurrentFileBinding();
        logStartupIdentity();

        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#16181d"));
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
        webView.clearCache(true);
        webView.addJavascriptInterface(new AndroidFileBridge(), "__SudokuAndroidBridge");
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
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
                // The client log posts its lines to the host, which writes them to logcat already.
                if (message.sourceId() != null && message.sourceId().endsWith(CLIENT_LOG_SCRIPT)) return true;
                final String rendered =
                    "JS console: " + message.message() + " @ " + message.sourceId() + ":" + message.lineNumber();
                switch (message.messageLevel()) {
                    case ERROR:
                        Log.e(LOG_IDENTITY, rendered);
                        break;
                    case WARNING:
                        Log.w(LOG_IDENTITY, rendered);
                        break;
                    case LOG:
                    case TIP:
                    case DEBUG:
                    default:
                        Log.d(LOG_IDENTITY, rendered);
                        break;
                }
                return true;
            }
        });

        launchSplashShownAtMs = SystemClock.elapsedRealtime();
        launchSplashView = makeLaunchSplashView();
        root = new FrameLayout(this);
        padClearOfSystemBars(root);
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
        applySystemBarsTheme(THEME_DARK);

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
            Log.w(LOG_IDENTITY, "Boot-ready signal not received before timeout; dismissing splash");
            showBootError("Timed out waiting for web boot-ready signal");
        }, SPLASH_BOOT_TIMEOUT_MS);
    }

    private void logStartupIdentity() {
        final int uid = getApplicationInfo().uid;
        final int userId = uid / ANDROID_UID_PER_USER_RANGE;
        final File filesDir = getFilesDir();
        final File saveFile = new File(filesDir, DEFAULT_SAVE_FILENAME);
        final String version = appVersionString();
        Log.i(
            LOG_IDENTITY,
            "android identity: package=" + getPackageName() +
                " version=" + version +
                " userId=" + userId +
                " uid=" + uid +
                " filesDir=" + filesDir.getAbsolutePath() +
                " save=" + saveFile.getAbsolutePath() +
                " exists=" + saveFile.exists()
        );
    }

    private String appVersionString() {
        try {
            final PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            final String name = info.versionName != null && !info.versionName.isEmpty() ? info.versionName : "0";
            return name + "(" + info.getLongVersionCode() + ")";
        } catch (PackageManager.NameNotFoundException ignored) {
            return "unknown";
        }
    }

    /** Show the boot failure sentence; `reason` goes to logcat only. */
    private void showBootError(String reason) {
        if (bootErrorShown) return;
        bootErrorShown = true;
        Log.e(LOG_IDENTITY, "boot failed: " + reason);
        Toast.makeText(this, BOOT_FAILED_MSG, Toast.LENGTH_LONG).show();
        webView.loadDataWithBaseURL(
            null,
            BOOT_ERROR_HTML,
            "text/html",
            "utf-8",
            null
        );
        dismissLaunchSplash();
    }

    @Override
    protected void onStop() {
        super.onStop();
        webView.evaluateJavascript(FLUSH_ON_CLOSE_JS, null);
    }

    /** Route Back to the open prompt, or give it back to the system when none is open. */
    private void setPromptOpen(boolean open) {
        promptOpen = open;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return;
        if (open && promptBackCallback == null) {
            promptBackCallback = this::dismissPrompt;
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, promptBackCallback);
        } else if (!open && promptBackCallback != null) {
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(promptBackCallback);
            promptBackCallback = null;
        }
    }

    private void dismissPrompt() {
        webView.evaluateJavascript(DISMISS_PROMPT_JS, null);
    }

    /** Back before Android 13; later versions use the callback `setPromptOpen` registers. */
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (promptOpen) {
            dismissPrompt();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        cancelPendingPicks();
        if (!isChangingConfigurations()) {
            JniHost.stopHost();
        }
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
                return;
            }
        }
        if (requestCode == REQUEST_CREATE_DOCUMENT && resultCode == RESULT_OK && data != null) {
            deleteIfEmpty(data.getData());
        }
    }

    /** A destroyed activity gets no picker result: end its waiting bridge calls as cancelled. */
    private void cancelPendingPicks() {
        synchronized (pickerLock) {
            if (openWaiter != null) openWaiter.complete(RESULT_CANCELED, null);
            if (saveWaiter != null) saveWaiter.complete(RESULT_CANCELED, null);
            openWaiter = null;
            saveWaiter = null;
        }
    }

    /** The picker creates the document before the app writes it; a create nobody waits for leaves it empty. */
    private void deleteIfEmpty(Uri uri) {
        if (uri == null) return;
        try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst() || cursor.getLong(0) != 0) return;
            DocumentsContract.deleteDocument(getContentResolver(), uri);
            Log.i(LOG_IDENTITY, "deleted empty document from a pick no call was waiting for: " + uri);
        } catch (RuntimeException | IOException err) {
            Log.w(LOG_IDENTITY, "could not delete empty document " + uri + ": " + err);
        }
    }

    private int dpToPx(int dp) {
        return Math.round(TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp,
            getResources().getDisplayMetrics()
        ));
    }

    /** From API 35 the window draws under the system bars: keep the game clear of them; the bars show the root's colour. */
    private static void padClearOfSystemBars(View view) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return;
        view.setOnApplyWindowInsetsListener((v, insets) -> {
            final Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return WindowInsets.CONSUMED;
        });
    }

    private void applySystemBarsTheme(String themeName) {
        final boolean lightTheme = THEME_LIGHT.equals(themeName);
        final Window window = getWindow();
        if (window == null) return;
        final int chromeColor = lightTheme ? CHROME_LIGHT : CHROME_DARK;
        root.setBackgroundColor(chromeColor);
        window.setStatusBarColor(chromeColor);
        window.setNavigationBarColor(chromeColor);
        final View decor = window.getDecorView();
        if (decor == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            final WindowInsetsController controller = window.getInsetsController();
            if (controller == null) return;
            final int lightMask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            controller.setSystemBarsAppearance(lightTheme ? lightMask : 0, lightMask);
            return;
        }
        int flags = decor.getSystemUiVisibility();
        final int legacyMask = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        if (lightTheme) flags |= legacyMask;
        else flags &= ~legacyMask;
        decor.setSystemUiVisibility(flags);
    }

    private String resolveSystemBarsThemeFromSystem() {
        final int mask = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
        return mask == Configuration.UI_MODE_NIGHT_YES ? THEME_DARK : THEME_LIGHT;
    }

    private void applyDeferredSystemBarsTheme() {
        final String theme =
            pendingSystemBarsTheme != null ? pendingSystemBarsTheme : resolveSystemBarsThemeFromSystem();
        pendingSystemBarsTheme = null;
        applySystemBarsTheme(theme);
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
                    if (webBootReady) applyDeferredSystemBarsTheme();
                })
                .start();
        }, remaining);
    }

    /** One bridge result object; keys and values alternate. */
    private static String jsonResult(Object... keysAndValues) {
        final JSONObject out = new JSONObject();
        try {
            for (int i = 0; i + 1 < keysAndValues.length; i += 2) out.put((String) keysAndValues[i], keysAndValues[i + 1]);
        } catch (JSONException err) {
            return JSON_FAILED_FALLBACK;
        }
        return out.toString();
    }

    private static String jsonCancelled() {
        return jsonResult(KEY_OK, false, KEY_CANCELLED, true);
    }

    private static String jsonFailed(String reason) {
        return jsonResult(KEY_OK, false, KEY_ERROR, reason);
    }

    private static String jsonFailed(String kind, Throwable cause) {
        return jsonFailed(kind + ": " + cause);
    }

    private static String jsonTaken(String name) {
        return jsonResult(KEY_OK, false, KEY_REASON, REASON_TAKEN, KEY_NAME, name);
    }

    private static String jsonSaveOk(String name) {
        return jsonResult(KEY_OK, true, KEY_NAME, name);
    }

    private static String jsonOpenOk(String name, String base64) {
        return jsonResult(KEY_OK, true, KEY_NAME, name, KEY_BASE64, base64);
    }

    /** Decode the page's Base64 payload and hand the bytes to `save`; a bad payload fails the call. */
    private static String withPayload(String base64, Function<byte[], String> save) {
        final byte[] bytes;
        try {
            bytes = Base64.decode(base64, Base64.DEFAULT);
        } catch (IllegalArgumentException err) {
            return jsonFailed(FAILED_PAYLOAD, err);
        }
        return save.apply(bytes);
    }

    private void rememberCurrentFile(Uri uri, String fallbackName) {
        if (uri == null) return;
        final String resolvedName = displayNameOf(uri, fallbackName);
        synchronized (pickerLock) {
            currentFileUri = uri;
            currentFileName = resolvedName;
        }
        persistCurrentFileBinding(uri, resolvedName);
    }

    private SharedPreferences fileBindingPrefs() {
        return getSharedPreferences(FILE_BIND_PREFS, MODE_PRIVATE);
    }

    private void persistCurrentFileBinding(Uri uri, String name) {
        if (uri == null) return;
        fileBindingPrefs()
            .edit()
            .putString(FILE_BIND_URI_KEY, uri.toString())
            .putString(FILE_BIND_NAME_KEY, name)
            .apply();
    }

    private void restoreCurrentFileBinding() {
        final String uriText = fileBindingPrefs().getString(FILE_BIND_URI_KEY, null);
        if (uriText == null || uriText.isEmpty()) return;
        final Uri uri = Uri.parse(uriText);
        final String name = fileBindingPrefs().getString(FILE_BIND_NAME_KEY, DEFAULT_SAVE_FILENAME);
        synchronized (pickerLock) {
            currentFileUri = uri;
            currentFileName = name;
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
        waiter.await();
        if (waiter.resultCode != RESULT_OK || waiter.data == null) return null;
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

    /** Every picker starts in the bound file's folder, else in the default folder; the player can still browse away. */
    private void startInGameFolder(Intent picker) {
        final Uri bound = currentUri();
        final Uri folder = bound != null ? folderOf(bound) : null;
        picker.putExtra(DocumentsContract.EXTRA_INITIAL_URI, folder != null ? folder : DocumentsContract.buildDocumentUri(
            EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY, PRIMARY_VOLUME_DOC_PREFIX + DEFAULT_VISIBLE_SAVE_DIR));
    }

    /** The document folder holding `file`, or null when its provider cannot say (e.g. a MediaStore entry). */
    private Uri folderOf(Uri file) {
        if (!DocumentsContract.isDocumentUri(this, file)) return null;
        try {
            final DocumentsContract.Path path = DocumentsContract.findDocumentPath(getContentResolver(), file);
            if (path == null) return null;
            final List<String> ids = path.getPath();
            if (ids == null || ids.size() < 2) return null;
            return DocumentsContract.buildDocumentUri(file.getAuthority(), ids.get(ids.size() - 2));
        } catch (IOException | RuntimeException err) {
            return null;
        }
    }

    /** Let the player pick a file of `mimeTypes` and read it; a saved game becomes the current file, a puzzle does not. */
    private String readViaPicker(String[] mimeTypes, boolean bindsFile, String fallbackName) {
        final Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        pick.addCategory(Intent.CATEGORY_OPENABLE);
        pick.setType(mimeTypes[0]);
        pick.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes);
        startInGameFolder(pick);
        pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        if (bindsFile) {
            pick.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            pick.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        }

        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_OPEN_DOCUMENT, pick);
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonFailed(FAILED_INTERRUPTED, err);
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        if (bindsFile) rememberPersistedPermission(result);
        final Uri uri = result.getData();
        final String name = displayNameOf(uri, fallbackName);

        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) return jsonFailed(FAILED_OPEN);
            final ByteArrayOutputStream out = new ByteArrayOutputStream();
            final byte[] buf = new byte[8192];
            int read;
            while ((read = in.read(buf)) != -1) out.write(buf, 0, read);
            if (bindsFile) rememberCurrentFile(uri, name);
            final String base64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
            return jsonOpenOk(name, base64);
        } catch (IOException err) {
            return jsonFailed(FAILED_OPEN, err);
        }
    }

    /** Write `bytes` to `uri`; null when written, else the failure result. */
    private String writeBytes(Uri uri, byte[] bytes) {
        try (OutputStream out = getContentResolver().openOutputStream(uri, "w")) {
            if (out == null) return jsonFailed(FAILED_SAVE);
            out.write(bytes);
            out.flush();
            return null;
        } catch (IOException err) {
            return jsonFailed(FAILED_SAVE, err);
        }
    }

    /** Write the saved game to `uri` and bind it; a file this install has no permission for is reported as taken. */
    private String saveBytesTo(Uri uri, byte[] bytes, String fallbackName) {
        final String failed;
        try {
            failed = writeBytes(uri, bytes);
        } catch (SecurityException err) {
            Log.w(LOG_IDENTITY, "no permission to write " + uri + ": " + err);
            return jsonTaken(fallbackName);
        }
        if (failed != null) return failed;
        rememberCurrentFile(uri, fallbackName);
        return jsonSaveOk(currentNameOr(fallbackName));
    }

    private Intent createDocumentIntent(String suggestedName, String mimeType) {
        final Intent create = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        create.addCategory(Intent.CATEGORY_OPENABLE);
        create.setType(mimeType);
        create.putExtra(Intent.EXTRA_TITLE, suggestedName);
        startInGameFolder(create);
        create.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        create.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        create.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        return create;
    }

    /** Let the player name a new file of `mimeType` and write `bytes` there; a saved game becomes the current file, a puzzle does not. */
    private String writeViaCreatePicker(byte[] bytes, String suggestedName, String mimeType, boolean bindsFile) {
        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_CREATE_DOCUMENT, createDocumentIntent(suggestedName, mimeType));
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonFailed(FAILED_INTERRUPTED, err);
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        final Uri uri = result.getData();
        final String name = displayNameOf(uri, suggestedName);
        if (!bindsFile) {
            final String failed = writeBytes(uri, bytes);
            return failed != null ? failed : jsonSaveOk(name);
        }
        rememberPersistedPermission(result);
        return saveBytesTo(uri, bytes, name);
    }

    /**
     * Writes the default autosave file in shared Downloads/Sudoku (no picker) and makes it the current file.
     * A same-named file this install does not own (left by an earlier install) is never shadowed by a renamed copy;
     * the result reports it so core can ask the user to pick it or choose a new name.
     */
    private String saveToDefaultVisible(byte[] bytes, String suggestedName) {
        final String name = defaultVisibleName(suggestedName);
        final Uri owned = findOwnedDefaultVisible(name);
        if (owned != null) return saveBytesTo(owned, bytes, name);

        final ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        values.put(MediaStore.MediaColumns.MIME_TYPE, MIME_OCTET_STREAM);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, DEFAULT_VISIBLE_SAVE_DIR);
        final Uri uri;
        try {
            uri = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        } catch (RuntimeException err) {
            return jsonFailed(FAILED_SAVE, err);
        }
        if (uri == null) return jsonFailed(FAILED_SAVE);
        if (name.equals(displayNameOf(uri, name))) return saveBytesTo(uri, bytes, name);

        try {
            getContentResolver().delete(uri, null, null);
        } catch (RuntimeException ignored) {
            // Leaves an empty renamed entry; the user's pick or new name still decides the current file.
        }
        return jsonTaken(name);
    }

    private String saveViaPickExisting(byte[] bytes) {
        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_OPEN_DOCUMENT, pickExistingIntent());
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonFailed(FAILED_INTERRUPTED, err);
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        rememberPersistedPermission(result);
        final Uri uri = result.getData();
        return saveBytesTo(uri, bytes, displayNameOf(uri, DEFAULT_SAVE_FILENAME));
    }

    /** MediaStore only lists files this install owns, so a hit is ours to overwrite. */
    private static String defaultVisibleName(String suggestedName) {
        return (suggestedName == null || suggestedName.isEmpty()) ? DEFAULT_SAVE_FILENAME : suggestedName;
    }

    private Uri findOwnedDefaultVisible(String name) {
        final String[] projection = new String[] { MediaStore.MediaColumns._ID };
        final String selection =
            MediaStore.MediaColumns.RELATIVE_PATH + "=? AND " + MediaStore.MediaColumns.DISPLAY_NAME + "=?";
        final String[] args = new String[] { DEFAULT_VISIBLE_SAVE_DIR + "/", name };
        try (Cursor cursor = getContentResolver().query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI, projection, selection, args, null)) {
            if (cursor == null || !cursor.moveToFirst()) return null;
            return ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cursor.getLong(0));
        } catch (RuntimeException err) {
            return null;
        }
    }

    /** Lets the user grant this install write access to an existing file in the default folder. */
    private Intent pickExistingIntent() {
        final Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        pick.addCategory(Intent.CATEGORY_OPENABLE);
        pick.setType(MIME_OCTET_STREAM);
        pick.putExtra(Intent.EXTRA_MIME_TYPES, OPEN_MIME_TYPES);
        startInGameFolder(pick);
        pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        return pick;
    }

    /** One method per file step (`flows/android_steps.js`), plus the page's boot, theme, prompt and error signals. */
    private final class AndroidFileBridge {
        /** The bound file, else a new file the player names. */
        @JavascriptInterface
        public String save(String base64, String suggestedName) {
            return withPayload(base64, bytes -> {
                final Uri uri = currentUri();
                if (uri != null) return saveBytesTo(uri, bytes, currentNameOr(suggestedName));
                return writeViaCreatePicker(bytes, suggestedName, MIME_OCTET_STREAM, true);
            });
        }

        @JavascriptInterface
        public String saveAs(String base64, String suggestedName) {
            return withPayload(base64, bytes -> writeViaCreatePicker(bytes, suggestedName, MIME_OCTET_STREAM, true));
        }

        /** The bound file, else the default visible file. */
        @JavascriptInterface
        public String autosave(String base64, String suggestedName) {
            return withPayload(base64, bytes -> {
                final Uri uri = currentUri();
                if (uri == null) return saveToDefaultVisible(bytes, suggestedName);
                return saveBytesTo(uri, bytes, currentNameOr(suggestedName));
            });
        }

        /** Whether this install's default visible file is there; another install's file is not seen here and answers taken on write. */
        @JavascriptInterface
        public boolean defaultFileExists(String suggestedName) {
            return findOwnedDefaultVisible(defaultVisibleName(suggestedName)) != null;
        }

        @JavascriptInterface
        public String reclaimFile(String base64) {
            return withPayload(base64, bytes -> saveViaPickExisting(bytes));
        }

        @JavascriptInterface
        public String open() {
            return readViaPicker(OPEN_MIME_TYPES, true, OPENED_FALLBACK_NAME);
        }

        @JavascriptInterface
        public String importPuzzle() {
            return readViaPicker(PUZZLE_MIME_TYPES, false, "");
        }

        @JavascriptInterface
        public String exportPuzzle(String base64, String suggestedName) {
            return withPayload(base64, bytes -> writeViaCreatePicker(bytes, suggestedName, MIME_TEXT_PLAIN, false));
        }

        @JavascriptInterface
        public String currentSudokuFileName() {
            if (currentUri() == null) return "";
            return currentNameOr("");
        }

        @JavascriptInterface
        public void logJsError(String message, String source, int line, int column) {
            Log.e(LOG_IDENTITY, "JS error: " + message + " @ " + source + ":" + line + ":" + column);
        }

        @JavascriptInterface
        public void setPromptOpen(boolean open) {
            runOnUiThread(() -> MainActivity.this.setPromptOpen(open));
        }

        @JavascriptInterface
        public void notifyWebBootReady() {
            runOnUiThread(() -> {
                webBootReady = true;
                if (launchSplashView == null) applyDeferredSystemBarsTheme();
                dismissLaunchSplash();
            });
        }

        @JavascriptInterface
        public void setSystemBars(String themeName) {
            final String resolved = THEME_LIGHT.equals(themeName) ? THEME_LIGHT : THEME_DARK;
            runOnUiThread(() -> {
                // The bars stay dark until the splash is gone; the splash's fade-out applies the held theme.
                if (!webBootReady || launchSplashView != null) {
                    pendingSystemBarsTheme = resolved;
                    return;
                }
                applySystemBarsTheme(resolved);
            });
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

        /** No time bound: the player may take as long as they like in a picker; `onDestroy` ends a wait that can't finish. */
        void await() throws InterruptedException {
            done.await();
        }
    }
}
