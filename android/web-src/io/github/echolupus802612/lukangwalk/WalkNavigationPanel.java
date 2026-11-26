package io.github.echolupus802612.lukangwalk;

import android.app.AlertDialog;
import android.app.Dialog;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.location.Location;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import org.json.JSONObject;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

final class WalkNavigationPanel {
    private final WalkMobileNavigation nav;
    private final WebWalkActivity host;
    private final Handler main=new Handler(Looper.getMainLooper());
    private AlertDialog settings;
    private Dialog route;
    private TextView status,distance,hint,notification;
    private Button close,retry;
    private Stage stage;
    private Location fix;
    private Double heading;
    private boolean ended,unavailable,expired;
    private boolean suggestSettings;
    private long lastMoved;
    private final Runnable expire=()->{ fix=null; heading=null; expired=true; refresh(); };

    WalkNavigationPanel(WalkMobileNavigation nav) { this.nav=nav;host=nav.host; }

    private int dp(float value) {return Math.round(value*host.getResources().getDisplayMetrics().density);}
    private LinearLayout column() {
        LinearLayout l=new LinearLayout(host); l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(dp(20),dp(14),dp(20),dp(14));return l;
    }
    private TextView text(String label,int size) {
        TextView t=new TextView(host); t.setText(label);t.setTextSize(size);return t;
    }
    private Button action(String title,Runnable use) {
        Button b=new Button(host);b.setAllCaps(false);b.setText(title);b.setOnClickListener(v->use.run());return b;
    }
    void settings(boolean startAfterSetup) {
        dismissSettings();
        JSONObject pref=nav.preferences();
        boolean saved=pref.optBoolean("hasReturnPoint");
        LinearLayout options=column();
        options.addView(text(saved?"已儲存回程地點":"尚未設定回程地點",16));
        options.addView(action(saved?"改用目前位置":"將目前位置設為回程地點",()->nav.savePoint(startAfterSetup)));
        if(suggestSettings && !WalkTrackingService.precise(host)) {
            options.addView(text("請在手機設定允許準確位置，再取得回程地點。",15));
            options.addView(action("開啟定位權限設定",nav::openDeviceSettings));
        }
        if(saved) {
            if(startAfterSetup) options.addView(action("開始回程",()->{dismissSettings();nav.askReturn();}));
            options.addView(action("清除回程地點",()->new AlertDialog.Builder(host).setTitle("清除回程地點？")
                    .setNegativeButton("取消",null).setPositiveButton("清除",(d,w)->nav.clearPoint()).show()));
        }
        Switch hidden=new Switch(host);
        hidden.setText("隱藏距離");hidden.setChecked(pref.optBoolean("hideDistance"));
        hidden.setPadding(0,dp(8),0,dp(8));hidden.setOnCheckedChangeListener((v,on)->nav.hideDistance(on));options.addView(hidden);
        options.addView(text("到站範圍",17));
        RadioGroup radii=new RadioGroup(host);
        for(int radius:new int[]{0,25,50,100}) {
            RadioButton r=new RadioButton(host);r.setId(View.generateViewId());
            r.setText(radius==0?"自動":radius+" 公尺");radii.addView(r);
            r.setChecked(radius==pref.optInt("arrivalRadius"));
            r.setOnClickListener(v->nav.setRadius(radius));
        }
        options.addView(radii);
        ScrollView scroll=new ScrollView(host);scroll.addView(options);
        settings=new AlertDialog.Builder(host).setTitle("導航設定").setView(scroll).setPositiveButton("完成",null).create();
        settings.setOnDismissListener(d->nav.cancelPoint());settings.show();
    }
    void pointSaved(boolean startAfterSetup){nav.message("已儲存回程地點");settings(startAfterSetup);}
    void permissionDenied(boolean startAfterSetup){suggestSettings=true;settings(startAfterSetup);}
    private void dismissSettings(){if(settings!=null) {settings.dismiss();settings=null;}}

