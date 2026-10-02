package local.shelf.reader.android;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.view.*;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.*;
import java.util.Locale;

final class Ui {
  static final int BG = Color.BLACK,
      SURFACE = 0xff151515,
      TEXT = 0xfff4f4f4,
      MUTED = 0xff9a9a9f,
      MINT = 0xff61c8b7;

  static int dp(Context c, float value) {
    return Math.round(value * c.getResources().getDisplayMetrics().density);
  }

  static GradientDrawable shape(int color, int radius, Context c) {
    GradientDrawable d = new GradientDrawable();
    d.setColor(color);
    d.setCornerRadius(dp(c, radius));
    return d;
  }

  static TextView text(Context c, String text, int sp, int color) {
    TextView v = new TextView(c);
    v.setText(text);
    v.setTextColor(color);
    v.setTextSize(sp);
    v.setGravity(Gravity.CENTER_VERTICAL);
    v.setHapticFeedbackEnabled(false);
    v.setFontFeatureSettings("tnum");
    return v;
  }

  static TextView button(Context c, String text, Runnable action) {
    TextView v = text(c, text, 16, TEXT);
    v.setGravity(Gravity.CENTER);
    v.setMinHeight(dp(c, 48));
    v.setPadding(dp(c, 10), 0, dp(c, 10), 0);
    v.setBackground(shape(SURFACE, 14, c));
    v.setOnClickListener(w -> action.run());
    v.setFocusable(true);
    return v;
  }

  static LinearLayout column(Context c) {
    LinearLayout v = new LinearLayout(c);
    v.setOrientation(LinearLayout.VERTICAL);
    return v;
  }

  static LinearLayout row(Context c) {
    LinearLayout v = new LinearLayout(c);
    v.setOrientation(LinearLayout.HORIZONTAL);
    v.setGravity(Gravity.CENTER_VERTICAL);
    return v;
  }

  static LinearLayout.LayoutParams weight() {
    return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
  }

  static void enabled(TextView v, boolean on) {
    v.setEnabled(on);
    v.setAlpha(on ? 1 : .35f);
  }

