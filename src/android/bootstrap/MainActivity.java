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

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;

public final class MainActivity extends Activity {
    private static final String LOG_IDENTITY = JniHost.logIdentity();
    private static final int REQUEST_OPEN_DOCUMENT = 2001;
    private static final int REQUEST_CREATE_DOCUMENT = 2002;
    private static final int PICKER_TIMEOUT_SECONDS = 60;
    private static final long MIN_LAUNCH_SPLASH_MS = 2000L;
    private static final long SPLASH_BOOT_TIMEOUT_MS = 12000L;
    private static final String MIME_OCTET_STREAM = "application/octet-stream";
    private static final String MIME_TEXT_PLAIN = "text/plain";
    private static final String[] OPEN_MIME_TYPES = new String[] {
        MIME_OCTET_STREAM,
        MIME_TEXT_PLAIN,
    };
    private static final String DEFAULT_SAVE_FILENAME = "sudoku.sud";
    private static final String DEFAULT_VISIBLE_SAVE_DIR = Environment.DIRECTORY_DOWNLOADS + "/" + JniHost.defaultFolderName();
    private static final String REASON_DEFAULT_TAKEN = "default_taken";
    /** Bridge result keys, read by `file_menu.js`. */
    private static final String KEY_OK = "ok";
    private static final String KEY_CANCELLED = "cancelled";
    private static final String KEY_ERROR = "error";
    private static final String KEY_REASON = "reason";
    private static final String KEY_NAME = "name";
    private static final String KEY_DIR = "dir";
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
    protected void onDestroy() {
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
            }
        }
    }

    private int dpToPx(int dp) {
        return Math.round(TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp,
            getResources().getDisplayMetrics()
        ));
    }

    private void applySystemBarsTheme(String themeName) {
        final boolean lightTheme = THEME_LIGHT.equals(themeName);
        final Window window = getWindow();
        if (window == null) return;
        final int chromeColor = lightTheme ? CHROME_LIGHT : CHROME_DARK;
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

    private static String jsonDefaultTaken(String name) {
        return jsonResult(KEY_OK, false, KEY_REASON, REASON_DEFAULT_TAKEN, KEY_NAME, name, KEY_DIR, DEFAULT_VISIBLE_SAVE_DIR);
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
        pick.setType(MIME_OCTET_STREAM);
        pick.putExtra(Intent.EXTRA_MIME_TYPES, OPEN_MIME_TYPES);
        pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);

        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_OPEN_DOCUMENT, pick);
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonFailed(FAILED_INTERRUPTED, err);
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        rememberPersistedPermission(result);
        final Uri uri = result.getData();
        final String name = displayNameOf(uri, "opened.sud");

        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) return jsonFailed(FAILED_OPEN);
            final ByteArrayOutputStream out = new ByteArrayOutputStream();
            final byte[] buf = new byte[8192];
            int read;
            while ((read = in.read(buf)) != -1) out.write(buf, 0, read);
            rememberCurrentFile(uri, name);
            final String base64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
            return jsonOpenOk(name, base64);
        } catch (IOException err) {
            return jsonFailed(FAILED_OPEN, err);
        }
    }

    private String saveBytesTo(Uri uri, byte[] bytes, String fallbackName) {
        try (OutputStream out = getContentResolver().openOutputStream(uri, "w")) {
            if (out == null) return jsonFailed(FAILED_SAVE);
            out.write(bytes);
            out.flush();
            rememberCurrentFile(uri, fallbackName);
            return jsonSaveOk(currentNameOr(fallbackName));
        } catch (IOException err) {
            return jsonFailed(FAILED_SAVE, err);
        }
    }

    private static Intent createDocumentIntent(String suggestedName) {
        final Intent create = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        create.addCategory(Intent.CATEGORY_OPENABLE);
        create.setType(MIME_OCTET_STREAM);
        create.putExtra(Intent.EXTRA_TITLE, suggestedName);
        create.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        create.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        create.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        return create;
    }

    private String saveViaCreateDocument(byte[] bytes, String suggestedName) {
        final Intent result;
        try {
            result = awaitResultIntent(REQUEST_CREATE_DOCUMENT, createDocumentIntent(suggestedName));
        } catch (InterruptedException err) {
            Thread.currentThread().interrupt();
            return jsonFailed(FAILED_INTERRUPTED, err);
        }
        if (result == null || result.getData() == null) return jsonCancelled();
        rememberPersistedPermission(result);
        final Uri uri = result.getData();
        final String name = displayNameOf(uri, suggestedName);
        return saveBytesTo(uri, bytes, name);
    }

    /**
     * Writes the default autosave file in shared Downloads/Sudoku (no picker) and makes it the working file.
     * A same-named file this install does not own (left by an earlier install) is never shadowed by a renamed copy;
     * the result reports it so core can ask the user to pick it or choose a new name.
     */
    private String saveToDefaultVisible(byte[] bytes, String suggestedName) {
        final String name = (suggestedName == null || suggestedName.isEmpty()) ? DEFAULT_SAVE_FILENAME : suggestedName;
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
            // Leaves an empty renamed entry; the user's pick or new name still decides the working file.
        }
        return jsonDefaultTaken(name);
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
    private static Intent pickExistingIntent() {
        final Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        pick.addCategory(Intent.CATEGORY_OPENABLE);
        pick.setType(MIME_OCTET_STREAM);
        pick.putExtra(Intent.EXTRA_MIME_TYPES, OPEN_MIME_TYPES);
        pick.putExtra(DocumentsContract.EXTRA_INITIAL_URI, DocumentsContract.buildDocumentUri(
            EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY, PRIMARY_VOLUME_DOC_PREFIX + DEFAULT_VISIBLE_SAVE_DIR));
        pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        pick.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        return pick;
    }

    private final class AndroidFileBridge {
        @JavascriptInterface
        public String saveSudokuFile(String base64, String suggestedName, boolean saveAs) {
            return withPayload(base64, bytes -> {
                final Uri uri = saveAs ? null : currentUri();
                if (uri != null) return saveBytesTo(uri, bytes, currentNameOr(suggestedName));
                return saveViaCreateDocument(bytes, suggestedName);
            });
        }

        @JavascriptInterface
        public String openSudokuFile() {
            return openViaPicker();
        }

        @JavascriptInterface
        public String saveSudokuFileToExisting(String base64) {
            return withPayload(base64, bytes -> saveViaPickExisting(bytes));
        }

        @JavascriptInterface
        public String saveCurrentSudokuFile(String base64, String suggestedName) {
            return withPayload(base64, bytes -> {
                final Uri uri = currentUri();
                if (uri == null) return saveToDefaultVisible(bytes, suggestedName);
                return saveBytesTo(uri, bytes, currentNameOr(suggestedName));
            });
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

        boolean await(long timeout, TimeUnit unit) throws InterruptedException {
            return done.await(timeout, unit);
        }
    }
}
