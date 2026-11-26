package io.github.echolupus802612.lukangwalk;

import android.app.Activity;
import android.content.Context;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.TextUtils;
import android.text.style.RelativeSizeSpan;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityEvent;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.IOException;
import java.io.InputStream;

final class WalkScreen {
    interface Actions {
        void band(int index);
        void start();
        void redraw();
        void toggleVoice();
        void stop();
        void step(boolean toward);
        void turn();
        void again();
        void credits();
        void simulate();
        void updateContent();
    }

    private static final int FULL = ViewGroup.LayoutParams.MATCH_PARENT;
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;
    private static final int INK = 0xfffbf3e6;
    private static final int GOLD = 0xfff2c14e;
    private static final int RUST = 0xff9a3a27;
    private static final int DARK_INK = 0xff3a1a12;
    private static final int LINE = 0x4dfbf3e6;
    private static final int CONTROL = 0x30000000;
    private static final String[] RELATIVE_DIRECTIONS = {"前方", "右前方", "右方", "右後方", "後方", "左後方", "左方", "左前方"};
    private static final String[] COMPASS_DIRECTIONS = {"北", "東北", "東", "東南", "南", "西南", "西", "西北"};
    final FrameLayout root;
    private final Activity activity;
    private final Actions actions;
    private final int outer, soft, cardPaper, cardInk;
    private final Typeface kai, kaiBold, sans, sansBold;
    private final ScrollView page;
    private final LinearLayout body;
    private final GuideView guide;
    private final TextView mode, hint, distance, sub, speech, foot, status;
    private final Button go, voice, simulationLink, creditsLink, updateLink;
    private final Button[] bands = new Button[3];
    private final LinearLayout bandRow, walkRow, simRow;
    private final HoldButton toward, wander;
    private final FrameLayout overlay;
    private final TextView cardNumber, cardName, cardTag, cardDesc;
    private final ImageView cardPhoto;
    private final Runnable hideSpeech;
    private int selectedBand = -1;
    private int guideDirection = -2;
    private int visibleCardId = -1;
    private String lastDistance = "", lastUnit = "";

