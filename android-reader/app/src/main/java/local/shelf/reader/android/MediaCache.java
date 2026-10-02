package local.shelf.reader.android;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import java.io.*;
import java.util.*;

/** Bounded disk LRU. Active animation files are leased until the player releases them. */
final class MediaCache extends SQLiteOpenHelper {
  final File directory;
  private final Map<String, Integer> pins = new HashMap<>();
  private final Map<String, Long> reservations = new HashMap<>();
  private boolean initialized;
  private final java.util.concurrent.ExecutorService releases =
      java.util.concurrent.Executors.newSingleThreadExecutor(
          r -> {
            Thread t = new Thread(r, "shelf-cache-release");
            t.setDaemon(true);
            return t;
          });

  MediaCache(Context context) {
    super(context, "media-cache.db", null, 1);
    directory = new File(context.getCacheDir(), "media-v1");
    setWriteAheadLoggingEnabled(true);
  }

  @Override
  public void onCreate(SQLiteDatabase db) {
    db.execSQL(
        "CREATE TABLE entries(path TEXT PRIMARY KEY,k TEXT NOT NULL,kind TEXT NOT NULL,size INTEGER"
            + " NOT NULL,etag TEXT,used INTEGER NOT NULL,active INTEGER NOT NULL)");
    db.execSQL("CREATE INDEX entries_key ON entries(k,active)");
    db.execSQL("CREATE INDEX entries_lru ON entries(kind,used)");
  }

  @Override
  public void onUpgrade(SQLiteDatabase db, int old, int next) {
    throw new IllegalStateException("unsupported cache version");
  }

  synchronized void initialize() throws IOException {
    if (initialized) return;
    if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("cache directory");
    SQLiteDatabase db = getWritableDatabase();
    Set<String> known = new HashSet<>();
    try (Cursor c = db.rawQuery("SELECT path,active FROM entries", null)) {
      while (c.moveToNext()) {
        String name = c.getString(0);
        if (!safe(name) || !new File(directory, name).isFile() || c.getInt(1) == 0) {
          if (safe(name)) new File(directory, name).delete();
          db.delete("entries", "path=?", new String[] {name});
        } else known.add(name);
      }
    }
    File[] files = directory.listFiles();
    if (files != null)
      for (File f : files)
        if ((safe(f.getName()) || f.getName().matches("[a-f0-9]{32}\\.part"))
            && !known.contains(f.getName())) f.delete();
    initialized = true;
  }

  private static boolean safe(String name) {
    return name != null && name.matches("[a-f0-9]{32}\\.bin");
  }

  final class Lease implements AutoCloseable {
    final File file;
    final String etag;
    final long size;
    private boolean closed;

    Lease(String name, String etag, long size) {
      file = new File(directory, name);
      this.etag = etag;
      this.size = size;
      pins.merge(name, 1, Integer::sum);
    }

    @Override
    public void close() {
      synchronized (this) {
        if (closed) return;
        closed = true;
      }
      // Releasing a recycled player must not wait for SQLite or a disk eviction on the UI thread.
      if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        releases.execute(() -> releaseLease(file.getName()));
      else releaseLease(file.getName());
    }
  }

  private synchronized void releaseLease(String name) {
    int count = pins.getOrDefault(name, 1) - 1;
    if (count > 0) pins.put(name, count);
    else {
      pins.remove(name);
      try (Cursor c =
          getReadableDatabase()
              .rawQuery("SELECT active FROM entries WHERE path=?", new String[] {name})) {
        if (c.moveToFirst() && c.getInt(0) == 0) remove(name);
      }
    }
  }

  synchronized Lease acquire(String key) throws IOException {
    initialize();
    SQLiteDatabase db = getWritableDatabase();
    try (Cursor c =
        db.rawQuery(
            "SELECT path,etag,size,used FROM entries WHERE k=? AND active=1 ORDER BY used DESC"
                + " LIMIT 1",
            new String[] {key})) {
      if (!c.moveToFirst()) return null;
      String name = c.getString(0);
      File file = new File(directory, name);
      if (!safe(name) || !file.isFile() || file.length() != c.getLong(2)) {
        remove(name);
        return null;
      }
      // Immutable media identities are still age-limited to 30 days.
      if (System.currentTimeMillis() - c.getLong(3) > 30L * 86400000 && !pins.containsKey(name)) {
        remove(name);
        return null;
      }
      ContentValues v = new ContentValues();
      v.put("used", System.currentTimeMillis());
      db.update("entries", v, "path=?", new String[] {name});
      return new Lease(name, c.getString(1), c.getLong(2));
    }
  }

