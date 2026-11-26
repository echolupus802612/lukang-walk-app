package io.github.echolupus802612.lukangwalk;

/** 同一目標與半徑必須在三十秒內收到兩筆獨立且準確的範圍內讀值。 */
final class WalkArrivalCheck {
    private long previous, lastSample, lastSelection;
    boolean confirms(double distance, double accuracy, long stamp, long now, long selection, int radius) {
        if (selection != lastSelection) {
            previous = 0;
            lastSelection = selection;
        }
        if (stamp < selection || stamp <= lastSample || stamp > now || now-stamp > 30000) return false;
        lastSample = stamp;
        double threshold = radius == 0 ? Math.min(25 + accuracy/2, 40) : radius;
        if (!Double.isFinite(distance) || !Double.isFinite(accuracy) || accuracy < 0 || accuracy > 40
                || distance < 0 || distance > threshold) {
            previous = 0;
            return false;
        }
        long prior = previous;
        previous = stamp;
        return prior != 0 && prior >= selection && now-prior <= 30000;
    }
}
