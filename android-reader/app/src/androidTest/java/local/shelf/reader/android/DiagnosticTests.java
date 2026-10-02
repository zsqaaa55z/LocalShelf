package local.shelf.reader.android;

import android.test.InstrumentationTestCase;
import java.net.ConnectException;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.zip.GZIPOutputStream;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.json.*;

/** Synthetic transport only; never accesses a real NAS or saved credentials. */
public final class DiagnosticTests extends InstrumentationTestCase {
  static final String ADDRESS = "http://192.168.9.77:8089", TOKEN = "x".repeat(32), DEVICE = "d".repeat(32);
  static final class Fixture implements Diagnostics.Exchange {
    final String scenario; int calls, authorized;
    Fixture(String scenario) { this.scenario = scenario; }
    public JSONObject get(String base, String path, String token, int limit) throws Exception {
      if (!base.equals(ADDRESS)) throw new AssertionError("unexpected address");
      calls++; if (token != null) authorized++;
      if (scenario.equals("offline")) throw new ConnectException("PRIVATE_ERROR_ADDRESS");
      if (path.equals("/v2/health")) {
        if (scenario.equals("redirect")) throw new Api.Problem(302, "PRIVATE_REDIRECT");
        JSONArray features = new JSONArray(List.of("reader-v1", "page-manifest-v1", "password-pair-v1"));
        if (!scenario.equals("legacy")) features.put("connection-diagnostics-v1");
        return new JSONObject().put("app", "localshelf-reader").put("version", 1)
            .put("serverKind", "nas").put("buildVersion", "0.1.18-dev").put("capabilities", features);
      }
      if (path.startsWith("/v2/identity?nonce=")) {
        String nonce = path.substring(path.indexOf('=') + 1);
        Mac mac = Mac.getInstance("HmacSHA256"); mac.init(new SecretKeySpec(TOKEN.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        String proof = Rules.hex(mac.doFinal(("localshelf-server-v2\n" + DEVICE + "\n" + nonce).getBytes(StandardCharsets.UTF_8)));
        return new JSONObject().put("deviceId", DEVICE).put("proof", scenario.equals("wrongIdentity") ? "0".repeat(64) : proof);
      }
      if (path.equals("/v2/diagnostics")) {
        if (scenario.equals("authorization")) throw new Api.Problem(401, "PRIVATE_SERVER_ERROR");
        JSONObject checks = new JSONObject().put("storage", "ready").put("index", "ready")
            .put("catalog", scenario.equals("unpublished") ? "not_published" : "ready");
        return new JSONObject().put("app", "localshelf-reader").put("schema", 1)
            .put("libraries", new JSONObject().put("eh", checks));
      }
      if (path.equals("/v1/books?offset=0&limit=50")) {
        return new JSONObject().put("libraryId", "a".repeat(64)).put("catalogRevision", "b".repeat(64))
            .put("orderPolicy", "ehviewer-downloads-time-desc").put("orderVerified", true).put("total", 1)
            .put("books", new JSONArray().put(new JSONObject().put("id", "1").put("title", "PRIVATE_TITLE").put("rank", 0)));
      }
      throw new AssertionError("Unexpected request: " + path);
    }
  }

  public void testScenariosPrivacyAndCredentialOrdering() throws Exception {
    Api.Session saved = new Api.Session(ADDRESS, DEVICE, TOKEN, Set.of());
    for (String scenario : List.of("ok", "offline", "unpaired", "wrongIdentity", "authorization", "unpublished", "manualDisabled", "legacy", "redirect")) {
      Fixture fixture = new Fixture(scenario);
      Diagnostics.Report report = Diagnostics.run(ADDRESS, scenario.equals("unpaired") ? null : saved,
          scenario.equals("manualDisabled") ? "manual" : "eh", fixture);
      assertEquals(scenario, Set.of("ok", "legacy").contains(scenario), report.summary.equals("当前书库连接正常"));
      for (String secret : List.of(ADDRESS, TOKEN, DEVICE, "PRIVATE_TITLE", "PRIVATE_SERVER_ERROR", "PRIVATE_ERROR_ADDRESS"))
        assertFalse(report.text().contains(secret));
      if (Set.of("offline", "unpaired", "wrongIdentity", "redirect").contains(scenario)) assertEquals(0, fixture.authorized);
      assertTrue(fixture.calls <= 4);
    }
  }

  public void testInvalidAddressDoesNotRequest() throws Exception {
    Fixture fixture = new Fixture("ok");
    Diagnostics.Report report = Diagnostics.run("https://public.example", null, "eh", fixture);
    assertEquals("地址格式需要调整", report.summary); assertEquals(0, fixture.calls);
  }

  public void testRealHttpBoundsGzipAndRedirect() throws Exception {
    for (String mode : List.of("plain", "gzip", "oversize", "gzipOversize", "redirect", "stall")) {
      try (ServerSocket server = new ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))) {
        server.setSoTimeout(7000);
        ExecutorService worker = Executors.newSingleThreadExecutor();
        Future<?> reply = worker.submit(() -> {
          try (Socket socket = server.accept()) {
            socket.setSoTimeout(5000);
            BufferedReader input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
            String line = input.readLine();
            if (!"GET /v2/health HTTP/1.1".equals(line)) throw new AssertionError("GET-only transport");
            while ((line = input.readLine()) != null && !line.isEmpty())
              if (line.toLowerCase(Locale.ROOT).startsWith("authorization:")) throw new AssertionError("unexpected credential");
            if (mode.equals("stall")) { Thread.sleep(4500); return; }
            byte[] data = (mode.toLowerCase(Locale.ROOT).contains("oversize") ? "x".repeat(9000) : "{\"ok\":true}").getBytes(StandardCharsets.UTF_8);
            boolean compressed = mode.startsWith("gzip");
            if (compressed) {
              ByteArrayOutputStream buffer = new ByteArrayOutputStream();
              try (GZIPOutputStream gzip = new GZIPOutputStream(buffer)) { gzip.write(data); }
              data = buffer.toByteArray();
            }
            String head = "HTTP/1.1 " + (mode.equals("redirect") ? "302 Found" : "200 OK") + "\r\nConnection: close\r\nContent-Length: " + data.length + "\r\n"
                + (compressed ? "Content-Encoding: gzip\r\n" : "")
                + (mode.equals("redirect") ? "Location: http://127.0.0.1:1/should-not-follow\r\n" : "") + "\r\n";
            socket.getOutputStream().write(head.getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().write(data); socket.getOutputStream().flush();
          } catch (Exception error) { throw new RuntimeException(error); }
        });
        try {
          long start = System.nanoTime();
          try {
            JSONObject result = Diagnostics.get("http://127.0.0.1:" + server.getLocalPort(), "/v2/health", null, 8192);
            assertTrue(mode, Set.of("plain", "gzip").contains(mode)); assertTrue(result.getBoolean("ok"));
          } catch (Api.Problem error) {
            assertEquals("redirect", mode); assertEquals(302, error.status);
          } catch (SocketTimeoutException error) {
            assertEquals("stall", mode); assertTrue(System.nanoTime() - start < 6_000_000_000L);
          } catch (IOException error) {
            assertTrue(mode + ": " + error, Set.of("oversize", "gzipOversize").contains(mode));
          }
          reply.get(7, TimeUnit.SECONDS);
        } finally { worker.shutdownNow(); }
      }
    }
  }

  public void testCancelledRunDoesNotSucceedOrSend() throws Exception {
    Thread.currentThread().interrupt();
    try {
      Diagnostics.Report report = Diagnostics.run(ADDRESS, null, "eh");
      assertEquals("诊断已取消", report.summary);
    } finally { Thread.interrupted(); }
  }
}