    WalkScreen(Activity activity, Actions actions) {
        this.activity = activity;
        this.actions = actions;
        boolean dark = (activity.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
                == Configuration.UI_MODE_NIGHT_YES;
        outer = dark ? 0xff2a0f0a : 0xff82301f;
        soft = dark ? 0xffd9bfae : 0xfff3dccb;
        cardPaper = dark ? 0xff241310 : INK;
        cardInk = dark ? 0xfff6e9da : DARK_INK;
        kai = face("walk-kai", Typeface.SERIF, false);
        kaiBold = face("walk-kai-bold", Typeface.SERIF, true);
        sans = face("walk-sans", Typeface.SANS_SERIF, false);
        sansBold = face("walk-sans-bold", Typeface.SANS_SERIF, true);

        root = new Background(activity, dark ? 0xff3b1610 : RUST, outer);
        page = new WidthLimitedScroll(activity, dp(520));
        page.setFillViewport(true);
        page.setVerticalScrollBarEnabled(false);
        root.addView(page, new FrameLayout.LayoutParams(FULL, FULL, Gravity.CENTER_HORIZONTAL));
        body = column();
        body.setPadding(dp(16), dp(14), dp(16), dp(10));
        page.addView(body);

        LinearLayout header = row();
        header.addView(label("散步吧", 22, kaiBold, INK, Gravity.START), new LinearLayout.LayoutParams(0, WRAP, 1));
        mode = label("", 13, sans, soft, Gravity.CENTER);
        styleBadge(mode, LINE);
        header.addView(mode);
        add(body, header, 0);
        hint = label("", 17, kai, soft, Gravity.CENTER);
        add(body, hint, 10);

        guide = new GuideView(activity, kaiBold);
        guide.setMinimumHeight(dp(168));
        body.addView(guide, new LinearLayout.LayoutParams(FULL, WRAP, 1));
        distance = label("？", 47, sansBold, INK, Gravity.CENTER);
        add(body, distance, 0);
        sub = label("", 13, sans, soft, Gravity.CENTER);
        add(body, sub, 0);
        speech = label("", 18, kai, INK, Gravity.CENTER);
        speech.setPadding(dp(12), dp(8), dp(12), dp(8));
        speech.setBackground(shape(0x2b000000, 16, 0));
        speech.setVisibility(View.GONE);
        speech.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(body, speech, 8);
        hideSpeech = () -> visible(speech, false);

        bandRow = row();
        String[] labels = {"近 ~500m", "中 ~1km", "遠 ~2km"};
        for (int i = 0; i < bands.length; i++) {
            final int index = i;
            bands[i] = button(labels[i], () -> actions.band(index));
            addButton(bandRow, bands[i]);
        }
        add(body, bandRow, 10);
        go = button("出門散步吧", actions::start);
        go.setMinHeight(dp(55));
        go.setTypeface(kaiBold);
        go.setTextSize(21);
        go.setTextColor(DARK_INK);
        go.setBackground(ripple(GOLD, 14, 0));
        add(body, go, 9);
        walkRow = row();
        addButton(walkRow, button("換個地方", actions::redraw));
        voice = button("語音：開", actions::toggleVoice);
        addButton(walkRow, voice);
        addButton(walkRow, button("收工", actions::stop));
        add(body, walkRow, 10);
        simRow = row();
        toward = hold("▲ 往目的地走", true);
        wander = hold("亂走", false);
        addButton(simRow, toward);
        addButton(simRow, wander);
        addButton(simRow, button("轉身 90°", actions::turn));
        add(body, simRow, 8);

        foot = label("", 13, sans, soft, Gravity.CENTER);
        add(body, foot, 8);
        status = label("", 13, sans, INK, Gravity.CENTER);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        status.setVisibility(View.GONE);
        add(body, status, 4);
        LinearLayout footer = row();
        footer.setGravity(Gravity.CENTER);
        simulationLink = link("模擬散步", actions::simulate);
        addButton(footer, simulationLink);
        creditsLink = link("資料來源", actions::credits);
        addButton(footer, creditsLink);
        updateLink = link("更新地點資料", actions::updateContent);
        addButton(footer, updateLink);
        add(body, footer, 2);
        visible(walkRow, false);
        visible(simRow, false);

        overlay = new FrameLayout(activity);
        overlay.setVisibility(View.GONE);
        overlay.setBackgroundColor(0xa3140603);
        overlay.setPadding(dp(16), dp(16), dp(16), dp(16));
        overlay.setClickable(true);
        root.addView(overlay, new FrameLayout.LayoutParams(FULL, FULL));
        ScrollView card = new WidthLimitedScroll(activity, dp(400));
        card.setBackground(shape(cardPaper, 20, 0));
        card.setClipToOutline(true);
        card.setElevation(dp(12));
        overlay.addView(card, new FrameLayout.LayoutParams(FULL, WRAP, Gravity.CENTER));
        LinearLayout cardBody = column();
        cardBody.setPadding(dp(22), dp(18), dp(22), dp(20));
        card.addView(cardBody);
        cardNumber = label("", 15, kaiBold, dark ? GOLD : 0xff88590a, Gravity.CENTER);
        cardNumber.setLetterSpacing(.12f);
        add(cardBody, cardNumber, 0);
        cardName = label("", 34, kaiBold, cardInk, Gravity.CENTER);
        if (Build.VERSION.SDK_INT >= 28) cardName.setAccessibilityHeading(true);
        add(cardBody, cardName, 7);
        cardTag = label("", 13, sans, cardInk, Gravity.CENTER);
        styleBadge(cardTag, dark ? 0x88f6e9da : 0x883a1a12);
        LinearLayout.LayoutParams tagParams = new LinearLayout.LayoutParams(WRAP, WRAP);
        tagParams.gravity = Gravity.CENTER;
        tagParams.topMargin = dp(5);
        cardBody.addView(cardTag, tagParams);
        cardPhoto = new ImageView(activity) {
            @Override protected void onMeasure(int width, int height) {
                super.onMeasure(width, MeasureSpec.makeMeasureSpec(MeasureSpec.getSize(width) * 10 / 16, MeasureSpec.EXACTLY));
            }
        };
        cardPhoto.setScaleType(ImageView.ScaleType.CENTER_CROP);
        cardPhoto.setBackground(shape(0x14000000, 12, 0));
        cardPhoto.setClipToOutline(true);
        add(cardBody, cardPhoto, 14);
        cardDesc = label("", 17, kai, cardInk, Gravity.START);
        cardDesc.setLineSpacing(dp(2), 1.14f);
        add(cardBody, cardDesc, 14);
        Button again = button("再走一趟", actions::again);
        again.setBackground(ripple(RUST, 14, 0));
        add(cardBody, again, 16);
    }

    void render(WalkEngine e, boolean voiceEnabled) {
        boolean walking = "walking".equals(e.phase);
        boolean ready = "ready".equals(e.phase);
        boolean locating = "locating".equals(e.phase);
        text(mode, e.mode);
        text(hint, e.hint);
        text(sub, e.sub);
        text(foot, e.foot);
        visible(foot, !TextUtils.isEmpty(e.foot));
        text(go, e.goText);
        text(voice, voiceEnabled ? "語音：開" : "語音：關");
        if (selectedBand != e.band) {
            selectedBand = e.band;
            for (int i = 0; i < bands.length; i++) {
                boolean selected = i == e.band;
                Button band = bands[i];
                band.setSelected(selected);
                band.setTextColor(selected ? outer : INK);
                band.setBackground(ripple(selected ? INK : CONTROL, 14, selected ? INK : LINE));
            }
        }
        visible(bandRow, ready || locating);
        visible(go, ready || locating);
        go.setEnabled(ready);
        for (Button band : bands) band.setEnabled(ready);
        visible(walkRow, walking);
        if (!walking || !e.sim) cancelHolds();
        visible(simRow, walking && e.sim);
        visible(simulationLink, ready && !e.sim);
        visible(updateLink, ready);
        creditsLink.setEnabled(!"arrived".equals(e.phase));
        String number = TextUtils.isEmpty(e.distanceText) ? "？" : e.distanceText;
        String unit = e.unit == null ? "" : e.unit;
        if (!number.equals(lastDistance) || !unit.equals(lastUnit)) {
            lastDistance = number;
            lastUnit = unit;
            SpannableString value = new SpannableString(number + (unit.isEmpty() ? "" : " " + unit));
            if (!unit.isEmpty()) value.setSpan(new RelativeSizeSpan(.4f), number.length(), value.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            distance.setText(value);
        }
        guide.update(e.pose, e.flip, e.relative, e.heading);
        int direction = walking ? Math.floorMod((int) Math.round(e.relative / 45), 8) : -1;
        if (walking && !Double.isFinite(e.heading)) direction += 8;
        if (direction != guideDirection) {
            guideDirection = direction;
            String description = "小嚮導";
            if (direction >= 8) description += "指著" + COMPASS_DIRECTIONS[direction - 8] + "方";
            else if (direction >= 0) description += "指著" + RELATIVE_DIRECTIONS[direction];
            guide.setContentDescription(description);
        }
        if (e.cardVisible && e.target != null) {
            if (e.target.id != visibleCardId) showCard(e);
        } else if (visibleCardId != -1) {
            visibleCardId = -1;
            visible(overlay, false);
            cardPhoto.setImageDrawable(null);
            page.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO);
            page.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
            page.scrollTo(0, 0);
            if (go.isShown()) go.requestFocus();
        }
    }

    void say(String line) {
        root.removeCallbacks(hideSpeech);
        if (TextUtils.isEmpty(line)) {
            visible(speech, false);
            return;
        }
        text(speech, line);
        visible(speech, true);
        root.postDelayed(hideSpeech, 5000);
    }

    void setStatus(String message) {
        text(status, message);
        visible(status, !TextUtils.isEmpty(message));
    }

    void pause() {
        cancelHolds();
        root.removeCallbacks(hideSpeech);
        visible(speech, false);
    }

    private void cancelHolds() {
        toward.cancelHold();
        wander.cancelHold();
    }

    private void showCard(WalkEngine engine) {
        WalkEngine.Place place = engine.target;
        visibleCardId = place.id;
        cardNumber.setText("第 " + engine.seenCount() + " 站");
        cardName.setText(place.name);
        String tag = engine.cardTag();
        cardTag.setText(tag);
        visible(cardTag, !TextUtils.isEmpty(tag));
        cardDesc.setText(TextUtils.isEmpty(place.desc) ? "沒有留下說明的地方。站一下，看看它現在的樣子。" : place.desc);
        Bitmap photo = null;
        if (place.photo) {
            try (InputStream in = WalkContent.open(activity, "photos/" + place.id + ".webp")) {
                photo = BitmapFactory.decodeStream(in);
            } catch (IOException ignored) {
                // 沒有照片時仍顯示地點簡介。
            }
        }
        cardPhoto.setImageBitmap(photo);
        cardPhoto.setContentDescription(place.name + "的照片");
        visible(cardPhoto, photo != null);
        ((ScrollView) overlay.getChildAt(0)).scrollTo(0, 0);
        page.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        page.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        visible(overlay, true);
        overlay.setFocusableInTouchMode(true);
        overlay.requestFocus();
        cardName.sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED);
    }

