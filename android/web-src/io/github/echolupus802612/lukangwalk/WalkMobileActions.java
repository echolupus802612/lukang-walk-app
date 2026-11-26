package io.github.echolupus802612.lukangwalk;

import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.Uri;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.Arrays;
import org.json.JSONObject;

/** 散步頁面的系統分享、地點問題回報及外觀設定。 */
final class WalkMobileActions {
    private static final String ADDRESS = "echolupus802612@gmail.com";
    private static final String FEEDBACK = "散步吧意見回報";
    private static final String OPTIONS = "walk-mobile-actions";
    private static final String[] REASONS = {"無法進入", "位置有誤", "地點已不存在", "其他"};
    private final WebWalkActivity host;
    private final SharedPreferences prefs;
    private AlertDialog reportDialog;

    WalkMobileActions(WebWalkActivity host) {
        this.host = host;
        prefs = host.getSharedPreferences(OPTIONS, Context.MODE_PRIVATE);
    }

    boolean handle(String action, JSONObject message) {
        switch (action) {
            case "theme":
                String mode = message.optString("value");
                if (mode.isEmpty() || "light".equals(mode) || "dark".equals(mode)) {
                    if (!mode.equals(prefs.getString("theme", ""))) prefs.edit().putString("theme", mode).apply();
                    refreshTheme();
                }
                return true;
            case "shareText":
            case "copyText":
                String text = message.optString("text", "");
                if (!text.isEmpty() && text.codePointCount(0, text.length()) <= 200) {
                    if ("copyText".equals(action)) copy(text);
                    else {
                        Intent send = new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text);
                        if (!open(Intent.createChooser(send, "分享散步"))) toast("找不到可以分享文字的 App。");
                    }
                }
                return true;
            case "openURL":
                String url = message.optString("url");
                if (url.equals("mailto:" + ADDRESS + "?subject=" + Uri.encode(FEEDBACK))) {
                    if (!open(emailIntent(FEEDBACK, ""))) {
                        new AlertDialog.Builder(host).setTitle("找不到郵件 App")
                                .setMessage("意見回報收件地址：" + ADDRESS)
                                .setPositiveButton("複製收件地址", (d, w) -> copy(ADDRESS))
                                .setNegativeButton("關閉", null).show();
                    }
                } else if (isShareURL(url) && !open(new Intent(Intent.ACTION_VIEW, Uri.parse(url)))) {
                    toast("無法開啟這個分享連結。");
                }
                return true;
            case "reportPlace":
                if (reportDialog == null) {
                    int id = message.optInt("placeID", -1);
                    JSONObject place = host.walkJournal().arrivedPlace(message.optString("visitID"), id);
                    if (place != null) new ReportForm(id, place.optString("name")).show();
                }
                return true;
            default:
                return false;
        }
    }

    private static boolean isDark(Context context) {
        String mode = context.getSharedPreferences(OPTIONS, Context.MODE_PRIVATE).getString("theme", "");
        int night = context.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
        return "dark".equals(mode) || (mode.isEmpty() && night == Configuration.UI_MODE_NIGHT_YES);
    }

    static int backdrop(Context context) {
        return isDark(context) ? Color.rgb(42, 15, 10) : Color.rgb(130, 48, 31);
    }

    void refreshTheme() {
        host.setTheme(isDark(host) ? android.R.style.Theme_Material_NoActionBar : android.R.style.Theme_Material_Light_NoActionBar);
        int backdrop = backdrop(host);
        host.getWindow().setStatusBarColor(backdrop);
        host.getWindow().setNavigationBarColor(backdrop);
        ViewGroup content = host.findViewById(android.R.id.content);
        if (content != null && content.getChildCount() > 0) content.getChildAt(0).setBackgroundColor(backdrop);
    }

    void close() {
        if (reportDialog != null) reportDialog.dismiss();
    }

    private static boolean isShareURL(String url) {
        if (url.length() > 1000) return false;
        try {
            URI uri = new URI(url);
            if (!"https".equals(uri.getScheme()) || uri.getUserInfo() != null || uri.getPort() != -1) return false;
            return Arrays.asList("line.me", "www.instagram.com", "www.threads.net", "x.com", "bsky.app")
                    .contains(uri.getHost());
        } catch (URISyntaxException invalid) { return false; }
    }

    private static Intent emailIntent(String subject, String body) {
        String url = "mailto:" + ADDRESS + "?subject=" + Uri.encode(subject);
        if (!body.isEmpty()) url += "&body=" + Uri.encode(body.replace("\r\n", "\n").replace('\r', '\n').replace("\n", "\r\n"));
        return new Intent(Intent.ACTION_SENDTO, Uri.parse(url))
                .putExtra(Intent.EXTRA_EMAIL, new String[]{ADDRESS})
                .putExtra(Intent.EXTRA_SUBJECT, subject).putExtra(Intent.EXTRA_TEXT, body);
    }

    private boolean open(Intent intent) {
        try {
            host.startActivity(intent);
            return true;
        } catch (ActivityNotFoundException | SecurityException unavailable) { return false; }
    }

    private void copy(String text) {
        host.getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("散步吧", text));
    }

    private void toast(String text) { Toast.makeText(host, text, Toast.LENGTH_SHORT).show(); }

    private final class ReportForm {
        private final int placeID;
        private final String placeName, reasonKey, detailsKey;
        private final LinearLayout form;
        private final RadioGroup choices;
        private final EditText note;
        private final TextView status;
        private final Button compose, copyReport, discard;

        ReportForm(int placeID, String placeName) {
            this.placeID = placeID;
            this.placeName = placeName;
            reasonKey = "reason-" + placeID;
            detailsKey = "details-" + placeID;
            form = new LinearLayout(host);
            form.setOrientation(LinearLayout.VERTICAL);
            int pad = Math.round(18 * host.getResources().getDisplayMetrics().density);
            form.setPadding(pad, pad / 2, pad, pad / 2);
            form.setFocusableInTouchMode(true);
            label(placeName + "（#" + placeID + "）", 21);
            label("收件人　" + ADDRESS, 15);
            label("回報原因", 18);
            choices = new RadioGroup(host);
            form.addView(choices);
            for (String reason : REASONS) {
                RadioButton option = new RadioButton(host);
                option.setId(View.generateViewId());
                option.setText(reason);
                choices.addView(option);
                if (reason.equals(prefs.getString(reasonKey, ""))) choices.check(option.getId());
            }
            label("補充說明", 18);
            note = new EditText(host);
            note.setMinLines(2);
            note.setGravity(Gravity.TOP | Gravity.START);
            note.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
            note.setHint("選擇「其他」時，請填寫原因。");
            note.setText(prefs.getString(detailsKey, ""));
            form.addView(note);
            compose = button("撰寫回報郵件", () -> {
                boolean opened = open(emailIntent(subject(), body()));
                status(opened ? "已開啟郵件 App。請在郵件中確認並寄出。" : "找不到郵件 App。可以複製完整回報與收件地址。");
            });
            copyReport = button("複製完整回報", () -> {
                copy("收件人：" + ADDRESS + "\n主旨：" + subject() + "\n\n" + body());
                status("已複製完整回報。");
            });
            button("複製收件地址", () -> { copy(ADDRESS); status("已複製收件地址。"); });
            status = label("", 15);
            status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
            discard = button("清除這份草稿", () -> new AlertDialog.Builder(host).setTitle("清除這份草稿？")
                    .setNegativeButton("保留", null).setPositiveButton("清除", (d, w) -> {
                        choices.clearCheck();
                        note.setText("");
                        status("已清除這份草稿。");
                    }).show());
            choices.setOnCheckedChangeListener((group, id) -> changed());
            note.addTextChangedListener(new TextWatcher() {
                public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
                public void onTextChanged(CharSequence s, int start, int before, int count) { changed(); }
                public void afterTextChanged(Editable s) {}
            });
            refresh();
        }

        private TextView label(String text, int size) {
            TextView label = new TextView(host);
            label.setTextSize(size);
            label.setText(text);
            form.addView(label);
            return label;
        }

        private Button button(String text, Runnable action) {
            Button button = new Button(host);
            button.setText(text);
            button.setOnClickListener(v -> action.run());
            form.addView(button);
            return button;
        }

        private String reason() {
            RadioButton selected = choices.findViewById(choices.getCheckedRadioButtonId());
            return selected == null ? "" : selected.getText().toString();
        }

        private void changed() {
            String selected = reason(), details = note.getText().toString();
            SharedPreferences.Editor edit = prefs.edit();
            if (selected.isEmpty()) edit.remove(reasonKey); else edit.putString(reasonKey, selected);
            if (details.isEmpty()) edit.remove(detailsKey); else edit.putString(detailsKey, details);
            edit.apply();
            status("");
            refresh();
        }

        private void refresh() {
            String selected = reason();
            boolean hasText = !details().isEmpty();
            boolean ready = !selected.isEmpty() && (!"其他".equals(selected) || hasText);
            compose.setEnabled(ready);
            copyReport.setEnabled(ready);
            discard.setVisibility(selected.isEmpty() && note.length() == 0 ? View.GONE : View.VISIBLE);
            status.setVisibility(status.length() == 0 ? View.GONE : View.VISIBLE);
        }

        private String details() { return note.getText().toString().replaceAll("^[\\s\\p{Z}]+|[\\s\\p{Z}]+$", ""); }
        private String subject() { return "《散步吧》地點問題回報 #" + placeID; }

        private String body() {
            String details = details();
            String body = "地點名稱：" + placeName + "\n地點編號：" + placeID + "\n回報原因：" + reason();
            return details.isEmpty() ? body : body + "\n補充說明：" + details;
        }

        private void status(String text) {
            status.setText(text);
            status.setVisibility(text.isEmpty() ? View.GONE : View.VISIBLE);
        }

        void show() {
            ScrollView scroll = new ScrollView(host);
            scroll.addView(form);
            AlertDialog dialog = new AlertDialog.Builder(host).setTitle("回報地點問題").setView(scroll)
                    .setNegativeButton("關閉", null).create();
            reportDialog = dialog;
            dialog.setOnDismissListener(d -> reportDialog = null);
            dialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                    | WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
            dialog.show();
        }
    }
}
