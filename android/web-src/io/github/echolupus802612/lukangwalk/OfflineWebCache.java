package io.github.echolupus802612.lukangwalk;

import android.content.Context;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.AtomicFile;
import android.webkit.WebResourceResponse;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.*;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.locks.ReentrantLock;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import javax.net.ssl.HttpsURLConnection;

/** 下載與組裝在背景進行。每個遊戲畫面固定讀取開啟當時的完整版本。 */
final class OfflineWebCache {
    interface Progress { void onProgress(int completed, int total); }
    private static final int WORKERS = 8, HEADER = 32, MAX_FILE = 32 << 20;
    private static final long MAX_ARCHIVE = 512L << 20;
    private static final Pattern SHA = Pattern.compile("[0-9a-f]{40}");
    private static final Pattern RANGE = Pattern.compile("bytes=([0-9]*)-([0-9]*)", Pattern.CASE_INSENSITIVE);
    private static final Object STATE = new Object();
    private static final Set<Snapshot> PINS = new HashSet<>();
    private static final Set<String> DAMAGED = new HashSet<>();
    private static final ExecutorService CLEANER = Executors.newSingleThreadExecutor(task -> {
        Thread worker = new Thread(task, "WalkCacheCleanup");
        worker.setDaemon(true);
        return worker;
    });
    private static final ReentrantLock WRITER = new ReentrantLock();
    private final File root, objects;
    private final AssetManager bundled;
    private final AtomicFile active;
    private volatile Operation running;
    private volatile boolean cancelled;

    OfflineWebCache(Context context) {
        bundled = context.getAssets();
        root = new File(context.getNoBackupFilesDir(), "walk-web-snapshots-v1");
        objects = new File(root, "objects");
        active = new AtomicFile(new File(root, "active.json"));
    }

    void cancel() {
        cancelled = true;
        Operation operation = running;
        if (operation != null) operation.cancel();
    }

    private static final class Asset {
        final String key;
        final long length;
        Asset(String key, long length) { this.key = key; this.length = length; }
    }

    static final class Snapshot implements AutoCloseable {
        final String commit;
        private final OfflineWebCache owner;
        private final File objects;
        private final Map<String,Asset> files;
        private final Set<String> verified = Collections.synchronizedSet(new HashSet<>());
        private boolean retired;
        private Snapshot(String commit, OfflineWebCache owner, Map<String,Asset> files) {
            this.commit = commit; this.owner = owner; this.objects = owner.objects; this.files = files;
        }
        @Override public void close() {
            synchronized (STATE) {
                if (PINS.remove(this) && retired) CLEANER.execute(() -> owner.discardRetired(this));
            }
        }

        WebResourceResponse response(String relativePath, String range) throws IOException {
            String path = "".equals(relativePath) ? "index.html" : relativePath;
            Asset asset = safePath(path) ? files.get(path) : null;
            if (asset == null) return error(404, "Not Found", -1);
            long size = asset.length, first = 0, last = size - 1;
            boolean partial = range != null && !range.isEmpty();
            if (partial) {
                Matcher m = RANGE.matcher(range.trim());
                if (!m.matches() || size == 0) return error(416, "Range Not Satisfiable", size);
                try {
                    String start = m.group(1), end = m.group(2);
                    if (start.isEmpty()) {
                        long suffix = Long.parseLong(end);
                        if (suffix <= 0) return error(416, "Range Not Satisfiable", size);
                        first = size - Math.min(size, suffix);
                    } else {
                        first = Long.parseLong(start);
                        if (!end.isEmpty()) last = Math.min(last, Long.parseLong(end));
                        if (first > last) return error(416, "Range Not Satisfiable", size);
                    }
                } catch (NumberFormatException invalid) { return error(416, "Range Not Satisfiable", size); }
            }
            File file = new File(objects, asset.key);
            if (file.length() != size + HEADER || (!verified.contains(asset.key) && !valid(file))) {
                synchronized (STATE) { DAMAGED.add(objects.getPath() + "/" + commit); }
                return error(503, "Cache Unavailable", -1);
            }
            verified.add(asset.key);
            long length = last - first + 1;
            FileInputStream input = new FileInputStream(file);
            try {
                input.getChannel().position(HEADER + first);
                Map<String,String> headers = new HashMap<>();
                headers.put("Cache-Control", "no-store");
                headers.put("Accept-Ranges", "bytes");
                headers.put("Content-Length", Long.toString(length));
                if (partial) headers.put("Content-Range", "bytes " + first + "-" + last + "/" + size);
                String type = mime(path);
                boolean text = type.startsWith("text/") || type.equals("application/json") || type.equals("image/svg+xml");
                return new WebResourceResponse(type, text ? "UTF-8" : null, partial ? 206 : 200,
                        partial ? "Partial Content" : "OK", headers, new Slice(input, length));
            } catch (IOException | RuntimeException failure) { input.close(); throw failure; }
        }
    }

