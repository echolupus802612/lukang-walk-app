package io.github.echolupus802612.lukangwalk;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.Handler;
import android.os.Looper;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** 在連上遊戲前，把 1.2、1.3 版的兩本足跡接回這個 App 自己的網頁儲存空間。 */
final class WebProgress {
    private static final String BLANK = "<!doctype html><meta charset=utf-8>"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\">";
    private static final String COMPLETE = "nativeToWeb14";
    private static final List<Request> waiting = new ArrayList<>();

    private static final class Request {
        final Activity activity;
        final Runnable ready, failed;
        Request(Activity activity, Runnable ready, Runnable failed) {
            this.activity = activity; this.ready = ready; this.failed = failed;
        }
    }

    /** 從主執行緒呼叫。匯入用的 WebView 與顯示遊戲的 WebView 分開。 */
    static void prepare(Activity activity, Runnable ready, Runnable failed) {
        Context ctx = activity.getApplicationContext();
        File database = ctx.getDatabasePath("walk.db");
        SharedPreferences prefs = ctx.getSharedPreferences("walk-web-migration", Context.MODE_PRIVATE);
        if (!database.isFile() || prefs.getBoolean(COMPLETE, false)) {
            ready.run();
            return;
        }
        waiting.add(new Request(activity, ready, failed));
        if (waiting.size() != 1) return;
        Handler main = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            try {
                String data = readBook(database).toString();
                main.post(() -> new ImportPage(ctx, prefs, main).start(data));
            } catch (RuntimeException | JSONException failure) {
                main.post(() -> notifyCallers(false));
            }
        }, "WalkProgress").start();
    }

    private static void notifyCallers(boolean success) {
        List<Request> callers = new ArrayList<>(waiting);
        waiting.clear();
        for (Request result : callers) {
            if (!result.activity.isFinishing() && !result.activity.isDestroyed()) {
                (success ? result.ready : result.failed).run();
            }
        }
    }

    private static JSONObject readBook(File file) throws JSONException {
        JSONObject data = new JSONObject();
        // 此處只讀。遇到損毀時也保留舊資料庫，供後續重試或復原。
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(file.getPath(), null,
                SQLiteDatabase.OPEN_READONLY, damaged -> { })) {
            try (Cursor rows = db.rawQuery("SELECT name,value FROM settings WHERE name IN ('imported','voice')", null)) {
                while (rows.moveToNext()) data.put(rows.getString(0), rows.getInt(1) == 1);
            }
            for (int mode = 0; mode <= 1; mode++) {
                String prefix = mode == 0 ? "" : "sim_";
                String[] args = {Integer.toString(mode)};
                try (Cursor rows = db.rawQuery("SELECT drawn FROM books WHERE sim=?", args)) {
                    if (!rows.moveToFirst()) throw new IllegalStateException("舊版缺少足跡簿");
                    data.put(prefix + "drawn", Math.max(0L, rows.getLong(0)));
                }
                data.put(prefix + "seen", ids(db, "SELECT place FROM footprints WHERE sim=? ORDER BY rowid", args));
                data.put(prefix + "recent", ids(db, "SELECT place FROM footprints WHERE sim=? "
                        + "AND recent_order IS NOT NULL ORDER BY recent_order DESC LIMIT 12", args));
            }
        }
        return data;
    }

    private static JSONArray ids(SQLiteDatabase db, String query, String[] args) {
        JSONArray ids = new JSONArray();
        try (Cursor rows = db.rawQuery(query, args)) {
            while (rows.moveToNext()) if (rows.getInt(0) > 0) ids.put(rows.getInt(0));
        }
        return ids;
    }

    // 先存下計算完成的整份結果，再逐項寫入。重試時沿用同一份結果，避免累加兩次。
    private static String migrationScript(String snapshot) {
        return "(function(n){try{"
                + "if(location.origin!=='" + WebRelease.ORIGIN + "')return false;"
                + "const s=window.localStorage,p='lkwalk_',m=p+'native_to_web_14';"
                + "const staged=s.getItem(m);if(staged==='done')return true;"
                + "let out;if(staged!==null){out=JSON.parse(staged);}else{"
                + "const get=k=>JSON.parse(s.getItem(p+k));"
                + "const count=v=>Number.isSafeInteger(v)&&v>=0?v:0;"
                + "const list=v=>Array.isArray(v)?v.filter(id=>Number.isSafeInteger(id)&&id>0):[];"
                + "const join=(a,b)=>Array.from(new Set(a.concat(b)));"
                + "const split=get('ver')>=2;out={};"
                + "for(const k of ['', 'sim_']){"
                + "let seen=list(get(k+'seen')),recent=list(get(k+'recent')),drawn=count(get(k+'drawn'));"
                // 舊網頁未分簿時，無前綴的資料全是模擬；中斷過的分簿可能已有部分副本。
                + "if(!split){if(k===''){seen=[];recent=[];drawn=0;}else{"
                + "seen=join(seen,list(get('seen')));recent=join(recent,list(get('recent')));"
                + "drawn=Math.max(drawn,count(get('drawn')));}}"
                + "out[k+'seen']=join(join(seen,recent),n[k+'seen']);"
                + "out[k+'recent']=join(n[k+'recent'],recent).slice(0,12);"
                + "out[k+'drawn']=n.imported?n[k+'drawn']:Math.min(Number.MAX_SAFE_INTEGER,drawn+n[k+'drawn']);}"
                + "if(typeof n.voice==='boolean')out.voice=n.voice;"
                + "out.ver=2;s.setItem(m,JSON.stringify(out));}"
                + "for(const k of Object.keys(out))s.setItem(p+k,JSON.stringify(out[k]));"
                + "s.setItem(m,'done');return true;}catch(e){return false;}})(" + snapshot + ")";
    }

    private static final class ImportPage extends WebViewClient {
        final Context ctx;
        final SharedPreferences prefs;
        final Handler main;
        final Runnable timeout = () -> finish(false);
        WebView view;
        String script;
        boolean done, started;
        ImportPage(Context ctx, SharedPreferences prefs, Handler main) {
            this.ctx = ctx; this.prefs = prefs; this.main = main;
        }
        void start(String snapshot) {
            try {
                script = migrationScript(snapshot);
                view = new WebView(ctx);
                WebSettings settings = view.getSettings();
                settings.setBlockNetworkLoads(true);
                settings.setAllowFileAccess(false);
                settings.setAllowContentAccess(false);
                settings.setGeolocationEnabled(false);
                settings.setDomStorageEnabled(true);
                settings.setJavaScriptEnabled(true);
                view.setWebViewClient(this);
                main.postDelayed(timeout, 10000);
                view.loadDataWithBaseURL(WebRelease.SITE, BLANK, "text/html", "UTF-8", WebRelease.SITE);
            } catch (RuntimeException | LinkageError failure) { finish(false); }
        }
        @Override public boolean shouldOverrideUrlLoading(WebView web, WebResourceRequest request) {
            return true;
        }
        @Override public void onPageFinished(WebView web, String url) {
            if (done || started) return;
            if (!WebRelease.SITE.equals(url)) { finish(false); return; }
            started = true;
            try { web.evaluateJavascript(script, result -> finish("true".equals(result))); }
            catch (RuntimeException failure) { finish(false); }
        }
        @Override public void onReceivedError(WebView web, WebResourceRequest request, WebResourceError error) {
            if (request.isForMainFrame()) finish(false);
        }
        @Override public boolean onRenderProcessGone(WebView web, RenderProcessGoneDetail detail) {
            finish(false);
            return true;
        }
        void finish(boolean success) {
            if (done) return;
            done = true;
            main.removeCallbacks(timeout);
            if (success) prefs.edit().putBoolean(COMPLETE, true).apply();
            try { if (view != null) view.destroy(); }
            catch (RuntimeException | LinkageError unavailable) { /* WebView 元件已中止。 */ }
            finally { view = null; notifyCallers(success); }
        }
    }
}
