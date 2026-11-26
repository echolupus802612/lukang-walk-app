package io.github.echolupus802612.lukangwalk;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** 每趟一個檔案，某一趟損毀時其他筆記及相片仍可開啟。由主執行緒串行更新。 */
final class WalkJournalFiles {
    final File root;
    private final File entries;
    private final SharedPreferences receipts;

    WalkJournalFiles(Context context) {
        root = new File(context.getFilesDir(), "walk-journal");
        entries = new File(root, "entries");
        receipts = context.getSharedPreferences("walk-journal-recovery", Context.MODE_PRIVATE);
    }

    static boolean validId(String id) {
        try { return id != null && UUID.fromString(id).toString().equalsIgnoreCase(id); }
        catch (IllegalArgumentException invalid) { return false; }
    }

    static String day(long time) {
        return new SimpleDateFormat("yyyy.MM.dd", Locale.TAIWAN).format(new Date(time));
    }

    static void ensure(File dir) throws IOException {
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("無法建立日誌資料夾");
    }

    static void write(File file, JSONObject value) throws IOException {
        ensure(file.getParentFile());
        AtomicFile dest = new AtomicFile(file);
        FileOutputStream output = dest.startWrite();
        try {
            output.write(value.toString().getBytes(StandardCharsets.UTF_8));
            dest.finishWrite(output);
        } catch (IOException | RuntimeException e) {
            dest.failWrite(output);
            throw e;
        }
    }

    static JSONObject read(File file) throws IOException, JSONException {
        return new JSONObject(new String(new AtomicFile(file).readFully(), StandardCharsets.UTF_8));
    }

    private File file(String id) throws IOException {
        if (!validId(id)) throw new IOException("散步編號無效");
        return new File(entries, id.toLowerCase(Locale.ROOT) + ".json");
    }

    JSONObject entry(String id) throws IOException, JSONException {
        File src = file(id);
        if (!src.exists() && !new File(src.getPath()+".bak").exists()) return null;
        JSONObject row = read(src);
        if (!id.equalsIgnoreCase(row.optString("id")) || row.getInt("placeID") < 1
                || !row.has("isSimulated") || !row.has("status")) throw new JSONException("日誌內容不完整");
        return row;
    }

    List<JSONObject> all() throws IOException {
        ensure(entries);
        File[] files = entries.listFiles();
        if (files == null) throw new IOException("暫時無法讀取日誌");
        Set<String> ids = new HashSet<>();
        for (File f : files) {
            String name = f.getName();
            if (name.endsWith(".json.bak")) name = name.substring(0, name.length()-4);
            if (name.endsWith(".json")) {
                String key = name.substring(0, name.length()-5);
                if (validId(key)) ids.add(key);
            }
        }
        List<JSONObject> result = new ArrayList<>();
        for (String id : ids) {
            try {
                JSONObject e = entry(id);
                if (e != null) result.add(e);
            } catch (IOException | JSONException damaged) { /* 保留檔案，讓其他紀錄照常顯示。 */ }
        }
        result.sort(Comparator.<JSONObject>comparingLong(e -> e.optLong("startedAt")).reversed()
                .thenComparing(e -> e.optString("id")));
        return result;
    }

    private void save(JSONObject row) throws JSONException, IOException { write(file(row.getString("id")), row); }

    JSONObject begin(JSONObject target) throws IOException, JSONException {
        String id = target.getString("id");
        int place = target.getInt("placeID");
        String name = target.getString("name").trim();
        if (place <= 0 || name.isEmpty()) throw new JSONException("目的地缺少資料");
        boolean sim = target.getBoolean("isSimulated");
        JSONObject item;
        try { item = entry(id); }
        catch (JSONException malformed) {
            File original = file(id);
            Files.move(original.toPath(), new File(entries,id+".damaged-"+UUID.randomUUID()).toPath());
            item = null;
        }
        if (item == null) {
            long now = System.currentTimeMillis();
            item = new JSONObject().put("id",id).put("status","walking").put("isSimulated",sim)
                    .put("startedAt",now).put("date",day(now)).put("note","").put("favorite",false);
        }
        if (item.getBoolean("isSimulated") != sim) throw new JSONException("散步模式不符");
        if (!"walking".equals(item.getString("status"))) return item;
        item.put("placeID",place).put("name",name).put("area",target.optString("area"));
        double lat = target.optDouble("latitude"), lon = target.optDouble("longitude");
        if (Double.isFinite(lat) && Math.abs(lat)<=90 && Double.isFinite(lon) && Math.abs(lon)<=180) {
            item.put("latitude",lat).put("longitude",lon);
        } else { item.remove("latitude"); item.remove("longitude"); }
        save(item);
        return item;
    }

