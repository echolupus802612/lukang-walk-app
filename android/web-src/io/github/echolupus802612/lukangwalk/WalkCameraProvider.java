package io.github.echolupus802612.lukangwalk;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.UUID;
import java.util.regex.Pattern;

/** 相機可用暫時授權寫入這一次拍攝的 JPEG。檔案留在 App 私有快取。 */
public final class WalkCameraProvider extends ContentProvider {
    static final String AUTHORITY = "io.github.echolupus802612.lukangwalk.camera";
    private static final Pattern NAME = Pattern.compile("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\\.jpg");
    private static File directory(Context context) { return new File(context.getCacheDir(), "walk-camera"); }

    static File create(Context context, boolean png) throws IOException {
        File folder = directory(context);
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("無法準備相機暫存空間");
        File photo = new File(folder, UUID.randomUUID() + (png ? ".png" : ".jpg"));
        if (!photo.createNewFile()) throw new IOException("無法建立暫存照片");
        return photo;
    }

    static File restore(Context context, String name) {
        if (name == null || !(NAME.matcher(name).matches()
                || (name.endsWith(".png") && NAME.matcher(name.substring(0, name.length()-4) + ".jpg").matches()))) return null;
        File file = new File(directory(context), name);
        return file.isFile() ? file : null;
    }

    static void clearExpired(Context context, String capture, String export) {
        File[] old = directory(context).listFiles();
        long expiry = System.currentTimeMillis() - 24L * 60 * 60 * 1000;
        if (old != null) for (File file : old) {
            String name = file.getName();
            if (!name.equals(capture) && !name.equals(export) && file.lastModified() < expiry
                    && restore(context, name) != null) file.delete();
        }
    }

    static Uri uri(File photo) {
        return new Uri.Builder().scheme("content").authority(AUTHORITY).appendPath(photo.getName()).build();
    }

    private File photo(Uri uri) {
        String name = uri.getLastPathSegment();
        if (!AUTHORITY.equals(uri.getAuthority()) || uri.getPathSegments().size() != 1
                || name == null || !NAME.matcher(name).matches()) throw new IllegalArgumentException("找不到這張照片");
        return new File(directory(getContext()), name);
    }

    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { photo(uri); return "image/jpeg"; }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        File file = photo(uri);
        if (!file.isFile()) throw new FileNotFoundException("找不到這張照片");
        // 僅開啟已經建立的暫存檔；拍攝作業結束之後不能再建立相同檔案。
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode) & ~ParcelFileDescriptor.MODE_CREATE);
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        File file = photo(uri);
        String[] columns = projection == null
                ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        if (file.isFile()) {
            MatrixCursor.RowBuilder row = cursor.newRow();
            for (String column : columns) {
                if (OpenableColumns.DISPLAY_NAME.equals(column)) row.add(file.getName());
                else if (OpenableColumns.SIZE.equals(column)) row.add(file.length());
                else row.add(null);
            }
        }
        return cursor;
    }

    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String where, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String where, String[] args) { throw new UnsupportedOperationException(); }
}
