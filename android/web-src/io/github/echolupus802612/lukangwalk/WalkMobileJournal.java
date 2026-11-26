package io.github.echolupus802612.lukangwalk;

import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

final class WalkMobileJournal {
    private final WebWalkActivity host;
    private final WalkJournalFiles files;
    private final WalkJournalPhotos photos;
    private AlertDialog window;
    private boolean closed;

    WalkMobileJournal(WebWalkActivity host) {
        this.host = host;
        files = new WalkJournalFiles(host);
        photos = new WalkJournalPhotos(host,files,this);
    }

    private void problem() {
        JSONObject message = new JSONObject();
        try { message.put("type","storeError"); } catch (JSONException ignored) { }
        host.emitWalk(message);
    }

    boolean begin(JSONObject target) {
        try { files.begin(target); return true; }
        catch (JSONException | IOException e) { problem(); return false; }
    }

    boolean arrive(JSONObject target,String date,int stop,Double walked) {
        try {
            JSONObject row = files.begin(target);
            files.finish(row.getString("id"),"arrived",date,target.optLong("endedAt",System.currentTimeMillis()),stop,walked);
            return true;
        } catch (JSONException | IOException e) { problem(); return false; }
    }

    boolean finish(String id,String status,Integer stop,Double walked) {
        try { files.finish(id,status,null,System.currentTimeMillis(),stop,walked); return true; }
        catch (JSONException | IOException e) { problem(); return false; }
    }

    boolean isWalking(String id) {
        try { JSONObject row = files.entry(id); return row != null && "walking".equals(row.optString("status")); }
        catch (IOException | JSONException e) { return false; }
    }

    boolean hasActive() {
        try {
            for (JSONObject row : files.all()) if ("walking".equals(row.optString("status"))) return true;
        } catch (IOException e) { problem(); }
        return false;
    }

    boolean stopActive() {
        try {
            for (JSONObject row : files.all()) {
                if ("walking".equals(row.optString("status")) && !finish(row.getString("id"),"stopped",null,null)) return false;
            }
            return true;
        } catch (JSONException | IOException e) { problem(); return false; }
    }

    void recover(String keep) {
        try { files.recover(keep); } catch (IOException e) { problem(); }
    }

    JSONObject arrivedPlace(String id,int placeID) {
        try {
            JSONObject row = files.entry(id);
            return row != null && "arrived".equals(row.optString("status")) && !row.getBoolean("isSimulated")
                    && row.getInt("placeID")==placeID ? row : null;
        } catch (IOException | JSONException e) { return null; }
    }

    void pageReady() {
        photos.pageReady();
        if (files.migrated()) return;
        String migration = "(()=>{const s=window.lukangInitialStore||{};const a=s.seen||[],b=s.sim_seen||[];"
                +"return {real:a,sim:b,places:window.lukangJournalPlaces([...a,...b])};})()";
        host.journalScript(migration,value -> {
            if (closed || value==null || value.equals("null")) return;
            try {
                JSONObject data = new JSONObject(value);
                files.migrate(data.getJSONArray("real"),data.getJSONArray("sim"),data.getJSONArray("places"));
            } catch (JSONException | IOException e) { problem(); }
        });
    }

    boolean handle(String action,JSONObject msg) {
        switch (action) {
            case "journalBegin":
                if (msg.optBoolean("isSimulated")) begin(msg);
                return true;
            case "journalFinish":
                try {
                    String id = msg.getString("id"), status = msg.getString("status");
                    JSONObject row = files.entry(id);
                    if (row!=null && ("stopped".equals(status) || "interrupted".equals(status)
                            || ("arrived".equals(status) && row.getBoolean("isSimulated")))) {
                        finish(id,status,msg.isNull("stop")?null:msg.getInt("stop"),
                                msg.isNull("walked")?null:msg.getDouble("walked"));
                    }
                } catch (JSONException | IOException e) { problem(); }
                return true;
            case "journal": case "photoAlbum":
                if (WalkJournalFiles.validId(msg.optString("id"))) detail(msg.optString("id"));
                else list();
                return true;
            case "walkPhoto":
                JSONObject visit = msg.optJSONObject("visit");
                if (visit!=null) {
                    try {
                        JSONObject row=files.entry(visit.optString("id"));
                        if (row!=null && "arrived".equals(row.optString("status")) && row.optInt("placeID")==visit.optInt("placeID")
                                && row.optBoolean("isSimulated")==visit.optBoolean("isSimulated")) photos.choose(row);
                    } catch (JSONException | IOException e) { problem(); }
                }
                return true;
            case "journalCard": photos.cardMessage(msg); return true;
            default: return false;
        }
    }

    boolean onActivityResult(int request,int result,Intent data) { return photos.result(request,result,data); }
    void close() {
        closed=true;
        photos.close();
        if (window!=null) window.dismiss();
    }

