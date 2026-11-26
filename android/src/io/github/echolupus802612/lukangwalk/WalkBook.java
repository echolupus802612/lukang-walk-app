package io.github.echolupus802612.lukangwalk;

import android.content.Context;
import android.database.Cursor;
import android.database.DatabaseUtils;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 保留永久地點編號。舊版的累積數字沒有日期，不推算成新的到達事件。 */
final class WalkBook extends SQLiteOpenHelper implements WalkEngine.Progress {
    WalkBook(Context context) { super(context, "walk.db", null, 1); }

    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE settings (name TEXT PRIMARY KEY, value INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE books (sim INTEGER PRIMARY KEY, drawn INTEGER NOT NULL)");
        db.execSQL("INSERT INTO books VALUES (0,0),(1,0)");
        db.execSQL("CREATE TABLE footprints (sim INTEGER NOT NULL, place INTEGER NOT NULL,"
                + " recent_order INTEGER, PRIMARY KEY(sim,place))");
        db.execSQL("CREATE TABLE arrivals (id TEXT PRIMARY KEY, sim INTEGER NOT NULL,"
                + " place INTEGER NOT NULL, completed_at INTEGER NOT NULL)");
    }
    @Override public void onUpgrade(SQLiteDatabase db, int previous, int next) {
        throw new IllegalStateException("無法辨識的足跡版本");
    }
    private long scalar(String query, boolean sim) {
        return DatabaseUtils.longForQuery(getReadableDatabase(), query, new String[]{sim ? "1" : "0"});
    }
    @Override public int drawn(boolean sim) { return (int)scalar("SELECT drawn FROM books WHERE sim=?", sim); }
    @Override public int seenCount(boolean sim) { return (int)scalar("SELECT count(*) FROM footprints WHERE sim=?", sim); }
    @Override public List<Integer> recent(boolean sim) {
        List<Integer> result = new ArrayList<>();
        try (Cursor rows = getReadableDatabase().rawQuery("SELECT place FROM footprints WHERE sim=?"
                + " AND recent_order IS NOT NULL ORDER BY recent_order DESC LIMIT 12", new String[]{sim ? "1" : "0"})) {
            while (rows.moveToNext()) result.add(rows.getInt(0));
        }
        return result;
    }
    @Override public void recordDraw(boolean sim) {
        getWritableDatabase().execSQL("UPDATE books SET drawn=drawn+1 WHERE sim=?", new Object[]{sim ? 1 : 0});
    }
    @Override public void recordArrival(boolean sim, int place) {
        SQLiteDatabase db = getWritableDatabase();
        int mode = sim ? 1 : 0;
        db.beginTransaction();
        try {
            long order = Math.max(0, scalar("SELECT COALESCE(MAX(recent_order),0) FROM footprints WHERE sim=?", sim)) + 1;
            db.execSQL("INSERT OR REPLACE INTO footprints VALUES(?,?,?)", new Object[]{mode, place, order});
            db.execSQL("INSERT INTO arrivals VALUES(?,?,?,?)", new Object[]{UUID.randomUUID().toString(),
                    mode, place, System.currentTimeMillis()});
            db.setTransactionSuccessful();
        } finally { db.endTransaction(); }
    }

    private int setting(String name, int fallback) {
        try (Cursor row = getReadableDatabase().rawQuery("SELECT value FROM settings WHERE name=?", new String[]{name})) {
            return row.moveToFirst() ? row.getInt(0) : fallback;
        }
    }
    private void set(String name, boolean value) {
        getWritableDatabase().execSQL("INSERT OR REPLACE INTO settings VALUES (?,?)", new Object[]{name, value ? 1 : 0});
    }
    boolean voice() { return setting("voice", 1) == 1; }
    void voice(boolean value) { set("voice", value); }
    boolean imported() { return setting("imported", 0) == 1; }

    void importLegacy(JSONObject old) {
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        try {
            if (imported()) return;
            boolean separated = old.optInt("ver", 1) >= 2;
            if (old.has("voice") && setting("voice", -1) < 0) set("voice", old.optBoolean("voice", true));
            if (separated) importBook(db, old, "", 0);
            importBook(db, old, separated || old.has("sim_drawn") ? "sim_" : "", 1);
            set("imported", true);
            db.setTransactionSuccessful();
        } finally { db.endTransaction(); }
    }
    private static void importBook(SQLiteDatabase db, JSONObject old, String prefix, int sim) {
        db.execSQL("UPDATE books SET drawn=drawn+? WHERE sim=?",
                new Object[]{Math.max(0, old.optInt(prefix + "drawn", 0)), sim});
        JSONArray seen = old.optJSONArray(prefix + "seen"), recent = old.optJSONArray(prefix + "recent");
        if (seen != null) for (int i = 0; i < seen.length(); i++) {
            int id = seen.optInt(i);
            if (id > 0) db.execSQL("INSERT OR IGNORE INTO footprints(sim,place) VALUES(?,?)", new Object[]{sim,id});
        }
        if (recent != null) for (int i = 0; i < Math.min(12, recent.length()); i++) {
            int id = recent.optInt(i);
            if (id <= 0) continue;
            db.execSQL("INSERT OR IGNORE INTO footprints(sim,place) VALUES(?,?)", new Object[]{sim,id});
            db.execSQL("UPDATE footprints SET recent_order=? WHERE sim=? AND place=? AND recent_order IS NULL",
                    new Object[]{-i-1,sim,id});
        }
    }
}
