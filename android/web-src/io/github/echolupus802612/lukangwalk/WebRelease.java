package io.github.echolupus802612.lukangwalk;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.InterruptedIOException;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

/** 在背景執行緒核對已部署的網頁版本與完整檔案清單。 */
final class WebRelease {
    static final String CONTENT_NAME = "lukang-walk-app-content";
    static final String HOST = "echolupus802612.github.io";
    static final String ORIGIN = "https://" + HOST;
    static final String BASE_PATH = "/" + CONTENT_NAME + "/";
    static final String SITE = ORIGIN + BASE_PATH;
    private static final String REPO = "echolupus802612/" + CONTENT_NAME;
    private static final String API = "https://api.github.com/repos/" + REPO;
    private static final Pattern HASH = Pattern.compile("[0-9a-f]{40}");

    static final class Entry {
        final String path, gitHash;
        final long bytes;

        Entry(String path, String gitHash, long bytes) {
            this.path = path;
            this.gitHash = gitHash;
            this.bytes = bytes;
        }
    }

    final String commit;
    final Map<String, Entry> files;
    final long totalBytes;

    private WebRelease(String commit, Map<String, Entry> files, long totalBytes) {
        this.commit = commit;
        this.files = Collections.unmodifiableMap(files);
        this.totalBytes = totalBytes;
    }

    static WebRelease check(String installedCommit) throws IOException {
        checkCancelled();
        try {
            // 舊版繼續從 Pages 的 main 更新；新版向專屬分支取出同一提交的網頁與素材。
            JSONObject ref = new JSONObject(api("/git/ref/heads/android-1.9"));
            JSONObject object = ref.getJSONObject("object");
            String commit = object.getString("sha");
            if (!"commit".equals(object.getString("type")) || !HASH.matcher(commit).matches()) {
                throw new IOException("Android 內容分支的版本無效。");
            }
            return commit.equals(installedCommit) ? null : fromTree(commit);
        } catch (JSONException invalid) {
            throw new IOException("無法辨識 Android 內容分支。", invalid);
        }
    }

    private static WebRelease fromTree(String commit) throws IOException, JSONException {
        JSONObject tree = new JSONObject(api("/git/trees/" + commit + "?recursive=1"));
        if (tree.getBoolean("truncated")) throw new IOException("網站檔案清單不完整。");
        JSONArray rows = tree.getJSONArray("tree");
        Inventory inventory = new Inventory();
        for (int i = 0; i < rows.length(); i++) {
            if ((i & 255) == 0) checkCancelled();
            JSONObject row = rows.getJSONObject(i);
            String path = row.getString("path");
            if (!path.startsWith("docs/") || "tree".equals(row.getString("type"))) continue;
            String mode = row.getString("mode");
            if (!"blob".equals(row.getString("type")) || !("100644".equals(mode) || "100755".equals(mode))) {
                throw new IOException("網站清單含有不支援的檔案類型。");
            }
            inventory.add(path.substring("docs/".length()), row.getString("sha"), row.getLong("size"));
        }
        return inventory.finish(commit);
    }

