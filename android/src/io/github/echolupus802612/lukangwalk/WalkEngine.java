package io.github.echolupus802612.lukangwalk;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.Set;

/** 散步規則和畫面狀態；從主執行緒傳入定位、按鈕與計時事件。 */
final class WalkEngine {
    static final class Place {
        final int id;
        final String name, cat, tag, desc;
        final double lat, lng;
        final boolean photo;
        Place(int id, String name, double lat, double lng, String cat, String tag, String desc, boolean photo) {
            this.id = id; this.name = name; this.lat = lat; this.lng = lng;
            this.cat = cat; this.tag = tag; this.desc = desc; this.photo = photo;
        }
    }

    interface Progress {
        int drawn(boolean sim);
        int seenCount(boolean sim);
        List<Integer> recent(boolean sim);
        void recordDraw(boolean sim);
        void recordArrival(boolean sim, int id);
    }

    interface Listener {
        void changed();
        void needLocation(boolean enable);
        void say(String asset, String line, boolean urgent);
        void arrived();
    }

    private static final int[] MIN = {0, 400, 900}, MAX = {500, 1000, 2000};
    private static final double EARTH = 6371000;
    private static final String[] DIRECTIONS = {"北","東北","東","東南","南","西南","西","西北"};
    private static final String CHOOSE = "選一個遠近，出門散步吧";
    private final List<Place> places;
    private final Progress progress;
    private final Listener listener;
    private final Random random = new Random();
    private final Map<String, Long> lastLine = new HashMap<>();
    private final Place home;

    String phase = "ready", mode = "尚未出發", hint = CHOOSE, sub, foot, goText = "出門散步吧";
    String distanceText = "？", unit = "", pose = "idle";
    boolean sim, flip, offer, cardVisible, sensorWanted;
    int band = 1;
    double heading = Double.NaN, relative;
    Place target;

    private Place offered;
    private double lat, lng, accuracy, anchorLat = Double.NaN, anchorLng;
    private double startDistance, aimless, distance;
    private int hits;
    private boolean halfSaid, nearSaid;
    private long lastFix, lastMove, pickedAt, behindAt, farAt, poseUntil, cardAt;
    private String momentary = "idle";

    WalkEngine(List<Place> places, Progress progress, Listener listener) {
        if (places.isEmpty()) throw new IllegalArgumentException("缺少散步地點");
        this.places = places;
        this.progress = progress;
        this.listener = listener;
        Place found = places.get(0);
        for (Place p : places) if (p.id == 32) { found = p; break; }
        home = found;
        aimless = random.nextDouble() * 360;
        foot = String.format(Locale.TAIWAN, "全台 %,d 個地點", places.size());
        sub = statLine();
    }

    int seenCount() { return progress.seenCount(sim); }
    String cardTag() {
        if (target == null) return "";
        switch (target.tag) {
            case "古蹟": case "歷史建築": case "文化景觀": return target.tag;
            default: return category(target.cat);
        }
    }
    private static String category(String cat) {
        switch (cat) {
            case "worship": return "一座廟或祠";
            case "history": return "一處老宅或舊址";
            case "structure": return "一段巷弄、一棟老樓";
            case "nature": return "一片能歇腳的地方";
            case "scenic": return "一處看風景的地方";
            case "culture": return "一處館舍或藝文空間";
            case "shop": return "一間老店";
            default: return "說不上來的地方";
        }
    }
    private String statLine() {
        return (sim ? "模擬：" : "") + "出發過 " + progress.drawn(sim) + " 次 · 到過 " + seenCount() + " 處";
    }
    private static long now() { return System.nanoTime() / 1_000_000; }
    private static double norm(double angle) { return ((angle % 360) + 540) % 360 - 180; }
    private static double dist(double a, double b, double c, double d) {
        double dp = Math.toRadians(c - a), dl = Math.toRadians(d - b);
        double h = Math.pow(Math.sin(dp/2), 2) + Math.cos(Math.toRadians(a))
                * Math.cos(Math.toRadians(c)) * Math.pow(Math.sin(dl/2), 2);
        return 2 * EARTH * Math.asin(Math.sqrt(Math.min(1, h)));
    }
    private double bearing() {
        double dl = Math.toRadians(target.lng - lng), a = Math.toRadians(lat), c = Math.toRadians(target.lat);
        double y = Math.sin(dl) * Math.cos(c);
        double x = Math.cos(a) * Math.sin(c) - Math.sin(a) * Math.cos(c) * Math.cos(dl);
        return (Math.toDegrees(Math.atan2(y, x)) + 360) % 360;
    }
    private void move(double degrees, double meters) {
        double b = Math.toRadians(degrees), arc = meters/EARTH, a = Math.toRadians(lat);
        double next = Math.asin(Math.sin(a)*Math.cos(arc) + Math.cos(a)*Math.sin(arc)*Math.cos(b));
        lng += Math.toDegrees(Math.atan2(Math.sin(b)*Math.sin(arc)*Math.cos(a), Math.cos(arc)-Math.sin(a)*Math.sin(next)));
        lat = Math.toDegrees(next);
    }
    private static String number(double meters) {
        return meters >= 1000 ? String.format(Locale.ROOT, "%.1f", meters/1000) : Long.toString(Math.round(meters));
    }
    private static String units(double meters) { return meters >= 1000 ? "公里" : "公尺"; }

