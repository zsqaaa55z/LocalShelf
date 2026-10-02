package local.shelf.reader.android;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import org.json.*;

/** Small metadata and progress database, independent from disposable image files. */
final class LocalStore extends SQLiteOpenHelper {
  record Snapshot(String body, String etag, long time) {}

  record Position(String anchor, int page) {}

  record Recent(Models.Book book, int number, int position, int count) {}

  LocalStore(Context context) {
    super(context, "reading.db", null, 1);
    setWriteAheadLoggingEnabled(true);
  }

  @Override
  public void onCreate(SQLiteDatabase db) {
    db.execSQL(
        "CREATE TABLE snapshots(k TEXT PRIMARY KEY,body TEXT NOT NULL,etag TEXT,received INTEGER"
            + " NOT NULL)");
    db.execSQL(
        "CREATE TABLE progress(scope TEXT,id TEXT,body TEXT,number INTEGER,position INTEGER,count"
            + " INTEGER,used INTEGER,PRIMARY KEY(scope,id))");
    db.execSQL("CREATE TABLE positions(k TEXT PRIMARY KEY,anchor TEXT,page INTEGER)");
  }

  @Override
  public void onUpgrade(SQLiteDatabase db, int old, int next) {
    throw new IllegalStateException("unsupported database upgrade");
  }

  synchronized Snapshot snapshot(String key) {
    try (Cursor c =
        getReadableDatabase()
            .rawQuery("SELECT body,etag,received FROM snapshots WHERE k=?", new String[] {key})) {
      return c.moveToFirst() ? new Snapshot(c.getString(0), c.getString(1), c.getLong(2)) : null;
    }
  }

  synchronized void snapshot(String key, String body, String etag) {
    if (body.length() > Rules.MAX_JSON) return;
    ContentValues v = new ContentValues();
    v.put("k", key);
    v.put("body", body);
    v.put("etag", etag);
    v.put("received", System.currentTimeMillis());
    SQLiteDatabase db = getWritableDatabase();
    db.insertWithOnConflict("snapshots", null, v, SQLiteDatabase.CONFLICT_REPLACE);
    db.execSQL(
        "DELETE FROM snapshots WHERE k NOT IN (SELECT k FROM snapshots ORDER BY received DESC LIMIT"
            + " 24)");
    // Cap serialized metadata as well as row count. Image cache is separate.
    long bytes = 0;
    java.util.List<String> expired = new java.util.ArrayList<>();
    try (Cursor c =
        db.rawQuery(
            "SELECT k,length(CAST(body AS BLOB)) FROM snapshots ORDER BY received DESC", null)) {
      while (c.moveToNext()) {
        bytes += c.getLong(1);
        if (bytes > 24L * 1024 * 1024) expired.add(c.getString(0));
      }
    }
    for (String old : expired) db.delete("snapshots", "k=?", new String[] {old});
  }

  synchronized void invalidateSnapshots() {
    getWritableDatabase().delete("snapshots", null, null);
  }

  synchronized Position position(String key) {
    try (Cursor c =
        getReadableDatabase()
            .rawQuery("SELECT anchor,page FROM positions WHERE k=?", new String[] {key})) {
      return c.moveToFirst() ? new Position(c.getString(0), c.getInt(1)) : new Position("", 0);
    }
  }

  synchronized void position(String key, String anchor, int page) {
    ContentValues v = new ContentValues();
    v.put("k", key);
    v.put("anchor", anchor);
    v.put("page", page);
    getWritableDatabase()
        .insertWithOnConflict("positions", null, v, SQLiteDatabase.CONFLICT_REPLACE);
  }

  synchronized int page(String scope, String id) {
    try (Cursor c =
        getReadableDatabase()
            .rawQuery(
                "SELECT number FROM progress WHERE scope=? AND id=?", new String[] {scope, id})) {
      return c.moveToFirst() ? c.getInt(0) : 0;
    }
  }

  synchronized void remember(String scope, Models.Book book, int number, int position, int count) {
    if (scope == null || number < 1 || count < 1 || position < 0 || position >= count) return;
    ContentValues v = new ContentValues();
    v.put("scope", scope);
    v.put("id", book.id);
    v.put("body", book.json().toString());
    v.put("number", number);
    v.put("position", position);
    v.put("count", count);
    v.put("used", System.currentTimeMillis());
    getWritableDatabase()
        .insertWithOnConflict("progress", null, v, SQLiteDatabase.CONFLICT_REPLACE);
  }

  synchronized Recent recent(String scope) {
    if (scope == null) return null;
    try (Cursor c =
        getReadableDatabase()
            .rawQuery(
                "SELECT body,number,position,count FROM progress WHERE scope=? ORDER BY used DESC"
                    + " LIMIT 1",
                new String[] {scope})) {
      if (c.moveToFirst())
        return new Recent(
            new Models.Book(new JSONObject(c.getString(0))), c.getInt(1), c.getInt(2), c.getInt(3));
    } catch (JSONException ignored) {
    }
    return null;
  }

  synchronized void resetProgress() {
    getWritableDatabase().delete("progress", null, null);
  }
}
