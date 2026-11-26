package io.github.echolupus802612.lukangwalk;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.webkit.GeolocationPermissions;
import android.webkit.JsResult;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/** 以原有 HTTPS 來源讀取手機足跡，從 App 專屬目錄載入每趟散步的內容。 */
public final class WebWalkActivity extends Activity {
    private static final String LOCATION_NOTICE = "散步吧：出發前確認定位權限";
    private static final int LOCATION_REQUEST = 1;
    private static final int BRICK = Color.rgb(130, 48, 31);

    private FrameLayout frame;
    private LinearLayout notice;
    private TextView noticeText;
    private Button applyUpdate;
    private WebView game;
    private View panel;
    private TextView downloadText;
    private ProgressBar downloadBar;
    private boolean pageFailed, locationAsked;
    private Consumer<Boolean> permissionAnswer;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private OfflineWebCache cache;
    private OfflineWebCache.Snapshot displayed;
    private OfflineWebCache.Snapshot pending;
    private ConnectivityManager network;
    private boolean networkRegistered, online, initialized, syncing, foreground, retryWhenFinished;
    private long lastCheck;
    private final Runnable hideNotice = () -> {
        if (pending == null) notice.setVisibility(View.GONE);
    };
    private final ConnectivityManager.NetworkCallback networkChanges = new ConnectivityManager.NetworkCallback() {
        @Override public void onCapabilitiesChanged(Network net, NetworkCapabilities capabilities) {
            main.post(() -> networkChanged());
        }
        @Override public void onLost(Network net) { main.post(() -> networkChanged()); }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout window = new LinearLayout(this);
        window.setOrientation(LinearLayout.VERTICAL);
        window.setBackgroundColor(BRICK);
        window.setFitsSystemWindows(true);
        frame = new FrameLayout(this);
        window.addView(frame, new LinearLayout.LayoutParams(-1, 0, 1));
        notice = new LinearLayout(this);
        notice.setGravity(Gravity.CENTER_VERTICAL);
        notice.setPadding(dp(12), dp(2), dp(12), dp(2));
        notice.setVisibility(View.GONE);
        noticeText = new TextView(this);
        noticeText.setTextColor(Color.WHITE);
        notice.addView(noticeText, new LinearLayout.LayoutParams(0, -2, 1));
        applyUpdate = new Button(this);
        applyUpdate.setText("套用新版");
        applyUpdate.setOnClickListener(v -> offerApply(true));
        notice.addView(applyUpdate);
        window.addView(notice, new LinearLayout.LayoutParams(-1, -2));
        setContentView(window);
        network = getSystemService(ConnectivityManager.class);
        cache = new OfflineWebCache(getApplicationContext());
        prepare();
    }

