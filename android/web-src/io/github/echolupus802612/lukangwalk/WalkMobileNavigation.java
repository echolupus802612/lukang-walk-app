package io.github.echolupus802612.lukangwalk;

import android.Manifest;
import android.app.AlertDialog;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.hardware.GeomagneticField;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.WindowManager;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.UUID;

import static io.github.echolupus802612.lukangwalk.WalkTrackingService.fields;
import static io.github.echolupus802612.lukangwalk.WalkTrackingService.read;

final class WalkMobileNavigation implements SensorEventListener {
    private static final int LOCATION = 700, NOTIFICATIONS = 701;
    private static WalkMobileNavigation current;
    final WebWalkActivity host;
    final SharedPreferences state;
    private final SensorManager sensors;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final WalkNavigationPanel panel;
    private Runnable permissionSuccess, permissionDenied;
    private LocationListener savingPoint;
    private boolean foreground, ready, journalRecovered, awake, listeningHeading, confirmingReturn;
    private final float[] rotation=new float[9], angles=new float[3];
    private float declination;
    private long lastHeading;
    private String lastShown;
    private boolean replayAfterReturn;
    private final Runnable pointTimeout = () -> { cancelPoint(); message("暫時無法取得準確位置，請到空曠處再試一次。"); };

    WalkMobileNavigation(WebWalkActivity host) {
        this.host=host;
        state=WalkTrackingService.state(host);
        // 手機重新開機後，先前的定位服務與單調時鐘已結束。已到站回條仍待畫面確認。
        int boot=android.provider.Settings.Global.getInt(host.getContentResolver(),android.provider.Settings.Global.BOOT_COUNT,-1);
        if(boot>=0 && state.getInt("bootCount",-1)!=boot) {
            SharedPreferences.Editor editor=state.edit().putInt("bootCount",boot);
            if(state.contains("bootCount")) editor.remove("active").remove("radiusChangedAt");
            editor.commit();
        }
        sensors=host.getSystemService(SensorManager.class);
        panel=new WalkNavigationPanel(this);
    }

    JSONObject preferences() {
        return fields("hideDistance",state.getBoolean("hideDistance",false),"arrivalRadius",state.getInt("radius",0),
                "hasReturnPoint",read(state,"point")!=null);
    }

    private void preferencesChanged() {
        JSONObject p=preferences();
        try { p.put("type","navigationPreferences"); } catch (JSONException ignored) { return; }
        event(p);
    }

    boolean handle(String action, JSONObject msg) {
        int session=msg.optInt("session");
        switch(action) {
            case "ready":
                ready=true;
                if (!journalRecovered) {
                    JSONObject keep=read(state,"pending");
                    if (keep==null) keep=read(state,"active");
                    host.walkJournal().recover(keep==null ? null : keep.optString("id",null));
                    journalRecovered=true;
                }
                preferencesChanged(); restore(); return true;
            case "start":
                if (returning() || read(state,"pending")!=null) { restore(); return true; }
                if (session>0) requestStart(session);
                return true;
            case "target":
                JSONObject active=read(state,"active");
                if (active!=null && !active.optBoolean("returning") && active.optInt("session")==session
                        && msg.optInt("placeID")>0 && coord(msg) && !msg.optString("name").isEmpty()
                        && uuid(msg.optString("id"))) {
                    if (!host.walkJournal().begin(msg)) { storageError(); return true; }
                    boolean oldBackground=active.optString("id").equals(msg.optString("id")) && active.optBoolean("distanceIncomplete");
                    try {
                        JSONObject route=new JSONObject(msg.toString());
                        route.put("selectedAt",SystemClock.elapsedRealtime());
                        route.put("distanceIncomplete",oldBackground);
                        if (!save("active",route)) return true;
                    } catch(JSONException ignored) { return true; }
                    requestNotifications(session);
                }
                return true;
            case "stop":
                JSONObject leg=read(state,"active");
                if (leg!=null && !leg.optBoolean("returning") && leg.optInt("session")==session) stopTracking();
                return true;
            case "arrivalShown":
                acknowledge(msg); return true;
            case "returnNavigation":
                if (!returning()) askReturn();
                return true;
            case "navigationSettings":
                panel.settings(false); return true;
            case "setHideDistance":
                hideDistance(msg.optBoolean("hidden")); return true;
            case "awake":
                if (!returning()) setAwake(msg.optBoolean("enabled"));
                return true;
            default: return false;
        }
    }