  static void inset(Activity activity, View root) {
    activity.getWindow().setDecorFitsSystemWindows(false);
    activity.getWindow().setStatusBarColor(BG);
    activity.getWindow().setNavigationBarColor(BG);
    root.setOnApplyWindowInsetsListener(
        (v, w) -> {
          Insets i =
              w.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
          v.setPadding(i.left, i.top, i.right, i.bottom);
          return w;
        });
    WindowInsetsController controller = activity.getWindow().getInsetsController();
    if (controller != null)
      controller.setSystemBarsAppearance(
          0,
          WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
              | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
    Display display = activity.getDisplay();
    if (display != null) {
      float rate = 60;
      for (Display.Mode mode : display.getSupportedModes())
        if (mode.getPhysicalWidth() == display.getMode().getPhysicalWidth()
            && mode.getPhysicalHeight() == display.getMode().getPhysicalHeight())
          rate = Math.max(rate, Math.min(120, mode.getRefreshRate()));
      WindowManager.LayoutParams p = activity.getWindow().getAttributes();
      p.preferredRefreshRate = rate;
      activity.getWindow().setAttributes(p);
    }
  }

  static void back(Activity activity, Runnable callback) {
    if (Build.VERSION.SDK_INT >= 33)
      activity
          .getOnBackInvokedDispatcher()
          .registerOnBackInvokedCallback(
              android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback::run);
  }

  static void toast(Context c, String text) {
    Toast.makeText(c, text, Toast.LENGTH_LONG).show();
  }

  static void confirm(Activity activity, String title, String message, Runnable action) {
    new AlertDialog.Builder(activity)
        .setTitle(title)
        .setMessage(message)
        .setNegativeButton("取消", null)
        .setPositiveButton("确定", (d, w) -> action.run())
        .show();
  }

  static String bytes(long value) {
    return value >= 1_000_000_000
        ? String.format(Locale.ROOT, "%.2f GB", value / 1e9)
        : String.format(Locale.ROOT, "%.1f MB", value / 1e6);
  }

  static void licenses(Activity activity) {
    ReaderApp app = (ReaderApp) activity.getApplication();
    app.io.execute(
        () -> {
          try {
            StringBuilder body = new StringBuilder();
            for (String name : new String[] {"NOTICE.txt", "Apache-2.0.txt"}) {
              try (java.io.BufferedReader in =
                  new java.io.BufferedReader(
                      new java.io.InputStreamReader(
                          activity.getAssets().open("licenses/" + name),
                          java.nio.charset.StandardCharsets.UTF_8))) {
                String line;
                while ((line = in.readLine()) != null) body.append(line).append('\n');
              }
              body.append("\n\n");
            }
            app.main.post(
                () -> {
                  if (activity.isFinishing() || activity.isDestroyed()) return;
                  ScrollView scroll = new ScrollView(activity);
                  TextView text = text(activity, body.toString(), 12, TEXT);
                  text.setTextIsSelectable(true);
                  text.setPadding(
                      dp(activity, 22), dp(activity, 12), dp(activity, 22), dp(activity, 12));
                  scroll.addView(text);
                  new AlertDialog.Builder(activity)
                      .setTitle("开源组件许可")
                      .setView(scroll)
                      .setPositiveButton("完成", null)
                      .show();
                });
          } catch (Exception error) {
            app.main.post(() -> toast(activity, "许可文件暂时无法读取"));
          }
        });
  }

  /** Current catalog page only. Overlay hit area; never subtract a grid column. */
  static final class Rail extends View {
    interface Seek {
      void jump(float value);
    }

    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    float progress;
    boolean active;
    Seek seek;

    Rail(Context c) {
      super(c);
      setHapticFeedbackEnabled(false);
      setContentDescription("当前书库页的滚动位置");
      setFocusable(true);
      setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    void position(float value, boolean scrollable) {
      progress = Math.max(0, Math.min(1, value));
      active = scrollable;
      setVisibility(active ? VISIBLE : INVISIBLE);
      invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
      super.onDraw(canvas);
      if (!active) return;
      float x = getWidth() - dp(getContext(), 6),
          top = dp(getContext(), 12),
          bottom = getHeight() - dp(getContext(), 12),
          size = dp(getContext(), 32);
      paint.setColor(0x55444444);
      paint.setStrokeWidth(dp(getContext(), 2));
      canvas.drawLine(x, top, x, bottom, paint);
      float y = top + (bottom - top - size) * progress;
      paint.setColor(MINT);
      canvas.drawRoundRect(
          x - dp(getContext(), 2), y, x + dp(getContext(), 2), y + size, 5, 5, paint);
    }

    @Override
    public boolean onTouchEvent(android.view.MotionEvent event) {
      if (!active) return false;
      if (event.getActionMasked() == MotionEvent.ACTION_DOWN
          || event.getActionMasked() == MotionEvent.ACTION_MOVE) {
        getParent().requestDisallowInterceptTouchEvent(true);
        float value =
            (event.getY() - dp(getContext(), 28)) / Math.max(1, getHeight() - dp(getContext(), 56));
        progress = Math.max(0, Math.min(1, value));
        if (seek != null) seek.jump(progress);
        invalidate();
        return true;
      }
      if (event.getActionMasked() == MotionEvent.ACTION_UP) {
        performClick();
        getParent().requestDisallowInterceptTouchEvent(false);
      }
      return true;
    }

    @Override
    public boolean performClick() {
      super.performClick();
      return true;
    }

    @Override
    public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
      super.onInitializeAccessibilityNodeInfo(info);
      info.setClassName(SeekBar.class.getName());
      info.setRangeInfo(
          AccessibilityNodeInfo.RangeInfo.obtain(
              AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0, 100, progress * 100));
      info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS);
    }

    @Override
    public boolean performAccessibilityAction(int action, Bundle args) {
      if (action == AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.getId()
          && args != null) {
        progress =
            Math.max(
                0,
                Math.min(
                    1, args.getFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE) / 100));
        if (seek != null) seek.jump(progress);
        invalidate();
        return true;
      }
      return super.performAccessibilityAction(action, args);
    }
  }
}
