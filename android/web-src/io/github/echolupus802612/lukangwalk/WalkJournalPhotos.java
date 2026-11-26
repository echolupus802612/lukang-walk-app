package io.github.echolupus802612.lukangwalk;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Base64;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Arrays;
import java.util.Comparator;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** 先留下相片及這趟的快照，再產生透卡；系統回收畫面時仍能接續原本那一趟。 */
final class WalkJournalPhotos {
    private static final int CAMERA=41, DOCUMENT=42, EXPORT=43, CHUNK=49152;
    private static final int EDGE=2048;
    private static final ExecutorService IMAGES=Executors.newSingleThreadExecutor();
    private static final AtomicBoolean EXPORT_WRITING=new AtomicBoolean();
    private final WebWalkActivity host;
    private final WalkMobileJournal journal;
    private final File root, draft;
    private final Handler timer=new Handler(Looper.getMainLooper());
    private String rendering;
    private boolean ready, closed, decoding, choosingExport;
    private String photo;
    private final Runnable timeout=()->renderFailed("照片已保留，請重新開啟散步筆記再產生透卡。");

    WalkJournalPhotos(WebWalkActivity host,WalkJournalFiles files,WalkMobileJournal journal) {
        this.host=host;
        this.journal=journal;
        root=new File(files.root,"photos");
        draft=new File(files.root,"photo-draft");
    }

    File[] album(String trip) {
        if (!WalkJournalFiles.validId(trip)) return new File[0];
        File[] found=new File(root,trip).listFiles(f->f.isDirectory() && WalkJournalFiles.validId(f.getName())
                && new File(f,"visit.json").isFile() && new File(f,"card.png").isFile());
        if (found==null) return new File[0];
        Arrays.sort(found,Comparator.comparingLong(File::lastModified));
        return found;
    }

    private File metadata() { return new File(draft,"visit.json"); }
    private JSONObject snapshot() throws IOException, JSONException { return WalkJournalFiles.read(metadata()); }

    void choose(JSONObject entry) {
        if (closed) return;
        if (draft.exists()) {
            if (new File(draft,"photo.jpg").isFile()) {
                render();
                journal.toast("正在接續上一張透卡。");
            } else {
                new AlertDialog.Builder(host).setTitle("接續上次的照片")
                    .setMessage("可以先取回上一張照片，或放棄未完成的選取。")
                    .setPositiveButton("取回照片",(d,w)->resumeSelection()).setNeutralButton("取消",null)
                    .setNegativeButton("放棄選取",(d,w)->{ clearDraft(); choose(entry); }).show();
            }
            return;
        }
        new AlertDialog.Builder(host).setTitle("留下這趟散步的照片")
                .setItems(new String[]{"拍照","從相簿選照片"},(d,w)->launch(entry,w==0))
                .setNegativeButton("取消",null).show();
    }

    private void launch(JSONObject entry,boolean camera) {
        if (draft.exists()) return;
        File stagedCamera=null;
        try {
            String status=entry.getString("status");
            JSONObject snap=new JSONObject().put("id",entry.getString("id"))
                    .put("photoID",UUID.randomUUID().toString()).put("placeID",entry.getInt("placeID"))
                    .put("status",status).put("date",entry.optString("date")).put("isSimulated",entry.getBoolean("isSimulated"))
                    .put("name","arrived".equals(status)?entry.getString("name"):"散步途中")
                    .put("area","arrived".equals(status)?entry.optString("area"):"");
            if(entry.has("stop")) snap.put("stop",entry.getInt("stop"));
            if(entry.has("walked")) snap.put("walked",entry.getDouble("walked"));
            Intent intent;
            if(camera) {
                stagedCamera=WalkCameraProvider.create(host,false);
                Uri output=WalkCameraProvider.uri(stagedCamera);
                snap.put("camera",stagedCamera.getName());
                intent=new Intent(MediaStore.ACTION_IMAGE_CAPTURE).putExtra(MediaStore.EXTRA_OUTPUT,output)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                intent.setClipData(ClipData.newRawUri("散步照片",output));
            } else {
                intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("image/*");
            }
            WalkJournalFiles.write(metadata(),snap);
            host.startActivityForResult(intent,camera?CAMERA:DOCUMENT);
        } catch(IOException | JSONException | SecurityException | ActivityNotFoundException e) {
            if (stagedCamera!=null) stagedCamera.delete();
            clearDraft();
            journal.toast(camera?"無法開啟相機，也可以從相簿選照片。":"無法開啟照片選擇器。");
        }
    }

