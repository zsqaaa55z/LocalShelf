package local.shelf.reader.android;

import android.app.*;
import android.content.*;
import android.os.*;
import android.text.InputType;
import android.text.TextUtils;
import android.view.*;
import android.widget.*;
import androidx.recyclerview.widget.*;
import java.util.*;
import org.json.*;

public final class MainActivity extends Activity implements BookAdapter.Actions {
  ReaderApp app;
  SharedPreferences prefs;
  LinearLayout root, segments, toolbar, continueBox, libraryHeader;
  TextView heading, status, eh, manual, layoutButton, previous, next, pageLabel;
  RecyclerView grid;
  GridLayoutManager layout;
  BookAdapter adapter;
  Ui.Rail rail;
  Models.Catalog catalog;
  String source = "eh", scope;
  int page, size = 100, columns = 3;
  boolean hidden, loading, booted;
  boolean diagnosing;
  java.util.concurrent.Future<?> diagnosticTask;
  long generation;
  String relationBase, relationLabel;
  int originalPage, originalScroll;
  String originalAnchor = "";

  @Override
  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    app = (ReaderApp) getApplication();
    prefs = getSharedPreferences("reader-ui", MODE_PRIVATE);
    source = prefs.getString("source", "eh");
    if (!source.equals("manual")) source = "eh";
    size = prefs.getInt("pageSize", 100);
    if (size < 50 || size > 500 || size % 50 != 0) size = 100;
    columns = prefs.getInt("columns", 3) == 2 ? 2 : 3;
    hidden = prefs.getBoolean("hiddenCovers", false);
    build();
    Ui.back(this, this::goBack);
    boot();
  }

  void build() {
    root = Ui.column(this);
    root.setBackgroundColor(Ui.BG);
    setContentView(root);
    Ui.inset(this, root);
    LinearLayout title = Ui.row(this);
    title.setPadding(Ui.dp(this, 18), 0, Ui.dp(this, 14), 0);
    heading = Ui.text(this, "LocalShelf", 20, Ui.TEXT);
    heading.setTypeface(null, android.graphics.Typeface.BOLD);
    title.addView(heading, Ui.weight());
    title.addView(compactButton("设置", this::settings));
    root.addView(title);
    segments = Ui.row(this);
    segments.setPadding(Ui.dp(this, 18), 0, Ui.dp(this, 18), 0);
    eh = compactButton("Eh 同步", () -> switchSource("eh"));
    manual = compactButton("手动上传", () -> switchSource("manual"));
    segments.addView(eh, Ui.weight());
    LinearLayout.LayoutParams gap = new LinearLayout.LayoutParams(Ui.dp(this, 8), 1);
    segments.addView(new View(this), gap);
    segments.addView(manual, Ui.weight());
    root.addView(segments);
    libraryHeader = Ui.column(this);
    toolbar = Ui.row(this);
    toolbar.setPadding(Ui.dp(this, 6), 0, Ui.dp(this, 6), 0);
    layoutButton = Ui.button(this, "", this::layoutOptions);
    toolbar.addView(layoutButton, Ui.weight());
    toolbar.addView(Ui.button(this, "刷新", () -> load(page, null, true)));
    libraryHeader.addView(toolbar);
    status = Ui.text(this, "正在准备书库…", 12, Ui.MUTED);
    status.setPadding(Ui.dp(this, 6), Ui.dp(this, 4), Ui.dp(this, 6), Ui.dp(this, 6));
    status.setMaxLines(3);
    status.setOnClickListener(
        v -> {
          if (app.session == null) connect();
          else load(page, null, true);
        });
    libraryHeader.addView(status);
    continueBox = Ui.column(this);
    continueBox.setPadding(Ui.dp(this, 6), 0, Ui.dp(this, 6), Ui.dp(this, 8));
    continueBox.setVisibility(View.GONE);
    libraryHeader.addView(continueBox);
    FrameLayout stage = new FrameLayout(this);
    grid = new RecyclerView(this);
    grid.setId(View.generateViewId());
    grid.setContentDescription("漫画书库");
    grid.setBackgroundColor(Ui.BG);
    grid.setPadding(Ui.dp(this, 12), 0, Ui.dp(this, 12), Ui.dp(this, 8));
    grid.setClipToPadding(false);
    layout = new GridLayoutManager(this, columns);
    layout.setSpanSizeLookup(
        new GridLayoutManager.SpanSizeLookup() {
          @Override
          public int getSpanSize(int position) {
            return position == 0 ? columns : 1;
          }
        });
    layout.setUsingSpansToEstimateScrollbarDimensions(true);
    layout.setInitialPrefetchItemCount(columns);
    grid.setLayoutManager(layout);
    grid.setItemAnimator(null);
    grid.setItemViewCacheSize(columns);
    grid.setHasFixedSize(true);
    grid.setHapticFeedbackEnabled(false);
    adapter = new BookAdapter(app, this);
    grid.setAdapter(
        new ConcatAdapter(
            new ConcatAdapter.Config.Builder()
                .setStableIdMode(ConcatAdapter.Config.StableIdMode.ISOLATED_STABLE_IDS)
                .build(),
            new LibraryHeaderAdapter(libraryHeader),
            adapter));
    stage.addView(grid, new FrameLayout.LayoutParams(-1, -1));
    rail = new Ui.Rail(this);
    rail.seek =
        f -> {
          int rows = (adapter.getItemCount() + columns - 1) / columns,
              visible =
                  Math.max(
                      1,
                      (bookIndex(layout.findLastVisibleItemPosition())
                              - bookIndex(layout.findFirstVisibleItemPosition())
                              + columns)
                          / columns);
          int row = Math.round(f * Math.max(0, rows - visible));
          scrollToBook(Rules.clamp(row * columns, adapter.getItemCount()));
          if (f > .99f) grid.post(() -> grid.scrollBy(0, Integer.MAX_VALUE));
        };
    stage.addView(rail, new FrameLayout.LayoutParams(Ui.dp(this, 24), -1, Gravity.RIGHT));
    root.addView(stage, new LinearLayout.LayoutParams(-1, 0, 1));
    grid.addOnScrollListener(
        new RecyclerView.OnScrollListener() {
          @Override
          public void onScrolled(RecyclerView r, int dx, int dy) {
            updateRail();
          }
        });
    LinearLayout bottom = Ui.row(this);
    bottom.setPadding(Ui.dp(this, 10), Ui.dp(this, 6), Ui.dp(this, 10), Ui.dp(this, 8));
    bottom.setBackgroundColor(Ui.SURFACE);
    previous = Ui.button(this, "‹ 上一页", () -> load(page - 1, null, false));
    pageLabel = Ui.button(this, "1 / 1 页 ⌄", this::pageMenu);
    next = Ui.button(this, "下一页 ›", () -> load(page + 1, null, false));
    bottom.addView(previous, Ui.weight());
    bottom.addView(pageLabel, new LinearLayout.LayoutParams(0, -2, 1.1f));
    bottom.addView(next, Ui.weight());
    root.addView(bottom);
    updateChrome();
  }

  TextView compactButton(String text, Runnable action) {
    TextView button = Ui.button(this, text, action);
    button.setTextSize(14);
    // Slim visual pill, while retaining the original 48 dp touch target.
    button.setBackground(
        new android.graphics.drawable.InsetDrawable(
            Ui.shape(Ui.SURFACE, 10, this), 0, Ui.dp(this, 6), 0, Ui.dp(this, 6)));
    button.setMinWidth(Ui.dp(this, 48));
    button.setPadding(Ui.dp(this, 10), 0, Ui.dp(this, 10), 0);
    return button;
  }

  int bookIndex(int gridPosition) {
    return Rules.clamp(gridPosition - 1, adapter.getItemCount());
  }

  void scrollToBook(int index) {
    // The first book shares the top destination with the scrolling controls.
    layout.scrollToPositionWithOffset(index <= 0 ? 0 : index + 1, 0);
  }

  void boot() {
    long g = ++generation;
    app.io.execute(
        () -> {
          try {
            Api.Session s = app.session != null ? app.session : app.vault.load();
            LocalStore.Position p =
                s == null
                    ? new LocalStore.Position("", 0)
                    : app.store.position(s.device + ":" + source);
            app.main.post(
                () -> {
                  if (!alive(g)) return;
                  app.session = s;
                  booted = true;
                  if (s == null) {
                    status.setText("连接 NAS 阅读服务，开始浏览你的书库");
                    connect();
                    return;
                  }
                  page = p.page();
                  load(page, p.anchor().isEmpty() ? null : p.anchor(), true);
                });
          } catch (Exception e) {
            app.main.post(
                () -> {
                  if (alive(g)) {
                    booted = true;
                    status.setText("已保存的连接无法读取，请重新连接");
                    connect();
                  }
                });
          }
        });
  }

  boolean alive(long g) {
    return !isFinishing() && !isDestroyed() && g == generation;
  }

  void switchSource(String target) {
    if (source.equals(target) || loading) return;
    savePosition();
    relationBase = null;
    relationLabel = null;
    source = target;
    prefs.edit().putString("source", source).apply();
    catalog = null;
    scope = null;
    continueBox.setVisibility(View.GONE);
    adapter.submit(List.of(), app.session, source, null, hidden, columns);
    updateChrome();
    if (app.session == null) {
      connect();
      return;
    }
    long g = ++generation;
    Api.Session s = app.session;
    app.io.execute(
        () -> {
          LocalStore.Position p = app.store.position(s.device + ":" + target);
          app.main.post(
              () -> {
                if (alive(g)) load(p.page(), p.anchor().isEmpty() ? null : p.anchor(), true);
              });
        });
  }

  void load(int requested, String anchor, boolean refresh) {
    if (!booted || loading) return;
    if (app.session == null) {
      connect();
      return;
    }
    requested = Math.max(0, requested);
    if (catalog != null && anchor == null && !refresh)
      requested = Math.min(requested, Rules.pageCount(catalog.total, size) - 1);
    final int target = requested, limit = size;
    final String selected = source, base = relationBase;
    final Api.Session session = app.session;
    final long g = ++generation;
    loading = true;
    status.setText(catalog == null ? "正在连接书库…" : "正在更新…");
    updateChrome();
    String path =
        base != null
            ? base + "&offset=" + (target * limit) + "&limit=" + limit
            : "/v1/books/window?anchor="
                + (anchor == null ? "" : anchor)
                + "&offset="
                + (target * limit)
                + "&limit="
                + limit;
    String key = session.device + ":" + selected + ":" + path;
    app.io.execute(
        () -> {
          try {
            LocalStore.Snapshot saved = app.store.snapshot(key);
            LocalStore.Snapshot previewSaved = saved;
            if (previewSaved == null && base == null)
              previewSaved =
                  app.store.snapshot(session.device + ":" + selected + ":latest:" + limit);
            if (previewSaved != null && catalog == null) {
              JSONObject j = new JSONObject(previewSaved.body());
              Models.Catalog preview = parseCatalog(j, selected);
              int p = j.has("offset") ? j.getInt("offset") / limit : target;
              app.main.post(
                  () -> {
                    if (alive(g)) {
                      display(preview, p, selected, session, false);
                      status.setText("已显示上次书库，正在确认连接…");
                    }
                  });
            }
            Api.Session verified = app.verified && !refresh ? session : Api.verify(session);
            Api.JsonResult response =
                Api.get(verified, selected, path, saved == null ? null : saved.etag());
            JSONObject body =
                response.notModified() && saved != null
                    ? new JSONObject(saved.body())
                    : response.value();
            if (body == null) throw new JSONException("empty reply");
            Models.Catalog result = parseCatalog(body, selected);
            int actual = body.has("offset") ? body.getInt("offset") / limit : target;
            if (actual < 0 || actual >= Rules.pageCount(result.total, limit))
              throw new JSONException("wrong page");
            if (base == null
                && result.books.size()
                    != Math.min(limit, Math.max(0, result.total - actual * limit)))
              throw new JSONException("partial catalog");
            applyNotes(body, result);
            app.store.snapshot(
                key,
                body.toString(),
                response.etag() != null ? response.etag() : saved == null ? null : saved.etag());
            if (base == null)
              app.store.snapshot(
                  session.device + ":" + selected + ":latest:" + limit, body.toString(), null);
            app.main.post(
                () -> {
                  if (!alive(g)) return;
                  app.session = verified;
                  app.verified = true;
                  loading = false;
                  display(result, actual, selected, verified, true);
                  if (anchor != null)
                    for (int i = 0; i < result.books.size(); i++)
                      if (result.books.get(i).id.equals(anchor)) {
                        scrollToBook(i);
                        break;
                      }
                  status.setText(
                      result.total == 0
                          ? "这里还没有漫画，请通过 Windows 上传端导入"
                          : "已连接 · "
                              + (base == null
                                  ? (selected.equals("manual")
                                      ? "手动书库 · 按导入顺序"
                                      : "Eh 同步书库 · 保留下载顺序")
                                  : "相关作品 · 保留书库顺序"));
                  grid.postOnAnimation(this::savePosition);
                  loadRecent();
                });
          } catch (Throwable error) {
            app.main.post(
                () -> {
                  if (!alive(g)) return;
                  loading = false;
                  if (error instanceof Api.Problem p && p.status == 401) app.verified = false;
                  status.setText(Models.error(error) + " · 轻点重试");
                  updateChrome();
                });
          }
        });
  }

  static Models.Catalog parseCatalog(JSONObject value, String source) throws JSONException {
    return new Models.Catalog(
        value.has("catalog") ? value.getJSONObject("catalog") : value, source);
  }

  static void applyNotes(JSONObject json, Models.Catalog c) {
    JSONArray ids = json.optJSONArray("possibleBookIDs");
    Set<String> possible = new HashSet<>();
    if (ids != null) for (int i = 0; i < ids.length(); i++) possible.add(ids.optString(i));
    JSONObject notes = json.optJSONObject("matchNotes"), parts = json.optJSONObject("partLabels");
    for (Models.Book b : c.books) {
      if (possible.contains(b.id)) b.note = UiNote(notes, b.id);
      if (parts != null && !parts.optString(b.id).isEmpty())
        b.note = (b.note.isEmpty() ? "" : b.note + " · ") + parts.optString(b.id);
    }
  }

  static String UiNote(JSONObject notes, String id) {
    if (notes == null) return "可能匹配";
    Object note = notes.opt(id);
    return note instanceof String ? Models.note((String) note) : "可能匹配";
  }

  void display(Models.Catalog result, int actual, String selected, Api.Session s, boolean online) {
    catalog = result;
    page = actual;
    scope = Rules.scope(s.device, result.library);
    adapter.submit(result.books, s, selected, scope, hidden, columns);
    layout.scrollToPositionWithOffset(0, 0);
    updateChrome();
    grid.post(this::updateRail);
  }

  void updateChrome() {
    eh.setTextColor(source.equals("eh") ? Ui.MINT : Ui.MUTED);
    manual.setTextColor(source.equals("manual") ? Ui.MINT : Ui.MUTED);
    eh.setEnabled(!loading);
    manual.setEnabled(!loading);
    segments.setVisibility(relationBase == null ? View.VISIBLE : View.GONE);
    heading.setText(
        relationBase != null
            ? "‹ " + relationLabel
            : catalog == null
                ? "LocalShelf"
                : "书库 · " + String.format(Locale.ROOT, "%,d", catalog.total) + " 本");
    heading.setMaxLines(1);
    heading.setEllipsize(TextUtils.TruncateAt.END);
    heading.setOnClickListener(
        v -> {
          if (relationBase != null) goBack();
        });
    layoutButton.setText(columns + " 列 · " + size + " 本 / 页");
    int pages = catalog == null ? 1 : Rules.pageCount(catalog.total, size);
    pageLabel.setText((page + 1) + " / " + pages + " 页 ⌄");
    Ui.enabled(previous, !loading && page > 0);
    Ui.enabled(next, !loading && page + 1 < pages);
    Ui.enabled(pageLabel, !loading && catalog != null);
  }

  void updateRail() {
    int range = grid.computeVerticalScrollRange() - grid.computeVerticalScrollExtent();
    rail.position(range <= 0 ? 0 : (float) grid.computeVerticalScrollOffset() / range, range > 0);
  }

  void pageMenu() {
    if (catalog == null) return;
    int pages = Rules.pageCount(catalog.total, size);
    String[] choices = new String[pages];
    for (int i = 0; i < pages; i++) choices[i] = "第 " + (pages - i) + " 页";
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("跳转页码")
            .setSingleChoiceItems(
                choices,
                pages - page - 1,
                (d, index) -> {
                  d.dismiss();
                  load(pages - index - 1, null, false);
                })
            .setNegativeButton("取消", null)
            .create();
    dialog.show();
    dialog.getListView().setHapticFeedbackEnabled(false);
    dialog.getListView().setSelection(pages - page - 1);
  }

  void layoutOptions() {
    if (loading) {
      Ui.toast(this, "书库正在更新，请稍候");
      return;
    }
    new AlertDialog.Builder(this)
        .setTitle("书库布局")
        .setItems(
            new String[] {"2 列封面", "3 列封面", "每页显示数量"},
            (d, n) -> {
              if (n == 2) chooseSize();
              else {
                columns = n + 2;
                prefs.edit().putInt("columns", columns).apply();
                layout.setSpanCount(columns);
                grid.setItemViewCacheSize(columns);
                if (catalog != null)
                  adapter.submit(catalog.books, app.session, source, scope, hidden, columns);
                updateChrome();
              }
            })
        .show();
  }

  void chooseSize() {
    String[] values = new String[10];
    for (int i = 0; i < 10; i++) values[i] = (i + 1) * 50 + " 本";
    new AlertDialog.Builder(this)
        .setTitle("每页漫画数量")
        .setSingleChoiceItems(
            values,
            size / 50 - 1,
            (d, i) -> {
              d.dismiss();
              int anchorOffset = page * size;
              size = (i + 1) * 50;
              prefs.edit().putInt("pageSize", size).apply();
              load(anchorOffset / size, null, false);
            })
        .setNegativeButton("取消", null)
        .show();
  }

  @Override
  public void open(Models.Book book) {
    if (!app.verified) {
      Ui.toast(this, "请先确认 NAS 连接");
      load(page, null, true);
      return;
    }
    if (!book.available) {
      Ui.toast(this, "这本漫画的本地文件暂时缺失");
      return;
    }
    savePosition();
    Intent intent = new Intent(this, ReaderActivity.class);
    intent.putExtra("book", book.json().toString());
    intent.putExtra("source", source);
    intent.putExtra("library", catalog.library);
    startActivity(intent);
  }

  @Override
  public void more(Models.Book book) {
    if (loading) return;
    String[] choices =
        relationBase == null
            ? new String[] {"查看同作者漫画", "查看同系列作品"}
            : new String[] {"查看同作者漫画", "查看同系列作品", "定位到书库原位置"};
    new AlertDialog.Builder(this)
        .setTitle(book.title)
        .setItems(
            choices,
            (d, i) -> {
              if (i == 2) locate(book);
              else related(book, i == 0 ? "authors" : "series");
            })
        .setNegativeButton("取消", null)
        .show();
  }

  void related(Models.Book book, String kind) {
    if (!app.verified || app.session == null) {
      Ui.toast(this, "请先连接 NAS");
      return;
    }
    Api.Session s = app.session;
    String selected = source, library = catalog.library;
    long g = ++generation;
    status.setText("正在查找相关作品…");
    String flags =
        "?evidence=3&relaxed=1" + (kind.equals("authors") ? "&credit=1&includePossible=1" : "");
    String path = "/v1/books/" + book.id + "/" + kind;
    app.io.execute(
        () -> {
          try {
            JSONObject json = Api.get(s, selected, path + flags, null).value();
            if (!library.equals(json.getString("libraryId")))
              throw new JSONException("wrong library");
            JSONArray options = json.getJSONArray("options");
            if (options.length() > 256) throw new JSONException("too many options");
            String[] labels = new String[options.length()];
            for (int i = 0; i < labels.length; i++) {
              JSONObject o = options.getJSONObject(i);
              if (!Rules.hash(o.getString("id"))) throw new JSONException("selector");
              labels[i] = o.getString("name") + " · " + o.getInt("count") + " 本";
            }
            app.main.post(
                () -> {
                  if (!alive(g)) return;
                  status.setText("相关作品由标题署名识别，可能匹配会标注");
                  if (labels.length == 0) {
                    Ui.toast(this, "没有找到可关联的" + (kind.equals("authors") ? "作者" : "系列"));
                    return;
                  }
                  java.util.function.IntConsumer choose =
                      index -> {
                        try {
                          if (relationBase == null) {
                            originalPage = page;
                            originalScroll = bookIndex(layout.findFirstVisibleItemPosition());
                            originalAnchor =
                                originalScroll < adapter.books.size()
                                    ? adapter.books.get(originalScroll).id
                                    : "";
                          }
                          relationBase =
                              path + "/" + options.getJSONObject(index).getString("id") + flags;
                          relationLabel = options.getJSONObject(index).getString("name");
                          catalog = null;
                          continueBox.setVisibility(View.GONE);
                          load(0, null, false);
                        } catch (JSONException e) {
                          Ui.toast(this, "关联结果已变化，请重试");
                        }
                      };
                  if (labels.length == 1) choose.accept(0);
                  else
                    new AlertDialog.Builder(this)
                        .setTitle(kind.equals("authors") ? "选择作者 / 署名" : "选择系列")
                        .setItems(labels, (d, i) -> choose.accept(i))
                        .setNegativeButton("取消", null)
                        .show();
                });
          } catch (Throwable e) {
            app.main.post(
                () -> {
                  if (alive(g)) {
                    status.setText(Models.error(e));
                    loading = false;
                    updateChrome();
                  }
                });
          }
        });
  }

  void locate(Models.Book book) {
    relationBase = null;
    relationLabel = null;
    catalog = null;
    load(0, book.id, true);
  }

  void goBack() {
    if (relationBase != null) {
      generation++;
      loading = false;
      relationBase = null;
      relationLabel = null;
      catalog = null;
      load(originalPage, originalAnchor.isEmpty() ? null : originalAnchor, true);
    } else finish();
  }

  // API 33+ uses Ui.back's OnBackInvokedDispatcher. This is the API 31/32 fallback.
  @android.annotation.SuppressLint("GestureBackNavigation")
  @Override
  public void onBackPressed() {
    goBack();
  }

  void loadRecent() {
    if (scope == null || relationBase != null) {
      continueBox.setVisibility(View.GONE);
      return;
    }
    String wanted = scope;
    long g = generation;
    app.io.execute(
        () -> {
          LocalStore.Recent recent = app.store.recent(wanted);
          app.main.post(
              () -> {
                if (!alive(g) || !wanted.equals(scope) || relationBase != null) return;
                continueBox.removeAllViews();
                continueBox.setVisibility(recent == null ? View.GONE : View.VISIBLE);
                if (recent == null) return;
                LinearLayout row = Ui.row(this);
                TextView label =
                    Ui.button(
                        this,
                        "继续阅读 · "
                            + (recent.position() + 1)
                            + " / "
                            + recent.count()
                            + "\n"
                            + recent.book().title,
                        () -> open(recent.book()));
                label.setTextSize(13);
                label.setMaxLines(2);
                label.setEllipsize(TextUtils.TruncateAt.END);
                label.setGravity(Gravity.CENTER_VERTICAL);
                row.addView(label, Ui.weight());
                TextView find = Ui.button(this, "定位", () -> locate(recent.book()));
                row.addView(find);
                continueBox.addView(row);
              });
        });
  }

  void savePosition() {
    if (app.session == null || relationBase != null || catalog == null || catalog.books.isEmpty())
      return;
    int first = bookIndex(layout.findFirstVisibleItemPosition());
    String id = catalog.books.get(first).id, key = app.session.device + ":" + source;
    int current = page;
    app.io.execute(() -> app.store.position(key, id, current));
  }

  @Override
  protected void onResume() {
    super.onResume();
    if (booted) loadRecent();
  }

  @Override
  protected void onPause() {
    savePosition();
    super.onPause();
  }

  @Override
  protected void onDestroy() {
    if (diagnosticTask != null) diagnosticTask.cancel(true);
    generation++;
    adapter.release();
    super.onDestroy();
  }

  void diagnose() {
    if (diagnosing) return;
    diagnosing = true;
    TextView result = Ui.text(this, "正在只读检查…\n不会尝试密码、扫描图片或自动重启。", 14, Ui.TEXT);
    result.setPadding(Ui.dp(this, 20), Ui.dp(this, 16), Ui.dp(this, 20), Ui.dp(this, 16));
    result.setTextIsSelectable(true);
    ScrollView scroll = new ScrollView(this); scroll.addView(result);
    AlertDialog dialog = new AlertDialog.Builder(this).setTitle("连接诊断").setView(scroll)
        .setPositiveButton("关闭", null).setNeutralButton("复制脱敏摘要", null).create();
    final String[] summary = {null};
    dialog.setOnDismissListener(v -> { diagnosing = false; if (diagnosticTask != null) diagnosticTask.cancel(true); });
    dialog.setOnShowListener(v -> {
      dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(false);
      dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(button -> {
        if (summary[0] != null) {
          ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("LocalShelf 诊断", summary[0]));
          Ui.toast(this, "已复制脱敏摘要");
        }
      });
    });
    dialog.show();
    final String targetSource = source, address = app.vault.address();
    final Api.Session active = app.session;
    diagnosticTask = app.io.submit(() -> {
      Api.Session saved = active;
      if (saved == null) { try { saved = app.vault.load(); } catch (Exception ignored) {} }
      // A newly verified session may precede the persisted address update.
      Diagnostics.Report report = Diagnostics.run(saved != null ? saved.address : address, saved, targetSource);
      if (Thread.currentThread().isInterrupted()) return;
      app.main.post(() -> {
        if (isFinishing() || isDestroyed() || !dialog.isShowing()) return;
        summary[0] = report.text(); result.setText(summary[0]);
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(true);
      });
    });
  }

  void settings() {
    LinearLayout box = Ui.column(this);
    box.setPadding(Ui.dp(this, 20), Ui.dp(this, 8), Ui.dp(this, 20), Ui.dp(this, 20));
    ScrollView scroll = new ScrollView(this);
    scroll.addView(box);
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("设置")
            .setView(scroll)
            .setPositiveButton("完成", null)
            .create();
    box.addView(Ui.text(this, "隐私显示", 14, Ui.MUTED));
    CheckBox covers = new CheckBox(this);
    covers.setText("隐藏所有封面");
    covers.setTextColor(Ui.TEXT);
    covers.setChecked(hidden);
    covers.setHapticFeedbackEnabled(false);
    covers.setOnCheckedChangeListener(
        (v, on) -> {
          hidden = on;
          prefs.edit().putBoolean("hiddenCovers", on).apply();
          if (catalog != null)
            adapter.submit(catalog.books, app.session, source, scope, hidden, columns);
        });
    box.addView(covers);
    TextView help = Ui.text(this, "仅隐藏封面并停止其加载；保留标题与正文阅读。", 12, Ui.MUTED);
    help.setPadding(0, 0, 0, Ui.dp(this, 16));
    box.addView(help);
    box.addView(
        Ui.button(
            this,
            "书库布局与每页数量",
            () -> {
              dialog.dismiss();
              layoutOptions();
            }));
    box.addView(
        Ui.button(
            this,
            "连接 / 更换 NAS",
            () -> {
              dialog.dismiss();
              connect();
            }));
    box.addView(Ui.button(this, "一键连接诊断", () -> { dialog.dismiss(); diagnose(); }));
    box.addView(
        Ui.button(
            this,
            "重新连接",
            () -> {
              dialog.dismiss();
              app.verified = false;
              load(page, null, true);
            }));
    TextView cache = Ui.text(this, "图片缓存 · 计算中…", 13, Ui.MUTED);
    cache.setPadding(0, Ui.dp(this, 20), 0, Ui.dp(this, 8));
    box.addView(cache);
    app.io.execute(
        () -> {
          long bytes = app.disk.usage(null);
          app.main.post(() -> cache.setText("图片缓存 " + Ui.bytes(bytes) + " / 2 GB"));
        });
    box.addView(
        Ui.button(
            this,
            "清理图片缓存",
            () ->
                Ui.confirm(
                    this,
                    "清理图片缓存",
                    "不删除 NAS 文件、阅读进度或配对信息。",
                    () -> {
                      adapter.release();
                      app.media.cancelAll();
                      app.io.execute(
                          () -> {
                            try {
                              app.disk.clear();
                              app.main.post(
                                  () -> {
                                    cache.setText("缓存已清理");
                                    if (catalog != null)
                                      adapter.submit(
                                          catalog.books,
                                          app.session,
                                          source,
                                          scope,
                                          hidden,
                                          columns);
                                  });
                            } catch (Exception e) {
                              app.main.post(() -> Ui.toast(this, "缓存清理失败，请稍后重试"));
                            }
                          });
                    })));
    box.addView(
        Ui.button(
            this,
            "重置所有阅读进度",
            () ->
                Ui.confirm(
                    this,
                    "重置阅读进度",
                    "清除两套书库在此设备的阅读位置和继续阅读入口，不改变漫画顺序。",
                    () -> {
                      app.records.execute(
                          () -> {
                            app.store.resetProgress();
                            app.main.post(
                                () -> {
                                  loadRecent();
                                  Ui.toast(this, "阅读进度已重置");
                                });
                          });
                    })));
    box.addView(
        Ui.button(
            this,
            "解除本机连接",
            () ->
                Ui.confirm(
                    this,
                    "解除连接",
                    "只清除本机连接凭据，NAS 与其他设备不受影响。",
                    () -> {
                      generation++;
                      app.forget();
                      catalog = null;
                      scope = null;
                      loading = false;
                      relationBase = null;
                      adapter.submit(List.of(), null, source, null, hidden, columns);
                      continueBox.setVisibility(View.GONE);
                      status.setText("已解除连接");
                      updateChrome();
                      dialog.dismiss();
                    })));
    TextView about =
        Ui.text(
            this,
            "LocalShelf 阅读 "
                + BuildConfig.VERSION_NAME
                + "\n"
                + "Android 原生自用版 · 局域网只读\n"
                + "封面缓存 1.5 GB + 正文缓存 0.5 GB\n"
                + "AndroidX RecyclerView / ViewPager2（Apache 2.0）\n"
                + "图片不会上传，阅读记录只在本机保存。",
            12,
            Ui.MUTED);
    about.setPadding(0, Ui.dp(this, 20), 0, 0);
    box.addView(about);
    box.addView(Ui.button(this, "开源组件许可", () -> Ui.licenses(this)));
    dialog.show();
  }

  void connect() {
    LinearLayout box = Ui.column(this);
    box.setPadding(Ui.dp(this, 22), Ui.dp(this, 8), Ui.dp(this, 22), 0);
    EditText address = new EditText(this);
    address.setSingleLine();
    address.setTextColor(Ui.TEXT);
    address.setHint("NAS 阅读地址（包含端口）");
    address.setText(app.session == null ? app.vault.address() : app.session.address);
    address.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
    address.setAutofillHints((String[]) null);
    box.addView(address);
    EditText password = new EditText(this);
    password.setSingleLine();
    password.setTextColor(Ui.TEXT);
    password.setHint("NAS 阅读密码");
    password.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    password.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
    box.addView(password);
    TextView message =
        Ui.text(this, "与 Windows 上传端填写的阅读地址、密码相同。\n连接成功后自动记住设备，无须每次输入。", 13, Ui.MUTED);
    message.setPadding(0, Ui.dp(this, 10), 0, Ui.dp(this, 12));
    box.addView(message);
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("连接 NAS")
            .setView(box)
            .setNegativeButton("稍后", null)
            .setPositiveButton("连接", null)
            .create();
    dialog.setOnDismissListener(d -> password.setText(""));
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener(
                    v -> {
                      String target;
                      try {
                        target = Rules.address(address.getText().toString());
                      } catch (Exception e) {
                        message.setText(e.getMessage());
                        return;
                      }
                      char[] secret = password.getText().toString().toCharArray();
                      password.setText("");
                      message.setText("正在验证连接…");
                      dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
                      long g = ++generation;
                      loading = false;
                      updateChrome();
                      app.io.execute(
                          () -> {
                            try {
                              Api.Session session = Api.login(target, secret);
                              app.main.post(
                                  () -> {
                                    if (!alive(g) || !dialog.isShowing()) return;
                                    app.media.cancelAll();
                                    app.session = session;
                                    app.verified = true;
                                    app.persist(session);
                                    catalog = null;
                                    scope = null;
                                    page = 0;
                                    relationBase = null;
                                    loading = false;
                                    dialog.dismiss();
                                    load(0, null, true);
                                  });
                            } catch (Throwable e) {
                              Arrays.fill(secret, '\0');
                              app.main.post(
                                  () -> {
                                    if (alive(g) && dialog.isShowing()) {
                                      dialog
                                          .getButton(AlertDialog.BUTTON_POSITIVE)
                                          .setEnabled(true);
                                      message.setText(Models.error(e));
                                    }
                                  });
                            }
                          });
                    }));
    dialog.show();
  }
}