    /** 安裝檔內的已發布版本清單。首次連線無法取得 GitHub 清單時仍能檢查每個下載檔案。 */
    static WebRelease fromSeed(InputStream input) throws IOException {
        checkCancelled();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8))) {
            String commit = reader.readLine();
            if (commit == null || !HASH.matcher(commit).matches()) throw new IOException("內附的網站版號無效。");
            Inventory inventory = new Inventory();
            String line;
            while ((line = reader.readLine()) != null) {
                checkCancelled();
                String[] columns = line.split("\t", -1);
                if (columns.length != 3) throw new IOException("內附的網站清單格式無效。");
                long bytes;
                try { bytes = Long.parseLong(columns[1]); }
                catch (NumberFormatException invalid) { throw new IOException("內附的檔案大小無效。", invalid); }
                inventory.add(columns[2], columns[0], bytes);
            }
            return inventory.finish(commit);
        }
    }

    private static final class Inventory {
        final Map<String, Entry> files = new LinkedHashMap<>();
        long total;

        void add(String path, String hash, long bytes) throws IOException {
            for (String part : path.split("/", -1)) {
                if (part.isEmpty() || ".".equals(part) || "..".equals(part) || part.indexOf('\\') >= 0
                        || part.indexOf('\0') >= 0) throw new IOException("網站檔案路徑無效。");
            }
            if (!HASH.matcher(hash).matches() || bytes < 0 || bytes > Long.MAX_VALUE - total
                    || files.containsKey(path)) throw new IOException("網站檔案資料無效。");
            files.put(path, new Entry(path, hash, bytes));
            total += bytes;
        }

        WebRelease finish(String commit) throws IOException {
            Entry index = files.get("index.html");
            if (index == null || index.bytes == 0) throw new IOException("網站缺少首頁。");
            return new WebRelease(commit, files, total);
        }
    }

    URL rawUrl(Entry entry) throws IOException {
        Entry known = files.get(entry.path);
        if (known == null || known.bytes != entry.bytes || !known.gitHash.equals(entry.gitHash)) {
            throw new IOException("所選的檔案不在這個版本的網站清單內。");
        }
        try {
            return new URI("https", "raw.githubusercontent.com", "/" + REPO + "/" + commit + "/docs/" + entry.path,
                    null).toURL();
        } catch (URISyntaxException invalid) {
            throw new IOException("無法取得網站檔案的網址。", invalid);
        }
    }

    URL archiveUrl() throws IOException {
        return new URL("https://codeload.github.com/" + REPO + "/zip/" + commit);
    }

    /** 尚在準備完整離線包時，線上散步也使用同一個提交並逐檔檢查。 */
    byte[] onlineFile(String name) throws IOException {
        Entry entry = files.get(name);
        if (entry == null || entry.bytes < 1 || entry.bytes > 32L * 1024 * 1024) {
            throw new IOException("找不到指定的散步素材。");
        }
        HttpURLConnection connection = connect(rawUrl(entry).toString(), false);
        try (InputStream in = connection.getInputStream()) {
            byte[] data = new byte[(int)entry.bytes];
            new java.io.DataInputStream(in).readFully(data);
            if (in.read() != -1) throw new IOException("素材長度不符。");
            MessageDigest hash;
            try { hash = MessageDigest.getInstance("SHA-1"); }
            catch (NoSuchAlgorithmException impossible) { throw new IOException(impossible); }
            hash.update(("blob " + data.length + "\0").getBytes(StandardCharsets.US_ASCII));
            byte[] digest = hash.digest(data);
            for (int i = 0; i < digest.length; i++) {
                int expected = Integer.parseInt(entry.gitHash.substring(i * 2, i * 2 + 2), 16);
                if ((digest[i] & 255) != expected) throw new IOException("素材與發布的版本不符。");
            }
            return data;
        } finally { connection.disconnect(); }
    }

    private static String api(String path) throws IOException {
        HttpURLConnection connection = connect(API + path, true);
        try (InputStream input = connection.getInputStream(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = input.read(buffer)) != -1) {
                checkCancelled();
                if (output.size() + n > 16 * 1024 * 1024) throw new IOException("網站清單過大。");
                output.write(buffer, 0, n);
            }
            return output.toString("UTF-8");
        } finally { connection.disconnect(); }
    }

    private static HttpURLConnection connect(String url, boolean api) throws IOException {
        checkCancelled();
        HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        connection.setConnectTimeout(12000);
        connection.setReadTimeout(20000);
        connection.setRequestProperty("User-Agent", "LukangWalk-Android");
        if (api) {
            connection.setRequestProperty("Accept", "application/vnd.github+json");
            connection.setRequestProperty("X-GitHub-Api-Version", "2022-11-28");
        } else {
            connection.setRequestProperty("Cache-Control", "no-cache");
        }
        try {
            int status = connection.getResponseCode();
            checkCancelled();
            if (status != 200) throw new IOException("無法查詢網站版本（HTTP " + status + "）。");
            return connection;
        } catch (IOException failure) {
            connection.disconnect();
            throw failure;
        }
    }

    private static void checkCancelled() throws InterruptedIOException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("網站版本檢查已取消。");
    }
}