    void band(int value) {
        if (!phase.equals("ready") || value < 0 || value >= MAX.length) return;
        band = value;
        if (offer) { clearOffer(); hint = CHOOSE; goText = "出門散步吧"; }
        listener.changed();
    }
    private void clearOffer() { offer = false; offered = null; }
    private void requestLocation(boolean enabled) {
        if (sensorWanted == enabled) return;
        sensorWanted = enabled;
        listener.needLocation(enabled);
    }
    void start() {
        if (!phase.equals("ready")) return;
        if (!offer) speak("greet");
        if (sim) { if (!Double.isFinite(heading)) heading = 0; pick(); return; }
        phase = "locating"; mode = "定位中"; goText = "找方向中…";
        clearFixes();
        listener.changed();
        requestLocation(true);
    }
    void simulate() {
        if (!phase.equals("ready") && !phase.equals("locating")) return;
        if (phase.equals("ready")) speak("greet");
        enterSimulation("模擬模式：按住「往目的地走」前進。");
    }
    private void enterSimulation(String reason) {
        requestLocation(false);
        clearFixes(); clearOffer();
        sim = true; accuracy = 5; heading = 0; lat = home.lat; lng = home.lng;
        move(200, 30);
        mode = "模擬行走"; foot = reason; target = null;
        phase = "ready";
        pick();
    }
    void locationError(String reason) {
        if (!sensorWanted || sim) return;
        String message;
        switch (reason) {
            case "denied": message = "未取得定位權限"; break;
            case "approximate": message = "目前只允許大概位置"; break;
            default: message = phase.equals("locating") ? "拿不到目前位置" : "定位中斷了";
        }
        enterSimulation(message + "，先在鹿港天后宮前模擬走走。");
    }
    private void clearFixes() {
        lastFix = 0; hits = 0; behindAt = 0; heading = Double.NaN;
        anchorLat = Double.NaN; lastMove = now();
    }
    void pauseFixes() {
        if (sim) return;
        clearFixes();
        if (phase.equals("walking")) {
            mode = "GPS（無指南針）";
            updateDirection(); updatePose(now()); listener.changed();
        }
    }
    void fix(double latitude, double longitude, double acc, double speed, long epochMillis) {
        if (!sensorWanted || sim) return;
        long age = System.currentTimeMillis() - epochMillis;
        if (!Double.isFinite(latitude) || !Double.isFinite(longitude) || !Double.isFinite(acc)
                || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || acc < 0
                || age < 0 || age > 2000 || epochMillis <= lastFix) return;
        lastFix = epochMillis;
        if (Double.isNaN(anchorLat) || dist(anchorLat, anchorLng, latitude, longitude) > 4 || speed > 0.6) {
            if (!Double.isNaN(anchorLat)) lastMove = now();
            anchorLat = latitude; anchorLng = longitude;
        }
        lat = latitude; lng = longitude; accuracy = acc;
        mode = Double.isFinite(heading) ? "GPS 實走" : "GPS（無指南針）";
        if (phase.equals("locating")) {
            for (Place place : places) if (dist(lat, lng, place.lat, place.lng) <= 5000) {
                foot = ""; pick(); return;
            }
            enterSimulation("你附近 5 公里內還沒有收錄的地點，先在鹿港天后宮前模擬走走。");
        } else if (phase.equals("walking")) updateWalk(true, false);
    }
    void heading(double degrees) {
        if (!sensorWanted || sim) return;
        heading = Double.isFinite(degrees) ? (degrees % 360 + 360) % 360 : Double.NaN;
        if (phase.equals("walking")) {
            mode = Double.isFinite(heading) ? "GPS 實走" : "GPS（無指南針）";
            updateDirection(); updatePose(now()); listener.changed();
        }
    }

