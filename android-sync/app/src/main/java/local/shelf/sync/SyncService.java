package local.shelf.sync;

import android.app.*;
import android.content.*;
import android.os.IBinder;

/** Fallback for Android 10–13; Android 14+ uses user-initiated transfer jobs. */
public final class SyncService extends Service {
    private boolean owns;
    @Override public int onStartCommand(Intent intent,int flags,int id){
        startForeground(SyncRunner.NOTICE,SyncRunner.notification(this,"正在准备同步…"));
        owns=SyncRunner.start(this,intent!=null&&intent.getBooleanExtra("full",false),intent!=null&&intent.getBooleanExtra("preflight",false),intent!=null&&intent.getBooleanExtra("newOnly",false),false,false,"",(estimated,transferred)->{},ended->{owns=false;stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();})!=null;
        if(!owns){stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}return START_NOT_STICKY;
    }
    @Override public void onDestroy(){if(owns)SyncRunner.stop();super.onDestroy();}
    @Override public void onTimeout(int startId,int fgsType){SyncRunner.stop();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
    @Override public IBinder onBind(Intent intent){return null;}
}
