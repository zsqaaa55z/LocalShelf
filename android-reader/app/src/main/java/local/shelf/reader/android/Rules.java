package local.shelf.reader.android;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Pure rules shared with JVM checks. No Android views, files or credentials. */
public final class Rules {
  public static final long COVER_DISK = 1_500_000_000L, BODY_DISK = 500_000_000L;
  public static final int MAX_IMAGE = 50 * 1024 * 1024, MAX_JSON = 8 * 1024 * 1024;

  private Rules() {}

  public static String address(String input) {
    try {
      String value = input.trim();
      if (!value.contains("://")) value = "http://" + value;
      URI uri = new URI(value);
      if (!List.of("http", "https").contains(uri.getScheme())
          || uri.getUserInfo() != null
          || uri.getQuery() != null
          || uri.getFragment() != null
          || !(uri.getPath().isEmpty() || uri.getPath().equals("/"))) throw new Exception();
      String host = uri.getHost();
      if (host == null || !host.matches("[0-9]{1,3}(\\.[0-9]{1,3}){3}")) throw new Exception();
      String[] parts = host.split("\\.");
      int[] bytes = new int[4];
      for (int i = 0; i < 4; i++) {
        bytes[i] = Integer.parseInt(parts[i]);
        if (bytes[i] > 255 || (parts[i].length() > 1 && parts[i].startsWith("0")))
          throw new Exception();
      }
      if (!(bytes[0] == 10
          || bytes[0] == 192 && bytes[1] == 168
          || bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31
          || bytes[0] == 127)) throw new Exception();
      if (uri.getPort() == 0 || uri.getPort() > 65535 || uri.getPort() < -1) throw new Exception();
      return uri.getScheme() + "://" + host + (uri.getPort() == -1 ? "" : ":" + uri.getPort());
    } catch (Exception error) {
      throw new IllegalArgumentException("请输入局域网 IPv4 阅读地址，例如 http://192.168.x.x:8089");
    }
  }

  public static boolean id(String value) {
    return value != null && value.matches("[1-9][0-9]{0,18}");
  }

  public static boolean hash(String value) {
    return value != null && value.matches("[a-f0-9]{64}");
  }

  public static String sha(byte[] value) {
    try {
      return hex(MessageDigest.getInstance("SHA-256").digest(value));
    } catch (Exception e) {
      throw new IllegalStateException(e);
    }
  }

  public static String key(String value) {
    return sha(value.getBytes(StandardCharsets.UTF_8));
  }

  public static String hex(byte[] bytes) {
    StringBuilder result = new StringBuilder(bytes.length * 2);
    for (byte b : bytes) result.append(String.format(Locale.ROOT, "%02x", b & 255));
    return result.toString();
  }

  public static int clamp(int value, int count) {
    return Math.max(0, Math.min(value, Math.max(0, count - 1)));
  }

  public static int pageCount(int total, int size) {
    return Math.max(1, (Math.max(0, total) + Math.max(1, size) - 1) / Math.max(1, size));
  }

  public static int slider(float position, float length, int count) {
    return !Float.isFinite(position) || !Float.isFinite(length) || length <= 0
        ? 0
        : clamp(Math.round(Math.max(0, Math.min(1, position / length)) * (count - 1)), count);
  }

  public static int jump(String text, int count) {
    try {
      if (!text.trim().matches("[0-9]{1,7}")) return -1;
      int n = Integer.parseInt(text.trim());
      return n >= 1 && n <= count ? n - 1 : -1;
    } catch (Exception e) {
      return -1;
    }
  }

  public static int[] nearby(int current, int count, int direction, boolean pressure) {
    if (current < 0 || current >= count) return new int[0];
    int d = direction < 0 ? -1 : 1;
    List<Integer> out = new ArrayList<>();
    for (int n : new int[] {current, current + d, current - d, current + 2 * d, current - 2 * d})
      if (n >= 0 && n < count && (!pressure || out.isEmpty())) out.add(n);
    int[] values = new int[out.size()];
    for (int i = 0; i < values.length; i++) values[i] = out.get(i);
    return values;
  }

  public static String route(String source, String logical) {
    if (!logical.startsWith("/v1/") || logical.contains("..") || logical.contains("#"))
      throw new IllegalArgumentException("无效接口");
    return "manual".equals(source) ? "/manual" + logical : logical;
  }

  public static String scope(String device, String library) {
    if (device == null || !device.matches("[a-f0-9]{32}") || !hash(library))
      throw new IllegalArgumentException("书库身份无效");
    return device + ":" + library;
  }
}
