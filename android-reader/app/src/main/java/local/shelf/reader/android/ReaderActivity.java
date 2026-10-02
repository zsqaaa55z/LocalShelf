package local.shelf.reader.android;

import android.app.*;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import androidx.recyclerview.widget.RecyclerView;
import androidx.viewpager2.widget.ViewPager2;
import java.util.*;
import org.json.*;

/** Native horizontal pager: images never own a competing pan or tap-to-turn recognizer. */
public final class ReaderActivity extends Activity {
  ReaderApp app;
  Models.Book book;
  String source, library, scope;
  List<Models.Page> pages = List.of();
  ViewPager2 pager;
  PageAdapter adapter;
  FrameLayout root;
  LinearLayout top, bottom;
  TextView counter, previous, next, play, state;
  SeekBar slider;
  boolean controls = true, resumed, playing = true, dragging, pressure;
  int current, direction = 1, restoredNumber;
  long generation;
  final Map<Integer, MediaPipeline.Request> preloads = new HashMap<>();
  boolean refreshingAfterChange;

  @Override
  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    app = (ReaderApp) getApplication();
    try {
      book = new Models.Book(new JSONObject(getIntent().getStringExtra("book")));
      source = getIntent().getStringExtra("source");
      library = getIntent().getStringExtra("library");
      if (!List.of("eh", "manual").contains(source)
          || !Rules.hash(library)
          || app.session == null
          || !app.verified) throw new Exception();
      scope = Rules.scope(app.session.device, library);
    } catch (Exception e) {
      Ui.toast(this, "连接已失效，请返回书库重新连接");
      finish();
      return;
    }
    root = new FrameLayout(this);
    root.setBackgroundColor(Ui.BG);
    setContentView(root);
    Ui.inset(this, root);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    Ui.back(this, this::finish);
    pager = new ViewPager2(this);
    pager.setOrientation(ViewPager2.ORIENTATION_HORIZONTAL);
    pager.setOffscreenPageLimit(1);
    pager.setLayoutDirection(View.LAYOUT_DIRECTION_LTR);
    pager.setHapticFeedbackEnabled(false);
    pager.setContentDescription("漫画阅读，左右滑动翻页");
    RecyclerView recycler = (RecyclerView) pager.getChildAt(0);
    recycler.setItemAnimator(null);
    recycler.setItemViewCacheSize(0);
    recycler.setOverScrollMode(View.OVER_SCROLL_NEVER);
    adapter = new PageAdapter();
    pager.setAdapter(adapter);
    root.addView(pager, new FrameLayout.LayoutParams(-1, -1));
    buildControls();
    pager.registerOnPageChangeCallback(
        new ViewPager2.OnPageChangeCallback() {
          @Override
          public void onPageSelected(int position) {
            direction = position < current ? -1 : 1;
            current = position;
            update();
            record(false);
            prefetch();
            adapter.playVisible();
          }

          @Override
          public void onPageScrollStateChanged(int state) {
            if (state == ViewPager2.SCROLL_STATE_IDLE) adapter.playVisible();
          }
        });
    if (saved != null) {
      restoredNumber = saved.getInt("pageNumber", 0);
      playing = saved.getBoolean("playing", true);
      if (!saved.getBoolean("controls", true)) toggle();
    }
    loadManifest(false);
  }

  void buildControls() {
    top = Ui.row(this);
    top.setPadding(Ui.dp(this, 6), Ui.dp(this, 4), Ui.dp(this, 6), Ui.dp(this, 4));
    top.setBackground(Ui.shape(0xee151515, 18, this));
    top.addView(
        Ui.button(this, "‹", this::finish),
        new LinearLayout.LayoutParams(Ui.dp(this, 48), Ui.dp(this, 48)));
    TextView title = Ui.text(this, book.title, 14, Ui.TEXT);
    title.setMaxLines(1);
    title.setEllipsize(TextUtils.TruncateAt.END);
    top.addView(title, Ui.weight());
    top.addView(
        Ui.button(this, "⋯", this::menu),
        new LinearLayout.LayoutParams(Ui.dp(this, 48), Ui.dp(this, 48)));
    FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
    tp.setMargins(Ui.dp(this, 12), Ui.dp(this, 8), Ui.dp(this, 12), 0);
    root.addView(top, tp);
    bottom = Ui.column(this);
    bottom.setPadding(Ui.dp(this, 12), Ui.dp(this, 8), Ui.dp(this, 12), Ui.dp(this, 8));
    bottom.setBackground(Ui.shape(0xf2151515, 18, this));
    slider = new SeekBar(this);
    slider.setHapticFeedbackEnabled(false);
    slider.setContentDescription("漫画页码进度，点击或拖动跳转");
    bottom.addView(slider, new LinearLayout.LayoutParams(-1, Ui.dp(this, 44)));
    slider.setOnSeekBarChangeListener(
        new SeekBar.OnSeekBarChangeListener() {
          public void onStartTrackingTouch(SeekBar s) {
            dragging = true;
          }

          public void onProgressChanged(SeekBar s, int value, boolean user) {
            if (user) counter.setText((value + 1) + " / " + pages.size() + " ⌃");
          }

          public void onStopTrackingTouch(SeekBar s) {
            dragging = false;
            jump(s.getProgress(), false);
          }
        });
    LinearLayout buttons = Ui.row(this);
    previous = Ui.button(this, "‹ 上一页", () -> jump(current - 1, true));
    next = Ui.button(this, "下一页 ›", () -> jump(current + 1, true));
    counter = Ui.button(this, "0 / 0 ⌃", this::jumpDialog);
    counter.setTextSize(15);
    play =
        Ui.button(
            this,
            "Ⅱ",
            () -> {
              playing = !playing;
              adapter.playVisible();
              update();
            });
    play.setContentDescription("暂停或播放动图");
    buttons.addView(previous, Ui.weight());
    buttons.addView(counter, Ui.weight());
    buttons.addView(play, new LinearLayout.LayoutParams(Ui.dp(this, 44), Ui.dp(this, 48)));
    buttons.addView(next, Ui.weight());
    bottom.addView(buttons);
    state = Ui.text(this, "正在读取页码…", 12, Ui.MUTED);
    state.setPadding(Ui.dp(this, 4), 0, Ui.dp(this, 4), Ui.dp(this, 4));
    state.setMaxLines(3);
    state.setOnClickListener(v -> loadManifest(true));
    bottom.addView(state);
    FrameLayout.LayoutParams bp = new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM);
    bp.setMargins(Ui.dp(this, 12), 0, Ui.dp(this, 12), Ui.dp(this, 10));
    root.addView(bottom, bp);
    update();
  }

  void loadManifest(boolean force) {
    long g = ++generation;
    state.setText("正在核对页码…");
    state.setVisibility(View.VISIBLE);
    Api.Session s = app.session;
    int oldNumber =
        pages.isEmpty() ? restoredNumber : pages.get(Rules.clamp(current, pages.size())).number;
    app.io.execute(
        () -> {
          try {
            String key = scope + ":manifest:" + book.id;
            LocalStore.Snapshot saved = force ? null : app.store.snapshot(key);
            Api.JsonResult response =
                Api.get(
                    s,
                    source,
                    "/v1/books/" + book.id + "/manifest",
                    saved == null ? null : saved.etag());
            JSONObject value =
                response.notModified() && saved != null
                    ? new JSONObject(saved.body())
                    : response.value();
            if (value == null) throw new JSONException("manifest");
            List<Models.Page> list = Models.pages(value, book.id, library);
            if (list.isEmpty()) throw new Api.Problem(404, "这本漫画还没有可读取的页面");
            int number = oldNumber > 0 ? oldNumber : app.store.page(scope, book.id);
            int selected = 0;
            for (int i = 0; i < list.size(); i++)
              if (list.get(i).number == number) {
                selected = i;
                break;
              }
            app.store.snapshot(
                key,
                value.toString(),
                response.etag() != null ? response.etag() : saved == null ? null : saved.etag());
            int start = selected;
            app.main.post(
                () -> {
                  if (g != generation || isFinishing() || isDestroyed()) return;
                  clearPreloads();
                  adapter.release();
                  pages = list;
                  current = start;
                  adapter.notifyDataSetChanged();
                  pager.setCurrentItem(start, false);
                  state.setText("");
                  state.setVisibility(View.GONE);
                  update();
                  record(false);
                  pager.post(
                      () -> {
                        prefetch();
                        adapter.playVisible();
                      });
                });
          } catch (Throwable error) {
            app.main.post(
                () -> {
                  if (g != generation || isFinishing()) return;
                  state.setText(Models.error(error) + " · 轻点重试");
                  state.setVisibility(View.VISIBLE);
                });
          }
        });
  }

  void update() {
    int count = pages.size();
    slider.setMax(Math.max(0, count - 1));
    slider.setEnabled(count > 1);
    if (!dragging) {
      slider.setProgress(current);
      counter.setText((count == 0 ? 0 : current + 1) + " / " + count + " ⌃");
    }
    Ui.enabled(previous, current > 0 && count > 0);
    Ui.enabled(next, current + 1 < count);
    Ui.enabled(counter, count > 0);
    play.setText(playing ? "Ⅱ" : "▶");
    boolean animated = adapter != null && adapter.currentAnimated();
    play.setVisibility(animated ? View.VISIBLE : View.GONE);
  }

  void jump(int position, boolean animate) {
    if (pages.isEmpty() || position < 0 || position >= pages.size()) return;
    pager.setCurrentItem(position, animate);
  }

  void jumpDialog() {
    if (pages.isEmpty()) return;
    EditText edit = new EditText(this);
    edit.setInputType(InputType.TYPE_CLASS_NUMBER);
    edit.setSingleLine();
    edit.setText(Integer.toString(current + 1));
    edit.selectAll();
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("跳转页码 · 共 " + pages.size() + " 张")
            .setView(edit)
            .setNegativeButton("取消", null)
            .setPositiveButton("跳转", null)
            .create();
    dialog.setOnShowListener(
        d -> {
          dialog
              .getButton(-1)
              .setOnClickListener(
                  v -> {
                    int n = Rules.jump(edit.getText().toString(), pages.size());
                    if (n < 0) {
                      edit.setError("请输入 1–" + pages.size());
                      return;
                    }
                    dialog.dismiss();
                    jump(n, false);
                  });
        });
    dialog.show();
    edit.requestFocus();
    dialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE);
  }

  void menu() {
    new AlertDialog.Builder(this)
        .setTitle(book.title)
        .setItems(
            new String[] {controls ? "隐藏阅读工具栏" : "显示阅读工具栏", "刷新页面信息", "从第一页开始"},
            (d, i) -> {
              if (i == 0) toggle();
              else if (i == 1) {
                refreshingAfterChange = false;
                loadManifest(true);
              } else jump(0, false);
            })
        .setNegativeButton("取消", null)
        .show();
  }

  void toggle() {
    controls = !controls;
    top.setVisibility(controls ? View.VISIBLE : View.GONE);
    bottom.setVisibility(
        controls
            ? View.VISIBLE
            : View.GONE); /* Keep stable content bounds, even when controls disappear. */
  }

  MediaPipeline.Asset asset(int position) {
    android.util.DisplayMetrics m = getResources().getDisplayMetrics();
    return MediaPipeline.Asset.page(
        app.session, source, scope, book.id, pages.get(position), m.widthPixels, m.heightPixels);
  }

  void prefetch() {
    if (!resumed || pages.isEmpty()) return;
    Set<Integer> desired = new HashSet<>();
    for (int n : Rules.nearby(current, pages.size(), direction, pressure))
      if (n != current) desired.add(n);
    for (int n : new ArrayList<>(preloads.keySet()))
      if (!desired.contains(n)) {
        preloads.remove(n).close();
      }
    for (int n : desired)
      if (!preloads.containsKey(n)) preloads.put(n, app.media.prefetch(asset(n)));
  }

  void clearPreloads() {
    for (MediaPipeline.Request r : preloads.values()) r.close();
    preloads.clear();
  }

  void record(boolean flush) {
    if (pages.isEmpty()) return;
    int p = Rules.clamp(current, pages.size());
    app.remember(scope, book, pages.get(p).number, p, pages.size(), flush);
  }

  @Override
  protected void onResume() {
    super.onResume();
    resumed = true;
    if (adapter != null) {
      prefetch();
      adapter.playVisible();
    }
  }

  @Override
  protected void onPause() {
    resumed = false;
    record(true);
    clearPreloads();
    if (adapter != null) adapter.playVisible();
    super.onPause();
  }

  @Override
  protected void onDestroy() {
    generation++;
    clearPreloads();
    if (adapter != null) adapter.release();
    super.onDestroy();
  }

  @Override
  protected void onSaveInstanceState(Bundle state) {
    super.onSaveInstanceState(state);
    if (!pages.isEmpty())
      state.putInt("pageNumber", pages.get(Rules.clamp(current, pages.size())).number);
    state.putBoolean("controls", controls);
    state.putBoolean("playing", playing);
  }

  @Override
  public void onTrimMemory(int level) {
    super.onTrimMemory(level);
    if (level >= TRIM_MEMORY_RUNNING_LOW) {
      pressure = true;
      clearPreloads();
      if (adapter != null)
        for (PageHolder h : new ArrayList<>(adapter.bound)) if (h.position != current) h.release();
    }
  }

  final class PageAdapter extends RecyclerView.Adapter<PageHolder> {
    final Set<PageHolder> bound = new HashSet<>();

    @Override
    public PageHolder onCreateViewHolder(ViewGroup parent, int type) {
      return new PageHolder();
    }

    @Override
    public void onBindViewHolder(PageHolder holder, int position) {
      holder.bind(position);
      bound.add(holder);
    }

    @Override
    public void onViewAttachedToWindow(PageHolder holder) {
      holder.attached = true;
      holder.active();
    }

    @Override
    public void onViewDetachedFromWindow(PageHolder holder) {
      holder.attached = false;
      holder.active();
    }

    @Override
    public void onViewRecycled(PageHolder holder) {
      holder.release();
      bound.remove(holder);
    }

    @Override
    public int getItemCount() {
      return pages.size();
    }

    void release() {
      for (PageHolder h : new ArrayList<>(bound)) h.release();
      bound.clear();
    }

    void playVisible() {
      for (PageHolder h : bound) h.active();
      update();
    }

    boolean currentAnimated() {
      for (PageHolder h : bound)
        if (h.position == current && h.decoded != null) return h.decoded.animated;
      return false;
    }
  }

  final class PageHolder extends RecyclerView.ViewHolder {
    final ImageView image;
    final TextView message;
    MediaPipeline.Decoded decoded;
    MediaPipeline.Request request;
    int position = -1, ticket;
    boolean attached, upgrading;

    PageHolder() {
      super(new FrameLayout(ReaderActivity.this));
      FrameLayout frame = (FrameLayout) itemView;
      frame.setLayoutParams(new RecyclerView.LayoutParams(-1, -1));
      frame.setBackgroundColor(Ui.BG);
      frame.setHapticFeedbackEnabled(false);
      image = new ImageView(ReaderActivity.this);
      image.setScaleType(ImageView.ScaleType.FIT_CENTER);
      image.setAdjustViewBounds(false);
      image.setHapticFeedbackEnabled(false);
      frame.addView(image, new FrameLayout.LayoutParams(-1, -1));
      image.setOnClickListener(v -> toggle());
      message = Ui.text(ReaderActivity.this, "", 14, Ui.MUTED);
      message.setGravity(Gravity.CENTER);
      message.setPadding(Ui.dp(ReaderActivity.this, 24), 0, Ui.dp(ReaderActivity.this, 24), 0);
      frame.addView(
          message,
          new FrameLayout.LayoutParams(-1, Ui.dp(ReaderActivity.this, 160), Gravity.CENTER));
      message.setOnClickListener(
          v -> {
            if (position >= 0) bind(position);
          });
    }

    void bind(int index) {
      boolean retainPreview = position == index && decoded != null && decoded.deferred;
      if (retainPreview) {
        ticket++;
        if (request != null) request.close();
        request = null;
        decoded.playing(false);
      } else release();
      upgrading = retainPreview;
      position = index;
      int token = ++ticket;
      message.setText(retainPreview ? "" : "正在载入…");
      message.setVisibility(retainPreview ? View.GONE : View.VISIBLE);
      image.setContentDescription("第 " + (index + 1) + " 张");
      request =
          app.media.request(
              asset(index),
              index == current ? 0 : 1,
              new MediaPipeline.Callback() {
                public void ready(MediaPipeline.Decoded value) {
                  if (token != ticket || isDestroyed()) {
                    value.close();
                    return;
                  }
                  MediaPipeline.Decoded old = decoded;
                  decoded = value;
                  upgrading = false;
                  image.setImageDrawable(value.drawable);
                  if (old != null) old.close();
                  message.setText("");
                  message.setVisibility(View.GONE);
                  active();
                  update();
                }

                public void failed(Throwable error) {
                  if (token != ticket) return;
                  upgrading = false;
                  message.setText(Models.error(error) + "\n轻点重试");
                  message.setVisibility(View.VISIBLE);
                  if (error instanceof Api.Problem p && p.status == 412 && !refreshingAfterChange) {
                    refreshingAfterChange = true;
                    loadManifest(true);
                  }
                }
              });
    }

    void active() {
      if (decoded != null) {
        if (resumed && attached && position == current && decoded.deferred && !upgrading) {
          bind(position);
          return;
        }
        decoded.playing(resumed && attached && position == current && playing);
        if (position == current) {
          state.setText(decoded.warning);
          state.setVisibility(decoded.warning.isEmpty() ? View.GONE : View.VISIBLE);
        }
      } else if (resumed && attached && position == current && request == null) bind(position);
    }

    void release() {
      ticket++;
      upgrading = false;
      if (request != null) {
        request.close();
        request = null;
      }
      image.setImageDrawable(null);
      if (decoded != null) {
        decoded.close();
        decoded = null;
      }
    }
  }
}
