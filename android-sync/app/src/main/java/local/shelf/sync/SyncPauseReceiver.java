package local.shelf.sync;

import android.content.*;

/** Explicit, non-exported action; an old notification cannot pause a newer task. */
public final class SyncPauseReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c,Intent intent){
        if(!"local.shelf.sync.PAUSE".equals(intent.getAction())||intent.getData()==null)return;
        String token=intent.getData().getLastPathSegment();
        if(token!=null&&!token.isEmpty()&&token.equals(LocalState.prefs(c).getString("taskToken","")))SyncJob.pause(c);
    }
}
