package io.github.echolupus802612.lukangwalk;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.speech.tts.TextToSpeech;
import android.view.Gravity;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.widget.Toast;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class WalkActivity extends Activity implements WalkScreen.Actions, WalkEngine.Listener {
    private static final int LOCATION_REQUEST = 1;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private WalkBook book;
    private WalkEngine engine;
    private WalkSensors sensors;
    private WalkScreen screen;
    private boolean foreground, askingLocation, updating, voice;
    private MediaPlayer player;
    private TextToSpeech fallbackVoice;
    private String pendingLine;
    private boolean ttsReady;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!foreground || engine == null) return;
            engine.tick();
            main.postDelayed(this, 150);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        FrameLayout loading = new FrameLayout(this);
        loading.setBackgroundColor(0xff82301f);
        ProgressBar spinner = new ProgressBar(this);
        spinner.setContentDescription("正在載入散步地點");
        loading.addView(spinner, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        setContentView(loading);
        book = new WalkBook(this);
        LegacyImport.run(this, book, imported -> {
            if (isDestroyed() || isFinishing()) return;
            worker.execute(() -> {
                try {
                    WalkContent.loadIndex(this);
                    List<WalkEngine.Place> places = WalkContent.places(this);
                    main.post(() -> openGame(places, imported));
                } catch (Exception e) {
                    main.post(() -> {
                        if (!isDestroyed() && !isFinishing()) new AlertDialog.Builder(this)
                                .setMessage("讀不到散步地點，請重新開啟或更新 App。")
                                .setPositiveButton("關閉", (d,w) -> finish()).show();
                    });
                }
            });
        });
    }

    private void openGame(List<WalkEngine.Place> places, boolean imported) {
        if (isFinishing() || isDestroyed()) return;
        voice = book.voice();
        engine = new WalkEngine(places, book, this);
        sensors = new WalkSensors(this, engine);
        screen = new WalkScreen(this, this);
        screen.root.setFitsSystemWindows(true);
        setContentView(screen.root);
        if (!imported) screen.setStatus("舊版足跡尚未匯入，下次開啟時會再試一次。");
        changed();
        if (foreground) main.post(tick);
    }

    @Override public void changed() {
        screen.render(engine, voice);
        screen.root.setKeepScreenOn(foreground && "walking".equals(engine.phase));
    }
    @Override public void band(int index) { engine.band(index); }
    @Override public void start() { engine.start(); }
    @Override public void simulate() { engine.simulate(); }
    @Override public void stop() { engine.stop(); }
    @Override public void again() { engine.again(); }
    @Override public void redraw() { engine.redraw(); }
    @Override public void step(boolean toward) { engine.step(toward); }
    @Override public void turn() { engine.turn(); }
    @Override public void toggleVoice() {
        voice = !voice;
        book.voice(voice);
        if (!voice) stopVoice();
        changed();
    }

    private boolean granted(String permission) { return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED; }
    @Override public void needLocation(boolean enable) {
        if (!enable || !foreground) { sensors.stop(); return; }
        if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) { sensors.start(); return; }
        if (granted(Manifest.permission.ACCESS_COARSE_LOCATION)) { engine.locationError("approximate"); return; }
        if (!askingLocation) {
            askingLocation = true;
            requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION}, LOCATION_REQUEST);
        }
    }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code != LOCATION_REQUEST) return;
        askingLocation = false;
        if (engine == null || !engine.sensorWanted) return;
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
            engine.locationError(granted(Manifest.permission.ACCESS_COARSE_LOCATION) ? "approximate" : "denied");
        } else if (foreground) sensors.start();
    }

    @Override public void say(String asset, String line, boolean urgent) {
        if (!foreground || (voice && !urgent && player != null)) return;
        screen.say(line);
        if (!voice) return;
        stopVoice();
        MediaPlayer audio = new MediaPlayer();
        player = audio;
        try {
            audio.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build());
            File updated = WalkContent.override(this, asset);
            if (updated != null) audio.setDataSource(updated.getPath());
            else try (AssetFileDescriptor fd = getAssets().openFd(asset)) {
                audio.setDataSource(fd.getFileDescriptor(), fd.getStartOffset(), fd.getLength());
            }
            audio.setOnCompletionListener(done -> { if (player == done) stopVoice(); });
            audio.setOnErrorListener((failed, what, extra) -> {
                if (player == failed) { stopVoice(); speakFallback(line); }
                return true;
            });
            audio.prepare();
            audio.start();
        } catch (Exception e) { stopVoice(); speakFallback(line); }
    }
    private void speakFallback(String line) {
        pendingLine = line;
        if (fallbackVoice == null) {
            fallbackVoice = new TextToSpeech(this, status -> main.post(() -> {
                if (isDestroyed() || fallbackVoice == null) return;
                ttsReady = status == TextToSpeech.SUCCESS && fallbackVoice.setLanguage(Locale.TAIWAN) >= 0;
                if (ttsReady && pendingLine != null && foreground && voice) speakFallback(pendingLine);
            }));
        } else if (ttsReady && foreground && voice) {
            fallbackVoice.speak(line, TextToSpeech.QUEUE_FLUSH, null, "walk");
            pendingLine = null;
        }
    }
    private void stopVoice() {
        pendingLine = null;
        if (player != null) { player.release(); player = null; }
        if (fallbackVoice != null && ttsReady) fallbackVoice.stop();
    }
    @Override public void arrived() {
        Vibrator vibrator = getSystemService(Vibrator.class);
        if (foreground && vibrator != null && vibrator.hasVibrator()) {
            vibrator.vibrate(VibrationEffect.createWaveform(new long[]{0,60,40,120}, -1));
        }
    }

    @Override public void updateContent() {
        if (updating) return;
        updating = true;
        screen.setStatus("正在檢查地點資料…");
        worker.execute(() -> {
            String message;
            try { message = WalkContent.update(this); }
            catch (Exception e) { message = "這次未能更新，仍可使用原有的地點資料。"; }
            String result = message;
            main.post(() -> {
                updating = false;
                if (!isDestroyed() && !isFinishing()) screen.setStatus(result);
            });
        });
    }

    @Override public void credits() {
        try {
            String html = new String(WalkContent.read(WalkContent.open(this,"credits.html"), 4 << 20), StandardCharsets.UTF_8);
            WebView sheet = new WebView(this);
            sheet.getSettings().setJavaScriptEnabled(false);
            sheet.getSettings().setAllowFileAccess(false);
            sheet.getSettings().setAllowContentAccess(false);
            sheet.getSettings().setBlockNetworkLoads(true);
            sheet.setWebViewClient(new WebViewClient() {
                @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    Uri url = request.getUrl();
                    if (request.isForMainFrame() && request.hasGesture() && "https".equals(url.getScheme())) {
                        try { startActivity(new Intent(Intent.ACTION_VIEW,url).addCategory(Intent.CATEGORY_BROWSABLE)); }
                        catch (ActivityNotFoundException e) {
                            Toast.makeText(WalkActivity.this,"找不到能開啟連結的瀏覽器。",Toast.LENGTH_SHORT).show();
                        }
                    }
                    return true;
                }
            });
            sheet.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle("資料來源與授權").setView(sheet)
                    .setPositiveButton("完成", null).create();
            dialog.setOnDismissListener(d -> {
                if (sheet.getParent() instanceof android.view.ViewGroup)
                    ((android.view.ViewGroup)sheet.getParent()).removeView(sheet);
                sheet.destroy();
            });
            dialog.show();
        } catch (Exception e) { screen.setStatus("讀不到資料來源與授權。"); }
    }

    @Override protected void onStart() {
        super.onStart();
        foreground = true;
        if (engine != null) {
            if (engine.sensorWanted && !askingLocation) {
                if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) sensors.start();
                else engine.locationError(granted(Manifest.permission.ACCESS_COARSE_LOCATION) ? "approximate" : "denied");
            }
            changed();
            main.post(tick);
        }
    }
    @Override protected void onStop() {
        foreground = false;
        main.removeCallbacks(tick);
        if (engine != null) {
            sensors.stop();
            engine.pauseFixes();
            screen.pause();
            screen.root.setKeepScreenOn(false);
        }
        stopVoice();
        super.onStop();
    }
    @Override protected void onDestroy() {
        worker.shutdownNow();
        main.removeCallbacks(tick);
        if (sensors != null) sensors.stop();
        stopVoice();
        if (fallbackVoice != null) { fallbackVoice.shutdown(); fallbackVoice = null; }
        if (book != null) book.close();
        super.onDestroy();
    }
}