    private static final class Candidate {
        final Place place;
        final double meters;
        Candidate(Place place, double meters) { this.place = place; this.meters = meters; }
        double weight() { return 1.0 / Math.pow(Math.max(meters, 120), 2); }
    }
    private void pick() {
        Set<Integer> recent = new HashSet<>(progress.recent(sim));
        List<Candidate> all = new ArrayList<>(), pool = new ArrayList<>();
        for (Place place : places) {
            if (target != null && target.id == place.id) continue;
            double d = dist(lat, lng, place.lat, place.lng);
            if (d < 60) continue;
            Candidate c = new Candidate(place, d);
            all.add(c);
            if (!recent.contains(place.id)) pool.add(c);
        }
        if (pool.isEmpty()) pool = all;
        Candidate nearest = null;
        List<Candidate> ring = new ArrayList<>(), inside = new ArrayList<>();
        for (Candidate c : pool) {
            if (nearest == null || c.meters < nearest.meters) nearest = c;
            if (c.meters <= MAX[band]) {
                inside.add(c);
                if (c.meters >= MIN[band]) ring.add(c);
            }
        }
        if (ring.size() < 4) ring = inside;
        if (ring.isEmpty()) {
            if (phase.equals("walking")) { sub = "這個距離內沒有別的地方了"; listener.changed(); return; }
            if (offered == null || nearest == null || offered.id != nearest.place.id) {
                offered = nearest == null ? null : nearest.place;
                offer = offered != null;
                phase = "ready"; requestLocation(false);
                hint = offer ? "這個距離內沒有地點，最近一處約 " + number(nearest.meters) + " " + units(nearest.meters)
                        : "附近沒有可以去的地方";
                goText = offer ? "那就走遠一點" : "出門散步吧";
                sub = statLine(); listener.changed(); return;
            }
            ring.add(nearest);
        }
        clearOffer();
        double total = 0;
        for (Candidate c : ring) total += c.weight();
        double choice = random.nextDouble() * total;
        Candidate selected = ring.get(ring.size()-1);
        for (Candidate c : ring) if ((choice -= c.weight()) <= 0) { selected = c; break; }
        target = selected.place; startDistance = selected.meters;
        phase = "walking"; hits = 0; halfSaid = false; nearSaid = false;
        farAt = pickedAt = now(); behindAt = 0;
        progress.recordDraw(sim);
        hint = "這次要去：" + category(target.cat);
        updateWalk(false, true);
    }
    void redraw() { if (phase.equals("walking")) pick(); }
    void stop() {
        if (phase.equals("arrived")) return;
        requestLocation(false); clearFixes(); speak("bye"); act("bye", 3200);
        sim = false; foot = ""; mode = "已收工"; ready("出門散步吧");
    }
    void again() {
        if (!phase.equals("arrived")) return;
        ready("再走一趟");
    }
    private void ready(String button) {
        phase = "ready"; cardVisible = false; target = null; clearOffer();
        relative = 0; goText = button; hint = CHOOSE; distanceText = "？"; unit = "";
        sub = statLine(); updatePose(now()); listener.changed();
    }
    void step(boolean toward) {
        if (!sim || !phase.equals("walking")) return;
        double direction;
        if (toward) {
            direction = bearing() + (random.nextDouble()-.5)*50;
            heading = (heading + norm(direction-heading)*.25 + 360) % 360;
        } else {
            aimless += (random.nextDouble()-.5)*30;
            direction = aimless; heading = (aimless % 360 + 360) % 360;
        }
        move(direction, 1.2); lastMove = now(); updateWalk(true, false);
    }
    void turn() {
        if (!sim || !phase.equals("walking")) return;
        heading = (heading + 90) % 360;
        updateDirection(); updatePose(now()); listener.changed();
    }
    private void updateDirection() {
        relative = norm(bearing() - (Double.isFinite(heading) ? heading : 0));
    }
    private void updateWalk(boolean freshFix, boolean first) {
        distance = dist(lat, lng, target.lat, target.lng);
        distanceText = number(distance); unit = units(distance);
        updateDirection();
        sub = accuracy > 35 ? "定位誤差約 " + Math.round(accuracy) + " 公尺" :
                !Double.isFinite(heading) ? "沒有指南針・目標在" + DIRECTIONS[(int)Math.round(bearing()/45) % 8] + "方" : statLine();
        long t = now();
        if (accuracy > 60 && speak("weak")) act("care", 4000);
        if (distance <= Math.min(25 + accuracy/2, 40)) {
            if (sim) { arrive(); return; }
            if (accuracy > 40) {
                hits = 0; sub = "已經很近了，等定位準一點…";
            } else {
                if (freshFix) hits++;
                if (hits >= 2) { arrive(); return; }
                sub = "已經很近了，確認位置中…";
            }
        } else {
            hits = 0;
            if (!first && !halfSaid && distance < startDistance/2 && startDistance > 300) {
                halfSaid = true; speak("half");
            } else if (!nearSaid && distance < 80) { nearSaid = true; speak("near"); }
            else if (distance > 250 && t-farAt > 90000) { farAt = t; speak("far"); }
        }
        updatePose(t); listener.changed();
    }
    private void arrive() {
        phase = "arrived"; pose = "cheer"; flip = false; cardVisible = false; cardAt = now()+1800;
        requestLocation(false);
        progress.recordArrival(sim, target.id);
        speak("arrived"); listener.arrived(); listener.changed();
    }
    void tick() {
        long t = now();
        if (phase.equals("arrived")) {
            if (!cardVisible && t >= cardAt) { cardVisible = true; listener.changed(); }
            return;
        }
        if (phase.equals("walking")) {
            if (Double.isFinite(heading) && Math.abs(relative)>120) {
                if (behindAt == 0) behindAt = t;
                else if (t-behindAt > 3500) speak("behind");
            } else behindAt = 0;
            if (t-lastMove > 45000) {
                lastMove = t;
                if (speak("idle")) act("care", 5000);
            }
        }
        String previous = pose; boolean wasFlipped = flip;
        updatePose(t);
        if (!pose.equals(previous) || wasFlipped != flip) listener.changed();
    }
    private void updatePose(long t) {
        flip = false;
        if (phase.equals("arrived")) pose = "cheer";
        else if (t < poseUntil) pose = momentary;
        else if (!phase.equals("walking")) pose = "idle";
        else if (Double.isFinite(heading) && Math.abs(relative) > 120) { pose = "pull"; flip = relative > 0; }
        else if (Double.isFinite(heading) && Math.abs(relative) > 35) { pose = "point"; flip = relative < 0; }
        else if (t-lastMove < (sim ? 1500 : 6000)) pose = "walk";
        else if (t-Math.max(lastMove, pickedAt) < 15000) pose = "pointup";
        else pose = "idle";
    }
    private void act(String name, long ms) { momentary = name; poseUntil = now()+ms; }
    private boolean speak(String event) {
        long t = now();
        Long previous = lastLine.get(event);
        if (previous != null && t-previous < 12000) return false;
        String[] lines;
        switch (event) {
            case "greet": lines = new String[]{"走吧，出門散步吧！跟著我。","今天想去哪走走？跟我來。"}; break;
            case "far": lines = new String[]{"還有一段路，慢慢來。","不急，我們慢慢走。"}; break;
            case "half": lines = new String[]{"走一半了。","過半了，你走得不錯。"}; break;
            case "near": lines = new String[]{"快到了，抬頭看看。","就在這附近了。"}; break;
            case "behind": lines = new String[]{"在你後面啦，轉個身。","方向反了，往回一點。"}; break;
            case "idle": lines = new String[]{"停下來了？歇一下也好。","我在這，等你。"}; break;
            case "weak": lines = new String[]{"訊號不太好，先站一下。"}; break;
            case "arrived": lines = new String[]{"到啦～就是這裡！"}; break;
            case "bye": lines = new String[]{"今天就走到這吧。","下次再一起出門散步吧。"}; break;
            default: return false;
        }
        lastLine.put(event,t);
        int index = random.nextInt(lines.length);
        boolean arrived = event.equals("arrived");
        listener.say("voice/" + event + (arrived ? "" : "_" + index) + ".mp3", lines[index],
                arrived || event.equals("bye") || event.equals("greet"));
        return true;
    }
}
