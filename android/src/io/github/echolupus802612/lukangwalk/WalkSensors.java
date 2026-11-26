package io.github.echolupus802612.lukangwalk;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.hardware.GeomagneticField;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;

/** 每次重新進入前景都建立獨立的監聽器，以免上次散步的事件混入這一趟。 */
final class WalkSensors {
    private final Activity activity;
    private final WalkEngine engine;
    private final LocationManager locations;
    private final SensorManager sensors;
    private final Handler main = new Handler(Looper.getMainLooper());
    private Session active;

    WalkSensors(Activity activity, WalkEngine engine) {
        this.activity = activity;
        this.engine = engine;
        locations = activity.getSystemService(LocationManager.class);
        sensors = activity.getSystemService(SensorManager.class);
    }
    void start() {
        if (active != null || !engine.sensorWanted) return;
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            permissionLost();
            return;
        }
        if (locations == null) { engine.locationError("unavailable"); return; }
        Session session = new Session();
        active = session;
        try {
            boolean haveGps = session.subscribe(LocationManager.GPS_PROVIDER);
            boolean haveNetwork = session.subscribe(LocationManager.NETWORK_PROVIDER);
            if (!haveGps && !haveNetwork) { session.fail("unavailable"); return; }
        } catch (SecurityException e) {
            stop(); permissionLost(); return;
        }
        if (sensors != null) {
            Sensor rotation = sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
            if (rotation == null) rotation = sensors.getDefaultSensor(Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR);
            if (rotation != null) sensors.registerListener(session, rotation, SensorManager.SENSOR_DELAY_UI, main);
        }
        main.postDelayed(session.timeout, 12000);
    }
    void stop() {
        Session old = active;
        active = null;
        if (old == null) return;
        main.removeCallbacks(old.timeout);
        try { locations.removeUpdates(old); } catch (SecurityException ignored) { /* 權限已收回。 */ }
        if (sensors != null) sensors.unregisterListener(old);
    }
    private void permissionLost() {
        boolean approximate = activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
        engine.locationError(approximate ? "approximate" : "denied");
    }
    private boolean enabled(String provider) {
        try { return locations.isProviderEnabled(provider); }
        catch (IllegalArgumentException ignored) { return false; }
    }
    private final class Session implements LocationListener, SensorEventListener {
        final Runnable timeout = () -> fail("unavailable");
        final long started = SystemClock.elapsedRealtimeNanos();
        final float[] rotationMatrix = new float[9], screenMatrix = new float[9], angles = new float[3];
        long lastFixNanos, lastGpsNanos, lastHeadingNanos;
        float declination;

        boolean subscribe(String provider) {
            if (!enabled(provider)) return false;
            locations.requestLocationUpdates(provider, 1000L, 0f, this, Looper.getMainLooper());
            return true;
        }
        void fail(String reason) {
            if (active != this) return;
            stop();
            engine.locationError(reason);
        }
        @Override public void onLocationChanged(Location fix) {
            if (active != this || fix == null || !fix.hasAccuracy()) return;
            long stamp = fix.getElapsedRealtimeNanos();
            long age = SystemClock.elapsedRealtimeNanos()-stamp;
            long wallAge = System.currentTimeMillis()-fix.getTime();
            if (stamp < started || stamp <= lastFixNanos || age < 0 || age > 2_000_000_000L
                    || wallAge < 0 || wallAge > 2000 || !Float.isFinite(fix.getAccuracy()) || fix.getAccuracy() < 0) return;
            double lat = fix.getLatitude(), lng = fix.getLongitude();
            if (!Double.isFinite(lat) || !Double.isFinite(lng) || Math.abs(lat)>90 || Math.abs(lng)>180) return;
            boolean gps = LocationManager.GPS_PROVIDER.equals(fix.getProvider());
            // GPS 穩定時忽略網路粗估，兩個來源同時回報也不能算成兩次到達。
            if (!gps && lastGpsNanos != 0 && stamp-lastGpsNanos < 3_000_000_000L) return;
            if (gps) lastGpsNanos = stamp;
            if (lastFixNanos != 0 && stamp-lastFixNanos < 400_000_000L) return;
            lastFixNanos = stamp;
            main.removeCallbacks(timeout);
            float altitude = fix.hasAltitude() ? (float)fix.getAltitude() : 0;
            declination = new GeomagneticField((float)lat, (float)lng, altitude, fix.getTime()).getDeclination();
            engine.fix(lat, lng, fix.getAccuracy(), fix.hasSpeed() ? fix.getSpeed() : -1, fix.getTime());
        }
        @Override public void onProviderDisabled(String provider) {
            if (active == this && !enabled(LocationManager.GPS_PROVIDER) && !enabled(LocationManager.NETWORK_PROVIDER)) {
                fail("unavailable");
            }
        }
        @Override public void onProviderEnabled(String provider) { }
        @Override public void onStatusChanged(String provider, int status, Bundle extras) { }

        @Override public void onSensorChanged(SensorEvent event) {
            if (active != this) return;
            long stamp = event.timestamp;
            long age = SystemClock.elapsedRealtimeNanos()-stamp;
            if (stamp < started || age < 0 || age > 2_000_000_000L || stamp-lastHeadingNanos < 150_000_000L) return;
            lastHeadingNanos = stamp;
            if (event.accuracy == SensorManager.SENSOR_STATUS_UNRELIABLE) {
                engine.heading(Double.NaN);
                return;
            }
            SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values);
            int x = SensorManager.AXIS_X, y = SensorManager.AXIS_Y;
            switch (activity.getWindowManager().getDefaultDisplay().getRotation()) {
                case Surface.ROTATION_90: x = SensorManager.AXIS_Y; y = SensorManager.AXIS_MINUS_X; break;
                case Surface.ROTATION_180: x = SensorManager.AXIS_MINUS_X; y = SensorManager.AXIS_MINUS_Y; break;
                case Surface.ROTATION_270: x = SensorManager.AXIS_MINUS_Y; y = SensorManager.AXIS_X; break;
                default: break;
            }
            SensorManager.remapCoordinateSystem(rotationMatrix, x, y, screenMatrix);
            SensorManager.getOrientation(screenMatrix, angles);
            engine.heading(Math.toDegrees(angles[0]) + declination);
        }
        @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {
            if (active == this && accuracy == SensorManager.SENSOR_STATUS_UNRELIABLE) engine.heading(Double.NaN);
        }
    }
}