    private static WebResourceResponse error(int status, String reason, long size) {
        Map<String,String> headers = new HashMap<>();
        headers.put("Cache-Control", "no-store");
        if (size >= 0) headers.put("Content-Range", "bytes */" + size);
        return new WebResourceResponse("text/plain", "UTF-8", status, reason, headers, new ByteArrayInputStream(new byte[0]));
    }

    private static final class Slice extends FilterInputStream {
        long remaining;
        Slice(InputStream in, long length) { super(in); remaining = length; }
        @Override public int read() throws IOException {
            if (remaining == 0) return -1;
            int next = in.read(); if (next >= 0) remaining--; return next;
        }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            if (len == 0) return 0;
            if (remaining == 0) return -1;
            int n = in.read(b, off, (int)Math.min(remaining, len)); if (n > 0) remaining -= n; return n;
        }
        @Override public long skip(long n) throws IOException {
            long skipped = in.skip(Math.min(remaining, n)); remaining -= skipped; return skipped;
        }
        @Override public int available() throws IOException { return (int)Math.min(remaining, in.available()); }
    }

    private static String mime(String path) {
        String ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        switch (ext) {
            case "html": case "htm": return "text/html";
            case "css": return "text/css";
            case "js": case "mjs": return "text/javascript";
            case "json": return "application/json";
            case "txt": return "text/plain";
            case "svg": return "image/svg+xml";
            case "webp": return "image/webp";
            case "png": return "image/png";
            case "jpg": case "jpeg": return "image/jpeg";
            case "gif": return "image/gif";
            case "ico": return "image/x-icon";
            case "mp3": return "audio/mpeg";
            case "ogg": return "audio/ogg";
            case "woff2": return "font/woff2";
            case "woff": return "font/woff";
            default: return "application/octet-stream";
        }
    }

    private static boolean safePath(String path) {
        if (path == null || path.isEmpty() || path.length() > 512 || path.startsWith("/") || path.endsWith("/")
                || path.indexOf('\\') >= 0 || path.indexOf('%') >= 0 || path.indexOf('?') >= 0
                || path.indexOf('#') >= 0 || path.indexOf(':') >= 0 || path.indexOf('\0') >= 0) return false;
        for (String part : path.split("/", -1)) if (part.isEmpty() || ".".equals(part) || "..".equals(part)) return false;
        return true;
    }

    private static String key(String path, String hash) {
        // p1 是 240 像素、WebP 品質 48 的版本；改動轉檔規格時提高版號。
        return (path.startsWith("photos/") && path.endsWith(".webp") ? "p1-" : "r1-") + hash;
    }
    private static MessageDigest md(String algorithm) {
        try { return MessageDigest.getInstance(algorithm); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length*2);
        for (byte b : bytes) result.append(Character.forDigit((b&255)>>>4, 16)).append(Character.forDigit(b&15, 16));
        return result.toString();
    }
    private static byte[] read(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(Math.max(0,limit), 65536));
        byte[] buf = new byte[16384];
        for (int n; (n=in.read(buf)) != -1;) {
            if (out.size() > limit-n) throw new IOException("檔案超出大小限制");
            out.write(buf,0,n);
        }
        return out.toByteArray();
    }

    Snapshot current() throws IOException {
        synchronized (STATE) {
            try (InputStream input = active.openRead()) {
                JSONObject index = new JSONObject(new String(read(input, 8<<20), StandardCharsets.UTF_8));
                String commit = index.getString("commit");
                if (!SHA.matcher(commit).matches() || index.getInt("format") != 1) return null;
                JSONObject entries = index.getJSONObject("files");
                Map<String,Asset> assets = new HashMap<>();
                String[] listed = objects.list();
                if (listed == null) return null;
                Set<String> present = new HashSet<>(Arrays.asList(listed));
                for (Iterator<String> it=entries.keys(); it.hasNext();) {
                    String path = it.next(); JSONArray info = entries.getJSONArray(path);
                    String hash = info.getString(0); long length = info.getLong(1);
                    if (!safePath(path) || !SHA.matcher(hash).matches() || length<0 || length>MAX_FILE) return null;
                    String name = key(path,hash);
                    if (!present.contains(name)) return null;
                    assets.put(path,new Asset(name,length));
                }
                if (!assets.containsKey("index.html")) return null;
                Snapshot result = new Snapshot(commit,this,assets);
                PINS.add(result); return result;
            } catch (FileNotFoundException | JSONException missing) { return null; }
        }
    }

    Snapshot sync(Progress progress) throws IOException {
        try { WRITER.lockInterruptibly(); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new InterruptedIOException(); }
        Operation op = new Operation();
        Snapshot previous = null;
        running = op;
        try {
            op.check();
            previous = current();
            WebRelease release;
            try { release = WebRelease.check(previous == null ? null : previous.commit); }
            catch (IOException discoveryUnavailable) {
                op.check();
                if (previous != null) throw discoveryUnavailable;
                try (InputStream seed = bundled.open("offline-seed.tsv")) { release = WebRelease.fromSeed(seed); }
                catch (IOException unavailable) { discoveryUnavailable.addSuppressed(unavailable); throw discoveryUnavailable; }
            }
            op.check();
            boolean damaged;
            synchronized (STATE) {
                damaged = previous != null && DAMAGED.contains(objects.getPath() + "/" + previous.commit);
            }
            if (release == null && previous != null && !damaged) {
                Snapshot unchanged = previous; previous = null;
                return unchanged;
            }
            if (release == null) release = WebRelease.check(null);
            if (release == null) throw new IOException("找不到網站版本");
            Files.createDirectories(objects.toPath());
            Map<String,Asset> assets = new HashMap<>();
            LinkedHashMap<String,WebRelease.Entry> missing = new LinkedHashMap<>();
            long reusedOriginalBytes = 0;
            for (WebRelease.Entry entry : release.files.values()) {
                op.check(); validate(entry);
                File blob = new File(objects, key(entry.path,entry.gitHash));
                if (valid(blob)) {
                    reusedOriginalBytes += entry.bytes;
                    assets.put(entry.path, new Asset(blob.getName(),blob.length()-HEADER));
                }
                else missing.put(entry.path,entry);
            }
            final int total = release.files.size();
            if (progress != null) progress.onProgress(assets.size(),total);
            Batch batch = new Batch(op, assets, missing, total, progress);
            try {
                if (previous == null && missing.size() >= 128 && assets.size() < 128
                        && reusedOriginalBytes < Math.max(1L, release.totalBytes / 20)) {
                    try { batch.archive(release); }
                    catch (IOException unavailable) { op.check(); }
                    // 已驗證的檔案繼續使用，封存下載中斷時只補齊剩下的項目。
                    batch.finishArchive();
                }
                for (WebRelease.Entry entry : new ArrayList<>(missing.values())) batch.raw(release,entry);
                batch.finish(); op.check();
                if (!missing.isEmpty() || !assets.containsKey("index.html")) throw new IOException("離線內容不完整");
                if (previous != null) { previous.close(); previous=null; }
                Snapshot result = activate(release,assets,op);
                return result;
            } finally { batch.shutdown(); }
        } finally {
            if (previous != null) previous.close();
            running = null; WRITER.unlock();
        }
    }

    private static void validate(WebRelease.Entry entry) throws IOException {
        if (!safePath(entry.path) || !SHA.matcher(entry.gitHash).matches() || entry.bytes<0 || entry.bytes>MAX_FILE)
            throw new IOException("不支援的網站檔案");
    }
    private static boolean valid(File blob) throws IOException {
        if (!blob.isFile() || blob.length()<HEADER || blob.length()>HEADER+(long)MAX_FILE) return false;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(blob)))) {
            byte[] expected = new byte[HEADER]; in.readFully(expected);
            MessageDigest actual = md("SHA-256"); byte[] buffer=new byte[16384];
            for (int n;(n=in.read(buffer))!=-1;) actual.update(buffer,0,n);
            return MessageDigest.isEqual(actual.digest(),expected);
        } catch (FileNotFoundException | EOFException damaged) { return false; }
    }
    private static Set<String> retained(File objects) {
        Set<String> keep = new HashSet<>();
        for (Snapshot snapshot : PINS) if (objects.equals(snapshot.objects)) {
            for (Asset asset : snapshot.files.values()) keep.add(asset.key);
        }
        return keep;
    }

    private void discardRetired(Snapshot old) {
        WRITER.lock();
        try (Snapshot installed=current()) {
            if (installed == null) return;
            Set<String> keep;
            synchronized (STATE) { keep=retained(objects); }
            // 僅清除已退役版本的物件。尚未完成的下載仍可接續使用。
            for (Asset a:old.files.values()) if (!keep.contains(a.key)) new File(objects,a.key).delete();
        } catch (IOException ignored) { /* 下次成功更新時再次清理。 */ }
        finally { WRITER.unlock(); }
    }

    private Snapshot activate(WebRelease release, Map<String,Asset> assets, Operation op) throws IOException {
        byte[] manifest;
        try {
            JSONObject list = new JSONObject();
            for (WebRelease.Entry e : release.files.values()) list.put(e.path,new JSONArray().put(e.gitHash).put(assets.get(e.path).length));
            manifest = new JSONObject().put("format",1).put("commit",release.commit).put("files",list)
                    .toString().getBytes(StandardCharsets.UTF_8);
        } catch (JSONException invalid) { throw new IOException(invalid); }
        Snapshot result;
        Set<String> keep;
        synchronized (STATE) {
            op.check();
            FileOutputStream out=active.startWrite();
            try { out.write(manifest); active.finishWrite(out); }
            catch (IOException failure) { active.failWrite(out); throw failure; }
            for (Snapshot snapshot:PINS) {
                if (objects.equals(snapshot.objects) && !snapshot.commit.equals(release.commit)) snapshot.retired=true;
            }
            DAMAGED.remove(objects.getPath() + "/" + release.commit);
            result = new Snapshot(release.commit,this,assets);
            PINS.add(result);
            keep = retained(objects);
        }
        File[] old=objects.listFiles();
        if (old!=null) for (File file:old) if (!keep.contains(file.getName())) file.delete();
        return result;
    }

    private final class Operation {
        final Set<HttpsURLConnection> network = new HashSet<>();
        final Thread owner = Thread.currentThread();
        volatile boolean stopped;
        void check() throws InterruptedIOException {
            if (cancelled || stopped || owner.isInterrupted() || Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
        }
        synchronized HttpsURLConnection connect(URL url) throws IOException {
            check();
            HttpsURLConnection c = (HttpsURLConnection)url.openConnection();
            c.setConnectTimeout(10000); c.setReadTimeout(20000); c.setUseCaches(false);
            c.setInstanceFollowRedirects(false); c.setRequestProperty("Accept-Encoding","identity");
            network.add(c); return c;
        }
        synchronized void close(HttpsURLConnection c) { network.remove(c); c.disconnect(); }
        void cancel() {
            List<HttpsURLConnection> opened;
            synchronized (this) { stopped=true; opened=new ArrayList<>(network); }
            for (HttpsURLConnection c:opened) c.disconnect();
        }
    }

    private final class Batch {
        final Operation op;
        final Map<String,Asset> assets;
        final Map<String,WebRelease.Entry> missing;
        final Set<String> scheduled = new HashSet<>();
        final int total;
        final Progress progress;
        final ExecutorService pool = Executors.newFixedThreadPool(WORKERS);
        final CompletionService<WebRelease.Entry> jobs = new ExecutorCompletionService<>(pool);
        int pending;
        Batch(Operation op, Map<String,Asset> assets, Map<String,WebRelease.Entry> missing, int total, Progress progress) {
            this.op=op; this.assets=assets; this.missing=missing; this.total=total; this.progress=progress;
        }
        void submit(WebRelease.Entry entry, Callable<byte[]> source) throws IOException {
            op.check(); if (pending>=WORKERS) complete();
            if (!scheduled.add(entry.path)) return;
            jobs.submit(() -> { op.check(); store(entry,source.call(),op); return entry; });
            pending++;
        }
        void complete() throws IOException {
            try {
                WebRelease.Entry e = jobs.take().get();
                File f=new File(objects,key(e.path,e.gitHash));
                assets.put(e.path,new Asset(f.getName(),f.length()-HEADER));
                missing.remove(e.path);
                if (progress!=null) progress.onProgress(assets.size(),total);
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new InterruptedIOException(); }
            catch (ExecutionException failure) { throw new IOException("無法準備離線檔案",failure.getCause()); }
            finally { pending--; }
        }
        void finish() throws IOException { while (pending>0) complete(); scheduled.clear(); }
        void finishArchive() throws IOException {
            while (pending>0) {
                try { complete(); }
                catch (IOException badEntry) { op.check(); }
            }
            scheduled.clear();
        }
        void shutdown() { pool.shutdownNow(); op.cancel(); }
        void raw(WebRelease release, WebRelease.Entry e) throws IOException {
            submit(e, () -> {
                HttpsURLConnection c=op.connect(release.rawUrl(e));
                try {
                    if (c.getResponseCode()!=200) throw new IOException("下載失敗：" + e.path);
                    try (InputStream input=c.getInputStream()) { return read(input,(int)e.bytes); }
                } finally { op.close(c); }
            });
        }
        void archive(WebRelease release) throws IOException {
            HttpsURLConnection c=op.connect(release.archiveUrl());
            String prefix="lukang-walk-"+release.commit+"/docs/";
            try {
                if (c.getResponseCode()!=200 || c.getContentLengthLong()>MAX_ARCHIVE) throw new IOException("無法讀取封存檔");
                try (ZipInputStream zip=new ZipInputStream(new BufferedInputStream(c.getInputStream(),65536))) {
                    long expanded=0;
                    int count=0;
                    byte[] discard=new byte[32768];
                    for (ZipEntry item;(item=zip.getNextEntry())!=null;) {
                        op.check();
                        if (++count>50000) throw new IOException("封存檔項目過多");
                        String name=item.getName();
                        WebRelease.Entry e=name.startsWith(prefix) ? missing.get(name.substring(prefix.length())) : null;
                        if (e!=null && !item.isDirectory() && !scheduled.contains(e.path)) {
                            byte[] bytes=read(zip,(int)e.bytes); expanded+=bytes.length;
                            submit(e,()->bytes);
                        } else {
                            for (int n;(n=zip.read(discard))!=-1;) {
                                expanded+=n; if (expanded>MAX_ARCHIVE) throw new IOException("封存檔過大");
                                op.check();
                            }
                        }
                        if (expanded>MAX_ARCHIVE) throw new IOException("封存檔過大");
                        zip.closeEntry();
                    }
                }
            } finally { op.close(c); }
        }
    }

    private void store(WebRelease.Entry entry, byte[] original, Operation op) throws IOException {
        if (original.length!=entry.bytes) throw new IOException("網站檔案長度不符");
        MessageDigest git=md("SHA-1");
        git.update(("blob "+original.length+"\0").getBytes(StandardCharsets.US_ASCII));
        if (!hex(git.digest(original)).equals(entry.gitHash)) throw new IOException("網站檔案校驗失敗");
        String name=key(entry.path,entry.gitHash);
        byte[] data=name.startsWith("p1-") ? thumbnail(original) : original;
        op.check();
        File temporary=File.createTempFile("incoming-",".tmp",objects);
        try {
            try (FileOutputStream out=new FileOutputStream(temporary)) {
                out.write(md("SHA-256").digest(data)); out.write(data);
                out.getFD().sync();
            }
            op.check();
            Files.move(temporary.toPath(),new File(objects,name).toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        } finally { temporary.delete(); }
    }
    private static byte[] thumbnail(byte[] source) throws IOException {
        BitmapFactory.Options options=new BitmapFactory.Options();
        options.inJustDecodeBounds=true;
        BitmapFactory.decodeByteArray(source,0,source.length,options);
        int w=options.outWidth,h=options.outHeight;
        if (w<1 || h<1 || w>8192 || h>8192 || (long)w*h>32000000 || (long)h*240/w>4096)
            throw new IOException("照片尺寸不符");
        options.inJustDecodeBounds=false; options.inSampleSize=1;
        while (w/(2*options.inSampleSize)>=240) options.inSampleSize*=2;
        Bitmap original=BitmapFactory.decodeByteArray(source,0,source.length,options);
        if (original==null) throw new IOException("無法讀取照片");
        Bitmap scaled=null;
        try {
            scaled=Bitmap.createScaledBitmap(original,240,Math.max(1,Math.round(h*240f/w)),true);
            ByteArrayOutputStream out=new ByteArrayOutputStream();
            if (!scaled.compress(Bitmap.CompressFormat.WEBP,48,out)) throw new IOException("無法儲存照片");
            return out.toByteArray();
        } finally {
            if (scaled!=null && scaled!=original) scaled.recycle();
            original.recycle();
        }
    }
}
