package local.shelf.reader.android;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;
import java.io.*;
import java.net.HttpURLConnection;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/** Three bounded transfers, two decoders, priority promotion and shared encoded requests. */
final class MediaPipeline {
  interface Callback {
    void ready(Decoded image);

    void failed(Throwable error);
  }

  record Asset(
      Api.Session session,
      String source,
      String scope,
      String path,
      String key,
      String expected,
      int width,
      int height,
      boolean cover) {
    static Asset cover(Api.Session s, String source, String scope, Models.Book book, int width) {
      int bucket = width <= 320 ? 320 : width <= 480 ? 480 : 640;
      String identity =
          book.cover.isEmpty() ? "ttl-" + (System.currentTimeMillis() / 300000) : book.cover;
      String key = Rules.key(scope + "\ncover\n" + book.id + "\n" + identity + "\n" + bucket);
      return new Asset(
          s,
          source,
          scope,
          "/v1/books/" + book.id + "/cover?width=" + bucket,
          key,
          "",
          bucket,
          bucket * 2,
          true);
    }

    static Asset page(
        Api.Session s,
        String source,
        String scope,
        String book,
        Models.Page page,
        int width,
        int height) {
      return new Asset(
          s,
          source,
          scope,
          "/v1/books/" + book + "/pages/" + page.number,
          Rules.key(scope + "\nbody\n" + book + "\n" + page.number + "\n" + page.sha),
          page.sha,
          width,
          height,
          false);
    }

    String bitmapKey() {
      return key + ":" + width + ":" + height;
    }
  }

  static final class Decoded implements AutoCloseable {
    final Drawable drawable;
    final boolean animated;
    final String warning;
    final boolean deferred;
    private MediaCache.Lease lease;
    private Runnable releaseBudget;

    Decoded(Drawable drawable, MediaCache.Lease lease) {
      this(drawable, lease, "", false, null);
    }

    Decoded(
        Drawable drawable,
        MediaCache.Lease lease,
        String warning,
        boolean deferred,
        Runnable releaseBudget) {
      this.drawable = drawable;
      animated = drawable instanceof AnimatedImageDrawable;
      this.lease = lease;
      this.warning = warning;
      this.deferred = deferred;
      this.releaseBudget = releaseBudget;
    }

    void playing(boolean value) {
      if (drawable instanceof AnimatedImageDrawable animated) {
        if (value) {
          animated.setRepeatCount(AnimatedImageDrawable.REPEAT_INFINITE);
          animated.start();
        } else animated.stop();
      }
    }

    @Override
    public void close() {
      playing(false);
      drawable.setCallback(null);
      if (lease != null) {
        lease.close();
        lease = null;
      }
      if (releaseBudget != null) {
        releaseBudget.run();
        releaseBudget = null;
      }
    }
  }

  final class Request implements AutoCloseable {
    final Asset asset;
    final Callback callback;
    final boolean decode;
    final int priority;
    volatile boolean canceled;
    Job job;

    Request(Asset asset, Callback callback, boolean decode, int priority) {
      this.asset = asset;
      this.callback = callback;
      this.decode = decode;
      this.priority = priority;
    }

    @Override
    public void close() {
      synchronized (lock) {
        if (canceled) return;
        canceled = true;
        if (job != null) {
          job.requests.remove(this);
          if (job.requests.isEmpty()) {
            job.canceled = true;
            network.getQueue().remove(job);
            if (jobs.get(asset.key) == job) jobs.remove(asset.key);
            HttpURLConnection c = job.connection;
            if (c != null) c.disconnect();
          }
        }
      }
    }
  }

  private final Object lock = new Object();
  private final Map<String, Job> jobs = new HashMap<>();
  private final ThreadPoolExecutor network;
  private final ExecutorService decoders;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final AtomicLong sequence = new AtomicLong();
  private final MediaCache disk;
  private final Context context;
  private final LruCache<String, Bitmap> covers, body;
  private final AtomicLong animationBytes = new AtomicLong();
  private static final long ANIMATION_BUDGET = 128L * 1024 * 1024;

  private static final class AnimationLimited extends RuntimeException {
    final boolean deferred;

    AnimationLimited(String message, boolean deferred) {
      super(message);
      this.deferred = deferred;
    }
  }

  static final class ImageRejected extends RuntimeException {
    ImageRejected(String message) {
      super(message);
    }
  }

  private boolean reserveAnimation(long bytes) {
    long old;
    do {
      old = animationBytes.get();
      if (old + bytes > ANIMATION_BUDGET) return false;
    } while (!animationBytes.compareAndSet(old, old + bytes));
    return true;
  }

  MediaPipeline(Context context, MediaCache disk) {
    this.context = context;
    this.disk = disk;
    network =
        new ThreadPoolExecutor(
            3,
            3,
            20,
            TimeUnit.SECONDS,
            new PriorityBlockingQueue<>(),
            r -> {
              Thread t = new Thread(r, "shelf-transfer");
              t.setDaemon(true);
              return t;
            });
    decoders =
        Executors.newFixedThreadPool(
            2,
            r -> {
              Thread t = new Thread(r, "shelf-decode");
              t.setDaemon(true);
              return t;
            });
    covers = cache(24 * 1024 * 1024);
    body = cache(32 * 1024 * 1024);
  }

