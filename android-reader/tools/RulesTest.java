import java.util.Arrays;
import local.shelf.reader.android.Rules;

public final class RulesTest {
  private static int checks;

  static void ok(boolean value) {
    checks++;
    if (!value) throw new AssertionError("check " + checks);
  }

  public static void main(String[] args) {
    ok(Rules.address(" 192.168.50.10:8089/ ").equals("http://192.168.50.10:8089"));
    for (String value :
        new String[] {"http://10.0.2.2:8098", "https://172.16.2.1", "http://127.0.0.1:1234"})
      ok(Rules.address(value).equals(value));
    for (String bad :
        new String[] {
          "http://example.com",
          "http://8.8.8.8",
          "http://192.168.50.10@8.8.8.8",
          "http://192.168.05.2",
          "file:///tmp",
          "http://192.168.50.10:0",
          "http://192.168.50.10:65536",
          "http://192.168.50.10/a",
          "http://192.168.50.10?token=secret",
          "http://172.32.0.1",
          "http://999.1.1.1",
          "http://192.168.50.10/#bad"
        }) {
      try {
        Rules.address(bad);
        throw new AssertionError(bad);
      } catch (IllegalArgumentException expected) {
        checks++;
      }
    }
    ok(Rules.pageCount(10073, 50) == 202);
    ok(Rules.pageCount(10073, 500) == 21);
    ok(Rules.pageCount(0, 100) == 1);
    ok(Rules.slider(50, 100, 50) == 25);
    ok(Rules.slider(100, 100, 500) == 499);
    ok(Rules.slider(Float.NaN, 100, 50) == 0);
    ok(Rules.jump("1", 50) == 0);
    ok(Rules.jump("51", 50) == -1);
    ok(Rules.jump("0", 50) == -1);
    ok(Rules.jump("-1", 50) == -1);
    ok(Arrays.equals(Rules.nearby(4, 10, 1, false), new int[] {4, 5, 3, 6, 2}));
    ok(Arrays.equals(Rules.nearby(0, 10, 1, false), new int[] {0, 1, 2}));
    ok(Arrays.equals(Rules.nearby(9, 10, -1, true), new int[] {9}));
    ok(Rules.route("manual", "/v1/books").equals("/manual/v1/books"));
    ok(Rules.route("eh", "/v1/books").equals("/v1/books"));
    ok(
        !Rules.scope("a".repeat(32), "b".repeat(64))
            .equals(Rules.scope("a".repeat(32), "c".repeat(64))));
    ok(Rules.COVER_DISK + Rules.BODY_DISK == 2_000_000_000L);
    System.out.println("PASS " + checks + " pure-rule checks");
  }
}
