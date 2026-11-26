package io.github.echolupus802612.lukangwalk;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.*;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.regex.Pattern;
import javax.net.ssl.HttpsURLConnection;

/** 內容更新只接受資料與媒體。所有檔案核對完畢後，才一次切換索引。 */
final class WalkContent {
    private static final String SITE = "https://echolupus802612.github.io/lukang-walk/android-content/";
    private static final Pattern NAME = Pattern.compile("places\\.json|credits\\.html|photos/[1-9][0-9]*\\.webp|voice/[a-z0-9_]+\\.mp3");
    private static final Pattern HASH = Pattern.compile("[a-f0-9]{64}");
    private static final Object WRITER = new Object();
    private static volatile Index bundled, current;
    private static volatile List<WalkEngine.Place> activePlaces;

    private static final class Index {
        final int revision;
        final Map<String,String> files = new HashMap<>();
        Index(byte[] bytes) throws JSONException, IOException {
            JSONObject json = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            revision = json.getInt("revision");
            if (revision < 1 || json.getInt("format") != 1) throw new IOException("不支援的內容版本");
            JSONObject entries = json.getJSONObject("files");
            Iterator<String> keys = entries.keys();
            while (keys.hasNext()) {
                String name = keys.next(), hash = entries.getString(name);
                if (!NAME.matcher(name).matches() || !HASH.matcher(hash).matches()) throw new IOException("檔案索引不完整");
                files.put(name, hash);
            }
            if (!files.containsKey("places.json") || !files.containsKey("credits.html")) throw new IOException("缺少必要內容");
        }
    }

