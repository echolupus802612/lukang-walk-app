package io.github.echolupus802612.lukangwalk;

import android.content.Context;
import android.content.SharedPreferences;
import android.webkit.WebResourceResponse;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.UUID;

/** 只有通過版本檢查的遊戲首頁才會裝上原生訊息入口；授權頁與外部連結不會取得它。 */
final class WalkMobileBridge {
    static final String MARKER = "<!--lukang-android-bridge-v1-->";
    private static final String[] KEYS = {"voice","theme","drawn","seen","recent","sim_drawn","sim_seen","sim_recent"};
    private final SharedPreferences prefs;
    final String token = "walk-" + UUID.randomUUID();
    private volatile boolean installed;

    WalkMobileBridge(Context context) {
        prefs = context.getSharedPreferences("walk-mobile-footprints", Context.MODE_PRIVATE);
    }

    boolean accepts(String message) { return installed && token.equals(message); }
    boolean isInstalled() { return installed; }

    WebResourceResponse page(WebResourceResponse source) throws IOException {
        if (source.getStatusCode() != 200) return source;
        String html;
        try (InputStream in = source.getData(); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = in.read(buffer)) != -1) {
                if (bytes.size() + n > 12 * 1024 * 1024) throw new IOException("首頁大小超出範圍。");
                bytes.write(buffer, 0, n);
            }
            html = bytes.toString("UTF-8");
        }
        installed = html.contains(MARKER);
        HashMap<String,String> headers = new HashMap<>();
        headers.put("Cache-Control", "no-store");
        if (installed) {
            // 分頁列在版面中保留高度，較小的螢幕可捲動散步內容，不會誤按底部分頁。
            String script = "<style>body{display:flex;flex-direction:column;overflow:hidden}"
                    + ".app{width:100%;flex:1 1 auto;min-height:0;overflow-y:auto;padding-bottom:12px}"
                    + ".tabs{position:static;flex:none}@media(max-height:660px){.stage{min-height:96px}}</style>"
                    + "<script>(()=>{document.getElementById('tabs').addEventListener('click',"
                    + "e=>{if(e.target.closest('[data-view]'))document.querySelector('.app').scrollTop=0});"
                    + "const send=m=>prompt(" + JSONObject.quote(token) + ",JSON.stringify(m));"
                    + "const legacy={};for(const k of ['ver','voice','theme','drawn','seen','recent','sim_drawn','sim_seen','sim_recent']){"
                    + "try{const v=localStorage.getItem('lkwalk_'+k);if(v!==null)legacy[k]=JSON.parse(v)}catch(e){}}"
                    + "const init=JSON.parse(send({action:'bootstrap',legacy}));"
                    + "window.lukangInitialStore=init.progress;window.lukangNavigation=init.navigation;"
                    + "window.lukangBackgroundWalk=window.lukangWalkPhotos=window.lukangWalkJournal=window.lukangPlaceReporting=true;"
                    + "window.lukangCardSprites={idle:'sprites/idle.webp',cheer:'sprites/cheer.webp'};"
                    + "window.webkit={messageHandlers:{lukangWalk:{postMessage:m=>send(m)}}};})();</script>";
            html = html.replace(MARKER, script);
            headers.put("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; "
                    + "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; "
                    + "font-src 'self' data:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'");
        }
        return new WebResourceResponse("text/html", "UTF-8", 200, "OK", headers,
                new ByteArrayInputStream(html.getBytes(StandardCharsets.UTF_8)));
    }

    JSONObject bootstrap(JSONObject legacy, JSONObject navigation) throws JSONException, IOException {
        JSONObject progress = read();
        if (!prefs.contains("state")) {
            if (legacy != null) {
                if (legacy.optInt("ver", 1) < 2) {
                    for (String key : new String[]{"drawn","seen","recent"}) {
                        if (legacy.has(key) && !legacy.has("sim_" + key)) legacy.put("sim_" + key, legacy.get(key));
                        legacy.remove(key);
                    }
                }
                copy(progress, legacy);
            }
            persist(progress);
        }
        return new JSONObject().put("progress", progress).put("navigation", navigation);
    }

    void save(JSONObject delta) throws JSONException, IOException {
        if (delta == null) return;
        JSONObject progress = read();
        copy(progress, delta);
        persist(progress);
    }

    JSONObject arrival(int place) throws JSONException, IOException {
        if (place < 1) throw new JSONException("地點編號無效");
        JSONObject progress = read();
        JSONArray seen = progress.optJSONArray("seen");
        if (seen == null) seen = new JSONArray();
        boolean visited = false;
        for (int i = 0; i < seen.length(); i++) if (seen.optInt(i) == place) visited = true;
        if (!visited) seen.put(place);
        JSONArray recent = new JSONArray().put(place);
        JSONArray old = progress.optJSONArray("recent");
        if (old != null) for (int i = 0; i < old.length() && recent.length() < 12; i++) {
            if (old.optInt(i) != place) recent.put(old.getInt(i));
        }
        progress.put("seen", seen).put("recent", recent);
        persist(progress);
        return new JSONObject().put("seen", seen).put("recent", recent);
    }

    private JSONObject read() throws JSONException {
        return new JSONObject(prefs.getString("state", "{\"ver\":2}"));
    }

    private void persist(JSONObject progress) throws IOException {
        if (!prefs.edit().putString("state", progress.toString()).commit()) throw new IOException("足跡尚未存好。");
    }

    private static void copy(JSONObject target, JSONObject changes) throws JSONException {
        for (String key : KEYS) {
            Object value = changes.opt(key);
            if (value instanceof JSONArray && (key.endsWith("seen") || key.endsWith("recent"))) {
                JSONArray result = new JSONArray();
                JSONArray list = (JSONArray)value;
                java.util.HashSet<Integer> used = new java.util.HashSet<>();
                for (int i = 0; i < list.length(); i++) {
                    int id = list.optInt(i, 0);
                    if (id > 0 && used.add(id)) result.put(id);
                    if (key.endsWith("recent") && result.length() == 12) break;
                }
                target.put(key, result);
            } else if (value instanceof Number && key.endsWith("drawn") && ((Number)value).longValue() >= 0) {
                target.put(key, ((Number)value).longValue());
            } else if (value instanceof Boolean && key.equals("voice")) {
                target.put(key, value);
            } else if (key.equals("theme") && ("".equals(value) || "light".equals(value) || "dark".equals(value))) {
                target.put(key, value);
            }
        }
    }
}
