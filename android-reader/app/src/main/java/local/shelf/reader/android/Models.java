package local.shelf.reader.android;

import java.util.*;
import org.json.*;

final class Models {
  static final class Book {
    final String id, title, cover;
    final int rank, count;
    final boolean available;
    String note = "";

    Book(JSONObject j) throws JSONException {
      id = j.getString("id");
      title = j.getString("title");
      rank = j.getInt("rank");
      available = j.optBoolean("available", true);
      cover = j.optString("coverIdentity", "");
      count = j.optInt("pageCount", 0);
      if (!Rules.id(id)
          || title.length() > 12000
          || rank < 0
          || rank >= 20000
          || (!cover.isEmpty() && !Rules.hash(cover))
          || count < 0
          || count > 20000) throw new JSONException("invalid book");
    }

    JSONObject json() {
      JSONObject j = new JSONObject();
      try {
        j.put("id", id)
            .put("title", title)
            .put("rank", rank)
            .put("available", available)
            .put("coverIdentity", cover)
            .put("pageCount", count);
      } catch (JSONException ignored) {
      }
      return j;
    }
  }

  static final class Catalog {
    final String library, revision, policy;
    final int total;
    final List<Book> books;
    final JSONObject raw;

    Catalog(JSONObject j, String source) throws JSONException {
      library = j.getString("libraryId");
      revision = j.getString("catalogRevision");
      policy = j.optString("orderPolicy");
      total = j.getInt("total");
      raw = j;
      if (!j.getBoolean("orderVerified")
          || !Rules.hash(library)
          || !Rules.hash(revision)
          || total < 0
          || total > 20000
          || !policy.equals(
              "manual".equals(source)
                  ? "manual-import-newest-first-v1"
                  : "ehviewer-downloads-time-desc")) throw new JSONException("invalid catalog");
      JSONArray array = j.getJSONArray("books");
      if (array.length() > 500 || array.length() > total)
        throw new JSONException("oversized catalog");
      books = new ArrayList<>();
      Set<String> ids = new HashSet<>();
      int rank = -1;
      for (int i = 0; i < array.length(); i++) {
        Book b = new Book(array.getJSONObject(i));
        if (!ids.add(b.id) || b.rank <= rank) throw new JSONException("duplicate/order");
        rank = b.rank;
        books.add(b);
      }
    }
  }

  static final class Page {
    final int number;
    final long size;
    final String sha;

    Page(JSONObject j) throws JSONException {
      number = j.getInt("number");
      size = j.getLong("size");
      sha = j.getString("sha256");
      if (number < 1
          || number > 99999999
          || size < 1
          || size > 1024L * 1024 * 1024
          || !Rules.hash(sha)) throw new JSONException("invalid page");
    }
  }

  static List<Page> pages(JSONObject j, String id, String library) throws JSONException {
    if (!j.getString("id").equals(id)
        || !j.getString("libraryId").equals(library)
        || !Rules.hash(j.getString("contentRevision")))
      throw new JSONException("wrong page library");
    JSONArray array = j.getJSONArray("pages");
    if (array.length() > 20000) throw new JSONException("too many pages");
    List<Page> out = new ArrayList<>();
    int previous = 0;
    for (int i = 0; i < array.length(); i++) {
      Page p = new Page(array.getJSONObject(i));
      if (p.number <= previous) throw new JSONException("page order");
      previous = p.number;
      out.add(p);
    }
    return out;
  }

  static String error(Throwable error) {
    if (error instanceof Api.Problem || error instanceof MediaPipeline.ImageRejected)
      return error.getMessage();
    if (error instanceof java.util.concurrent.CancellationException
        || error instanceof InterruptedException) return "操作已取消";
    if (error instanceof JSONException) return "书库返回的数据不完整，请刷新重试";
    if (error instanceof OutOfMemoryError) return "已启用内存保护，请重试当前页";
    return "暂时无法连接或读取，请确认 Wi-Fi 和 NAS 服务，再重试";
  }

  static String note(String key) {
    return switch (key) {
      case "circle" -> "同社团 · 待确认";
      case "creditName" -> "署名线索 · 待确认";
      case "workCredit" -> "同作署名 · 待确认";
      case "edition" -> "同作不同版本";
      case "seriesVariant" -> "标题写法相近";
      case "authorSeries" -> "作者与系列线索";
      default -> "可能匹配";
    };
  }
}
