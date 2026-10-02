package local.shelf.reader.android;

import android.app.Application;
import android.os.Handler;
import android.os.Looper;
import java.util.concurrent.*;

public final class ReaderApp extends Application {
  final ExecutorService io = Executors.newFixedThreadPool(2);
  final ScheduledExecutorService records = Executors.newSingleThreadScheduledExecutor();
  final Handler main = new Handler(Looper.getMainLooper());
  Vault vault;
  LocalStore store;
  MediaCache disk;
  MediaPipeline media;
  volatile Api.Session session;
  volatile boolean verified;
  private ScheduledFuture<?> pendingRecord;

  @Override
  public void onCreate() {
    super.onCreate();
    vault = new Vault(this);
    store = new LocalStore(this);
    disk = new MediaCache(this);
    media = new MediaPipeline(this, disk);
    io.execute(
        () -> {
          try {
            disk.initialize();
          } catch (Exception ignored) {
          }
        });
  }

  synchronized void remember(
      String scope, Models.Book book, int number, int position, int count, boolean flush) {
    if (pendingRecord != null) pendingRecord.cancel(false);
    pendingRecord =
        records.schedule(
            () -> store.remember(scope, book, number, position, count),
            flush ? 0 : 250,
            TimeUnit.MILLISECONDS);
  }

  void persist(Api.Session value) {
    records.execute(
        () -> {
          Api.Session current = session;
          if (current == null
              || !current.device.equals(value.device)
              || !current.token.equals(value.token)) return;
          try {
            vault.save(value);
          } catch (Exception error) {
            main.post(
                () -> {
                  if (session == value) Ui.toast(this, "已连接，但连接信息暂未保存；下次可能需要重新输入");
                });
          }
        });
  }

  void forget() {
    verified = false;
    session = null;
    records.execute(vault::forget);
    media.cancelAll();
  }

  @Override
  public void onTrimMemory(int level) {
    super.onTrimMemory(level);
    if (level >= TRIM_MEMORY_RUNNING_LOW) media.trim();
  }
}
