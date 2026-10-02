package local.shelf.reader.android;

import android.app.*;
import android.content.*;
import android.database.sqlite.*;
import android.graphics.drawable.AnimatedImageDrawable;
import android.os.*;
import android.test.InstrumentationTestCase;
import android.view.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.*;

/** Uses only the local synthetic fixture server. Not a test against personal books. */
public final class ReaderTests extends InstrumentationTestCase {
  static final String ADDRESS = "http://10.0.2.2:8098";
  private static Api.Session saved;

  ReaderApp app() {
    return (ReaderApp) getInstrumentation().getTargetContext().getApplicationContext();
  }

  Api.Session session() throws Exception {
    if (saved == null) saved = Api.login(ADDRESS, "fixture-pass-123".toCharArray());
    return saved;
  }

  void main(Runnable action) {
    getInstrumentation().runOnMainSync(action);
  }

  interface Condition {
    boolean check();
  }

  void until(String message, Condition condition, long timeout) throws Exception {
    long end = SystemClock.uptimeMillis() + timeout;
    while (SystemClock.uptimeMillis() < end) {
      AtomicBoolean ready = new AtomicBoolean();
      main(() -> ready.set(condition.check()));
      if (ready.get()) return;
      Thread.sleep(30);
    }
    fail(message);
  }

  Models.Catalog catalog(String source, int offset, int size) throws Exception {
    return new Models.Catalog(
        Api.get(session(), source, "/v1/books?offset=" + offset + "&limit=" + size, null).value(),
        source);
  }

  Models.Book first() throws Exception {
    return catalog("eh", 0, 50).books.get(0);
  }