    void showReturn() {
        if(route!=null && route.isShowing())return;
        dismissSettings();
        fix=null;heading=null;unavailable=false;ended=false;expired=false;
        route=new Dialog(host,android.R.style.Theme_Material_NoActionBar);
        route.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout content=column();
        int backdrop=WalkMobileActions.backdrop(host);
        content.setBackgroundColor(backdrop);content.setGravity(Gravity.CENTER_HORIZONTAL);
        if (android.os.Build.VERSION.SDK_INT>=35) {
            content.setOnApplyWindowInsetsListener((view,insets)->{
                android.graphics.Insets bars=insets.getInsets(android.view.WindowInsets.Type.systemBars()
                        | android.view.WindowInsets.Type.displayCutout());
                view.setPadding(dp(20)+bars.left,dp(14)+bars.top,dp(20)+bars.right,dp(14)+bars.bottom);
                return insets;
            });
        }
        TextView title=text("帶我回去",22);title.setGravity(Gravity.CENTER);title.setTextColor(Color.WHITE);
        content.addView(title,-1,-2);
        status=text("",24); status.setTypeface(Typeface.DEFAULT,Typeface.BOLD);status.setGravity(Gravity.CENTER);
        stage=new Stage(); distance=text("",32);distance.setGravity(Gravity.CENTER);
        distance.setOnLongClickListener(v->{nav.hideDistance(!nav.preferences().optBoolean("hideDistance"));return true;});
        hint=text("",16);hint.setGravity(Gravity.CENTER);
        notification=text("",14);notification.setGravity(Gravity.CENTER);
        for(TextView t:new TextView[]{status,distance,hint,notification})t.setTextColor(Color.rgb(251,243,230));
        content.addView(status,-1,-2);
        content.addView(stage,new LinearLayout.LayoutParams(-1,0,1));
        content.addView(distance,-1,-2);content.addView(hint,-1,-2);content.addView(notification,-1,-2);
        retry=action("重新定位",nav::retryReturn);content.addView(retry,-1,-2);
        close=action("停止回程",nav::endReturn);content.addView(close,-1,-2);
        route.setContentView(content);route.setOnCancelListener(d->nav.endReturn());
        Window w=route.getWindow();w.setStatusBarColor(backdrop);w.setNavigationBarColor(backdrop);
        w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        route.show();w.setLayout(-1,-1);notificationChanged();refresh();
    }
    void waiting(){fix=null;heading=null;ended=false;unavailable=false;expired=false;refresh();}
    void position(Location location){
        if(route==null||ended)return;
        if(location.getAccuracy()>40)return;
        if(fix!=null && fix.distanceTo(location)>4 || location.hasSpeed() && location.getSpeed()>0.6f)lastMoved=SystemClock.elapsedRealtime();
        fix=location;unavailable=false;expired=false;main.removeCallbacks(expire);main.postDelayed(expire,15000);refresh();
    }
    void heading(Double value){heading=value;refresh();}
    void failed(){fix=null;heading=null;unavailable=true;main.removeCallbacks(expire);refresh();}
    void arrived(){
        ended=true;main.removeCallbacks(expire);
        if(route!=null)route.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        refresh();
    }
    void paused(){main.removeCallbacks(expire);fix=null;heading=null;if(stage!=null)stage.animating=false;}
    void notificationChanged(){
        if(route==null) return;
        notification.setText(WalkTrackingService.canNotify(host)?"":"目前無法傳送通知。回到 App 即可查看回程狀態。");
    }
    void refresh(){
        if(route==null||!route.isShowing())return;
        boolean hidden=nav.preferences().optBoolean("hideDistance");
        JSONObject point=WalkTrackingService.read(nav.state,"point");
        boolean showsArrow= !ended && fix!=null && point!=null;
        double angle=0;
        String pose;
        if(ended){
            status.setText("已抵達回程地點");hint.setText("你已經回到儲存的位置。");pose="cheer";
        } else if(showsArrow){
            Location dest=new Location("return");dest.setLatitude(point.optDouble("latitude"));dest.setLongitude(point.optDouble("longitude"));
            double meters=fix.distanceTo(dest),bearing=(fix.bearingTo(dest)+360)%360;
            angle=((bearing-(heading==null?0:heading)+540)%360)-180;
            String[] directions={"北","東北","東","東南","南","西南","西","西北"};
            status.setText("朝"+directions[((int)Math.round(bearing/45))%8]+"方回程");
            distance.setText(hidden?"距離已隱藏": meters>=1000?String.format(Locale.TAIWAN,"距離 %.1f 公里",meters/1000):"距離 "+Math.round(meters)+" 公尺");
            hint.setText(heading==null?"上方為北，箭頭指向回程地點的方位。":"將手機朝向箭頭所指的方向。");
            pose=heading!=null&&Math.abs(angle)>120?"pull":heading!=null&&Math.abs(angle)>35?"point":SystemClock.elapsedRealtime()-lastMoved<6000?"walk":"pointup";
        } else {
            status.setText(unavailable||expired?"暫時無法定位":"正在取得位置");distance.setText(hidden?"距離已隱藏":"等待定位");
            hint.setText(unavailable||expired?"請確認準確定位已開啟，或到空曠處重新定位。":"取得位置後會顯示回程方向。");
            pose=unavailable||expired?"care":"idle";
        }
        stage.drawState(pose,angle,heading,showsArrow);
        distance.setVisibility(ended?View.GONE:View.VISIBLE);distance.setContentDescription(distance.getText()+"。長按切換距離顯示");
        retry.setVisibility(!ended && (unavailable||expired)?View.VISIBLE:View.GONE);
        close.setText(ended?"完成":"停止回程");
    }
    void dismissReturn(){main.removeCallbacks(expire);if(route!=null){route.setOnCancelListener(null);route.dismiss();route=null;}stage=null;}
    void close(){dismissSettings();dismissReturn();}