  private static LruCache<String, Bitmap> cache(int budget) {
    return new LruCache<>(budget) {
      @Override
      protected int sizeOf(String key, Bitmap bitmap) {
        return bitmap.getAllocationByteCount();
      }
    };
  }

  Request request(Asset asset, int priority, Callback callback) {
    return enqueue(asset, priority, callback, true);
  }

  Request prefetch(Asset asset) {
    return enqueue(asset, 2, null, false);
  }

  private Request enqueue(Asset asset, int priority, Callback callback, boolean decode) {
    Request request = new Request(asset, callback, decode, priority);
    Bitmap bitmap = (asset.cover ? covers : body).get(asset.bitmapKey());
    if (bitmap != null && decode) {
      main.post(
          () -> {
            if (!request.canceled)
              callback.ready(new Decoded(new BitmapDrawable(context.getResources(), bitmap), null));
          });
      return request;
    }
    synchronized (lock) {
      Job job = jobs.get(asset.key);
      if (job == null) {
        job = new Job(asset, priority);
        jobs.put(asset.key, job);
        job.requests.add(request);
        request.job = job;
        network.execute(job);
      } else {
        job.requests.add(request);
        request.job = job;
        if (priority < job.priority) {
          boolean queued = network.getQueue().remove(job);
          job.priority = priority;
          if (queued) network.execute(job);
        }
      }
    }
    return request;
  }

  private final class Job implements Runnable, Comparable<Job> {
    final Asset asset;
    final long order = sequence.incrementAndGet();
    final List<Request> requests = new ArrayList<>();
    int priority;
    volatile boolean canceled;
    volatile HttpURLConnection connection;

    Job(Asset asset, int priority) {
      this.asset = asset;
      this.priority = priority;
    }

    @Override
    public int compareTo(Job other) {
      int n = Integer.compare(priority, other.priority);
      return n == 0 ? Long.compare(order, other.order) : n;
    }

    @Override
    public void run() {
      List<Request> waiting;
      MediaCache.Lease guard = null;
      try {
        if (canceled) return;
        guard = disk.acquire(asset.key);
        if (guard == null) {
          download();
          guard = disk.acquire(asset.key);
        }
        if (guard == null) throw new IOException("missing cached transfer");
        synchronized (lock) {
          waiting = new ArrayList<>(requests);
          requests.clear();
          if (jobs.get(asset.key) == this) jobs.remove(asset.key);
        }
        for (Request r : waiting) {
          if (r.canceled || !r.decode) continue;
          try {
            MediaCache.Lease lease = disk.acquire(asset.key);
            if (lease == null) throw new IOException("cache lease");
            decoders.execute(() -> decode(r, lease));
          } catch (Exception e) {
            main.post(
                () -> {
                  if (!r.canceled) r.callback.failed(e);
                });
          }
        }
      } catch (Throwable error) {
        synchronized (lock) {
          waiting = new ArrayList<>(requests);
          requests.clear();
          if (jobs.get(asset.key) == this) jobs.remove(asset.key);
        }
        for (Request r : waiting)
          if (!r.canceled && r.callback != null)
            main.post(
                () -> {
                  if (!r.canceled) r.callback.failed(error);
                });
      } finally {
        if (guard != null) guard.close();
      }
    }

    void download() throws Exception {
      if (canceled) throw new InterruptedIOException();
      String ticket = null;
      HttpURLConnection c =
          Api.connection(
              asset.session.address, Rules.route(asset.source, asset.path), asset.session.token);
      connection = c;
      try {
        c.setRequestProperty("Accept-Encoding", "identity");
        if (!asset.expected.isEmpty())
          c.setRequestProperty("If-Match", "\"" + asset.expected + "\"");
        int status = c.getResponseCode();
        if (status != 200) throw Api.failure(status, c);
        long length = c.getContentLengthLong();
        if (length > Rules.MAX_IMAGE) throw new Api.Problem(0, "图片超过 50 MiB 保护上限，暂不载入");
        if (canceled) throw new InterruptedIOException();
        ticket =
            disk.reserve(asset.cover ? "cover" : "body", length > 0 ? length : Rules.MAX_IMAGE);
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        long received = 0;
        try (InputStream in = c.getInputStream();
            FileOutputStream out = new FileOutputStream(disk.temporary(ticket))) {
          byte[] buffer = new byte[128 * 1024];
          int n;
          while ((n = in.read(buffer)) != -1) {
            if (canceled || Thread.currentThread().isInterrupted())
              throw new InterruptedIOException();
            received += n;
            if (received > Rules.MAX_IMAGE || (length >= 0 && received > length))
              throw new IOException("image bound");
            out.write(buffer, 0, n);
            digest.update(buffer, 0, n);
          }
          out.getFD().sync();
        }
        if (received == 0 || length >= 0 && length != received)
          throw new IOException("short transfer");
        String sha = Rules.hex(digest.digest()), etag = c.getHeaderField("ETag");
        if (!asset.expected.isEmpty() && !sha.equals(asset.expected))
          throw new Api.Problem(0, "图片校验不一致，请刷新后重试");
        if (etag != null && etag.matches("\"[a-f0-9]{64}\"") && !etag.equals("\"" + sha + "\""))
          throw new IOException("image etag mismatch");
        disk.commit(ticket, asset.key, etag, received);
        ticket = null;
      } finally {
        connection = null;
        c.disconnect();
        if (ticket != null) disk.cancel(ticket);
      }
    }
  }

