package local.shelf.reader.android;

import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import androidx.recyclerview.widget.RecyclerView;

/** One full-span library header; the book adapter keeps book-only indices and IDs. */
final class LibraryHeaderAdapter extends RecyclerView.Adapter<LibraryHeaderAdapter.Holder> {
  private final View content;

  LibraryHeaderAdapter(View content) {
    this.content = content;
    setHasStableIds(true);
  }

  @Override
  public int getItemCount() {
    return 1;
  }

  @Override
  public long getItemId(int position) {
    return 0;
  }

  @Override
  public Holder onCreateViewHolder(ViewGroup parent, int viewType) {
    FrameLayout frame = new FrameLayout(parent.getContext());
    frame.setLayoutParams(new RecyclerView.LayoutParams(-1, -2));
    return new Holder(frame);
  }

  @Override
  public void onBindViewHolder(Holder holder, int position) {
    FrameLayout frame = (FrameLayout) holder.itemView;
    if (content.getParent() == frame) return;
    // A recreated holder must not duplicate the Activity's controls or callbacks.
    if (content.getParent() instanceof ViewGroup old) old.removeView(content);
    frame.addView(content, new FrameLayout.LayoutParams(-1, -2));
  }

  @Override
  public void onViewRecycled(Holder holder) {
    if (content.getParent() == holder.itemView) ((FrameLayout) holder.itemView).removeView(content);
  }

  static final class Holder extends RecyclerView.ViewHolder {
    Holder(View view) {
      super(view);
    }
  }
}
