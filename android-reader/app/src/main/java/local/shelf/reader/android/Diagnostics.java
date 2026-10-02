package local.shelf.reader.android;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.*;
import java.util.zip.GZIPInputStream;
import org.json.*;

/** Explicitly invoked, GET-only, no password attempts or connection-state writes. */
final class Diagnostics {
  record Step(String title, String detail, boolean passed) {}
  static final class Report {
    final String timestamp = Instant.now().toString();
    final List<Step> steps = new ArrayList<>();
    String summary = "检查未完成", version = "未取得";
    void add(String title, String detail, boolean passed) { steps.add(new Step(title, detail, passed)); }
    String text() {
      StringBuilder out = new StringBuilder("LocalShelf Android " + BuildConfig.VERSION_NAME
          + " · 连接诊断\n" + timestamp + "\nNAS 版本：" + version + "\n" + summary);
      for (Step step : steps) out.append('\n').append(step.passed ? "通过" : "注意")
          .append(" · ").append(step.title).append("：").append(step.detail);
      return out.append("\n仅只读检查；未测试图片完整性。已省略地址、账号、凭据、书名和图片。").toString();
    }
  }
  interface Exchange { JSONObject get(String base, String path, String token, int limit) throws Exception; }

  static JSONObject get(String base, String path, String token, int limit) throws Exception {
    if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
    HttpURLConnection c = Api.connection(base, path, token);
    c.setConnectTimeout(4000); c.setReadTimeout(4000); c.setUseCaches(false);
    long deadline = System.nanoTime() + 8_000_000_000L;
    try {
      int status = c.getResponseCode();
      if (status != 200) throw new Api.Problem(status, "diagnostic_http");
      try (InputStream raw = c.getInputStream(); InputStream in =
          "gzip".equalsIgnoreCase(c.getContentEncoding()) ? new GZIPInputStream(raw) : raw) {
        ByteArrayOutputStream data = new ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int n;
        while ((n = in.read(buffer)) != -1) {
          if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
          if (System.nanoTime() > deadline) throw new SocketTimeoutException();
          if (data.size() + n > limit) throw new IOException("diagnostic_response_limit");
          data.write(buffer, 0, n);
        }
        return new JSONObject(data.toString(StandardCharsets.UTF_8.name()));
      }
    } finally { c.disconnect(); }
  }

  static Report run(String address, Api.Session saved, String source) {
    return run(address, saved, source, Diagnostics::get);
  }
  static Report run(String address, Api.Session saved, String source, Exchange exchange) {
    Report r = new Report(); String base;
    try { base = Rules.address(address); }
    catch (Exception ignored) {
      r.add("地址检查", "请填写完整的局域网阅读地址，包含 http:// 和阅读端口。", false);
      r.summary = "地址格式需要调整"; return r;
    }
    r.add("地址检查", "格式正确；不会探测管理或上传端口。", true);
    String phase = "阅读服务";
    try {
      long started = System.nanoTime();
      JSONObject health = exchange.get(base, "/v2/health", null, 8192);
      r.add("阅读端口", "已收到 HTTP 响应，耗时 " + ((System.nanoTime() - started) / 1_000_000L) + " ms。", true);
      Set<String> features = Api.healthFeatures(health);
      String version = health.optString("buildVersion");
      if (version.matches("[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(-dev)?")) r.version = version;
      r.add("服务识别", "已识别为兼容的 NAS 阅读服务。", true);
      if (saved == null) {
        r.add("身份与权限", "尚无可用的已保存配对；请先正常连接。诊断不会尝试密码。", false);
        r.summary = "服务可达，尚未验证阅读权限"; return r;
      }
      phase = "服务器身份";
      byte[] random = new byte[32]; new SecureRandom().nextBytes(random); String nonce = Rules.hex(random);
      JSONObject proof = exchange.get(base, "/v2/identity?nonce=" + nonce, null, 8192);
      Api.verifyProof(saved, nonce, proof);
      r.add(phase, "已确认是原配对服务器。", true);
      phase = "书库就绪";
      if (features.contains("connection-diagnostics-v1")) {
        JSONObject state = exchange.get(base, "/v2/diagnostics", saved.token, 8192);
        if (!state.optString("app").equals("localshelf-reader") || state.optInt("schema") != 1)
          throw new IOException("diagnostic_schema");
        JSONObject checks = state.getJSONObject("libraries").optJSONObject(source);
        if (checks == null) {
          r.add(phase, "当前书库未启用，请切换书库或检查 NAS 配置。", false);
          r.summary = "当前书库不可用"; return r;
        }
        String[][] names = {{"storage", "存储目录", "目录不可读或未挂载"},
            {"index", "书库索引", "索引不可读或暂时忙"}, {"catalog", "已发布目录", "目录尚未发布或暂不可读"}};
        for (String[] name : names) {
          boolean ok = checks.optString(name[0]).equals("ready");
          r.add(name[1], ok ? "检查通过。" : name[2] + "；诊断不会创建或修复数据。", ok);
          if (!ok) { r.summary = "NAS 书库暂未就绪"; return r; }
        }
      } else r.add("详细健康检查", "旧版 NAS 不支持，继续用实际目录请求检查。", true);
      phase = "目录读取";
      if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
      Models.Catalog list = new Models.Catalog(exchange.get(base,
          Rules.route(source, "/v1/books?offset=0&limit=50"), saved.token, 2*1024*1024), source);
      if (list.books.size() > 50) throw new IOException("diagnostic_catalog_limit");
      if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
      r.add("读取权限与目录", list.total == 0 ? "权限正常；当前书库为空。"
          : "权限正常，已读取第一页目录；未下载封面或正文。", true);
      r.summary = "当前书库连接正常";
    } catch (Exception error) {
      if (Thread.currentThread().isInterrupted()) { r.summary = "诊断已取消"; return r; }
      r.add(phase, message(error, phase), false);
      r.summary = "检查未通过；未更改现有连接";
    }
    return r;
  }

  static String message(Exception error, String phase) {
    if (phase.equals("服务器身份")) return "无法确认是已配对的服务器，或保存的凭据已变化；未发送阅读凭据。";
    if (error instanceof SocketTimeoutException) return "请求超时。检查局域网、服务端口和防火墙；不能据此判定容器已停止。";
    if (error instanceof ConnectException || error instanceof NoRouteToHostException || error instanceof UnknownHostException)
      return "阅读端口无法连接。可能是网络、服务或端口映射问题，不代表密码错误。";
    if (error instanceof Api.Problem p) {
      if (p.status == 401 || p.status == 403) return "访问被拒绝，请核对保存的配对与权限；不会自动重试密码。";
      if (p.status == 429 || p.status >= 500) return "服务暂忙或书库未就绪，请稍后再试。";
      if (p.status >= 300 && p.status < 400) return "收到跳转，已停止；请核对阅读地址。";
      if (phase.equals("阅读服务")) return "该地址不是兼容的 NAS 阅读服务，请勿使用管理或上传端口。";
    }
    return "回复异常或目录校验未通过；未修改缓存、书库或配对。";
  }
}