    private int dp(int n) { return Math.round(host.getResources().getDisplayMetrics().density*n); }
    private LinearLayout panel() {
        LinearLayout content = new LinearLayout(host);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(18),dp(4),dp(18),dp(2));
        return content;
    }

    private void show(AlertDialog dialog) {
        if (closed || host.isFinishing() || host.isDestroyed()) return;
        if (window!=null) window.dismiss();
        window=dialog;
        dialog.show();
    }

    private Button action(LinearLayout content,String name,Runnable click) {
        Button button = new Button(host);
        button.setText(name);
        button.setAllCaps(false);
        button.setOnClickListener(view -> click.run());
        content.addView(button);
        return button;
    }

    private void text(LinearLayout content,String value) {
        TextView label = new TextView(host);
        label.setPadding(0,dp(5),0,dp(5));
        label.setTextSize(16);
        label.setText(value);
        content.addView(label);
    }

    private static String mode(JSONObject row) { return row.optBoolean("isSimulated") ? "模擬散步" : "實地散步"; }
    private static String status(JSONObject row) {
        switch (row.optString("status")) {
            case "walking": return "散步中";
            case "arrived": return "已到站";
            case "stopped": return "已收工";
            case "interrupted": return "途中中斷";
            default: return "舊版已到訪";
        }
    }

    private void list() {
        List<JSONObject> rows;
        try { rows=files.all(); }
        catch(IOException e) { toast("暫時無法讀取散步筆記，請再試一次。"); return; }
        LinearLayout box=panel();
        EditText search = new EditText(host);
        search.setSingleLine(true);
        search.setHint("搜尋地名或筆記");
        box.addView(search);
        CheckBox favorites=new CheckBox(host);
        favorites.setText("只看收藏");
        box.addView(favorites);
        ListView list = new ListView(host);
        list.setMinimumHeight(dp(200));
        TextView empty = new TextView(host);
        box.addView(empty);
        box.addView(list,new LinearLayout.LayoutParams(-1,0,1));
        List<JSONObject> shown=new ArrayList<>();
        ArrayAdapter<String> adapter=new ArrayAdapter<>(host,android.R.layout.simple_list_item_1);
        list.setAdapter(adapter);
        Runnable filter = () -> {
            String query = search.getText().toString().trim().toLowerCase(Locale.TAIWAN);
            adapter.clear(); shown.clear();
            for (JSONObject row : rows) {
                boolean fav=row.optBoolean("favorite");
                if (favorites.isChecked() && !fav) continue;
                String title=WalkJournalFiles.title(row), note=row.optString("note");
                if (!(title+"\n"+note).toLowerCase(Locale.TAIWAN).contains(query)) continue;
                shown.add(row);
                String date=row.optString("date");
                adapter.add((fav?"♥ ":"")+title+"\n"+mode(row)+" · "+status(row)+(date.isEmpty()?"":" · "+date)
                        +(note.isEmpty()?"":"\n"+(note.length()>100?note.substring(0,100)+"…":note)));
            }
            empty.setText(rows.isEmpty()?"還沒有散步筆記。出發後就會記下這一趟。":"沒有符合的散步筆記。");
            empty.setVisibility(shown.isEmpty()?View.VISIBLE:View.GONE);
        };
        search.addTextChangedListener(new TextWatcher(){
            public void afterTextChanged(Editable s){filter.run();}
            public void onTextChanged(CharSequence s,int start,int before,int count){}
            public void beforeTextChanged(CharSequence s,int start,int count,int after){}
        });
        favorites.setOnCheckedChangeListener((button,checked)->filter.run());
        list.setOnItemClickListener((parent,item,pos,id)->detail(shown.get(pos).optString("id")));
        filter.run();
        box.setFocusableInTouchMode(true); box.requestFocus();
        show(new AlertDialog.Builder(host).setTitle("散步筆記").setView(box).setPositiveButton("完成",null).create());
    }

    void detail(String id) {
        JSONObject row;
        try { row=files.entry(id); }
        catch (IOException | JSONException e) { row=null; }
        if (row==null) { toast("暫時無法讀取這一趟散步。"); return; }
        final JSONObject item=row;
        LinearLayout box=panel();
        text(box,mode(item)+" · "+status(item));
        if (item.has("startedAt")) text(box,"出發時間　"+time(item.optLong("startedAt")));
        if (item.has("endedAt")) text(box,"結束時間　"+time(item.optLong("endedAt")));
        if (item.has("walked")) text(box,"走了 "+Math.round(item.optDouble("walked"))+" 公尺");
        String note=item.optString("note");
        if (!note.isEmpty()) text(box,note);
        action(box,note.isEmpty()?"寫筆記":"編輯筆記",()->edit(item));
        CheckBox favorite=new CheckBox(host);
        favorite.setText("收藏這趟散步");
        favorite.setChecked(item.optBoolean("favorite"));
        favorite.setOnCheckedChangeListener((b,checked)->{
            try { files.edit(id,null,checked); }
            catch (IOException | JSONException e) { toast("收藏還沒存好，請再試一次。"); detail(id); }
        });
        box.addView(favorite);
        if (WalkJournalFiles.revealed(item) && !item.optBoolean("isSimulated") && item.has("latitude") && item.has("longitude"))
            action(box,"在地圖查看地點",()->map(item));
        for (File album : photos.album(id)) {
            try {
                JSONObject saved=WalkJournalFiles.read(new File(album,"visit.json"));
                action(box,saved.optString("name")+" · 相片",()->photo(album));
            } catch (IOException | JSONException ignored) { /* 其他相片仍可開啟。 */ }
        }
        if (!"legacy".equals(item.optString("status"))) action(box,"拍照或從相簿選照片",()->photos.choose(item));
        ScrollView scroll=new ScrollView(host); scroll.addView(box);
        AlertDialog dialog=new AlertDialog.Builder(host).setTitle(WalkJournalFiles.title(item)).setView(scroll)
                .setNeutralButton("散步筆記",(d,w)->list()).setPositiveButton("完成",null).create();
        show(dialog);
    }

    private String time(long value) {
        return new java.text.SimpleDateFormat("yyyy 年 M 月 d 日 HH:mm",Locale.TAIWAN).format(new Date(value));
    }
    private void edit(JSONObject row) {
        String id=row.optString("id");
        EditText edit=new EditText(host);
        edit.setHint("記下這趟散步");
        edit.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        edit.setMinLines(3);
        edit.setText(row.optString("note"));
        AlertDialog dialog = new AlertDialog.Builder(host).setTitle("編輯筆記").setView(edit)
                .setNegativeButton("取消",(d,w)->detail(id)).setPositiveButton("儲存",null).create();
        show(dialog);
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            try { files.edit(id,edit.getText().toString(),null); detail(id); }
            catch(IOException | JSONException e){ toast("筆記還沒存好，可以再試一次。"); }
        });
    }

    private void map(JSONObject item) {
        String point=item.optDouble("latitude")+","+item.optDouble("longitude");
        Uri geo=Uri.parse("geo:"+point+"?q="+Uri.encode(point+"("+item.optString("name")+")"));
        try { host.startActivity(new Intent(Intent.ACTION_VIEW,geo)); }
        catch (ActivityNotFoundException unavailable) {
            try { host.startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse("https://www.openstreetmap.org/?mlat="
                    +item.optDouble("latitude")+"&mlon="+item.optDouble("longitude")))); }
            catch (ActivityNotFoundException e) { toast("這支手機沒有可以開啟地圖的應用程式。"); }
        }
    }

    void photo(File album) {
        try {
            JSONObject info=WalkJournalFiles.read(new File(album,"visit.json"));
            LinearLayout box=panel();
            ImageView image=new ImageView(host);
            image.setAdjustViewBounds(true);
            image.setScaleType(ImageView.ScaleType.FIT_CENTER);
            box.addView(image,new LinearLayout.LayoutParams(-1,host.getResources().getDisplayMetrics().heightPixels/2));
            boolean[] card={true};
            Button toggle=new Button(host);
            box.addView(toggle);
            Runnable refresh=()->{
                image.setImageBitmap(BitmapFactory.decodeFile(new File(album,card[0]?"card.png":"photo.jpg").getPath()));
                image.setContentDescription(card[0]?"小嚮導透卡":"原始照片");
                toggle.setText(card[0]?"查看原始照片":"查看透卡");
            };
            toggle.setOnClickListener(v->{card[0]=!card[0];refresh.run();});
            refresh.run();
            LinearLayout actions=new LinearLayout(host);
            box.addView(actions);
            action(actions,"分享",()->photos.share(album,info,card[0]))
                    .setLayoutParams(new LinearLayout.LayoutParams(0,-2,1));
            action(actions,"另存圖片",()->photos.export(album,info,card[0]))
                    .setLayoutParams(new LinearLayout.LayoutParams(0,-2,1));
            ScrollView scroll=new ScrollView(host); scroll.addView(box);
            show(new AlertDialog.Builder(host).setTitle(info.optString("name")).setView(scroll)
                    .setNeutralButton("返回筆記",(d,w)->detail(info.optString("id"))).setPositiveButton("完成",null).create());
        } catch(IOException | JSONException e){ toast("暫時無法開啟這張照片。"); }
    }

    void toast(String words) { if (!closed) Toast.makeText(host,words,Toast.LENGTH_LONG).show(); }
}
