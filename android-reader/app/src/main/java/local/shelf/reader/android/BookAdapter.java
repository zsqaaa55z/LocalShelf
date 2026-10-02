package local.shelf.reader.android;

import android.content.Context;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.*;
import android.widget.*;
import androidx.recyclerview.widget.RecyclerView;
import java.util.*;

final class BookAdapter extends RecyclerView.Adapter<BookAdapter.Holder> {
  interface Actions {
    void open(Models.Book book);

    void more(Models.Book book);
  }

  final ReaderApp app;
  final Actions actions;
  final List<Models.Book> books = new ArrayList<>();
  final Set<Holder> bound = new HashSet<>();
  String source, scope;
  Api.Session session;
  boolean hidden;
  int columns = 3;

  BookAdapter(ReaderApp app, Actions actions) {
    this.app = app;
    this.actions = actions;
    setHasStableIds(true);
  }

  void submit(
      List<Models.Book> value,
      Api.Session session,
      String source,
      String scope,
      boolean hidden,
      int columns) {
    release();
    this.session = session;
    this.source = source;
    this.scope = scope;
    this.hidden = hidden;
    this.columns = columns;
    books.clear();
    books.addAll(value);
    notifyDataSetChanged();
  }

  void release() {
    for (Holder h : new ArrayList<>(bound)) h.release();
    bound.clear();
  }

  @Override
  public long getItemId(int position) {
    return Long.parseUnsignedLong(books.get(position).id);
  }

  @Override
  public int getItemCount() {
    return books.size();
  }

  @Override
  public Holder onCreateViewHolder(ViewGroup parent, int type) {
    return new Holder(parent.getContext());
  }

  @Override
  public void onBindViewHolder(Holder h, int position) {
    h.bind(books.get(position));
    bound.add(h);
  }

  @Override
  public void onViewRecycled(Holder h) {
    h.release();
    bound.remove(h);
  }

  final class Holder extends RecyclerView.ViewHolder {
    final LinearLayout root;
    final FrameLayout cover;
    final ImageView image;
    final TextView placeholder, badge, title, note;
    MediaPipeline.Request request;
    MediaPipeline.Decoded decoded;
    int ticket;

    Holder(Context c) {
      super(Ui.column(c));
      root = (LinearLayout) itemView;
      root.setHapticFeedbackEnabled(false);
      root.setPadding(Ui.dp(c, 6), Ui.dp(c, 6), Ui.dp(c, 6), Ui.dp(c, 14));
      root.setLayoutParams(new RecyclerView.LayoutParams(-1, -2));
      cover = new FrameLayout(c);
      cover.setBackground(Ui.shape(Ui.SURFACE, 12, c));
      cover.setClipToOutline(true);
      root.addView(cover, new LinearLayout.LayoutParams(-1, Ui.dp(c, 180)));
      placeholder = Ui.text(c, "", 28, Ui.MUTED);
      placeholder.setGravity(Gravity.CENTER);
      cover.addView(placeholder, new FrameLayout.LayoutParams(-1, -1));
      image = new ImageView(c);
      image.setScaleType(ImageView.ScaleType.FIT_CENTER);
      image.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
      cover.addView(image, new FrameLayout.LayoutParams(-1, -1));
      badge = Ui.text(c, "", 13, Ui.TEXT);
      badge.setTypeface(null, Typeface.BOLD);
      badge.setGravity(Gravity.CENTER);
      badge.setPadding(Ui.dp(c, 6), Ui.dp(c, 2), Ui.dp(c, 6), Ui.dp(c, 2));
      badge.setBackground(Ui.shape(0xdd181818, 6, c));
      FrameLayout.LayoutParams bp =
          new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.RIGHT);
      bp.setMargins(0, 0, Ui.dp(c, 6), Ui.dp(c, 6));
      cover.addView(badge, bp);
      title = Ui.text(c, "", 14, Ui.TEXT);
      title.setMaxLines(2);
      title.setMinLines(2);
      title.setEllipsize(TextUtils.TruncateAt.END);
      title.setPadding(0, Ui.dp(c, 8), 0, 0);
      root.addView(title, new LinearLayout.LayoutParams(-1, -2));
      note = Ui.text(c, "", 11, Ui.MINT);
      note.setMaxLines(1);
      note.setEllipsize(TextUtils.TruncateAt.END);
      root.addView(note);
    }

    void bind(Models.Book book) {
      release();
      int t = ++ticket;
      Context c = root.getContext();
      int screen = c.getResources().getDisplayMetrics().widthPixels;
      int width = Math.max(Ui.dp(c, 80), (screen - Ui.dp(c, 24)) / columns - Ui.dp(c, 12));
      cover.getLayoutParams().height = Math.round(width * 1.40f);
      cover.requestLayout();
      title.setText(book.title);
      note.setText(book.note);
      note.setVisibility(book.note.isEmpty() ? View.GONE : View.VISIBLE);
      badge.setText(Integer.toString(book.count));
      badge.setVisibility(book.count > 0 ? View.VISIBLE : View.GONE);
      root.setContentDescription(
          book.title
              + (book.count > 0 ? "，" + book.count + " 张" : "")
              + (book.available ? "" : "，文件缺失"));
      root.setOnClickListener(v -> actions.open(book));
      root.setOnLongClickListener(
          v -> {
            actions.more(book);
            return true;
          });
      placeholder.setText(hidden ? "▧" : book.available ? "" : "暂缺");
      if (hidden || !book.available || session == null || !app.verified) return;
      request =
          app.media.request(
              MediaPipeline.Asset.cover(session, source, scope, book, width),
              0,
              new MediaPipeline.Callback() {
                public void ready(MediaPipeline.Decoded value) {
                  if (t != ticket) {
                    value.close();
                    return;
                  }
                  decoded = value;
                  image.setImageDrawable(value.drawable);
                  placeholder.setText("");
                }

                public void failed(Throwable error) {
                  if (t == ticket) placeholder.setText("···");
                }
              });
    }

    void release() {
      ticket++;
      if (request != null) {
        request.close();
        request = null;
      }
      image.setImageDrawable(null);
      if (decoded != null) {
        decoded.close();
        decoded = null;
      }
    }
  }
}