    static byte[] read(InputStream in, int limit) throws IOException {
        try (InputStream source = in; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = source.read(buffer)) != -1) {
                if (out.size() + n > limit) throw new IOException("內容檔案過大");
                out.write(buffer, 0, n);
            }
            return out.toByteArray();
        }
    }

    private static File folder(Context ctx) { return new File(ctx.getFilesDir(), "walk-content"); }

    static void loadIndex(Context ctx) throws Exception {
        synchronized (WRITER) {
            bundled = new Index(read(ctx.getAssets().open("content-index.json"), 8 << 20));
            current = bundled;
            Snapshot saved = savedContent(ctx);
            if (saved != null) {
                current = saved.index;
                activePlaces = saved.places;
            } else {
                activePlaces = catalog(ctx, bundled);
            }
        }
    }

    private static final class Snapshot {
        final Index index;
        final List<WalkEngine.Place> places;
        Snapshot(Index index, List<WalkEngine.Place> places) {
            this.index = index;
            this.places = places;
        }
    }

    private static Snapshot savedContent(Context ctx) {
        AtomicFile stored = new AtomicFile(new File(folder(ctx), "active.json"));
        try {
            Index saved = new Index(read(stored.openRead(), 8 << 20));
            if (saved.revision <= bundled.revision) return null;
            for (Map.Entry<String,String> entry : saved.files.entrySet()) {
                String hash = entry.getValue();
                if (!hash.equals(bundled.files.get(entry.getKey())) && !cached(new File(folder(ctx), hash), hash)) return null;
            }
            return new Snapshot(saved, catalog(ctx, saved));
        } catch (IOException | JSONException damagedOrAbsent) {
            // 下載資料可能遭清除或毀損。此時直接使用隨附資料，下次仍可重新下載同一版。
            return null;
        }
    }

    static File override(Context ctx, String name) {
        Index snapshot = current;
        if (snapshot == null) return null;
        String hash = snapshot.files.get(name);
        if (hash == null || hash.equals(bundled.files.get(name))) return null;
        return new File(folder(ctx), hash);
    }

    static InputStream open(Context ctx, String name) throws IOException {
        File file = override(ctx, name);
        return file == null ? ctx.getAssets().open(name) : new FileInputStream(file);
    }

    static List<WalkEngine.Place> places(Context ctx) throws Exception {
        return activePlaces;
    }

    private static List<WalkEngine.Place> catalog(Context ctx, Index index) throws IOException, JSONException {
        String hash = index.files.get("places.json");
        InputStream source = hash.equals(bundled.files.get("places.json")) ? ctx.getAssets().open("places.json")
                : new FileInputStream(new File(folder(ctx), hash));
        return parsePlaces(read(source, 16 << 20), index);
    }

    private static List<WalkEngine.Place> parsePlaces(byte[] bytes, Index index) throws IOException, JSONException {
        JSONArray data = new JSONArray(new String(bytes, StandardCharsets.UTF_8));
        List<WalkEngine.Place> places = new ArrayList<>(data.length());
        Set<Integer> ids = new HashSet<>();
        for (int i = 0; i < data.length(); i++) {
            JSONObject p = data.getJSONObject(i);
            int id = p.getInt("id");
            double lat = p.getDouble("lat"), lng = p.getDouble("lng");
            String name = p.getString("name").trim();
            boolean photo = p.has("ph");
            if (id <= 0 || p.getDouble("id") != id || !ids.add(id) || name.isEmpty() || !Double.isFinite(lat) || !Double.isFinite(lng)
                    || Math.abs(lat) > 90 || Math.abs(lng) > 180
                    || (photo && !index.files.containsKey("photos/" + id + ".webp"))) throw new IOException("地點資料不完整");
            places.add(new WalkEngine.Place(id, name, lat, lng, p.optString("cat"), p.optString("tag"), p.optString("desc"), photo));
        }
        if (!ids.contains(32)) throw new IOException("缺少鹿港模擬起點");
        return Collections.unmodifiableList(places);
    }

    private static byte[] fetch(String path, int limit) throws IOException {
        HttpsURLConnection connection = (HttpsURLConnection)new URL(SITE + path).openConnection();
        try {
            connection.setConnectTimeout(10000);
            connection.setReadTimeout(20000);
            connection.setUseCaches(false);
            connection.setInstanceFollowRedirects(false);
            int status = connection.getResponseCode();
            if (status == 404) throw new FileNotFoundException(path);
            if (status != 200) throw new IOException("下載失敗（" + status + "）");
            return read(connection.getInputStream(), limit);
        } finally { connection.disconnect(); }
    }

    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    private static String hex(byte[] hash) {
        StringBuilder result = new StringBuilder(64);
        for (byte b : hash) {
            result.append(Character.forDigit((b & 255) >>> 4, 16)).append(Character.forDigit(b & 15, 16));
        }
        return result.toString();
    }

    private static boolean cached(File file, String expected) {
        if (!file.isFile() || file.length() > (16 << 20)) return false;
        MessageDigest digest = sha256();
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = input.read(buffer)) != -1) digest.update(buffer, 0, n);
            return hex(digest.digest()).equals(expected);
        } catch (IOException unreadable) { return false; }
    }

    private static void write(AtomicFile out, byte[] data) throws IOException {
        FileOutputStream stream = out.startWrite();
        try { stream.write(data); out.finishWrite(stream); }
        catch (IOException e) { out.failWrite(stream); throw e; }
    }

    static String update(Context ctx) throws Exception {
        synchronized (WRITER) {
            byte[] manifest;
            try { manifest = fetch("android-content.json", 8 << 20); }
            catch (FileNotFoundException e) { return "目前沒有已發布的新版地點資料。"; }
            Index next = new Index(manifest);
            AtomicFile active = new AtomicFile(new File(folder(ctx), "active.json"));
            Snapshot saved = savedContent(ctx);
            int installed = saved == null ? bundled.revision : saved.index.revision;
            if (next.revision <= installed) return "地點資料已是最新版本。";
            Files.createDirectories(folder(ctx).toPath());
            for (Map.Entry<String,String> entry : next.files.entrySet()) {
                String name = entry.getKey(), expected = entry.getValue();
                File target = new File(folder(ctx), expected);
                if (expected.equals(bundled.files.get(name)) || cached(target, expected)) continue;
                byte[] bytes = fetch(name, 16 << 20);
                if (!hex(sha256().digest(bytes)).equals(expected)) throw new IOException("內容校驗失敗");
                write(new AtomicFile(target), bytes);
            }
            catalog(ctx, next);
            write(active, manifest);
            Set<String> retained = new HashSet<>(next.files.values());
            retained.addAll(current.files.values());
            File[] old = folder(ctx).listFiles();
            if (old != null) for (File file : old) {
                if (HASH.matcher(file.getName()).matches() && !retained.contains(file.getName())) file.delete();
            }
            return "已下載新版地點資料，下次開啟散步吧時會套用。";
        }
    }
}