  private void decode(Request request, MediaCache.Lease lease) {
    Decoded result = null;
    long[] reserved = {0};
    boolean[] staticFallback = {false};
    try {
      if (request.canceled) {
        lease.close();
        return;
      }
      Asset asset = request.asset;
      ImageDecoder.OnHeaderDecodedListener header =
          (decoder, info, source) -> {
            long pixels = (long) info.getSize().getWidth() * info.getSize().getHeight();
            if (pixels <= 0 || pixels > 100_000_000) throw new ImageRejected("图片原始尺寸超过保护上限，已停止解码");
            if (info.isAnimated() && pixels > 16_000_000)
              throw new ImageRejected("动图原始尺寸超过 1600 万像素，已停止解码以保护内存");
            double scale =
                Math.min(
                    1,
                    Math.min(
                        (double) Math.max(1, asset.width) / info.getSize().getWidth(),
                        (double) Math.max(1, asset.height) / info.getSize().getHeight()));
            scale = Math.min(scale, Math.sqrt((asset.cover ? 900_000d : 2_500_000d) / pixels));
            if (info.isAnimated() && !asset.cover && !staticFallback[0]) {
              if (pixels > 8_000_000 || lease.size > 32L * 1024 * 1024)
                throw new AnimationLimited("动图超过 800 万像素或 32 MiB，已显示静态预览", false);
              long estimate =
                  lease.size + pixels * 8 + (long) (pixels * scale * scale) * 8 + 1024 * 1024;
              if (request.priority > 0 && estimate > 48L * 1024 * 1024)
                throw new AnimationLimited("大动图将在切到当前页后播放", true);
              if (!reserveAnimation(estimate))
                throw new AnimationLimited("动图播放资源暂不足，轻点提示重试", request.priority > 0);
              reserved[0] = estimate;
            }
            decoder.setTargetSize(
                Math.max(1, (int) Math.round(info.getSize().getWidth() * scale)),
                Math.max(1, (int) Math.round(info.getSize().getHeight() * scale)));
            decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
            decoder.setOnPartialImageListener(error -> false);
          };
      if (asset.cover) {
        Bitmap bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(lease.file), header);
        lease.close();
        covers.put(asset.bitmapKey(), bitmap);
        result = new Decoded(new BitmapDrawable(context.getResources(), bitmap), null);
      } else {
        Drawable drawable;
        try {
          drawable = ImageDecoder.decodeDrawable(ImageDecoder.createSource(lease.file), header);
        } catch (AnimationLimited limit) {
          staticFallback[0] = true;
          Bitmap preview = ImageDecoder.decodeBitmap(ImageDecoder.createSource(lease.file), header);
          lease.close();
          result =
              new Decoded(
                  new BitmapDrawable(context.getResources(), preview),
                  null,
                  limit.getMessage(),
                  limit.deferred,
                  null);
          Decoded ready = result;
          main.post(
              () -> {
                if (request.canceled) ready.close();
                else request.callback.ready(ready);
              });
          return;
        }
        if (drawable instanceof BitmapDrawable bitmap) {
          body.put(asset.bitmapKey(), bitmap.getBitmap());
          lease.close();
          result = new Decoded(drawable, null);
        } else {
          long charged = reserved[0];
          reserved[0] = 0;
          result =
              new Decoded(drawable, lease, "", false, () -> animationBytes.addAndGet(-charged));
        }
      }
      Decoded ready = result;
      main.post(
          () -> {
            if (request.canceled) ready.close();
            else request.callback.ready(ready);
          });
    } catch (Throwable error) {
      if (error instanceof OutOfMemoryError) trim();
      lease.close();
      if (result != null) result.close();
      main.post(
          () -> {
            if (!request.canceled) request.callback.failed(error);
          });
    } finally {
      if (reserved[0] > 0) animationBytes.addAndGet(-reserved[0]);
    }
  }

  void trim() {
    covers.evictAll();
    body.evictAll();
  }

  void cancelAll() {
    synchronized (lock) {
      for (Job job : new ArrayList<>(jobs.values())) {
        job.canceled = true;
        for (Request r : job.requests) r.canceled = true;
        if (job.connection != null) job.connection.disconnect();
      }
      jobs.clear();
      network.getQueue().clear();
    }
    trim();
  }
}
