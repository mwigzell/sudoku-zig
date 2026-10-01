package com.wigzell.sudoku_zig;

import android.app.Activity;
import android.os.Bundle;
import android.widget.Toast;
import android.webkit.WebSettings;
import android.webkit.WebView;

public final class MainActivity extends Activity {
    private WebView webView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        webView = new WebView(this);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);

        webView.loadUrl("about:blank");
        setContentView(webView);

        JniHost.startHost(getFilesDir().getAbsolutePath(), new JniHost.ReadyCallback() {
            @Override
            public void onReady(String url) {
                runOnUiThread(() -> webView.loadUrl(url));
            }

            @Override
            public void onError(String message) {
                runOnUiThread(() -> Toast.makeText(MainActivity.this, message, Toast.LENGTH_LONG).show());
            }
        });
    }

    @Override
    protected void onDestroy() {
        JniHost.stopHost();
        super.onDestroy();
    }
}