    private static boolean uuid(String text) {
        try {return UUID.fromString(text).toString().equalsIgnoreCase(text);} catch (IllegalArgumentException e){return false;}
    }

    static boolean coord(JSONObject value) {
        return Math.abs(value.optDouble("latitude"))<=90 && Math.abs(value.optDouble("longitude"))<=180;
    }

    private boolean save(String key,JSONObject obj) {
        if (state.edit().putString(key,obj.toString()).commit()) return true;
        storageError(); return false;
    }

    private void requestStart(int session) {
        JSONObject old=read(state,"active");
        if (old!=null && old.optInt("session")==session) { restartService(); return; }
        JSONObject route=fields("session",session);
        if (!save("active",route)) return;
        requireLocation(()->{
            JSONObject active=read(state,"active");
            if (active!=null && active.optInt("session")==session) restartService();
        },()->{
            JSONObject active=read(state,"active");
            if (active==null || active.optInt("session")!=session) return;
            stopTracking();
            event(fields("type","error","session",session,"reason",locationReason()));
        });
    }

    private String locationReason() {
        return host.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)==PackageManager.PERMISSION_GRANTED ? "approximate":"denied";
    }

    private void requireLocation(Runnable success, Runnable denied) {
        if (WalkTrackingService.precise(host)) { success.run(); return; }
        if (permissionSuccess!=null || !foreground) { denied.run(); return; }
        permissionSuccess=success; permissionDenied=denied;
        host.requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION,Manifest.permission.ACCESS_COARSE_LOCATION},LOCATION);
    }

    void onRequestPermissionsResult(int code) {
        if (code==LOCATION) {
            Runnable next=WalkTrackingService.precise(host)?permissionSuccess:permissionDenied;
            permissionSuccess=null; permissionDenied=null;
            if (next!=null) next.run();
        } else if (code==NOTIFICATIONS) {
            JSONObject leg=read(state,"active");
            if (leg!=null && !WalkTrackingService.canNotify(host))
                event(fields("type","notificationUnavailable","session",leg.optInt("session")));
            panel.notificationChanged();
        }
    }

    private void requestNotifications(int session) {
        if (Build.VERSION.SDK_INT>=33 && host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED
                && !state.getBoolean("notificationAsked",false) && foreground) {
            state.edit().putBoolean("notificationAsked",true).apply();
            host.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},NOTIFICATIONS);
        } else if (!WalkTrackingService.canNotify(host))
            event(fields("type","notificationUnavailable","session",session));
    }

    private void restartService() {
        if (!foreground) return;
        try {
            host.startForegroundService(new Intent(host,WalkTrackingService.class));
            monitorHeading();
        } catch (SecurityException | IllegalStateException failure) {
            JSONObject route=read(state,"active");
            if (route==null) return;
            stopTracking();
            if (route.optBoolean("returning")) {
                state.edit().putString("returnError","unavailable").apply();
                panel.failed();
            } else event(fields("type","error","session",route.optInt("session"),"reason","unavailable"));
        }
    }

    private void stopTracking() {
        state.edit().remove("active").commit();
        host.stopService(new Intent(host,WalkTrackingService.class));
        monitorHeading();
        setAwake(false);
    }

    void setAwake(boolean enabled) {
        awake=enabled;
        if (enabled && foreground) host.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else host.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    void onResume() {
        foreground=true; current=this; setAwake(awake);
        JSONObject leg=read(state,"active");
        if (leg!=null && leg.has("latitude") && WalkTrackingService.precise(host)) {
            event(fields("type","pause","session",leg.optInt("session")));
            restartService();
        }
        monitorHeading(); restore();
    }

    void onPause() {
        foreground=false; if(current==this) current=null;
        host.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        JSONObject leg=read(state,"active");
        if (leg!=null && leg.has("id")) {
            try { leg.put("distanceIncomplete",true); save("active",leg); } catch(JSONException ignored) { }
        } else if (leg!=null && !leg.has("latitude") && permissionSuccess==null) {
            state.edit().remove("active").commit();
            host.stopService(new Intent(host,WalkTrackingService.class));
            state.edit().putString("error",fields("type","error","reason","unavailable","session",leg.optInt("session")).toString()).apply();
        }
        cancelPoint(); monitorHeading(); panel.paused();
    }

    void close() {
        foreground=false; ready=false; if(current==this) current=null;
        cancelPoint(); monitorHeading(); panel.close();
    }

    static boolean visible() { return current!=null && current.foreground; }
    static void storageError() { if (visible()) current.event(fields("type","storeError")); }
    static void changed() { if (visible()) {current.monitorHeading(); current.restore();} }
    static void position(JSONObject route, Location fix) { if(visible()) current.onPosition(route,fix); }

    private void event(JSONObject event) {
        if (ready && foreground) host.emitWalk(event);
    }

    private void restore() {
        if (!ready || !foreground || host.isFinishing() || host.isDestroyed()) return;
        JSONObject leg=read(state,"active");
        if (returning()) {
            panel.showReturn();
            if (read(state,"returnReceipt")!=null) { panel.arrived(); setAwake(false); }
            else if (state.contains("returnError")) panel.failed();
            return;
        }
        JSONObject pending=read(state,"pending");
        if (pending!=null) {
            setAwake(false);
            JSONObject values=host.recordWalkArrival(pending.optInt("placeID"));
            if (values==null || values.optJSONArray("seen")==null || values.optJSONArray("recent")==null) {storageError(); return;}
            JSONArray seen=values.optJSONArray("seen");
            if (!host.walkJournal().arrive(pending,pending.optString("date"),seen.length(),null)) {storageError(); return;}
            String id=pending.optString("id");
            JSONObject receipt=fields("type","arrival","token",id,"session",pending.optInt("session"),"placeID",pending.optInt("placeID"),
                    "seen",seen,"recent",values.optJSONArray("recent"),"date",pending.optString("date"),
                    "distanceIncomplete",pending.optBoolean("distanceIncomplete"),"replayAfterReturn",replayAfterReturn);
            if (!id.equals(lastShown)) {lastShown=id; vibrate();}
            event(receipt);
        } else if (leg!=null && leg.has("id")) {
            event(fields("type","resumeWalk","session",leg.optInt("session"),"placeID",leg.optInt("placeID"),"id",leg.optString("id")));
            if (!WalkTrackingService.canNotify(host)) event(fields("type","notificationUnavailable","session",leg.optInt("session")));
        } else {
            JSONObject error=read(state,"error");
            if (error!=null) {
                String id=error.optString("id");
                if (id.isEmpty() || host.walkJournal().finish(id,"interrupted",null,null)) state.edit().remove("error").apply();
                event(error);
            }
        }
    }

    private void acknowledge(JSONObject msg) {
        JSONObject p=read(state,"pending");
        if (!foreground || returning() || p==null || !p.optString("id").equals(msg.optString("token"))) return;
        JSONObject values=host.recordWalkArrival(p.optInt("placeID"));
        if (values==null || values.optJSONArray("seen")==null) {storageError(); return;}
        double walked=msg.optDouble("walked");
        Double distance=!p.optBoolean("distanceIncomplete") && Double.isFinite(walked) && walked>=0 ? walked:null;
        if (host.walkJournal().arrive(p,p.optString("date"),values.optJSONArray("seen").length(),distance)
                && state.edit().remove("pending").commit()) {
            replayAfterReturn=false;
            cancelNotice();
        } else storageError();
    }

    private void cancelNotice() { host.getSystemService(NotificationManager.class).cancel(WalkTrackingService.ARRIVAL); }

    private void vibrate() {
        android.os.Vibrator motor=host.getSystemService(android.os.Vibrator.class);
        if (motor!=null && motor.hasVibrator()) motor.vibrate(android.os.VibrationEffect.createOneShot(150,android.os.VibrationEffect.DEFAULT_AMPLITUDE));
    }

    private void monitorHeading() {
        boolean needed=foreground && read(state,"active")!=null && sensors!=null;
        if (needed==listeningHeading) return;
        if (!needed) { if (sensors!=null) sensors.unregisterListener(this); listeningHeading=false; return; }
        Sensor sensor=sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
        if (sensor!=null) listeningHeading=sensors.registerListener(this,sensor,SensorManager.SENSOR_DELAY_UI);
    }
    @Override public void onSensorChanged(SensorEvent e) {
        if (!foreground || e.timestamp-lastHeading<150000000L) return;
        lastHeading=e.timestamp;
        Double heading=null;
        if(e.accuracy!=SensorManager.SENSOR_STATUS_UNRELIABLE) {
            SensorManager.getRotationMatrixFromVector(rotation,e.values);
            SensorManager.getOrientation(rotation,angles);
            heading=(Math.toDegrees(angles[0])+declination+360)%360;
        }
        heading(heading);
    }
    @Override public void onAccuracyChanged(Sensor sensor,int accuracy) {
        if(accuracy==SensorManager.SENSOR_STATUS_UNRELIABLE) heading(null);
    }
    private void heading(Double heading) {
        JSONObject route=read(state,"active");
        if(route==null) return;
        if(route.optBoolean("returning")) panel.heading(heading);
        else event(fields("type","heading","session",route.optInt("session"),"degrees",heading==null?JSONObject.NULL:heading));
    }
    private void onPosition(JSONObject route,Location fix) {
        declination=new GeomagneticField((float)fix.getLatitude(),(float)fix.getLongitude(),(float)fix.getAltitude(),fix.getTime()).getDeclination();
        if(route.optBoolean("returning")) panel.position(fix);
        else event(fields("type","position","session",route.optInt("session"),"coords",
                fields("latitude",fix.getLatitude(),"longitude",fix.getLongitude(),"accuracy",fix.getAccuracy(),"speed",fix.hasSpeed()?fix.getSpeed():-1),
                "timestamp",fix.getTime()));
    }

    boolean returning() {
        JSONObject route=read(state,"active");
        return route!=null && route.optBoolean("returning") || state.contains("returnReceipt") || state.contains("returnError");
    }
    void hideDistance(boolean hide) {
        if (!state.edit().putBoolean("hideDistance",hide).commit()) {storageError();return;}
        preferencesChanged(); panel.refresh();
    }
    void setRadius(int radius) {
        if(radius!=0 && radius!=25 && radius!=50 && radius!=100) return;
        if (!state.edit().putInt("radius",radius).putLong("radiusChangedAt",SystemClock.elapsedRealtime()).commit()) {storageError();return;}
        preferencesChanged();
    }
    void clearPoint() {
        if (state.edit().remove("point").commit()) {preferencesChanged();panel.settings(false);}
        else storageError();
    }

    void savePoint(boolean startAfterSetup) {
        requireLocation(()->acquirePoint(startAfterSetup),()->panel.permissionDenied(startAfterSetup));
    }
    void openDeviceSettings() {
        Intent settings=new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package",host.getPackageName(),null));
        try {host.startActivity(settings);}
        catch (android.content.ActivityNotFoundException ignored) {message("請從手機設定開啟定位權限。");}
    }
    private void returnPermissionDenied() {
        new AlertDialog.Builder(host).setTitle("回程需要準確位置")
                .setMessage("請在手機設定允許《散步吧》使用準確位置。")
                .setNegativeButton("取消",null).setPositiveButton("前往設定",(d,w)->openDeviceSettings()).show();
    }
    private void acquirePoint(boolean startAfterSetup) {
        cancelPoint();
        LocationManager manager=host.getSystemService(LocationManager.class);
        savingPoint=new LocationListener(){
            @Override public void onLocationChanged(Location f) {
                long age=SystemClock.elapsedRealtime()-f.getElapsedRealtimeNanos()/1000000;
                if(!foreground || savingPoint!=this || !f.hasAccuracy() || f.getAccuracy()<0 || f.getAccuracy()>40 || age<0 || age>10000) return;
                JSONObject point=fields("latitude",f.getLatitude(),"longitude",f.getLongitude());
                if (!coord(point)) return;
                cancelPoint();
                if (!save("point",point)) return;
                preferencesChanged();
                panel.pointSaved(startAfterSetup);
            }
            @Override public void onStatusChanged(String p,int s,Bundle b) {}
            @Override public void onProviderEnabled(String p) {}
            @Override public void onProviderDisabled(String p) {}
        };
        boolean registered=false;
        for(String provider:new String[]{LocationManager.GPS_PROVIDER,LocationManager.NETWORK_PROVIDER}) try {
            if(manager!=null && manager.isProviderEnabled(provider)){
                manager.requestLocationUpdates(provider,750,0,savingPoint,Looper.getMainLooper()); registered=true;
                Location recent=manager.getLastKnownLocation(provider);
                if (recent!=null) savingPoint.onLocationChanged(recent);
                if (savingPoint==null) return;
            }
        } catch(SecurityException | IllegalArgumentException ignored) { }
        if(!registered) {pointTimeout.run();return;}
        message("正在取得目前位置…"); main.postDelayed(pointTimeout,15000);
    }
    void cancelPoint() {
        main.removeCallbacks(pointTimeout);
        if(savingPoint!=null) {
            try {host.getSystemService(LocationManager.class).removeUpdates(savingPoint);} catch (RuntimeException ignored) { }
            savingPoint=null;
        }
    }

    void askReturn() {
        if(read(state,"point")==null) {panel.settings(true);return;}
        requireLocation(()->{
            if (host.walkJournal().hasActive()) {
                if(confirmingReturn) return;
                confirmingReturn=true;
                AlertDialog dialog=new AlertDialog.Builder(host).setTitle("現在回程？").setMessage("這趟散步會收工。照片和筆記會留在日誌裡。")
                        .setNegativeButton("繼續散步",null).setPositiveButton("結束散步並回程",(d,w)->{
                            if(host.walkJournal().stopActive()) beginReturn(); else storageError();
                        }).create();
                dialog.setOnDismissListener(d->confirmingReturn=false);
                dialog.show();
            } else beginReturn();
        },this::returnPermissionDenied);
    }

    void beginReturn() {
        JSONObject point=read(state,"point");
        if(point==null) return;
        state.edit().remove("returnError").remove("returnReceipt").apply();
        JSONObject route=fields("session",-1,"returning",true,"latitude",point.optDouble("latitude"),"longitude",point.optDouble("longitude"),"selectedAt",SystemClock.elapsedRealtime());
        if (!save("active",route)) return;
        replayAfterReturn=read(state,"pending")!=null;
        event(fields("type","leaveForReturn"));
        panel.showReturn(); panel.waiting();
        setAwake(true); restartService(); requestNotifications(-1);
    }

    void endReturn() {
        if(read(state,"returnReceipt")!=null) cancelNotice();
        state.edit().remove("returnError").remove("returnReceipt").apply();
        stopTracking(); panel.dismissReturn(); restore();
    }
    void retryReturn() { requireLocation(this::beginReturn,this::returnPermissionDenied); }
    void message(String text) { Toast.makeText(host,text,Toast.LENGTH_LONG).show(); }
}