  ReaderActivity reader() throws Exception {
    Api.Session s = session();
    main(
        () -> {
          app().session = s;
          app().verified = true;
        });
    Models.Catalog c = catalog("eh", 0, 50);
    Intent i =
        new Intent(getInstrumentation().getTargetContext(), ReaderActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("book", c.books.get(0).json().toString())
            .putExtra("source", "eh")
            .putExtra("library", c.library);
    ReaderActivity a = (ReaderActivity) getInstrumentation().startActivitySync(i);
    until("reader manifest", () -> a.pages.size() == 5, 10000);
    return a;
  }

  MainActivity home() throws Exception {
    Api.Session s = session();
    app().vault.save(s);
    main(
        () -> {
          app().session = s;
          app().verified = true;
          app()
              .getSharedPreferences("reader-ui", 0)
              .edit()
              .putString("source", "eh")
              .putInt("pageSize", 100)
              .putInt("columns", 3)
              .putBoolean("hiddenCovers", false)
              .commit();
        });
    MainActivity a =
        (MainActivity)
            getInstrumentation()
                .startActivitySync(
                    new Intent(getInstrumentation().getTargetContext(), MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    until("home catalog", () -> a.catalog != null && !a.loading, 15000);
    return a;
  }

  public void test01AuthenticationAndIdentity() throws Exception {
    Api.Session s = session();
    assertEquals(s.device, Api.verify(s).device);
    assertTrue(s.features.contains("manual-library-v1"));
    assertFalse(s.token.contains("fixture"));
    try {
      Api.verify(new Api.Session(s.address, s.device, "z".repeat(32), s.features));
      fail();
    } catch (Api.Problem e) {
      assertEquals(401, e.status);
    }
  }

  public void test02Catalog10073AndLastPage() throws Exception {
    Models.Catalog first = catalog("eh", 0, 500), last = catalog("eh", 10000, 500);
    assertEquals(10073, first.total);
    assertEquals(500, first.books.size());
    assertEquals(73, last.books.size());
    assertEquals("10001", last.books.get(0).id);
    assertEquals(10072, last.books.get(72).rank);
    assertEquals(5, first.books.get(0).count);
  }

  public void test03ManualScopeAndWindowsOrder() throws Exception {
    Models.Catalog eh = catalog("eh", 0, 50), manual = catalog("manual", 0, 50);
    assertEquals(3, manual.total);
    assertEquals("3", manual.books.get(0).id);
    assertFalse(eh.library.equals(manual.library));
    List<Models.Page> mp =
        Models.pages(
            Api.get(session(), "manual", "/v1/books/1/manifest", null).value(),
            "1",
            manual.library);
    List<Models.Page> ep =
        Models.pages(
            Api.get(session(), "eh", "/v1/books/1/manifest", null).value(), "1", eh.library);
    assertEquals(ep.get(2).sha, mp.get(0).sha);
    assertEquals(ep.get(0).sha, mp.get(1).sha);
    assertEquals(ep.get(1).sha, mp.get(2).sha);
  }

  public void test04ConditionalManifestAndCatalog() throws Exception {
    Api.JsonResult one = Api.get(session(), "eh", "/v1/books/1/manifest", null);
    assertNotNull(one.etag());
    assertTrue(Api.get(session(), "eh", "/v1/books/1/manifest", one.etag()).notModified());
    one = Api.get(session(), "eh", "/v1/books?offset=0&limit=100", null);
    assertTrue(Api.get(session(), "eh", "/v1/books?offset=0&limit=100", one.etag()).notModified());
  }

  public void test05AuthorAndSeries() throws Exception {
    for (String kind : List.of("authors", "series")) {
      String flags =
          "?evidence=3&relaxed=1" + (kind.equals("authors") ? "&credit=1&includePossible=1" : "");
      JSONObject options = Api.get(session(), "eh", "/v1/books/1/" + kind + flags, null).value();
      assertTrue(options.getJSONArray("options").length() > 0);
      String selector = options.getJSONArray("options").getJSONObject(0).getString("id");
      JSONObject result =
          Api.get(
                  session(),
                  "eh",
                  "/v1/books/1/" + kind + "/" + selector + flags + "&limit=50",
                  null)
              .value();
      Models.Catalog books = new Models.Catalog(result.getJSONObject("catalog"), "eh");
      assertTrue(books.total >= 3);
      assertEquals("1", books.books.get(0).id);
    }
  }

  public void test06LocateAtomicWindow() throws Exception {
    JSONObject j =
        Api.get(session(), "eh", "/v1/books/window?anchor=5321&offset=0&limit=500", null).value();
    assertEquals(5000, j.getInt("offset"));
    assertEquals("5321", j.getString("anchor"));
    Models.Catalog c = new Models.Catalog(j.getJSONObject("catalog"), "eh");
    assertEquals("5321", c.books.get(320).id);
  }

  public void test07InvalidDataRejected() throws Exception {
    Models.Catalog c = catalog("eh", 0, 50);
    JSONObject j = new JSONObject(c.raw.toString());
    j.getJSONArray("books").put(1, j.getJSONArray("books").getJSONObject(0));
    try {
      new Models.Catalog(j, "eh");
      fail("duplicate allowed");
    } catch (JSONException expected) {
    }
    try {
      new Models.Catalog(c.raw, "manual");
      fail("scope policy");
    } catch (JSONException expected) {
    }
    JSONObject p = Api.get(session(), "eh", "/v1/books/1/manifest", null).value();
    try {
      Models.pages(p, "2", c.library);
      fail("wrong book");
    } catch (JSONException expected) {
    }
  }

  public void test08VaultEncryptedAndRestored() throws Exception {
    Api.Session s = session();
    app().vault.save(s);
    Api.Session read = app().vault.load();
    assertEquals(s.device, read.device);
    assertEquals(s.token, read.token);
    String stored = app().getSharedPreferences("connection", 0).getAll().toString();
    assertFalse(stored.contains(s.token));
    assertFalse(stored.contains("fixture-pass"));
  }

  public void test09ProgressScopesReset() throws Exception {
    Models.Catalog eh = catalog("eh", 0, 50), manual = catalog("manual", 0, 50);
    String one = Rules.scope(session().device, eh.library),
        two = Rules.scope(session().device, manual.library);
    app().store.remember(one, eh.books.get(0), 4, 3, 5);
    app().store.remember(two, manual.books.get(2), 2, 1, 3);
    assertEquals(4, app().store.page(one, "1"));
    assertEquals(2, app().store.page(two, "1"));
    app().store.resetProgress();
    assertNull(app().store.recent(one));
    assertEquals(0, app().store.page(two, "1"));
  }

  public void test10LeasedCacheClearAndCancel() throws Exception {
    Context parent = getInstrumentation().getTargetContext();
    File root = new File(parent.getCacheDir(), "isolated-cache-test");
    root.mkdirs();
    Context isolated =
        new ContextWrapper(parent) {
          @Override
          public File getCacheDir() {
            return root;
          }

          @Override
          public File getDatabasePath(String name) {
            return new File(root, name);
          }

          @Override
          public SQLiteDatabase openOrCreateDatabase(
              String name,
              int mode,
              SQLiteDatabase.CursorFactory factory,
              android.database.DatabaseErrorHandler handler) {
            return SQLiteDatabase.openOrCreateDatabase(
                getDatabasePath(name).getPath(), factory, handler);
          }
        };
    MediaCache cache = new MediaCache(isolated);
    cache.initialize();
    cache.clear();
    String key = Rules.key("lease-test"), ticket = cache.reserve("body", 4);
    try (FileOutputStream f = new FileOutputStream(cache.temporary(ticket))) {
      f.write(new byte[] {1, 2, 3, 4});
    }
    cache.commit(ticket, key, null, 4);
    MediaCache.Lease lease = cache.acquire(key);
    assertNotNull(lease);
    cache.clear();
    assertTrue(lease.file.exists());
    assertNull(cache.acquire(key));
    lease.close();
    assertFalse(lease.file.exists());
    assertEquals(0L, cache.usage(null));
    ticket = cache.reserve("cover", 5);
    File partial = cache.temporary(ticket);
    try (FileOutputStream f = new FileOutputStream(partial)) {
      f.write(1);
    }
    cache.cancel(ticket);
    assertFalse(partial.exists());
    try {
      cache.reserve("body", Rules.MAX_IMAGE + 1L);
      fail();
    } catch (IOException expected) {
    }
    cache.close();
  }

  public void test11StaticGifWebpAndWarmNoAutoplay() throws Exception {
    Models.Catalog c = catalog("eh", 0, 50);
    List<Models.Page> pages =
        Models.pages(
            Api.get(session(), "eh", "/v1/books/1/manifest", null).value(), "1", c.library);
    String scope = Rules.scope(session().device, c.library);
    for (int index : new int[] {0, 1, 2, 4}) {
      CountDownLatch latch = new CountDownLatch(1);
      AtomicReference<MediaPipeline.Decoded> result = new AtomicReference<>();
      AtomicReference<Throwable> error = new AtomicReference<>();
      MediaPipeline.Request r =
          app()
              .media
              .request(
                  MediaPipeline.Asset.page(
                      session(), "eh", scope, "1", pages.get(index), 1080, 2200),
                  0,
                  new MediaPipeline.Callback() {
                    public void ready(MediaPipeline.Decoded value) {
                      result.set(value);
                      latch.countDown();
                    }

                    public void failed(Throwable e) {
                      error.set(e);
                      latch.countDown();
                    }
                  });
      assertTrue("image callback", latch.await(15, TimeUnit.SECONDS));
      if (error.get() != null) throw new AssertionError(error.get());
      MediaPipeline.Decoded image = result.get();
      assertEquals(index != 0, image.animated);
      assertTrue(image.drawable.getIntrinsicWidth() <= 1080);
      assertTrue(image.drawable.getIntrinsicHeight() <= 2200);
      if (image.animated) {
        AnimatedImageDrawable gif = (AnimatedImageDrawable) image.drawable;
        assertFalse(gif.isRunning());
        main(() -> image.playing(true));
        assertTrue(gif.isRunning());
        main(() -> image.playing(false));
        assertFalse(gif.isRunning());
      }
      main(image::close);
      r.close();
    }
  }

  public void test12LibraryUI500PageAndSwitch() throws Exception {
    MainActivity a = home();
    try {
      main(
          () -> {
            a.size = 500;
            a.load(20, null, false);
          });
      until("last page", () -> !a.loading && a.page == 20, 10000);
      assertEquals(73, a.adapter.getItemCount());
      main(() -> a.switchSource("manual"));
      until("manual UI", () -> !a.loading && a.catalog != null && a.catalog.total == 3, 10000);
      assertEquals("manual", a.source);
      String manualScope = a.scope;
      main(() -> a.switchSource("eh"));
      until("eh UI", () -> !a.loading && a.catalog != null && a.catalog.total == 10073, 10000);
      assertFalse(manualScope.equals(a.scope));
      main(
          () -> {
            a.hidden = true;
            a.adapter.submit(a.catalog.books, app().session, a.source, a.scope, true, a.columns);
          });
      getInstrumentation().waitForIdleSync();
      for (BookAdapter.Holder h : new ArrayList<>(a.adapter.bound)) assertNull(h.request);
    } finally {
      main(a::finish);
    }
  }

  public void test13NativePagerSliderAnimationAndBack() throws Exception {
    ReaderActivity a = reader();
    try {
      main(() -> a.jump(1, false));
      until("gif active", () -> a.current == 1 && a.adapter.currentAnimated(), 10000);
      final AtomicReference<AnimatedImageDrawable> old = new AtomicReference<>();
      main(
          () -> {
            for (ReaderActivity.PageHolder h : a.adapter.bound)
              if (h.position == 1) old.set((AnimatedImageDrawable) h.decoded.drawable);
          });
      assertTrue(old.get().isRunning());
      main(() -> a.jump(2, false));
      until("webp active", () -> a.current == 2 && a.adapter.currentAnimated(), 10000);
      assertFalse(old.get().isRunning());
      main(() -> a.play.performClick());
      assertFalse(a.playing);
      main(() -> a.play.performClick());
      assertTrue(a.playing);
      main(() -> a.jump(0, false));
      getInstrumentation().waitForIdleSync();
      swipe(a, .60f, .22f, 110);
      until("short left swipe advances", () -> a.current == 1, 4000);
      main(() -> a.toggle());
      assertFalse(a.controls);
      main(() -> a.toggle());
      assertTrue(a.controls);
      assertTrue(a.adapter.bound.size() <= 5);
    } finally {
      main(a::finish);
    }
  }

  public void test14RapidPagingKeepsBoundedPlayers() throws Exception {
    ReaderActivity a = reader();
    try {
      for (int i = 0; i < 40; i++) {
        int page = i % 5;
        main(() -> a.jump(page, false));
        Thread.sleep(55);
      }
      until("final animation", () -> a.current == 4 && a.adapter.currentAnimated(), 10000);
      main(
          () -> {
            int playing = 0;
            for (ReaderActivity.PageHolder h : a.adapter.bound) {
              if (h.decoded != null
                  && h.decoded.drawable instanceof AnimatedImageDrawable d
                  && d.isRunning()) playing++;
            }
            assertEquals(1, playing);
            assertTrue(a.adapter.bound.size() <= 5);
          });
      assertTrue(app().disk.usage(null) < Rules.COVER_DISK + Rules.BODY_DISK);
    } finally {
      main(a::finish);
    }
  }

  public void test15BackgroundStopsPlayerAndProgressPersists() throws Exception {
    ReaderActivity a = reader();
    main(() -> a.jump(2, false));
    until("animation", () -> a.current == 2 && a.adapter.currentAnimated(), 10000);
    AtomicReference<AnimatedImageDrawable> d = new AtomicReference<>();
    main(
        () -> {
          for (ReaderActivity.PageHolder h : a.adapter.bound)
            if (h.position == 2) d.set((AnimatedImageDrawable) h.decoded.drawable);
          a.finish();
        });
    Thread.sleep(400);
    assertFalse(d.get().isRunning());
    assertEquals(3, app().store.page(a.scope, "1"));
  }

  public void test16SliderTapAndDrag() throws Exception {
    ReaderActivity a = reader();
    try {
      main(() -> a.jump(0, false));
      getInstrumentation().waitForIdleSync();
      int[] pos = new int[2];
      main(() -> a.slider.getLocationOnScreen(pos));
      float x = pos[0] + a.slider.getWidth() * .95f, y = pos[1] + a.slider.getHeight() * .5f;
      touch(x, y);
      until("tap slider to last", () -> a.current == 4, 4000);
      x = pos[0] + a.slider.getWidth() * .04f;
      touch(x, y);
      until("tap slider to first", () -> a.current == 0, 4000);
    } finally {
      main(a::finish);
    }
  }

  public void test17MemoryStressAndOnlyOnePlaying() throws Exception {
    ReaderActivity a = reader();
    try {
      until(
          "first frame",
          () ->
              a.adapter.bound.stream().anyMatch(h -> h.position == a.current && h.decoded != null),
          10000);
      long baseline = Debug.getPss(), peak = baseline;
      for (int i = 0; i < 100; i++) {
        int n = i % 5;
        main(() -> a.jump(n, false));
        Thread.sleep(65);
        if (i % 10 == 0) peak = Math.max(peak, Debug.getPss());
      }
      until("stress last frame", () -> a.current == 4 && a.adapter.currentAnimated(), 10000);
      Thread.sleep(2000);
      long settled = Debug.getPss();
      System.out.println(
          "MEMORY_KIB baseline=" + baseline + " peak=" + peak + " settled=" + settled);
      main(
          () -> {
            int running = 0;
            for (ReaderActivity.PageHolder h : a.adapter.bound)
              if (h.decoded != null
                  && h.decoded.drawable instanceof AnimatedImageDrawable d
                  && d.isRunning()) running++;
            assertEquals(1, running);
          });
    } finally {
      main(a::finish);
    }
  }

  public void test18LibraryRailTracksCurrentPage() throws Exception {
    MainActivity a = home();
    try {
      main(
          () -> {
            a.size = 50;
            a.load(0, null, false);
          });
      until("50 book page", () -> !a.loading && a.adapter.getItemCount() == 50, 10000);
      main(() -> a.rail.seek.jump(1));
      until("rail bottom", () -> a.layout.findLastVisibleItemPosition() == 50, 3000);
      assertEquals(0, a.page);
      main(
          () -> {
            a.size = 500;
            a.load(0, null, false);
          });
      until("500 book page", () -> !a.loading && a.adapter.getItemCount() == 500, 10000);
      main(() -> a.rail.seek.jump(1));
      until("500 bottom", () -> a.layout.findLastVisibleItemPosition() == 500, 3000);
      assertEquals(0, a.page);
    } finally {
      main(a::finish);
    }
  }

  public void test19WrongPasswordRecovers() throws Exception {
    try {
      Api.login(ADDRESS, "not-the-password".toCharArray());
      fail();
    } catch (Api.Problem e) {
      assertEquals(403, e.status);
    }
    assertEquals(session().device, Api.login(ADDRESS, "fixture-pass-123".toCharArray()).device);
  }

  public void test20NativeEdgeBackFromRelatedAndReader() throws Exception {
    MainActivity a = home();
    try {
      main(() -> a.related(a.catalog.books.get(0), "series"));
      until(
          "related result", () -> a.relationBase != null && a.catalog != null && !a.loading, 15000);
      edgeBack(a);
      until(
          "global edge back to shelf",
          () ->
              a.relationBase == null && !a.loading && a.catalog != null && a.catalog.total == 10073,
          5000);
      ReaderActivity r = reader();
      edgeBack(r);
      until("reader edge return", r::isFinishing, 5000);
    } finally {
      main(a::finish);
    }
  }

  public void test21MemoryPressureThenPageRecovery() throws Exception {
    ReaderActivity a = reader();
    try {
      main(
          () -> {
            a.jump(1, false);
            a.onTrimMemory(android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW);
          });
      main(() -> a.jump(2, false));
      until(
          "page recovered after trim", () -> a.current == 2 && a.adapter.currentAnimated(), 10000);
      assertTrue(a.pressure);
      assertEquals(0, a.preloads.size());
    } finally {
      main(a::finish);
    }
  }

  public void test22LruBudgetAndPendingReservationBound() throws Exception {
    Context parent = getInstrumentation().getTargetContext();
    File root = new File(parent.getCacheDir(), "isolated-budget-test");
    root.mkdirs();
    Context isolated =
        new ContextWrapper(parent) {
          @Override
          public File getCacheDir() {
            return root;
          }

          @Override
          public File getDatabasePath(String n) {
            return new File(root, n);
          }

          @Override
          public SQLiteDatabase openOrCreateDatabase(
              String n,
              int m,
              SQLiteDatabase.CursorFactory f,
              android.database.DatabaseErrorHandler h) {
            return SQLiteDatabase.openOrCreateDatabase(getDatabasePath(n).getPath(), f, h);
          }
        };
    MediaCache disk = new MediaCache(isolated);
    disk.initialize();
    disk.clear();
    long length = Rules.MAX_IMAGE;
    for (int i = 0; i < 11; i++) {
      String ticket = disk.reserve("body", length);
      try (RandomAccessFile f = new RandomAccessFile(disk.temporary(ticket), "rw")) {
        f.setLength(length);
      }
      disk.commit(ticket, Rules.key("budget-" + i), null, length);
      assertTrue(disk.usage("body") <= Rules.BODY_DISK);
    }
    assertNull(disk.acquire(Rules.key("budget-0")));
    MediaCache.Lease last = disk.acquire(Rules.key("budget-10"));
    assertNotNull(last);
    last.close();
    disk.clear();
    List<String> reserved = new ArrayList<>();
    try {
      for (int i = 0; i < 9; i++) reserved.add(disk.reserve("body", length));
      try {
        disk.reserve("body", length);
        fail("reservation overflow");
      } catch (IOException expected) {
      }
    } finally {
      for (String ticket : reserved) disk.cancel(ticket);
    }
    assertEquals(0L, disk.usage(null));
    disk.close();
  }

  public void test23WrongContentHashNeverCached() throws Exception {
    Models.Catalog c = catalog("eh", 0, 50);
    Models.Page wrong =
        new Models.Page(
            new JSONObject().put("number", 1).put("size", 1000).put("sha256", "f".repeat(64)));
    MediaPipeline.Asset asset =
        MediaPipeline.Asset.page(
            session(), "eh", Rules.scope(session().device, c.library), "1", wrong, 1080, 2200);
    CountDownLatch latch = new CountDownLatch(1);
    AtomicReference<Throwable> error = new AtomicReference<>();
    MediaPipeline.Request r =
        app()
            .media
            .request(
                asset,
                0,
                new MediaPipeline.Callback() {
                  public void ready(MediaPipeline.Decoded d) {
                    d.close();
                    latch.countDown();
                  }

                  public void failed(Throwable e) {
                    error.set(e);
                    latch.countDown();
                  }
                });
    assertTrue(latch.await(10, TimeUnit.SECONDS));
    assertTrue(error.get() instanceof Api.Problem);
    assertEquals(412, ((Api.Problem) error.get()).status);
    assertNull(app().disk.acquire(asset.key()));
    r.close();
  }

  public void test24LargeNeighborDeferredThenCurrentPlays() throws Exception {
    Models.Catalog c = catalog("eh", 0, 50);
    List<Models.Page> list =
        Models.pages(
            Api.get(session(), "eh", "/v1/books/1/manifest", null).value(), "1", c.library);
    MediaPipeline.Asset asset =
        MediaPipeline.Asset.page(
            session(),
            "eh",
            Rules.scope(session().device, c.library),
            "1",
            list.get(4),
            1440,
            2560);
    for (int priority : new int[] {1, 0}) {
      CountDownLatch latch = new CountDownLatch(1);
      AtomicReference<MediaPipeline.Decoded> result = new AtomicReference<>();
      AtomicReference<Throwable> error = new AtomicReference<>();
      MediaPipeline.Request request =
          app()
              .media
              .request(
                  asset,
                  priority,
                  new MediaPipeline.Callback() {
                    public void ready(MediaPipeline.Decoded d) {
                      result.set(d);
                      latch.countDown();
                    }

                    public void failed(Throwable e) {
                      error.set(e);
                      latch.countDown();
                    }
                  });
      assertTrue(latch.await(10, TimeUnit.SECONDS));
      assertNull(error.get());
      assertEquals(priority == 0, result.get().animated);
      assertEquals(priority == 1, result.get().deferred);
      main(result.get()::close);
      request.close();
    }
  }

  public void test25MetadataRowAndByteCap() throws Exception {
    String body = "x".repeat(1024 * 1024);
    for (int i = 0; i < 28; i++) app().store.snapshot("qa-large-" + i, body, null);
    try (android.database.Cursor c =
        app()
            .store
            .getReadableDatabase()
            .rawQuery("SELECT COUNT(*),SUM(length(CAST(body AS BLOB))) FROM snapshots", null)) {
      assertTrue(c.moveToFirst());
      assertTrue(c.getInt(0) <= 24);
      assertTrue(c.getLong(1) <= 24L * 1024 * 1024);
    }
    app().store.invalidateSnapshots();
  }

  public void test26UnsignedStableIdAndUnknownOrderRejected() throws Exception {
    Models.Book book =
        new Models.Book(
            new JSONObject()
                .put("id", "9999999999999999999")
                .put("title", "Synthetic boundary")
                .put("rank", 0));
    BookAdapter adapter =
        new BookAdapter(
            app(),
            new BookAdapter.Actions() {
              public void open(Models.Book b) {}

              public void more(Models.Book b) {}
            });
    adapter.books.add(book);
    assertEquals(Long.parseUnsignedLong(book.id), adapter.getItemId(0));
    JSONObject catalog = new JSONObject(catalog("eh", 0, 50).raw.toString());
    catalog.put("orderPolicy", "unknown-order");
    try {
      new Models.Catalog(catalog, "eh");
      fail("unknown order accepted");
    } catch (JSONException expected) {
    }
  }

  boolean visible(View view) {
    return view.isAttachedToWindow()
        && view.isShown()
        && view.getGlobalVisibleRect(new android.graphics.Rect());
  }

  int screenY(View view) {
    int[] xy = new int[2];
    view.getLocationOnScreen(xy);
    return xy[1];
  }

  public void test27HeaderScrollsButNavigationStaysFixed() throws Exception {
    MainActivity a = home();
    try {
      Models.Book b = a.catalog.books.get(0);
      app().store.remember(a.scope, b, 3, 2, 5);
      main(
          () -> {
            a.loadRecent();
            a.scrollToBook(0);
          });
      until(
          "recent card at top",
          () ->
              visible(a.continueBox)
                  && a.continueBox.getChildCount() == 1
                  && visible(a.layoutButton),
          5000);
      int[] fixed = new int[3];
      main(
          () -> {
            fixed[0] = screenY(a.heading);
            fixed[1] = screenY(a.segments);
            fixed[2] = screenY(a.pageLabel);
            assertTrue(((View) a.heading.getParent()).getHeight() <= Ui.dp(a, 48));
            assertEquals(Ui.dp(a, 48), a.segments.getHeight());
            assertTrue(a.eh.getHeight() >= Ui.dp(a, 48));
            assertTrue(a.manual.getHeight() >= Ui.dp(a, 48));
            View settings = ((android.widget.LinearLayout) a.heading.getParent()).getChildAt(1);
            assertTrue(settings.getWidth() >= Ui.dp(a, 48));
            a.grid.scrollBy(0, a.grid.getHeight());
          });
      until(
          "controls scroll completely away",
          () -> !visible(a.layoutButton) && !visible(a.continueBox),
          3000);
      main(
          () -> {
            assertEquals(fixed[0], screenY(a.heading));
            assertEquals(fixed[1], screenY(a.segments));
            assertEquals(fixed[2], screenY(a.pageLabel));
            assertTrue(visible(a.eh));
            assertTrue(visible(a.next));
            a.rail.seek.jump(0);
          });
      until(
          "controls return at top", () -> visible(a.layoutButton) && visible(a.continueBox), 3000);
    } finally {
      main(a::finish);
    }
  }

  public void test28FullSpanHeaderRecycleAndColumnSwitch() throws Exception {
    MainActivity a = home();
    try {
      for (int count : new int[] {2, 3}) {
        main(
            () -> {
              a.columns = count;
              a.layout.setSpanCount(count);
              a.adapter.submit(a.catalog.books, app().session, a.source, a.scope, a.hidden, count);
              a.scrollToBook(0);
            });
        until("header measured", () -> visible(a.layoutButton), 3000);
        main(
            () -> {
              assertEquals(
                  a.grid.getWidth() - a.grid.getPaddingLeft() - a.grid.getPaddingRight(),
                  a.libraryHeader.getWidth());
              assertEquals(count, a.layout.getSpanSizeLookup().getSpanSize(0));
              for (int p = 1; p <= count; p++) {
                View v = a.layout.findViewByPosition(p);
                assertNotNull(v);
                assertEquals(a.layout.findViewByPosition(1).getTop(), v.getTop());
              }
            });
        for (int n = 0; n < 3; n++) {
          main(() -> a.rail.seek.jump(1));
          until("header offscreen", () -> !visible(a.layoutButton), 3000);
          main(
              () -> {
                a.grid.getRecycledViewPool().clear();
                a.loadRecent();
                a.scrollToBook(0);
              });
          until("recycled header returns", () -> visible(a.layoutButton), 3000);
          main(() -> assertEquals(3, a.libraryHeader.getChildCount()));
        }
      }
    } finally {
      main(a::finish);
    }
  }

  public void test29ScrollAnchorUsesBookNotHeaderIndex() throws Exception {
    MainActivity a = home();
    try {
      main(() -> a.scrollToBook(33));
      until("middle row", () -> a.layout.findFirstVisibleItemPosition() > 1, 3000);
      AtomicReference<String> expected = new AtomicReference<>();
      main(
          () -> {
            int global = a.layout.findFirstVisibleItemPosition();
            androidx.recyclerview.widget.RecyclerView.ViewHolder h =
                a.grid.findViewHolderForAdapterPosition(global);
            assertNotNull(h);
            assertSame(a.adapter, h.getBindingAdapter());
            int local = h.getBindingAdapterPosition();
            assertEquals(global - 1, local);
            expected.set(a.adapter.books.get(local).id);
            a.savePosition();
          });
      until(
          "stored real book anchor",
          () -> expected.get().equals(app().store.position(app().session.device + ":eh").anchor()),
          5000);
      main(() -> a.locate(a.catalog.books.get(33)));
      until(
          "locate middle book",
          () -> !a.loading && a.catalog != null && a.layout.findFirstVisibleItemPosition() > 1,
          10000);
      main(
          () -> {
            int pos = a.layout.findFirstVisibleItemPosition();
            assertEquals(33, a.bookIndex(pos));
            a.scrollToBook(0);
          });
      until("first book includes controls", () -> visible(a.layoutButton), 3000);
    } finally {
      main(a::finish);
    }
  }

  public void test30DiagnosticsAgainstCandidateNasBothLibraries() throws Exception {
    Api.Session before = session();
    app().vault.save(before);
    for (String source : List.of("eh", "manual")) {
      Diagnostics.Report report = Diagnostics.run(before.address, before, source);
      assertEquals(source, "当前书库连接正常", report.summary);
      assertEquals("0.1.18-dev", report.version);
      assertEquals(8, report.steps.size());
      for (String secret : List.of(before.address, before.device, before.token, "Journey", "Manual Story"))
        assertFalse(report.text().contains(secret));
    }
    Api.Session after = app().vault.load();
    assertEquals(before.address, after.address); assertEquals(before.device, after.device); assertEquals(before.token, after.token);
  }

  void edgeBack(Activity a) {
    int width = a.getResources().getDisplayMetrics().widthPixels,
        height = a.getResources().getDisplayMetrics().heightPixels;
    long down = SystemClock.uptimeMillis();
    for (int i = 0; i <= 12; i++) {
      int action =
          i == 0
              ? MotionEvent.ACTION_DOWN
              : i == 12 ? MotionEvent.ACTION_UP : MotionEvent.ACTION_MOVE;
      MotionEvent e =
          MotionEvent.obtain(
              down, down + i * 20, action, 2 + (width * .40f) * i / 12, height * .52f, 0);
      e.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
      getInstrumentation().getUiAutomation().injectInputEvent(e, true);
      e.recycle();
      SystemClock.sleep(20);
    }
  }

  void touch(float x, float y) {
    long now = SystemClock.uptimeMillis();
    MotionEvent down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0),
        up = MotionEvent.obtain(now, now + 90, MotionEvent.ACTION_UP, x, y, 0);
    getInstrumentation().sendPointerSync(down);
    SystemClock.sleep(90);
    getInstrumentation().sendPointerSync(up);
    down.recycle();
    up.recycle();
  }

  void swipe(ReaderActivity a, float from, float to, long duration) {
    int[] location = new int[2];
    main(() -> a.pager.getLocationOnScreen(location));
    float x1 = location[0] + a.pager.getWidth() * from,
        x2 = location[0] + a.pager.getWidth() * to,
        y = location[1] + a.pager.getHeight() * .5f;
    long down = SystemClock.uptimeMillis();
    for (int i = 0; i <= 10; i++) {
      int action =
          i == 0
              ? MotionEvent.ACTION_DOWN
              : i == 10 ? MotionEvent.ACTION_UP : MotionEvent.ACTION_MOVE;
      MotionEvent e =
          MotionEvent.obtain(down, down + duration * i / 10, action, x1 + (x2 - x1) * i / 10, y, 0);
      getInstrumentation().sendPointerSync(e);
      e.recycle();
      if (i < 10) SystemClock.sleep(duration / 10);
    }
  }
}
