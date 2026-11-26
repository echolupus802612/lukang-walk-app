package io.github.echolupus802612.lukangwalk;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;

import org.json.JSONException;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public final class WalkTrackingService extends Service implements LocationListener {
    static final int TRACKING = 4101, ARRIVAL = 4102;
    static final String TRACK_CHANNEL = "walk-navigation", ARRIVE_CHANNEL = "walk-arrivals";
    private LocationManager locations;
    private SharedPreferences state;
    private long lastFix;
    private final WalkArrivalCheck arrival = new WalkArrivalCheck();
    private boolean listening;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable firstFixTimeout = () -> {
        JSONObject route=read(state,"active");
        if (route==null) stopSelf();
        else if (!route.has("latitude")) fail("unavailable");
    };

    static SharedPreferences state(Context ctx) {
        return ctx.getSharedPreferences("walk-navigation-v1", Context.MODE_PRIVATE);
    }

    static JSONObject read(SharedPreferences state, String key) {
        String raw = state.getString(key, null);
        if (raw == null) return null;
        try { return new JSONObject(raw); } catch (JSONException ignored) { return null; }
    }

    static JSONObject fields(Object... pairs) {
        JSONObject o = new JSONObject();
        try {
            for (int i=0; i<pairs.length; i+=2) o.put((String)pairs[i], pairs[i+1]);
        } catch (JSONException e) { throw new IllegalArgumentException(e); }
        return o;
    }

    static boolean precise(Context ctx) {
        return ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    static void channels(Context ctx) {
        NotificationManager manager = ctx.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(TRACK_CHANNEL, "散步定位", NotificationManager.IMPORTANCE_LOW));
        manager.createNotificationChannel(new NotificationChannel(ARRIVE_CHANNEL, "到站提醒", NotificationManager.IMPORTANCE_HIGH));
    }

    static boolean canNotify(Context ctx) {
        NotificationManager manager = ctx.getSystemService(NotificationManager.class);
        channels(ctx);
        return manager.areNotificationsEnabled()
                && manager.getNotificationChannel(ARRIVE_CHANNEL).getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    private Notification notification(String channel, String title, String text, boolean ongoing) {
        Intent open = new Intent(this, WebWalkActivity.class)
                .setFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent tap = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, channel).setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle(title).setContentText(text).setContentIntent(tap).setOnlyAlertOnce(ongoing)
                .setOngoing(ongoing).setAutoCancel(!ongoing).setCategory(ongoing ? Notification.CATEGORY_SERVICE : Notification.CATEGORY_EVENT).build();
    }

    @Override public void onCreate() {
        super.onCreate();
        state = state(this);
        locations = getSystemService(LocationManager.class);
        channels(this);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        JSONObject route = read(state,"active");
        boolean returning = route != null && route.optBoolean("returning");
        try {
            Notification n = notification(TRACK_CHANNEL, returning ? "正在回程" : "正在散步",
                    "正在使用定位，點一下回到導航畫面。", true);
            if (Build.VERSION.SDK_INT >= 29) startForeground(TRACKING, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
            else startForeground(TRACKING, n);
            if (route == null) { stopSelf(startId); return START_NOT_STICKY; }
            main.removeCallbacks(firstFixTimeout);
            if (!route.has("latitude")) main.postDelayed(firstFixTimeout,20000);
            if (!precise(this)) { fail("denied"); return START_NOT_STICKY; }
            if (!listening) {
                for (String provider : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER}) {
                    if (enabled(provider)) {
                        locations.requestLocationUpdates(provider, 750L, 0f, this, Looper.getMainLooper());
                        listening = true;
                    }
                }
                if (!listening) { fail("unavailable"); return START_NOT_STICKY; }
            }
            return START_STICKY;
        } catch (SecurityException | IllegalStateException error) {
            fail("unavailable");
            return START_NOT_STICKY;
        }
    }

    private boolean enabled(String provider) {
        try { return locations != null && locations.isProviderEnabled(provider); }
        catch (IllegalArgumentException ignored) { return false; }
    }

    private void fail(String reason) {
        JSONObject route = read(state,"active");
        if (route != null) {
            JSONObject error = fields("type","error","reason",reason,"session",route.optInt("session"),"id",route.optString("id"));
            if (route.optBoolean("returning")) {
                state.edit().putString("returnError",reason).remove("active").commit();
            } else {
                state.edit().putString("error",error.toString()).remove("active").commit();
            }
            WalkMobileNavigation.changed();
        }
        stopSelf();
    }

    @Override public void onLocationChanged(Location fix) {
        JSONObject route = read(state,"active");
        if (route == null) { stopSelf(); return; }
        long now = SystemClock.elapsedRealtime();
        long stamp = fix.getElapsedRealtimeNanos()/1000000;
        long age = now-stamp;
        if (stamp <= lastFix || age < 0 || age > 30000 || !fix.hasAccuracy() || fix.getAccuracy() < 0
                || !Double.isFinite(fix.getLatitude()) || !Double.isFinite(fix.getLongitude())) return;
        lastFix = stamp;
        boolean visible = WalkMobileNavigation.visible();
        long selection = Math.max(route.optLong("selectedAt"),state.getLong("radiusChangedAt",0));
        if (route.has("latitude") && stamp >= selection) {
            float[] meters = new float[1];
            Location.distanceBetween(fix.getLatitude(),fix.getLongitude(),route.optDouble("latitude"),route.optDouble("longitude"),meters);
            int radius = state.getInt("radius",0);
            if (arrival.confirms(meters[0],fix.getAccuracy(),stamp,now,selection,radius)) {
                if (visible && age<=2000) WalkMobileNavigation.position(route,fix);
                finishArrival(route,visible);
                return;
            }
        }
        if (visible && age<=2000) WalkMobileNavigation.position(route,fix);
    }

    private void finishArrival(JSONObject route, boolean visible) {
        boolean returning = route.optBoolean("returning");
        long time = System.currentTimeMillis();
        try {
            route.put("endedAt",time);
            route.put("date",new SimpleDateFormat("yyyy.MM.dd",Locale.US).format(new Date(time)));
            route.put("distanceIncomplete",!visible || route.optBoolean("distanceIncomplete"));
        } catch (JSONException ignored) { return; }
        if (!state.edit().remove("active").putString(returning ? "returnReceipt" : "pending",route.toString()).commit()) {
            if (visible) WalkMobileNavigation.storageError();
            return;
        }
        if (!visible && canNotify(this)) {
            Notification n=notification(ARRIVE_CHANNEL,returning ? "已抵達回程地點" : "散步到站了",
                    returning ? "你已經回到設定的位置了。" : "小嚮導已經找到目的地，點一下揭曉這一站。",false);
            try { getSystemService(NotificationManager.class).notify(ARRIVAL,n); } catch (SecurityException ignored) { }
        }
        WalkMobileNavigation.changed();
        stopSelf();
    }

    @Override public void onProviderDisabled(String provider) {
        if (!enabled(LocationManager.GPS_PROVIDER) && !enabled(LocationManager.NETWORK_PROVIDER)) fail("unavailable");
    }
    @Override public void onProviderEnabled(String provider) { }
    @Override public void onStatusChanged(String provider,int status,Bundle extras) { }
    @Override public void onDestroy() {
        main.removeCallbacks(firstFixTimeout);
        if (locations!=null) locations.removeUpdates(this);
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