    private final class Stage extends View {
        final Map<String,Bitmap> sheets=new HashMap<>();
        final Set<String> requested=new HashSet<>();
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG|Paint.FILTER_BITMAP_FLAG);
        String pose="idle";double angle;Double north;boolean arrow,animating=true;
        long started=SystemClock.elapsedRealtime();
        Stage(){super(host);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        void drawState(String next,double angle,Double heading,boolean arrow){
            animating=true;
            if(!next.equals(pose)){pose=next;started=SystemClock.elapsedRealtime();}
            this.angle=angle;this.north=heading;this.arrow=arrow;
            if(requested.add(next)) host.walkSprite(next,b->{if(b!=null)sheets.put(next,b);invalidate();});
            invalidate();
        }
        @Override protected void onDraw(Canvas c){
            super.onDraw(c);
            float unit=Math.min(getWidth()/400f,getHeight()/330f);if(unit<=0)return;
            c.save();c.translate((getWidth()-400*unit)/2,(getHeight()-330*unit)/2);c.scale(unit,unit);
            paint.setColor(0xff543628);c.drawOval(50,244,350,309,paint);
            if(arrow){
                c.save();c.translate(200,275);c.scale(1,0.36f);c.rotate((float)angle);
                Path p=new Path();p.moveTo(0,-125);p.lineTo(43,45);p.lineTo(0,24);p.lineTo(-43,45);p.close();
                paint.setColor(0xffffcc55);c.drawPath(p,paint);c.restore();
                double rad=Math.toRadians(north==null?0:-north);
                paint.setTextAlign(Paint.Align.CENTER);paint.setTextSize(17);paint.setColor(Color.WHITE);
                c.drawText("北",(float)(200+145*Math.sin(rad)),(float)(278-35*Math.cos(rad)),paint);
            }
            Bitmap b=sheets.get(pose);
            if(b!=null){
                boolean two=pose.equals("point")||pose.equals("pointup");
                int count=two?2:4,width=b.getWidth()/count;
                int delay=two?420:pose.equals("walk")?150:pose.equals("cheer")?170:260;
                int frame=(int)((SystemClock.elapsedRealtime()-started)/delay%count);
                float h=236,w=h*width/b.getHeight();
                RectF dest=new RectF(200-w/2,278-h,200+w/2,278);
                c.save();
                if(pose.equals("point")&&angle<0 || pose.equals("pull")&&angle>0)c.scale(-1,1,200,270);
                paint.setColor(Color.WHITE);c.drawBitmap(b,new Rect(frame*width,0,(frame+1)*width,b.getHeight()),dest,paint);c.restore();
            }
            c.restore();
            if(animating && isShown()) postInvalidateDelayed(150);
        }
    }
}
