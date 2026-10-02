package local.shelf.reader.android;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import java.util.zip.GZIPInputStream;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.json.*;

/** Read-only client. No upload, deletion, or NAS filesystem API is exposed. */
final class Api {
  static final class Problem extends IOException {
    final int status;

    Problem(int status, String text) {
      super(text);
      this.status = status;
    }
  }

  static final class Session {
    final String address, device, token;
    final Set<String> features;

    Session(String address, String device, String token, Set<String> features) throws IOException {
      this.address = Rules.address(address);
      this.device = device;
      this.token = token;
      this.features = Set.copyOf(features);
      if (!device.matches("[a-f0-9]{32}") || !token.matches("[A-Za-z0-9_-]{32}"))
        throw new Problem(0, "连接凭据无效，请重新连接");
    }
  }

  record JsonResult(JSONObject value, String etag, boolean notModified) {}

  static HttpURLConnection connection(String base, String path, String token) throws IOException {
    if (!path.startsWith("/")
        || path.startsWith("//")
        || path.indexOf('\r') >= 0
        || path.indexOf('\n') >= 0) throw new IOException("invalid route");
    HttpURLConnection c =
        (HttpURLConnection) new URL(Rules.address(base) + path).openConnection(Proxy.NO_PROXY);
    c.setInstanceFollowRedirects(false);
    c.setConnectTimeout(8000);
    c.setReadTimeout(25000);
    c.setRequestProperty("User-Agent", "LocalShelf-Android/" + BuildConfig.VERSION_NAME);
    c.setRequestProperty("Accept-Encoding", "gzip");
    if (token != null) c.setRequestProperty("Authorization", "Bearer " + token);
    return c;
  }

  static JsonResult json(String base, String token, String path, byte[] post, String etag)
      throws IOException, JSONException {
    HttpURLConnection c = connection(base, path, token);
    try {
      if (etag != null && !etag.isEmpty()) c.setRequestProperty("If-None-Match", etag);
      if (post != null) {
        c.setRequestMethod("POST");
        c.setDoOutput(true);
        c.setFixedLengthStreamingMode(post.length);
        c.setRequestProperty("Content-Type", "text/plain; charset=utf-8");
        try (OutputStream out = c.getOutputStream()) {
          out.write(post);
        }
      }
      int status = c.getResponseCode();
      if (status == 304) return new JsonResult(null, c.getHeaderField("ETag"), true);
      if (status != 200) throw failure(status, c);
      try (InputStream raw = c.getInputStream();
          InputStream in =
              "gzip".equalsIgnoreCase(c.getContentEncoding()) ? new GZIPInputStream(raw) : raw) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[32768];
        int n;
        while ((n = in.read(buffer)) != -1) {
          if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
          if (out.size() + n > Rules.MAX_JSON) throw new Problem(0, "书库回复过大，已停止读取");
          out.write(buffer, 0, n);
        }
        return new JsonResult(
            new JSONObject(out.toString(StandardCharsets.UTF_8.name())),
            c.getHeaderField("ETag"),
            false);
      }
    } finally {
      c.disconnect();
    }
  }

  static Problem failure(int status, HttpURLConnection c) {
    String code = "";
    try (InputStream in = c.getErrorStream()) {
      if (in != null) {
        byte[] small = new byte[2048];
        int n = in.read(small);
        if (n > 0)
          code = new JSONObject(new String(small, 0, n, StandardCharsets.UTF_8)).optString("error");
      }
    } catch (Exception ignored) {
    }
    String message =
        switch (code) {
          case "incorrect_password" -> "密码不正确，请核对 NAS 阅读密码";
          case "password_pair_rate_limited" -> "尝试次数过多，请稍后再连接";
          case "manual_library_disabled" -> "NAS 尚未启用手动书库，请先切回 Eh 同步";
          case "page_content_changed" -> "此页内容已更新，请刷新页码";
          case "image_missing", "file_unavailable" -> "NAS 上暂时找不到这张图片";
          default ->
              switch (status) {
                case 401, 403 -> "连接凭据已失效，请到设置重新连接";
                case 404 -> "书目已更新或文件不存在，请刷新书库";
                case 412 -> "内容已更新，请刷新页码";
                case 429, 503 -> "NAS 暂时忙，请稍后重试";
                default -> "请求未完成，请核对阅读地址和服务版本";
              };
        };
    return new Problem(status, message);
  }

  static Set<String> health(String address) throws Exception {
    JSONObject j = json(address, null, "/v2/health", null, null).value();
    return healthFeatures(j);
  }

  static Set<String> healthFeatures(JSONObject j) throws Exception {
    if (!j.optString("app").equals("localshelf-reader")
        || j.optInt("version") != 1
        || !j.optString("serverKind").equals("nas")) throw new Problem(0, "这不是 NAS 阅读服务，请检查端口");
    Set<String> out = new HashSet<>();
    JSONArray list = j.getJSONArray("capabilities");
    for (int i = 0; i < list.length(); i++) out.add(list.getString(i));
    if (!out.containsAll(List.of("reader-v1", "page-manifest-v1", "password-pair-v1")))
      throw new Problem(0, "NAS 版本过旧，请更新阅读服务");
    return out;
  }

  static Session login(String address, char[] password) throws Exception {
    String normalized = Rules.address(address);
    Set<String> features = health(normalized);
    byte[] data = new String(password).getBytes(StandardCharsets.UTF_8);
    Arrays.fill(password, '\0');
    try {
      if (data.length < 8 || data.length > 128) throw new Problem(0, "请输入 8–128 字节的 NAS 阅读密码");
      JSONObject j = json(normalized, null, "/v2/password-pair", data, null).value();
      if (!j.optString("app").equals("localshelf") || j.optInt("version") != 2)
        throw new Problem(0, "连接回复不兼容");
      Session result =
          new Session(normalized, j.getString("deviceId"), j.getString("token"), features);
      verify(result);
      return result;
    } finally {
      Arrays.fill(data, (byte) 0);
    }
  }

  static Session verify(Session old) throws Exception {
    Set<String> features = health(old.address);
    byte[] random = new byte[32];
    new SecureRandom().nextBytes(random);
    String nonce = Rules.hex(random);
    JSONObject j = json(old.address, null, "/v2/identity?nonce=" + nonce, null, null).value();
    verifyProof(old, nonce, j);
    return new Session(old.address, old.device, old.token, features);
  }

  static void verifyProof(Session old, String nonce, JSONObject j) throws Exception {
    Mac mac = Mac.getInstance("HmacSHA256");
    mac.init(new SecretKeySpec(old.token.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
    String expected =
        Rules.hex(
            mac.doFinal(
                ("localshelf-server-v2\n" + old.device + "\n" + nonce)
                    .getBytes(StandardCharsets.UTF_8)));
    if (!old.device.equals(j.optString("deviceId"))
        || !MessageDigest.isEqual(
            expected.getBytes(StandardCharsets.US_ASCII),
            j.optString("proof").getBytes(StandardCharsets.US_ASCII)))
      throw new Problem(401, "该地址不是已配对的 NAS，请在设置重新连接");
  }

  static JsonResult get(Session session, String source, String path, String etag) throws Exception {
    if (source.equals("manual") && !session.features.contains("manual-library-v1"))
      throw new Problem(404, "NAS 尚未启用手动书库，请切回 Eh 同步");
    return json(session.address, session.token, Rules.route(source, path), null, etag);
  }
}
