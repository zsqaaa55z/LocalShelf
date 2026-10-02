package local.shelf.sync;

import android.app.*;
import android.content.*;
import android.os.*;
import java.io.InterruptedIOException;
import java.io.IOException;
import java.util.function.Consumer;
import java.util.concurrent.atomic.AtomicBoolean;

final class SyncRunner {
    static final AtomicBoolean busy=new AtomicBoolean(false);
    static volatile Cancel active;
    static final int NOTICE=71;
    interface Observer {void update(long estimated,long transferred);}
    static class Cancel {
        volatile boolean stopped,systemStopped,reschedule,terminal;
        volatile String reason="";
        final TransferMonitor monitor=new TransferMonitor();
        boolean unattended,preflight;String token="";int limit,used;
        void check()throws InterruptedIOException{if(stopped || Thread.currentThread().isInterrupted())throw new InterruptedIOException("已暂停；再次同步会从已有进度继续");}
        void stop(String reason,boolean system,boolean retry){this.reason=reason;systemStopped=system;reschedule=retry;stopped=true;}
        void checkpoint(android.content.SharedPreferences.Editor editor)throws IOException {
            check();
            if(!token.isEmpty())editor.putInt("taskUsed",++used);
            if(!editor.commit())throw new IOException("无法保存同步断点，请检查手机剩余空间；已确认文件会在恢复时复用");
            monitor.complete();
        }
    }
    static Notification notification(Context c,String message){
        NotificationManager nm=c.getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("sync","书库同步",NotificationManager.IMPORTANCE_LOW));
        PendingIntent open=PendingIntent.getActivity(c,0,new Intent(c,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder=new Notification.Builder(c,"sync").setSmallIcon(local.shelf.sync.R.drawable.ic_app).setContentTitle("书库同步").setContentText(message).setStyle(new Notification.BigTextStyle().bigText(message)).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE);
        addPause(c,builder);
        return builder.build();
    }
    static void addPause(Context c,Notification.Builder builder){
        String token=LocalState.prefs(c).getString("taskToken","");
        if(!token.isEmpty()){
            Intent pause=new Intent(c,SyncPauseReceiver.class).setAction("local.shelf.sync.PAUSE").setData(android.net.Uri.parse("localshelf-sync://pause/"+token));
            builder.addAction(new Notification.Action.Builder(null,"暂停同步",PendingIntent.getBroadcast(c,0,pause,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE)).build());
        }
    }
    static Cancel start(Context ctx,boolean full,boolean preflight,boolean newOnly,boolean jobManaged,boolean allowRetry,String token,Observer observer,Consumer<Cancel> finished){
        if(!busy.compareAndSet(false,true))return null;
        Context c=ctx.getApplicationContext();Cancel cancel=new Cancel();cancel.token=token;cancel.preflight=preflight;cancel.unattended=allowRetry&&!preflight;active=cancel;
        if(token.isEmpty())LocalState.prefs(c).edit().putString("taskToken",java.util.UUID.randomUUID().toString()).apply();
        Handler main=new Handler(Looper.getMainLooper());
        Runnable pulse=new Runnable(){public void run(){if(active!=cancel)return;try{
            if(!cancel.stopped)c.getSystemService(NotificationManager.class).notify(NOTICE,notification(c,cancel.monitor.summary()));
            observer.update(cancel.monitor.estimatedBytes(),cancel.monitor.confirmedBytes());
        }catch(RuntimeException ignored){}main.postDelayed(this,5000);}};
        c.getSystemService(NotificationManager.class).cancel(72);main.post(pulse);
        new Thread(()->{
            // JobScheduler owns the wake lock for UIDT and ordinary jobs. Do not stack a 6-hour manual lock on them.
            PowerManager.WakeLock wake=null;
            SyncEngine engine=null;
            try{
                var p=LocalState.prefs(c);cancel.check();
                cancel.limit=token.isEmpty()?p.getInt("batchLimit",100):p.getInt("taskLimit",100);
                cancel.used=token.isEmpty()?0:p.getInt("taskUsed",0);
                if(!p.edit().putString("runState","running").commit())throw new IOException("无法保存任务状态");
                if(!jobManaged){wake=c.getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"LocalShelfSync:legacy-transfer");wake.acquire(6*60*60*1000L);}
                engine=new SyncEngine(c,cancel,text->{cancel.monitor.stage(text);LocalState.status(c,text);});
                if(preflight)engine.preflight();
                else if(TaskBudget.exhausted(cancel.limit,cancel.used)){engine.batchPaused=true;LocalState.status(c,"本批数量已完成，进度已保留；点击继续才会开始下一批");}
                else engine.run(full,newOnly,TaskBudget.remaining(cancel.limit,cancel.used));
                cancel.check();
                cancel.terminal=true;
                if(!p.edit().putString("runState",engine.batchPaused?"batch":"complete").putBoolean("batchPaused",engine.batchPaused).putInt("runMissingSources",engine.missingSources).putBoolean("taskRequested",false).commit())throw new IOException("无法保存完成状态");
            }catch(Exception e){
                boolean retry=cancel.systemStopped&&cancel.reschedule&&RecoveryPolicy.cancellation(e)||!cancel.stopped&&cancel.unattended&&RecoveryPolicy.exhausted(e);
                cancel.terminal=true;
                cancel.reschedule=retry;
                String state=retry?"waiting_system":cancel.stopped?"paused":"failed";
                var editor=LocalState.prefs(c).edit().putString("runState",state);
                if(!retry)editor.putBoolean("taskRequested",false);
                if(!editor.commit()){retry=false;cancel.reschedule=false;state="failed";}
                LocalState.status(c,(retry?"等待系统安排续传，进度已保留":cancel.stopped?"已暂停，进度已保留":"同步未完成，需要处理，进度已保留")+
                    "\n"+(cancel.reason.isEmpty()?friendly(e):cancel.reason)+"\n"+cancel.monitor.summary()+
                    (retry?"\n系统条件允许后尝试恢复；不会使用移动数据。":"\n处理后点击「开始 / 继续同步」。"));
            }finally{
                if(engine!=null&&!preflight)saveRunStats(c,engine);if(wake!=null&&wake.isHeld())wake.release();
                main.post(()->{main.removeCallbacks(pulse);try{finished.accept(cancel);terminal(c,cancel);}finally{if(active==cancel){active=null;busy.set(false);}}});
            }
        },"localshelf-sync").start();return cancel;
    }
    static void stop(){Cancel cancel=active;if(cancel!=null)cancel.stop("你已暂停同步",false,false);}
    static void terminal(Context c,Cancel cancel){
        var p=LocalState.prefs(c);String state=p.getString("runState","");
        String text=switch(state){case "complete"->"同步已完成";case "batch"->"本批已完成，等待你继续";case "waiting_system"->"等待系统恢复续传";case "paused"->"同步已暂停";default->"同步未完成，请打开 App 处理";};
        if(state.equals("complete")&&cancel.preflight)text="迁移预检已完成（未上传文件）";
        else if((state.equals("complete")||state.equals("batch"))&&p.getInt("runMissingSources",0)>0)text+=" · 有 "+p.getInt("runMissingSources",0)+" 本源目录缺失，请查看说明";
        if(cancel.systemStopped&&!cancel.reason.isEmpty())text+=" · "+cancel.reason;
        try{
            NotificationManager nm=c.getSystemService(NotificationManager.class);
            nm.createNotificationChannel(new NotificationChannel("sync-result","同步完成与异常",NotificationManager.IMPORTANCE_DEFAULT));
            PendingIntent open=PendingIntent.getActivity(c,0,new Intent(c,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
            Notification.Builder b=new Notification.Builder(c,"sync-result").setSmallIcon(local.shelf.sync.R.drawable.ic_app).setContentTitle("书库同步").setContentText(text).setStyle(new Notification.BigTextStyle().bigText(text+"\n"+cancel.monitor.summary())).setContentIntent(open).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE);
            if(state.equals("waiting_system")||state.equals("paused"))b.setChannelId("sync");
            if(state.equals("waiting_system"))addPause(c,b);
            nm.notify(72,b.build());
        }catch(RuntimeException ignored){}
    }
    static void saveRunStats(Context c,SyncEngine engine){
        // Bounded anonymous history, not titles, paths, IDs, URLs or pairing data.
        // Best effort only: diagnostics must never alter the transfer outcome.
        try{
            var p=LocalState.prefs(c);org.json.JSONArray previous;
            try{previous=new org.json.JSONArray(p.getString("runHistory","[]"));}catch(org.json.JSONException e){previous=new org.json.JSONArray();}
            org.json.JSONObject item=new org.json.JSONObject(engine.stats.snapshot());
            item.put("endedAtMs",System.currentTimeMillis()).put("state",p.getString("runState","unknown"))
                .put("version",c.getPackageManager().getPackageInfo(c.getPackageName(),0).versionName)
                .put("readLanes",engine.readConcurrency).put("uploadLanes",engine.uploadConcurrency)
                .put("pipelineEnabled",engine.pipelineEnabled).put("batchSupported",engine.batchSupported)
                .put("scannedBooks",engine.scannedBooks).put("archiveGroups",engine.archiveGroupsDone)
                .put("verifiedFiles",engine.verifiedFiles).put("verifiedBytes",engine.verifiedBytes);
            org.json.JSONArray next=new org.json.JSONArray();
            for(int i=Math.max(0,previous.length()-19);i<previous.length();i++)next.put(previous.getJSONObject(i));
            next.put(item);p.edit().putString("runHistory",next.toString()).commit();
        }catch(Exception ignored){}
    }
    static String friendly(Exception e){if(e instanceof java.net.SocketTimeoutException)return "连接或传输超时，请确认当前 Wi-Fi 能访问接收端；进度已保留";if(e instanceof java.net.ConnectException||e instanceof java.net.NoRouteToHostException)return "无法连接接收端，请检查服务是否启动、地址是否改变，以及当前 Wi-Fi 是否允许设备互通";if(e instanceof java.net.SocketException)return "网络连接已中断，请恢复 Wi-Fi 与接收端连接后继续";if(e instanceof java.io.FileNotFoundException)return "文件或授权已失效，请重新选择备份 / 下载目录";String m=e.getMessage();return m==null?e.getClass().getSimpleName():m;}
}