  synchronized String reserve(String kind, long size) throws IOException {
    initialize();
    long budget = kind.equals("cover") ? Rules.COVER_DISK : Rules.BODY_DISK;
    if (size < 1 || size > Rules.MAX_IMAGE) throw new IOException("image bound");
    long reserved = 0;
    for (Map.Entry<String, Long> entry : reservations.entrySet())
      if (entry.getKey().startsWith(kind + ":")) reserved += entry.getValue();
    long used = usage(kind);
    List<String> victims = new ArrayList<>();
    try (Cursor c =
        getReadableDatabase()
            .rawQuery(
                "SELECT path,size FROM entries WHERE kind=? ORDER BY active ASC,used ASC",
                new String[] {kind})) {
      while (used + reserved + size > budget && c.moveToNext()) {
        if (pins.containsKey(c.getString(0))) continue;
        victims.add(c.getString(0));
        used -= c.getLong(1);
      }
    }
    for (String victim : victims) remove(victim);
    used = usage(kind);
    if (used + reserved + size > budget || directory.getUsableSpace() < size + 128L * 1024 * 1024)
      throw new Api.Problem(0, "设备缓存空间不足，请清理缓存或释放存储空间");
    String id = kind + ":" + UUID.randomUUID().toString().replace("-", "");
    reservations.put(id, size);
    return id;
  }

  synchronized File temporary(String ticket) {
    if (!reservations.containsKey(ticket)) throw new IllegalStateException("expired reservation");
    return new File(directory, ticket.substring(ticket.indexOf(':') + 1) + ".part");
  }

  synchronized void cancel(String ticket) {
    if (ticket == null) return;
    File file = temporaryIfValid(ticket);
    reservations.remove(ticket);
    if (file != null) file.delete();
  }

  private File temporaryIfValid(String ticket) {
    return reservations.containsKey(ticket)
        ? new File(directory, ticket.substring(ticket.indexOf(':') + 1) + ".part")
        : null;
  }

  synchronized void commit(String ticket, String key, String etag, long size) throws IOException {
    Long reserved = reservations.get(ticket);
    if (reserved == null || size > reserved || size < 1) throw new IOException("cache reservation");
    File temporary = temporary(ticket);
    String name = ticket.substring(ticket.indexOf(':') + 1) + ".bin";
    File destination = new File(directory, name);
    if (temporary.length() != size || !temporary.renameTo(destination))
      throw new IOException("cache commit");
    SQLiteDatabase db = getWritableDatabase();
    db.beginTransaction();
    boolean committed = false;
    try {
      ContentValues inactive = new ContentValues();
      inactive.put("active", 0);
      db.update("entries", inactive, "k=?", new String[] {key});
      ContentValues v = new ContentValues();
      v.put("path", name);
      v.put("k", key);
      v.put("kind", ticket.substring(0, ticket.indexOf(':')));
      v.put("size", size);
      v.put("etag", etag);
      v.put("used", System.currentTimeMillis());
      v.put("active", 1);
      db.insertOrThrow("entries", null, v);
      db.setTransactionSuccessful();
      committed = true;
    } finally {
      db.endTransaction();
      reservations.remove(ticket);
      if (!committed) destination.delete();
    }
    removeRetired();
  }

  private void removeRetired() {
    List<String> remove = new ArrayList<>();
    try (Cursor c =
        getReadableDatabase().rawQuery("SELECT path FROM entries WHERE active=0", null)) {
      while (c.moveToNext()) if (!pins.containsKey(c.getString(0))) remove.add(c.getString(0));
    }
    for (String name : remove) remove(name);
  }

  private void remove(String name) {
    if (!safe(name)) return;
    File file = new File(directory, name);
    if (!file.exists() || file.delete())
      getWritableDatabase().delete("entries", "path=?", new String[] {name});
  }

  synchronized long usage(String kind) {
    try (Cursor c =
        getReadableDatabase()
            .rawQuery(
                "SELECT COALESCE(SUM(size),0) FROM entries" + (kind == null ? "" : " WHERE kind=?"),
                kind == null ? null : new String[] {kind})) {
      c.moveToFirst();
      return c.getLong(0);
    }
  }

  synchronized long clear() throws IOException {
    initialize();
    long before = usage(null);
    ContentValues v = new ContentValues();
    v.put("active", 0);
    getWritableDatabase().update("entries", v, null, null);
    removeRetired();
    return before - usage(null);
  }
}