    boolean result(int request,int result,Intent data) {
        if (request==EXPORT) { finishExport(result,data); return true; }
        if (request!=CAMERA && request!=DOCUMENT) return false;
        if (result!=Activity.RESULT_OK) { clearDraft(); return true; }
        try {
            JSONObject snap=snapshot();
            if (request==DOCUMENT) {
                Uri uri=data==null?null:data.getData();
                if (uri==null || !"content".equals(uri.getScheme()) || WalkCameraProvider.AUTHORITY.equals(uri.getAuthority())) {
                    clearDraft();
                    journal.toast("未能取得這張照片。");
                    return true;
                }
                try { host.getContentResolver().takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION); }
                catch(SecurityException ignored) { /* 部分相簿只在這次選取時授權。 */ }
                snap.put("source",uri.toString());
            }
            snap.put("selected",true);
            WalkJournalFiles.write(metadata(),snap);
            resumeSelection();
        } catch(IOException | JSONException e) { journal.toast("尚未存入筆記，可以重新開啟筆記再試。"); }
        return true;
    }

    private void resumeSelection() {
        if (closed || decoding) return;
        try {
            JSONObject snap=snapshot();
            File camera=WalkCameraProvider.restore(host,snap.optString("camera",null));
            Uri source=camera!=null?WalkCameraProvider.uri(camera):
                    (snap.has("source")?Uri.parse(snap.getString("source")):null);
            if (source==null || (camera!=null && camera.length()==0)) {
                journal.toast("未取得照片，可以重新選取。"); return;
            }
            if(camera!=null) host.revokeUriPermission(source,Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            decoding=true;
            IMAGES.execute(()->{
                try {
                    if(!new File(draft,"photo.jpg").isFile()) {
                        Bitmap bitmap=normalized(source);
                        File partial=new File(draft,"photo.part");
                        try (FileOutputStream out=new FileOutputStream(partial)) {
                            if(!bitmap.compress(Bitmap.CompressFormat.JPEG,87,out)) throw new IOException();
                            out.getFD().sync();
                        } finally { bitmap.recycle(); }
                        Files.move(partial.toPath(),new File(draft,"photo.jpg").toPath(),StandardCopyOption.REPLACE_EXISTING);
                    }
                    releaseSource(snap);
                    host.runOnUiThread(()->{decoding=false;if(!closed) render();});
                } catch(IOException | RuntimeException e) {
                    host.runOnUiThread(()->{decoding=false;journal.toast("暫時無法讀取這張照片，可回筆記重試或重新選取。");});
                }
            });
        } catch(IOException | JSONException e) { journal.toast("暫時無法取回這張照片。"); }
    }

    private Bitmap normalized(Uri uri) throws IOException {
        BitmapFactory.Options options=new BitmapFactory.Options(); options.inJustDecodeBounds=true;
        try(InputStream in=host.getContentResolver().openInputStream(uri)){BitmapFactory.decodeStream(in,null,options);}
        int width=options.outWidth,height=options.outHeight;
        if (width<1 || height<1) throw new IOException("不支援這個影像格式");
        int sample=1;
        while (Math.max(width,height)/(double)sample > EDGE*1.5) sample*=2;
        int orientation=ExifInterface.ORIENTATION_NORMAL;
        try(InputStream in=host.getContentResolver().openInputStream(uri)) {
            if(in!=null) orientation=new ExifInterface(in).getAttributeInt(ExifInterface.TAG_ORIENTATION,1);
        } catch(IOException | IllegalArgumentException ignored) { /* 沒有方向標記時沿用圖片方向。 */ }
        options.inJustDecodeBounds=false;options.inSampleSize=sample;
        Bitmap bitmap;
        try(InputStream in=host.getContentResolver().openInputStream(uri)){bitmap=BitmapFactory.decodeStream(in,null,options);}
        if(bitmap==null)throw new IOException("影像無法解碼");
        Matrix m=new Matrix();
        switch(orientation) {
            case 2: m.setScale(-1,1); break;
            case 3: m.setRotate(180); break;
            case 4: m.setScale(1,-1); break;
            case 5: m.setRotate(90); m.postScale(-1,1); break;
            case 6: m.setRotate(90); break;
            case 7: m.setRotate(270); m.postScale(-1,1); break;
            case 8: m.setRotate(270); break;
            default: break;
        }
        float scale=Math.min(1f,(float)EDGE/Math.max(bitmap.getWidth(),bitmap.getHeight()));
        m.postScale(scale,scale);
        Bitmap target=Bitmap.createBitmap(bitmap,0,0,bitmap.getWidth(),bitmap.getHeight(),m,true);
        if(target!=bitmap)bitmap.recycle();
        return target;
    }

    private void releaseSource(JSONObject snap) {
        if (snap.has("source")) {
            try { host.getContentResolver().releasePersistableUriPermission(Uri.parse(snap.optString("source")),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION); } catch(SecurityException ignored) { }
        }
        File camera=WalkCameraProvider.restore(host,snap.optString("camera",null));
        if(camera!=null) {
            host.revokeUriPermission(WalkCameraProvider.uri(camera),Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            camera.delete();
        }
    }

    void pageReady() {
        ready=true;
        if (exportReceipt().isFile() && !EXPORT_WRITING.get()) {
            try {
                JSONObject pending=WalkJournalFiles.read(exportReceipt());
                if (pending.has("destination")) writeExport(pending);
            } catch (IOException | JSONException ignored) { /* 開啟另存功能時可取消未完成的選取。 */ }
        }
        resetRender();
        if (new File(draft,"photo.jpg").isFile()) render();
        else if (metadata().isFile()) {
            try { if (snapshot().optBoolean("selected")) resumeSelection(); }
            catch (IOException | JSONException ignored) { }
        }
    }

    private void render() {
        if(closed || !ready || rendering!=null || !new File(draft,"photo.jpg").isFile()) return;
        String token=UUID.randomUUID().toString();
        rendering=token;
        timer.postDelayed(timeout,90000);
        IMAGES.execute(()->{
            try {
                String base64=Base64.encodeToString(Files.readAllBytes(new File(draft,"photo.jpg").toPath()),Base64.NO_WRAP);
                JSONObject snap=snapshot();
                host.runOnUiThread(()->{
                    if (!current(token)) return;
                    photo=base64;
                    host.journalScript("window.__walkPhoto={key:"+JSONObject.quote(token)+",input:'',out:''};true",result->{
                        if ("true".equals(result)) sendChunk(token,0,snap);
                        else if(current(token)) renderFailed("散步畫面尚未準備好，照片已保留。");
                    });
                });
            } catch(IOException | JSONException e) { host.runOnUiThread(()->{if(current(token)) renderFailed("照片尚未存好，請再試一次。");}); }
        });
    }

    private boolean current(String token) { return !closed && token!=null && token.equals(rendering); }
    private void sendChunk(String token,int offset,JSONObject snap) {
        if (!current(token)) return;
        if (offset<photo.length()) {
            int next=Math.min(offset+CHUNK,photo.length());
            String script="(()=>{let s=window.__walkPhoto;if(s?.key!=="+JSONObject.quote(token)+")return false;s.input+="
                    +JSONObject.quote(photo.substring(offset,next))+";return true;})()";
            host.journalScript(script,result->{
                if ("true".equals(result)) sendChunk(token,next,snap);
                else if(current(token)) renderFailed("照片已保留，請重新開啟筆記再試。");
            });
        } else {
            photo=null;
            String script="(async()=>{let s=window.__walkPhoto;if(s?.key!=="+JSONObject.quote(token)+")return;"
                    +"try{s.out=await window.lukangRenderJournalCard(s.input,"+snap+");}catch(e){s.out='';}s.input='';"
                    +"if(s===window.__walkPhoto)window.webkit.messageHandlers.lukangWalk.postMessage("
                    +"{action:'journalCard',token:s.key,length:s.out.length});})()";
            host.journalScript(script,null);
        }
    }

    void cardMessage(JSONObject msg) {
        String token=msg.optString("token");
        if (!current(token))return;
        int length=msg.optInt("length");
        if(length<=0 || length>32*1024*1024 || length%4!=0){renderFailed("透卡還沒製作完成。照片已保留，可以再試一次。");return;}
        File partial=new File(draft,"card.part");
        try {
            Files.deleteIfExists(partial.toPath());
            receiveChunk(token,0,length,partial);
        } catch(IOException e) { renderFailed("暫時無法儲存透卡。"); }
    }

    private void receiveChunk(String token,int offset,int length,File partial) {
        if (!current(token))return;
        int next=Math.min(offset+CHUNK,length);
        String script="(()=>{let s=window.__walkPhoto;return s?.key==="+JSONObject.quote(token)
                +"?s.out.slice("+offset+","+next+"):null})()";
        host.journalScript(script,result->{
            if (!current(token)) return;
            try {
                Object value=new JSONTokener(result==null?"null":result).nextValue();
                if(!(value instanceof String) || ((String)value).length()!=next-offset) throw new IOException();
                try(FileOutputStream out=new FileOutputStream(partial,true)) {
                    out.write(Base64.decode((String)value,Base64.NO_WRAP));
                    if (next==length) out.getFD().sync();
                }
                if(next<length){receiveChunk(token,next,length,partial);return;}
                finishCard(partial);
            } catch(IOException | JSONException | IllegalArgumentException e){renderFailed("透卡未能儲存，原始照片已保留。");}
        });
    }

    private void finishCard(File partial) throws IOException, JSONException {
        BitmapFactory.Options size=new BitmapFactory.Options();size.inJustDecodeBounds=true;
        BitmapFactory.decodeFile(partial.getPath(),size);
        if(!"image/png".equals(size.outMimeType) || size.outWidth<1 || size.outHeight<1) throw new IOException();
        JSONObject snap=snapshot();
        String trip=snap.getString("id"),id=snap.getString("photoID");
        if(!WalkJournalFiles.validId(trip) || !WalkJournalFiles.validId(id)) throw new IOException();
        File tripDir=new File(root,trip);
        WalkJournalFiles.ensure(tripDir);
        File album=new File(tripDir,id);
        snap.remove("camera"); snap.remove("source"); snap.remove("selected");
        WalkJournalFiles.write(metadata(),snap);
        Files.move(partial.toPath(),new File(draft,"card.png").toPath(),StandardCopyOption.REPLACE_EXISTING);
        Files.move(draft.toPath(),album.toPath(),StandardCopyOption.ATOMIC_MOVE);
        host.journalScript("delete window.__walkPhoto",null);
        resetRender();
        journal.photo(album);
    }

    void share(File album,JSONObject info,boolean card) {
        try {
            File copy=WalkCameraProvider.create(host,card);
            Files.copy(new File(album,card?"card.png":"photo.jpg").toPath(),copy.toPath(),StandardCopyOption.REPLACE_EXISTING);
            Uri uri=WalkCameraProvider.uri(copy);
            String caption;
            if(!"arrived".equals(info.optString("status")))
                caption=info.optBoolean("isSimulated")?"和小嚮導模擬散步中！#散步吧":"和小嚮導散步中！#散步吧";
            else caption=(info.optBoolean("isSimulated")?"模擬散步和小嚮導走到了":"跟著小嚮導走到了")+info.optString("name")+"！#散步吧";
            Intent send=new Intent(Intent.ACTION_SEND).setType(card?"image/png":"image/jpeg")
                    .putExtra(Intent.EXTRA_STREAM,uri).putExtra(Intent.EXTRA_TEXT,caption)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            send.setClipData(ClipData.newRawUri("散步照片",uri));
            host.startActivity(Intent.createChooser(send,"分享散步照片"));
        } catch(IOException | ActivityNotFoundException e){journal.toast("暫時無法分享照片。");}
    }

    private File exportReceipt() { return new File(root.getParentFile(),"photo-export.json"); }

    void export(File album,JSONObject info,boolean card) {
        if (choosingExport || EXPORT_WRITING.get()) { journal.toast("上一張圖片還在儲存中。"); return; }
        File pending=exportReceipt();
        if (pending.isFile()) {
            new AlertDialog.Builder(host).setTitle("上一次另存尚未完成")
                    .setPositiveButton("繼續另存",(d,w)->{
                        try {
                            JSONObject state=WalkJournalFiles.read(pending);
                            if(state.has("destination")) writeExport(state); else chooseDestination(state);
                        } catch(IOException | JSONException e){journal.toast("請取消上一次另存，再重新選取。");}
                    }).setNegativeButton("取消上次另存",(d,w)->{
                        if (!EXPORT_WRITING.get()) pending.delete();
                    }).show();
            return;
        }
        try {
            String trip=info.getString("id");
            if (!WalkJournalFiles.validId(trip) || !WalkJournalFiles.validId(album.getName())) return;
            JSONObject state=new JSONObject().put("trip",trip).put("photo",album.getName()).put("card",card)
                    .put("date",info.optString("date"));
            WalkJournalFiles.write(pending,state);
            chooseDestination(state);
        } catch (IOException | JSONException e) { journal.toast("無法準備這次另存圖片。"); }
    }

    private void chooseDestination(JSONObject state) {
        boolean card=state.optBoolean("card");
        Intent save=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType(card?"image/png":"image/jpeg").putExtra(Intent.EXTRA_TITLE,
                        (card?"散步吧透卡-":"散步吧照片-")+state.optString("date")+(card?".png":".jpg"));
        try {
            choosingExport=true;
            host.startActivityForResult(save,EXPORT);
        } catch(ActivityNotFoundException e) {
            choosingExport=false; exportReceipt().delete(); journal.toast("無法開啟儲存位置。");
        }
    }

    private void finishExport(int result,Intent data) {
        choosingExport=false;
        if (EXPORT_WRITING.get()) return;
        File pending=exportReceipt();
        if (result!=Activity.RESULT_OK) { pending.delete(); journal.toast("已取消儲存。"); return; }
        Uri dest=data==null?null:data.getData();
        if (dest==null || !"content".equals(dest.getScheme()) || WalkCameraProvider.AUTHORITY.equals(dest.getAuthority())) {
            pending.delete(); journal.toast("無法寫入所選的位置。"); return;
        }
        try {
            JSONObject state=WalkJournalFiles.read(pending);
            try {
                host.getContentResolver().takePersistableUriPermission(dest,Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            } catch(SecurityException ignored) { /* 有些文件服務只在這次操作期間授權。 */ }
            state.put("destination",dest.toString());
            WalkJournalFiles.write(pending,state);
            writeExport(state);
        } catch(IOException | JSONException e){ journal.toast("找不到要儲存的影像，請重新選取。"); }
    }

    // 確認整份來源及影像結尾，再以截斷模式寫入使用者選擇的檔案。
    private byte[] exportBytes(JSONObject state) throws IOException, JSONException {
        String trip=state.getString("trip"),photoId=state.getString("photo");
        if (!WalkJournalFiles.validId(trip) || !WalkJournalFiles.validId(photoId)) throw new IOException();
        boolean card=state.getBoolean("card");
        File album=new File(new File(root,trip),photoId);
        File source=new File(album,card?"card.png":"photo.jpg");
        byte[] bytes;
        try(FileInputStream input=new FileInputStream(source)) {
            long length=input.getChannel().size();
            if(length<12 || length>24*1024*1024) throw new IOException();
            bytes=new byte[(int)length];
            new java.io.DataInputStream(input).readFully(bytes);
            if (input.read()!=-1) throw new IOException();
        }
        int n=bytes.length;
        if(card) {
            byte[] end={0,0,0,0,'I','E','N','D',(byte)0xae,0x42,0x60,(byte)0x82};
            for(int i=0;i<end.length;i++) if(bytes[n-end.length+i]!=end[i]) throw new IOException();
        } else if ((bytes[n-2]&255)!=255 || (bytes[n-1]&255)!=217) throw new IOException();
        BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;
        BitmapFactory.decodeByteArray(bytes,0,n,bounds);
        if(!(card?"image/png":"image/jpeg").equals(bounds.outMimeType) || bounds.outWidth<=0 || bounds.outHeight<=0)
            throw new IOException();
        return bytes;
    }

    private void writeExport(JSONObject state) {
        if (!EXPORT_WRITING.compareAndSet(false,true)) return;
        Uri dest=Uri.parse(state.optString("destination"));
        IMAGES.execute(()->{
            boolean success=false;
            try {
                if(!"content".equals(dest.getScheme()) || WalkCameraProvider.AUTHORITY.equals(dest.getAuthority())) throw new IOException();
                byte[] complete=exportBytes(state);
                try(OutputStream stream=host.getContentResolver().openOutputStream(dest,"wt")) {
                    if(stream==null) throw new IOException();
                    stream.write(complete);
                }
                success=true;
            } catch(IOException | JSONException | SecurityException ignored) {
                // 留下日誌原檔，讓使用者可重新另存到其他位置。
            } finally {
                try { host.getContentResolver().releasePersistableUriPermission(dest,Intent.FLAG_GRANT_WRITE_URI_PERMISSION); }
                catch(SecurityException ignored) { }
                exportReceipt().delete();
                EXPORT_WRITING.set(false);
            }
            String words=success?"圖片已儲存。":"圖片未能儲存，請從筆記重新選取。";
            host.runOnUiThread(()->journal.toast(words));
        });
    }

    private void renderFailed(String message) { resetRender(); journal.toast(message); }
    private void resetRender() { timer.removeCallbacks(timeout); rendering=null; photo=null; }
    private void clearDraft() {
        if(decoding || rendering!=null)return;
        try { if(metadata().isFile())releaseSource(snapshot()); } catch(IOException | JSONException ignored) { }
        File[] contents=draft.listFiles();
        if(contents!=null) for(File file:contents) file.delete();
        draft.delete();
    }
    void close() { closed=true;resetRender(); }
}