    private void prepare() {
        clearPanel();
        ProgressBar spinner = new ProgressBar(this);
        spinner.setContentDescription("正在開啟散步吧");
        panel = spinner;
        frame.addView(spinner, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        WebProgress.prepare(this, () -> {
            if (active()) findSavedGame();
        }, () -> {
            if (active()) showMessage("暫時無法載入先前的散步紀錄，請再試一次。", "重試", this::prepare);
        });
    }

    private boolean active() { return !isFinishing() && !isDestroyed(); }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private boolean connected() {
        if (network == null) return false;
        NetworkCapabilities caps = network.getNetworkCapabilities(network.getActiveNetwork());
        return caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
    }

    private void findSavedGame() {
        worker.execute(() -> {
            OfflineWebCache.Snapshot found = null;
            try { found = cache.current(); } catch (IOException ignored) { /* 重新下載可復原。 */ }
            final OfflineWebCache.Snapshot saved = found;
            main.post(() -> {
                if (!active()) { if (saved != null) saved.close(); return; }
                initialized = true;
                displayed = saved;
                online = connected();
                if (saved != null) {
                    loadGame();
                    if (!online) banner("正在使用已下載的離線內容", false);
                } else if (online) downloadPanel(); else firstOffline();
                if (online && foreground) synchronize();
            });
        });
    }

    private void networkChanged() {
        if (!active() || !initialized || !foreground) return;
        boolean previous = online;
        online = connected();
        if (online && !previous) {
            lastCheck = 0;
            if (displayed == null && game == null) downloadPanel();
            if (syncing) retryWhenFinished = true; else synchronize();
        } else if (!online && previous && displayed == null && game == null && !syncing) {
            firstOffline();
        }
    }

    private void synchronize() {
        if (!initialized || syncing || !connected() || !active()) return;
        syncing = true;
        retryWhenFinished = false;
        lastCheck = SystemClock.elapsedRealtime();
        AtomicLong lastUpdate = new AtomicLong();
        worker.execute(() -> {
            try {
                OfflineWebCache.Snapshot saved = cache.sync((complete, total) -> {
                    long now = SystemClock.elapsedRealtime();
                    long previous = lastUpdate.get();
                    if (complete < total && now - previous < 350) return;
                    if (lastUpdate.compareAndSet(previous, now)) main.post(() -> progress(complete, total));
                });
                main.post(() -> synchronizedGame(saved));
            } catch (Exception failure) { main.post(this::syncFailed); }
        });
    }

    private void progress(int complete, int total) {
        if (!active() || !syncing || total <= 0) return;
        int percent = (int)(100L * complete / total);
        if (downloadText != null) {
            downloadText.setText("正在準備離線內容　" + percent + "%");
            downloadBar.setIndeterminate(false);
            downloadBar.setProgress(percent);
        } else if (game != null && complete < total) {
            banner((displayed == null ? "正在下載離線內容　" : "正在下載內容更新　") + percent + "%", false);
        }
    }

    private void synchronizedGame(OfflineWebCache.Snapshot saved) {
        syncing = false;
        retryWhenFinished = false;
        if (!active()) { saved.close(); return; }
        if (game == null && displayed == null) {
            displayed = saved;
            loadGame();
            banner("全台散步內容已下載，可離線遊玩", false);
        } else if (displayed != null && displayed.commit.equals(saved.commit)) {
            saved.close();
            if (pending == null) notice.setVisibility(View.GONE);
        } else {
            if (pending != null) pending.close();
            pending = saved;
            if (pageFailed) { usePending(); return; }
            banner(displayed == null ? "離線內容已下載，這趟結束後即可套用" : "散步內容更新已下載", true);
            offerApply(false);
        }
    }

    private void offerApply(boolean fromButton) {
        if (pending == null || game == null) return;
        game.evaluateJavascript("Boolean(document.getElementById('go')?.offsetWidth"
                + " && !document.getElementById('go').disabled"
                + " && !document.querySelector('.veil.on'))", result -> {
            if (!active() || pending == null) return;
            if ("true".equals(result)) usePending();
            else if (fromButton) Toast.makeText(this, "請先收工或關閉地點卡，再套用新版。", Toast.LENGTH_SHORT).show();
        });
    }

    private void usePending() {
        // 舊 WebView 完全結束後，才改用新版本的頁面和素材。
        disposeGame();
        OfflineWebCache.Snapshot old = displayed;
        displayed = pending;
        pending = null;
        if (old != null) old.close();
        loadGame();
        banner("已可離線遊玩", false);
    }

    private void syncFailed() {
        syncing = false;
        if (!active()) return;
        if (retryWhenFinished && foreground && connected()) {
            synchronize();
            return;
        }
        retryWhenFinished = false;
        if (displayed == null && game == null) {
            if (!connected()) { firstOffline(); return; }
            showMessage("離線內容尚未下載完成。重試會接續已下載的檔案。", "繼續下載", this::retrySync);
            addOnlineOption();
        } else if (pending != null) {
            banner("已下載的新版可在這趟結束後套用", true);
        } else {
            banner(displayed != null ? "目前使用已下載的版本" : "離線內容尚未下載完成", false);
        }
    }

    private void retrySync() {
        online = connected();
        if (!online) { firstOffline(); return; }
        downloadPanel();
        synchronize();
    }

    private void firstOffline() {
        showMessage("這支手機尚未下載完整內容。請先連上網路，下載後就能離線散步。", "重新連線", this::retrySync);
    }

    private void addOnlineOption() {
        Button play = new Button(this);
        play.setText("先連線散步");
        play.setOnClickListener(v -> {
            loadGame();
            if (!syncing) synchronize();
        });
        ((LinearLayout)panel).addView(play, new LinearLayout.LayoutParams(-2, -2));
    }

    private void downloadPanel() {
        showMessage("首次連線會下載全台地點、照片與語音，目前約 123 MB。建議使用 Wi-Fi。", "先連線散步", this::loadGame);
        LinearLayout box = (LinearLayout)panel;
        downloadText = new TextView(this);
        downloadText.setText("正在檢查離線內容…");
        downloadText.setTextColor(Color.WHITE);
        downloadText.setGravity(Gravity.CENTER);
        downloadBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        downloadBar.setMax(100); downloadBar.setIndeterminate(true);
        box.addView(downloadBar, 1, new LinearLayout.LayoutParams(-1, dp(14)));
        box.addView(downloadText, 2);
    }

    private void banner(String text, boolean action) {
        main.removeCallbacks(hideNotice);
        noticeText.setText(text);
        applyUpdate.setVisibility(action ? View.VISIBLE : View.GONE);
        notice.setVisibility(View.VISIBLE);
        if (!action && !syncing) main.postDelayed(hideNotice, 4500);
    }

    private void loadGame() {
        clearPanel();
        pageFailed = false;
        if (game == null) {
            game = new WebView(this);
            game.setBackgroundColor(BRICK);
            WebSettings settings = game.getSettings();
            settings.setJavaScriptEnabled(true);
            settings.setDomStorageEnabled(true);
            settings.setGeolocationEnabled(true);
            settings.setAllowFileAccess(false);
            settings.setAllowContentAccess(false);
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
            settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
            game.setWebViewClient(new Navigation(displayed));
            game.setWebChromeClient(new Permissions());
            frame.addView(game, 0);
        }
        game.setVisibility(View.VISIBLE);
        game.loadUrl(WebRelease.SITE);
    }

    private static boolean isSite(Uri uri) {
        return uri != null && "https".equals(uri.getScheme()) && WebRelease.HOST.equals(uri.getHost())
                && uri.getUserInfo() == null && (uri.getPort() == -1 || uri.getPort() == 443);
    }

    private static boolean isGame(String url) {
        if (url == null) return false;
        Uri uri = Uri.parse(url);
        String path = uri.getEncodedPath();
        return isSite(uri) && (WebRelease.BASE_PATH.equals(path) || (WebRelease.BASE_PATH + "index.html").equals(path));
    }

    private boolean has(String permission) {
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    private void checkLocation(Consumer<Boolean> answer) {
        if (!active() || locationAsked || has(Manifest.permission.ACCESS_COARSE_LOCATION)) {
            answer.accept(active() && has(Manifest.permission.ACCESS_FINE_LOCATION));
            return;
        }
        locationAsked = true;
        permissionAnswer = answer;
        requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION}, LOCATION_REQUEST);
    }

    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == LOCATION_REQUEST) finishPermission(has(Manifest.permission.ACCESS_FINE_LOCATION));
    }

    private void finishPermission(boolean granted) {
        Consumer<Boolean> answer = permissionAnswer;
        permissionAnswer = null;
        if (answer != null) answer.accept(granted);
    }

    private final class Permissions extends WebChromeClient {
        @Override public boolean onJsAlert(WebView view, String url, String message, JsResult result) {
            if (view != game || !isGame(url) || !LOCATION_NOTICE.equals(message)) {
                return super.onJsAlert(view, url, message, result);
            }
            checkLocation(allowed -> result.confirm());
            return true;
        }

        @Override public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback answer) {
            if (game == null || !isGame(game.getUrl()) || !isSite(Uri.parse(origin))) {
                answer.invoke(origin, false, false);
                return;
            }
            checkLocation(allowed -> answer.invoke(origin, allowed && game != null && isGame(game.getUrl()), false));
        }
    }

    private final class Navigation extends WebViewClient {
        private final OfflineWebCache.Snapshot snapshot;
        Navigation(OfflineWebCache.Snapshot snapshot) { this.snapshot = snapshot; }

        @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri uri = request.getUrl();
            if (!isSite(uri))
                return super.shouldInterceptRequest(view, request);
            String path = uri.getPath();
            String relative = path != null && path.startsWith(WebRelease.BASE_PATH)
                    ? path.substring(WebRelease.BASE_PATH.length()) : null;
            if (relative == null || (!relative.isEmpty() && !OfflineWebCache.safePath(relative)))
                return new WebResourceResponse("text/plain", "UTF-8", 404, "Not Found",
                        Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
            if (snapshot == null || !"GET".equals(request.getMethod()))
                return super.shouldInterceptRequest(view, request);
            String range = null;
            for (Map.Entry<String,String> header : request.getRequestHeaders().entrySet()) {
                if ("Range".equalsIgnoreCase(header.getKey())) range = header.getValue();
            }
            try {
                return snapshot.response(relative.isEmpty() ? "index.html" : relative, range);
            } catch (IOException unavailable) {
                return new WebResourceResponse("text/plain", "UTF-8", 503, "Unavailable",
                        Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
            }
        }
        @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            Uri uri = request.getUrl();
            if (!request.isForMainFrame()) return true;
            if (isGame(uri.toString())) return false;
            if (request.hasGesture() && "https".equals(uri.getScheme()) && uri.getHost() != null) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE));
                } catch (ActivityNotFoundException e) {
                    Toast.makeText(WebWalkActivity.this, "找不到能開啟連結的瀏覽器。", Toast.LENGTH_SHORT).show();
                }
            }
            return true;
        }

        @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (view == game && request.isForMainFrame()) connectionError();
        }
        @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
            if (view == game && request.isForMainFrame() && response.getStatusCode() >= 400) connectionError();
        }
        @Override public void onPageFinished(WebView view, String url) {
            if (view != game || pageFailed || !isGame(url) || locationAsked || has(Manifest.permission.ACCESS_COARSE_LOCATION)) return;
            // 保留第一次出發的點擊，讓定位逾時從玩家回答系統權限後才開始計算。
            view.evaluateJavascript("(() => {const b=document.getElementById('go');"
                    + "if (!b || b.dataset.androidPermission || location.hash==='#sim') return;"
                    + "b.dataset.androidPermission='1';"
                    + "b.addEventListener('click',()=>alert('" + LOCATION_NOTICE
                    + "'),{capture:true,once:true});})()", null);
        }
        @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            if (view == game) {
                game = null;
                finishPermission(false);
                frame.removeView(view);
                view.destroy();
                connectionError();
            }
            return true;
        }
    }

    private void connectionError() {
        if (pageFailed || !active()) return;
        pageFailed = true;
        if (game != null) game.setVisibility(View.GONE);
        if (pending != null) { usePending(); return; }
        if (displayed == null) {
            showMessage("暫時無法載入散步吧，離線內容也尚未就緒。", "重新連線", () -> {
                loadGame();
                if (connected() && !syncing) synchronize();
            });
        } else showMessage("暫時無法開啟已下載的散步內容。", "再試一次", this::loadGame);
    }

    private void clearPanel() {
        if (panel != null) frame.removeView(panel);
        panel = null;
        downloadText = null;
        downloadBar = null;
    }

    private void showMessage(String text, String action, Runnable retry) {
        clearPanel();
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        int pad = Math.round(24 * getResources().getDisplayMetrics().density);
        box.setPadding(pad, pad, pad, pad);
        TextView message = new TextView(this);
        message.setText(text);
        message.setTextColor(Color.WHITE);
        message.setGravity(Gravity.CENTER);
        message.setTextSize(18);
        box.addView(message);
        Button button = new Button(this);
        button.setText(action);
        button.setOnClickListener(v -> retry.run());
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-2, -2);
        params.topMargin = pad;
        box.addView(button, params);
        panel = box;
        frame.addView(box);
    }

    @Override protected void onStart() {
        super.onStart();
        foreground = true;
        boolean wasOnline = online;
        online = connected();
        if (network != null && !networkRegistered) {
            network.registerDefaultNetworkCallback(networkChanges); networkRegistered = true;
        }
        if (initialized && online && syncing && !wasOnline) retryWhenFinished = true;
        if (initialized && online && !syncing && (!wasOnline || lastCheck == 0 || SystemClock.elapsedRealtime()-lastCheck > 60000)) {
            if (game == null && displayed == null) downloadPanel();
            synchronize();
        }
    }
    @Override protected void onStop() {
        foreground = false;
        if (networkRegistered) {
            network.unregisterNetworkCallback(networkChanges); networkRegistered = false;
        }
        super.onStop();
    }
    @Override protected void onPause() {
        if (game != null) {
            if (isGame(game.getUrl()) && !pageFailed) {
                game.evaluateJavascript("if (!document.getElementById('walkrow')?.hidden"
                        + " && !document.getElementById('sim')?.classList.contains('on')"
                        + " && typeof window.resetFixes==='function') window.resetFixes()", null);
            }
            game.onPause();
        }
        super.onPause();
    }
    @Override protected void onResume() {
        super.onResume();
        if (game != null) game.onResume();
        if (pending != null) offerApply(false);
    }
    private void disposeGame() {
        if (game != null) {
            frame.removeView(game);
            game.destroy();
            game = null;
        }
    }
    @Override protected void onDestroy() {
        finishPermission(false);
        cache.cancel();
        worker.shutdownNow();
        main.removeCallbacks(hideNotice);
        disposeGame();
        if (displayed != null) displayed.close();
        if (pending != null) pending.close();
        super.onDestroy();
    }
}