    private void apply(String id, JSONObject end) throws IOException, JSONException {
        JSONObject item = entry(id);
        if (item == null) throw new IOException("找不到散步紀錄");
        String status = end.getString("status"), old = item.getString("status");
        if (!("arrived".equals(status) || "stopped".equals(status) || "interrupted".equals(status)))
            throw new JSONException("散步狀態無效");
        if (!old.equals(status) && !"walking".equals(old)
                && !("arrived".equals(status) && "interrupted".equals(old))) return;
        if (!old.equals(status)) {
            item.put("status",status);
            if (!"interrupted".equals(status)) {
                long time = end.getLong("at");
                item.put("endedAt",time).put("date",end.optString("date",day(time)));
            }
        }
        if (!item.has("stop") && end.has("stop")) item.put("stop",end.getInt("stop"));
        if (!item.has("walked") && end.has("walked")) item.put("walked",end.getDouble("walked"));
        save(item);
    }

    void finish(String id, String status, String date, long at, Integer stop, Double walked) throws IOException, JSONException {
        if (!validId(id)) throw new JSONException("散步編號無效");
        JSONObject end = new JSONObject().put("status",status).put("at",at);
        if (date != null && date.matches("\\d{4}\\.\\d{2}\\.\\d{2}")) end.put("date",date);
        if (stop != null && stop >= 0) end.put("stop",stop);
        if (walked != null && Double.isFinite(walked) && walked >= 0) end.put("walked",walked);
        if ("stopped".equals(status)) {
            String saved = receipts.getString(id,null);
            if (saved != null) end = new JSONObject(saved);
            else if (!receipts.edit().putString(id,end.toString()).commit()) throw new IOException("無法保留收工紀錄");
        }
        apply(id,end);
        if ("stopped".equals(status)) receipts.edit().remove(id).commit();
    }

    void recover(String keep) throws IOException {
        for (Map.Entry<String,?> pending : receipts.getAll().entrySet()) {
            try {
                apply(pending.getKey(),new JSONObject((String)pending.getValue()));
                receipts.edit().remove(pending.getKey()).commit();
            } catch (IOException | JSONException ignored) { /* 下次開啟時再試。 */ }
        }
        for (JSONObject row : all()) {
            String id = row.optString("id");
            if (!"walking".equals(row.optString("status")) || id.equalsIgnoreCase(keep)
                    || receipts.contains(id)) continue;
            try { finish(id,"interrupted",null,System.currentTimeMillis(),null,null); }
            catch (IOException | JSONException ignored) { /* 一筆寫入失敗不影響其他行程。 */ }
        }
    }

    void edit(String id, String note, Boolean favorite) throws IOException, JSONException {
        JSONObject item = entry(id);
        if (item == null) throw new IOException("找不到這趟散步");
        if (note != null) item.put("note",note);
        if (favorite != null) item.put("favorite",favorite);
        save(item);
    }

    void migrate(JSONArray real, JSONArray simulated, JSONArray places) throws IOException, JSONException {
        if (migrated()) return;
        Set<String> visited = new HashSet<>();
        for (JSONObject row : all()) {
            if (revealed(row)) visited.add(row.optBoolean("isSimulated")+":"+row.optInt("placeID"));
        }
        Map<Integer,JSONObject> indexed = new HashMap<>();
        for (int i=0; i<places.length(); i++) {
            JSONObject place = places.getJSONObject(i);
            indexed.put(place.getInt("placeID"),place);
        }
        for (boolean sim : new boolean[]{false,true}) {
            JSONArray ids = sim ? simulated : real;
            for (int i=0; i<ids.length(); i++) {
                int pid = ids.optInt(i);
                if (pid<=0) continue;
                String key = sim+":"+pid;
                if (!visited.add(key)) continue;
                String id = UUID.nameUUIDFromBytes(("legacy:"+key).getBytes(StandardCharsets.UTF_8)).toString();
                if (entry(id) != null) continue;
                JSONObject place=indexed.get(pid);
                if (place==null) place=new JSONObject().put("placeID",pid).put("name","先前造訪的地點（編號 "+pid+"）");
                JSONObject row = new JSONObject(place.toString()).put("id",id).put("status","legacy")
                        .put("isSimulated",sim).put("date","").put("favorite",false).put("note","");
                save(row);
            }
        }
        write(new File(root,"migration.json"),new JSONObject().put("version",1));
    }

    boolean migrated() { return new File(root,"migration.json").isFile(); }
    static boolean revealed(JSONObject row) {
        return "arrived".equals(row.optString("status")) || "legacy".equals(row.optString("status"));
    }
    static String title(JSONObject row) {
        if (revealed(row)) return row.optString("name");
        switch (row.optString("status")) {
            case "stopped": return "中途收工的散步";
            case "interrupted": return "中斷的散步";
            default: return "散步途中";
        }
    }
}
