package io.github.echolupus802612.lukangwalk;

import android.app.Activity;
import android.content.pm.PackageInfo;
import android.os.Handler;
import android.os.Looper;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.function.Consumer;

/** 舊版升級時，從這個 App 自己使用過的 WebView 空間讀取足跡與語音偏好。 */
final class LegacyImport extends WebViewClient {
    private static final String ORIGIN = "https://echolupus802612.github.io";
    private static final String BASE = ORIGIN + "/lukang-walk/";
    private static final String BLANK = "<!doctype html><meta charset=utf-8>"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\">";
    private static final String READ = "(function(){if(location.origin!=='" + ORIGIN + "')return null;"
            + "var data={},keys=['ver','voice','seen','recent','drawn','sim_seen','sim_recent','sim_drawn'];"
            + "for(var i=0;i<keys.length;i++){var key=keys[i],raw=localStorage.getItem('lkwalk_'+key);"
            + "if(raw!==null)data[key]=JSON.parse(raw);}return data;})()";

    private final WalkBook book;
    private final Consumer<Boolean> finished;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable timeout = () -> finish(false);
    private WebView view;
    private boolean reading;
    private boolean done;

    static void run(Activity activity, WalkBook book, Consumer<Boolean> finished) {
        LegacyImport task = new LegacyImport(book, finished);
        try {
            if (book.imported()) {
                task.finish(true);
                return;
            }
            PackageInfo pkg = activity.getPackageManager().getPackageInfo(activity.getPackageName(), 0);
            if (pkg.firstInstallTime > 0 && pkg.firstInstallTime == pkg.lastUpdateTime) {
                book.importLegacy(new JSONObject());
                task.finish(true);
                return;
            }
            task.start(activity);
        } catch (Exception | LinkageError failure) {
            task.finish(false);
        }
    }

    private LegacyImport(WalkBook book, Consumer<Boolean> finished) {
        this.book = book;
        this.finished = finished;
    }

    private void start(Activity activity) {
        view = new WebView(activity);
        WebSettings settings = view.getSettings();
        settings.setBlockNetworkLoads(true);
        settings.setAllowContentAccess(false);
        settings.setAllowFileAccess(false);
        settings.setGeolocationEnabled(false);
        settings.setDomStorageEnabled(true);
        settings.setJavaScriptEnabled(true);
        view.setWebViewClient(this);
        handler.postDelayed(timeout, 5000);
        view.loadDataWithBaseURL(BASE, BLANK, "text/html", "UTF-8", BASE);
    }

    @Override public boolean shouldOverrideUrlLoading(WebView web, WebResourceRequest request) {
        return true;
    }

    @Override public void onPageFinished(WebView web, String url) {
        if (done || reading) return;
        if (!BASE.equals(url)) {
            finish(false);
            return;
        }
        reading = true;
        try {
            web.evaluateJavascript(READ, raw -> {
                if (done) return;
                try {
                    if (raw == null) { finish(false); return; }
                    book.importLegacy(new JSONObject(raw));
                    finish(true);
                } catch (JSONException | RuntimeException failure) {
                    finish(false);
                }
            });
        } catch (RuntimeException failure) {
            finish(false);
        }
    }

    @Override public void onReceivedError(WebView web, WebResourceRequest request, WebResourceError error) {
        if (request.isForMainFrame()) finish(false);
    }

    @Override public boolean onRenderProcessGone(WebView web, RenderProcessGoneDetail detail) {
        finish(false);
        return true;
    }

    private void finish(boolean success) {
        if (done) return;
        done = true;
        handler.removeCallbacks(timeout);
        try {
            if (view != null) view.destroy();
        } catch (RuntimeException | LinkageError unavailable) {
            // 舊版 WebView 元件已中止時，使用者仍可繼續使用原生遊戲。
        } finally {
            view = null;
            finished.accept(success);
        }
    }
}
