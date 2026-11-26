package io.github.echolupus802612.lukangwalk;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.webkit.WebView;
import android.widget.Toast;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.UUID;

/** 只接收目前到站卡的 PNG，位置由系統文件選擇器決定。 */
final class WalkPhotoExport {
    static final int REQUEST = 9;
    private final Activity activity;
    private final SharedPreferences recoveredPhotos;
    private File file;
    private WebView source;
    private String token;
    private boolean choosing, preparing;
    private AlertDialog recovery;

    WalkPhotoExport(Activity activity, Bundle state) {
        this.activity = activity;
        recoveredPhotos = activity.getSharedPreferences("walk-camera-recovery", Activity.MODE_PRIVATE);
        if (state != null) {
            file = WalkCameraProvider.restore(activity, state.getString("exportFile"));
            choosing = file != null && state.getBoolean("exportChoosing");
        }
        if (file == null) file = WalkCameraProvider.restore(activity, recoveredPhotos.getString("original", null));
    }

    String retainedName() { return file == null ? null : file.getName(); }

    void install(WebView view) {
        source = view;
        token = "walk-card-" + UUID.randomUUID();
        // 正式版與先前已下載的首頁都使用這個按鈕。保留瀏覽器可直接分享檔案時的原有流程。
        String script = "(function(key){const b=document.getElementById('shareGo'),p=document.getElementById('sharev'),"
                + "img=document.getElementById('shareImg'),msg=document.getElementById('shareMsg');if(!b||!p||!img||!msg)return;"
                + "if(b.walkSaveClick)b.removeEventListener('click',b.walkSaveClick,true);"
                + "b.walkSaveClick=async e=>{if(!e.isTrusted||!p.classList.contains('on')||b.disabled||b.textContent!=='存圖片')return;"
                + "e.preventDefault();e.stopImmediatePropagation();b.disabled=true;msg.textContent='正在準備圖片…';"
                + "try{const src=img.src;if(!src.startsWith('blob:'+location.origin+'/'))throw 0;"
                + "const blob=await (await fetch(src)).blob();if(blob.type!=='image/png'||blob.size>8388608)throw 0;"
                + "const data=await new Promise((ok,no)=>{const r=new FileReader();r.onload=()=>ok(r.result);r.onerror=no;r.readAsDataURL(blob)});"
                + "if(img.src!==src||!p.classList.contains('on')||prompt(key,data)!=='ok')throw 0;"
                + "msg.textContent='請選擇要儲存的位置。';}catch(e){msg.textContent='這張圖片未能儲存，請再試一次。';}"
                + "finally{b.disabled=false;}};b.addEventListener('click',b.walkSaveClick,true);})(" + JSONObject.quote(token) + ")";
        view.evaluateJavascript(script, null);
    }

    boolean accepts(WebView view, String key) { return view == source && token != null && token.equals(key); }
    boolean prepare(String data) {
        String prefix = "data:image/png;base64,";
        if (file != null || preparing || data == null || !data.startsWith(prefix) || data.length() > 11200000) return false;
        preparing = true;
        WebView page = source;
        new Thread(() -> {
            File staged = null;
            try {
                byte[] bytes = Base64.decode(data.substring(prefix.length()), Base64.NO_WRAP);
                BitmapFactory.Options bounds = new BitmapFactory.Options();
                bounds.inJustDecodeBounds = true;
                BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
                if (!"image/png".equals(bounds.outMimeType) || bounds.outWidth != 1080 || bounds.outHeight <= 0
                        || bounds.outHeight > 4096) throw new IOException("透卡的圖片格式不符");
                staged = WalkCameraProvider.create(activity, true);
                try (FileOutputStream output = new FileOutputStream(staged)) { output.write(bytes); }
            } catch (IOException | RuntimeException failure) {
                if (staged != null) staged.delete();
                staged = null;
            }
            File result = staged;
            activity.runOnUiThread(() -> {
                preparing = false;
                if (source != page || activity.isDestroyed() || activity.isFinishing()) {
                    if (result != null) result.delete();
                } else if (result == null) message("這張圖片未能儲存，請再試一次。");
                else { file = result; pickDestination(); }
            });
        }, "WalkPrepareCard").start();
        return true;
    }

