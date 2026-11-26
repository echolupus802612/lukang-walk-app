package io.github.echolupus802612.lukangwalk;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.view.View;

import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

/** 畫出腳下的導航箭頭、小嚮導的動作和北方標記。 */
final class GuideView extends View {
    private enum Motion {
        IDLE("idle", 260, 0,0,0,1,1,0,0,2,0,0,3,3),
        WALK("walk", 150, 0,1,2,3),
        POINT("point", 420, 0,1), POINT_UP("pointup", 420, 0,1),
        PULL("pull", 220, 0,1,2,3), CARE("care", 380, 0,1,2,3),
        CHEER("cheer", 170, 0,1,2,3), BYE("bye", 300, 0,1,2,3);

        final String name;
        final int interval;
        final int[] sequence;
        Motion(String name, int interval, int... sequence) {
            this.name = name;
            this.interval = interval;
            this.sequence = sequence;
        }
    }

    private final Map<String, Motion> motions = new HashMap<>();
    private final Map<Motion, Bitmap> sheets = new HashMap<>();
    private final Paint shapes = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint image = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final Rect source = new Rect();
    private final RectF figure = new RectF(45, -29, 355, 281);
    private final Path arrow = new Path();
    private final float maxWidth;
    private Motion motion = Motion.IDLE;
    private boolean flipped;
    private long began = SystemClock.uptimeMillis();
    private float angle;
    private float destination;
    private float north;
    private long lastDraw;

    GuideView(Context context, Typeface font) {
        super(context);
        maxWidth = 380 * getResources().getDisplayMetrics().density;
        setContentDescription("小嚮導指著方向");
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
        for (Motion item : Motion.values()) motions.put(item.name, item);
        arrow.moveTo(0, -38);
        arrow.lineTo(28, 32);
        arrow.lineTo(0, 17);
        arrow.lineTo(-28, 32);
        arrow.close();
        shapes.setStrokeJoin(Paint.Join.ROUND);
        shapes.setTextAlign(Paint.Align.CENTER);
        shapes.setTextSize(24);
        shapes.setTypeface(font);
    }

    void update(String name, boolean flip, double relative, double heading) {
        Motion next = motions.get(name);
        if (next == null) next = Motion.IDLE;
        float nextAngle = Double.isFinite(relative) ? (float) relative : 0;
        float nextNorth = Double.isFinite(heading) ? (float) heading : 0;
        if (next == motion && flip == flipped && nextAngle == destination && nextNorth == north) return;
        if (next != motion) began = SystemClock.uptimeMillis();
        motion = next;
        flipped = flip;
        north = nextNorth;
        destination = nextAngle;
        invalidate();
    }

    private Bitmap sheet() {
        if (!sheets.containsKey(motion)) {
            Bitmap bitmap = null;
            try (InputStream in = getContext().getAssets().open("sprites/" + motion.name + ".webp")) {
                bitmap = BitmapFactory.decodeStream(in);
            } catch (IOException ignored) {
                // 箭頭與北方標記仍可指出行走方向。
            }
            sheets.put(motion, bitmap);
        }
        return sheets.get(motion);
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        long now = SystemClock.uptimeMillis();
        boolean animate = ValueAnimator.areAnimatorsEnabled();
        float delta = (destination - angle + 540) % 360 - 180;
        float elapsed = lastDraw == 0 ? 16 : Math.min(250, now - lastDraw);
        angle = !animate || Math.abs(delta) < 0.25f ? destination
                : angle + delta * (1 - (float) Math.exp(-elapsed / 128));
        angle = ((angle + 540) % 360) - 180;
        lastDraw = now;

        float scale = Math.min(Math.min(getWidth() / 400f, getHeight() / 330f), maxWidth / 400f);
        canvas.save();
        canvas.translate((getWidth() - 400 * scale) / 2, (getHeight() - 330 * scale) / 2);
        canvas.scale(scale, scale);

        canvas.save();
        canvas.translate(200, 268);
        canvas.scale(1, .42f);
        canvas.rotate(angle);
        canvas.scale(3.4f, 3.4f);
        canvas.translate(0, 3);
        shapes.setStyle(Paint.Style.STROKE);
        shapes.setColor(0x802a0d07);
        shapes.setStrokeWidth(7);
        canvas.drawPath(arrow, shapes);
        shapes.setColor(0xfff2c14e);
        shapes.setStrokeWidth(3);
        shapes.setStyle(Paint.Style.FILL_AND_STROKE);
        canvas.drawPath(arrow, shapes);
        canvas.restore();

        shapes.setStyle(Paint.Style.FILL);
        shapes.setColor(0x662a0d07);
        canvas.drawOval(126, 253, 274, 283, shapes);
        double radians = Math.toRadians(-north);
        shapes.setColor(0xcffbf3e6);
        canvas.drawText("北", 200 + 172 * (float) Math.sin(radians),
                277 - 72.24f * (float) Math.cos(radians), shapes);
        Bitmap bitmap = sheet();
        if (bitmap != null) {
            int side = bitmap.getHeight();
            int index = animate ? (int) ((now - began) / motion.interval % motion.sequence.length) : 0;
            int left = motion.sequence[index] * side;
            source.set(left, 0, left + side, side);
            if (flipped) canvas.scale(-1, 1, 200, 0);
            canvas.drawBitmap(bitmap, source, figure, image);
        }
        canvas.restore();
        if (animate && isShown() && getWindowVisibility() == VISIBLE) {
            long untilFrame = motion.interval - (now - began) % motion.interval;
            postInvalidateDelayed(Math.abs(delta) > .25f ? Math.min(16, untilFrame) : untilFrame);
        }
    }
}