    private Typeface face(String name, Typeface fallback, boolean bold) {
        try {
            return Typeface.createFromAsset(activity.getAssets(), "fonts/" + name + ".ttf");
        } catch (RuntimeException unavailable) {
            return Typeface.create(fallback, bold ? Typeface.BOLD : Typeface.NORMAL);
        }
    }

    private int dp(float value) {
        return Math.round(activity.getResources().getDisplayMetrics().density * value);
    }

    private GradientDrawable shape(int fill, int radius, int stroke) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(fill);
        shape.setCornerRadius(dp(radius));
        if (stroke != 0) shape.setStroke(dp(1), stroke);
        return shape;
    }

    private RippleDrawable ripple(int fill, int radius, int stroke) {
        return new RippleDrawable(ColorStateList.valueOf(0x38ffffff), shape(fill, radius, stroke), shape(0xffffffff, radius, 0));
    }

    private TextView label(String value, float size, Typeface font, int color, int gravity) {
        TextView view = new TextView(activity);
        view.setText(value);
        view.setTextSize(size);
        view.setTypeface(font);
        view.setTextColor(color);
        view.setIncludeFontPadding(false);
        view.setGravity(gravity);
        return view;
    }

    private void styleBadge(TextView label, int stroke) {
        label.setPadding(dp(10), dp(4), dp(10), dp(4));
        label.setBackground(shape(0, 30, stroke));
    }

    private Button button(String value, Runnable action) {
        Button b = new Button(activity);
        decorateButton(b, value);
        b.setOnClickListener(v -> action.run());
        return b;
    }

    private void decorateButton(Button b, String value) {
        b.setText(value);
        b.setTypeface(sans);
        b.setTextSize(15);
        b.setTextColor(INK);
        b.setAllCaps(false);
        b.setSingleLine(false);
        b.setGravity(Gravity.CENTER);
        b.setMinimumWidth(0);
        b.setMinWidth(0);
        b.setMinHeight(dp(48));
        b.setMinimumHeight(dp(48));
        b.setPadding(dp(5), dp(5), dp(5), dp(5));
        b.setStateListAnimator(null);
        b.setBackground(ripple(CONTROL, 14, LINE));
    }

    private Button link(String title, Runnable action) {
        Button b = button(title, action);
        b.setTypeface(sans);
        b.setTextSize(13);
        b.setPadding(dp(4), 0, dp(4), 0);
        b.setTextColor(soft);
        b.setPaintFlags(b.getPaintFlags() | Paint.UNDERLINE_TEXT_FLAG);
        b.setBackground(ripple(0, 12, 0));
        return b;
    }

    private LinearLayout row() {
        LinearLayout row = new LinearLayout(activity);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setBaselineAligned(false);
        return row;
    }

    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(activity);
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }

    private void add(LinearLayout parent, View child, int top) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(FULL, WRAP);
        params.topMargin = dp(top);
        parent.addView(child, params);
    }

    private void addButton(LinearLayout parent, Button child) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, WRAP, 1);
        if (parent.getChildCount() > 0) params.leftMargin = dp(7);
        parent.addView(child, params);
    }

    private static void text(TextView label, String value) {
        if (!TextUtils.equals(label.getText(), value)) label.setText(value);
    }

    private static void visible(View view, boolean show) {
        int visibility = show ? View.VISIBLE : View.GONE;
        if (view.getVisibility() != visibility) view.setVisibility(visibility);
    }

    private HoldButton hold(String label, boolean toward) {
        HoldButton b = new HoldButton(activity, () -> actions.step(toward));
        decorateButton(b, label);
        b.setTextSize(14);
        return b;
    }

    /** 長按連續前進，讀屏的點按動作也可以前進一步。 */
    private static final class HoldButton extends Button {
        private final Runnable step;
        private boolean down;
        private boolean repeated;
        private final Runnable repeat = new Runnable() {
            @Override public void run() {
                if (!down || !isShown()) return;
                repeated = true;
                step.run();
                if (down) postDelayed(this, 100);
            }
        };

        HoldButton(Context context, Runnable step) {
            super(context);
            this.step = step;
            setOnClickListener(v -> step.run());
        }

        void cancelHold() {
            if (!down) return;
            down = false;
            removeCallbacks(repeat);
            setPressed(false);
            if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(false);
        }

        @Override public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    down = true;
                    repeated = false;
                    setPressed(true);
                    getParent().requestDisallowInterceptTouchEvent(true);
                    postDelayed(repeat, 100);
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (event.getX() < 0 || event.getX() >= getWidth() || event.getY() < 0 || event.getY() >= getHeight()) cancelHold();
                    return true;
                case MotionEvent.ACTION_UP:
                    boolean tapped = down && !repeated;
                    cancelHold();
                    if (tapped) performClick();
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    cancelHold();
                    return true;
                default:
                    return super.onTouchEvent(event);
            }
        }

        @Override protected void onDetachedFromWindow() {
            cancelHold();
            super.onDetachedFromWindow();
        }
    }

    private static final class WidthLimitedScroll extends ScrollView {
        private final int maximum;
        WidthLimitedScroll(Context context, int maximum) {
            super(context);
            this.maximum = maximum;
        }
        @Override protected void onMeasure(int width, int height) {
            super.onMeasure(MeasureSpec.makeMeasureSpec(Math.min(maximum, MeasureSpec.getSize(width)), MeasureSpec.EXACTLY), height);
        }
    }

    private static final class Background extends FrameLayout {
        private final int center, edge;
        private final Paint paint = new Paint();
        Background(Context context, int center, int edge) {
            super(context);
            this.center = center;
            this.edge = edge;
            setWillNotDraw(false);
        }
        @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
            if (w > 0 && h > 0) {
                paint.setShader(new RadialGradient(w * .5f, h * .38f, Math.max(w * .65f, h * .7f),
                        center, edge, Shader.TileMode.CLAMP));
            }
        }
        @Override protected void onDraw(Canvas canvas) { canvas.drawPaint(paint); }
    }
}