    void recover(File camera) {
        file = camera;
        recoveredPhotos.edit().putString("original", camera.getName()).apply();
        offerRecovery();
    }
    void offerRecovery() {
        if (file == null || choosing || recovery != null || activity.isFinishing()) return;
        recovery = new AlertDialog.Builder(activity).setTitle("保留剛才的照片")
                .setMessage("散步畫面已重新開啟，可以將剛拍好的照片存到手機。")
                .setPositiveButton("另存照片", (dialog, which) -> pickDestination())
                .setNegativeButton("捨棄照片", (dialog, which) -> discard())
                .setCancelable(false).create();
        recovery.setOnDismissListener(dialog -> recovery = null);
        recovery.show();
    }

    private void pickDestination() {
        boolean png = file.getName().endsWith(".png");
        Intent create = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType(png ? "image/png" : "image/jpeg")
                .putExtra(Intent.EXTRA_TITLE, png ? "散步吧透卡.png" : "散步照片.jpg");
        try { choosing = true; activity.startActivityForResult(create, REQUEST); }
        catch (ActivityNotFoundException | SecurityException unavailable) {
            choosing = false; message("這支手機沒有可用的檔案儲存工具。");
            if (png) discard(); else activity.getWindow().getDecorView().post(this::offerRecovery);
        }
    }

    void result(int code, Intent data) {
        choosing = false;
        if (file == null) return;
        Uri dest = data == null ? null : data.getData();
        if (code != Activity.RESULT_OK || dest == null || !"content".equals(dest.getScheme())
                || WalkCameraProvider.AUTHORITY.equals(dest.getAuthority())) {
            if (file.getName().endsWith(".png")) { discard(); message("已取消儲存。"); }
            else offerRecovery();
            return;
        }
        File saved = file;
        file = null;
        new Thread(() -> {
            try (FileInputStream input = new FileInputStream(saved)) {
                long expected = input.getChannel().size();
                if (expected == 0) throw new IOException("找不到要儲存的照片");
                try (OutputStream output = activity.getContentResolver().openOutputStream(dest, "wt")) {
                    if (output == null) throw new IOException("無法開啟檔案");
                    byte[] buffer = new byte[32768];
                    long copied = 0;
                    int n;
                    while ((n = input.read(buffer)) != -1) { output.write(buffer, 0, n); copied += n; }
                    if (copied != expected) throw new IOException("照片未完整寫入");
                }
            } catch (IOException | RuntimeException failed) {
                activity.runOnUiThread(() -> {
                    if (saved.getName().endsWith(".jpg")) {
                        if (!activity.isDestroyed() && !activity.isFinishing()) recover(saved);
                    } else saved.delete();
                    message("圖片未能儲存，請再試一次。");
                });
                return;
            }
            activity.runOnUiThread(() -> { remove(saved); message("圖片已儲存。"); });
        }, "WalkSavePhoto").start();
    }

    private void message(String text) {
        if (activity.isDestroyed() || activity.isFinishing()) return;
        if (source != null) source.evaluateJavascript("(()=>{const m=document.getElementById('shareMsg');if(m)m.textContent="
                + JSONObject.quote(text) + ";})()", null);
        Toast.makeText(activity, text, Toast.LENGTH_SHORT).show();
    }
    void save(Bundle state) {
        if (file != null) state.putString("exportFile", file.getName());
        state.putBoolean("exportChoosing", choosing);
    }
    void forgetPage() { source = null; token = null; }
    private void remove(File old) {
        if (old.getName().equals(recoveredPhotos.getString("original", null)))
            recoveredPhotos.edit().remove("original").apply();
        old.delete();
    }
    private void discard() { if (file != null) remove(file); file = null; }
    void close(boolean finishing) {
        forgetPage();
        if (recovery != null) recovery.dismiss();
        if (finishing && file != null && file.getName().endsWith(".png")) discard();
    }
}
