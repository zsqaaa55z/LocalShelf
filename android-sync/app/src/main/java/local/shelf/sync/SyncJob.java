package local.shelf.sync;

import android.app.job.*;
import android.app.NotificationManager;
import android.content.*;
import android.net.*;
import android.os.*;

public final class SyncJob extends JobService {
    static final int MANUAL=401,AUTO=402;
    private JobParameters current;
    private SyncRunner.Cancel running;
    private final Handler main=new Handler(Looper.getMainLooper());
    static boolean pending(Context c){return c.getSystemService(JobScheduler.class).getPendingJob(MANUAL)!=null;}
    static void manual(Context c,boolean full,boolean preflight){
        if(SyncRunner.busy.get()||pending(c))throw new IllegalStateException("已有任务正在执行或等待系统恢复；请先暂停");
        if(Build.VERSION.SDK_INT>=34&&!preflight){
            var p=LocalState.prefs(c);String token=java.util.UUID.randomUUID().toString();
            PersistableBundle extras=new PersistableBundle();extras.putBoolean("full",full);extras.putBoolean("newOnly",p.getBoolean("newOnly",false));extras.putString("token",token);extras.putBoolean("unattended",p.getBoolean("unattended",true));
            JobInfo info=new JobInfo.Builder(MANUAL,new ComponentName(c,SyncJob.class)).setRequiredNetwork(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()).setUserInitiated(true).setBackoffCriteria(30_000,JobInfo.BACKOFF_POLICY_EXPONENTIAL).setExtras(extras).build();
            if(!p.edit().putString("taskToken",token).putBoolean("taskRequested",true).putInt("taskLimit",p.getInt("batchLimit",100)).putInt("taskUsed",0).putString("runState","scheduled").commit())throw new IllegalStateException("无法保存任务请求，请检查手机空间");
            try{if(c.getSystemService(JobScheduler.class).schedule(info)!=JobScheduler.RESULT_SUCCESS)throw new IllegalStateException("系统未能安排传输，请保持 App 前台后重试");}
            catch(RuntimeException e){p.edit().putBoolean("taskRequested",false).putString("runState","failed").commit();throw e;}
            LocalState.status(c,"任务已安排，等待 Wi-Fi 与系统启动传输；可息屏，仍受系统后台策略限制。\n"+(p.getInt("batchLimit",100)>0?"当前为分批模式，到达上限后主动暂停。":"当前为不限数量、连续同步。"));
        }else c.startForegroundService(new Intent(c,SyncService.class).putExtra("full",full).putExtra("preflight",preflight).putExtra("newOnly",LocalState.prefs(c).getBoolean("newOnly",false)));
    }
    static void automatic(Context c,boolean enabled){
        JobScheduler scheduler=c.getSystemService(JobScheduler.class);
        if(enabled){
            JobInfo info=new JobInfo.Builder(AUTO,new ComponentName(c,SyncJob.class)).setRequiredNetwork(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()).setRequiresCharging(true).setPersisted(true).setPeriodic(15*60*1000L).build();
            if(scheduler.schedule(info)!=JobScheduler.RESULT_SUCCESS)throw new IllegalStateException("自动检查未能启用");
        }else scheduler.cancel(AUTO);
        LocalState.prefs(c).edit().putBoolean("auto",enabled).apply();
    }
    static void pause(Context c){
        SyncRunner.stop();
        boolean saved=LocalState.prefs(c).edit().putBoolean("taskRequested",false).putBoolean("auto",false).putString("runState","paused").commit();
        JobScheduler scheduler=c.getSystemService(JobScheduler.class);scheduler.cancel(MANUAL);scheduler.cancel(AUTO);
        if(!SyncRunner.busy.get()){c.getSystemService(NotificationManager.class).cancel(SyncRunner.NOTICE);LocalState.status(c,"已暂停；自动检查已关闭，再次同步可继续");}
        if(!saved)LocalState.status(c,"已请求停止，但暂停状态无法保存，请检查手机空间");
    }
    @Override public boolean onStartJob(JobParameters params){
        var p=LocalState.prefs(this);
        if(params.getJobId()==MANUAL&&(!p.getBoolean("taskRequested",false)||!params.getExtras().getString("token","").equals(p.getString("taskToken",""))))return false;
        if(params.getJobId()==AUTO&&(p.getBoolean("batchPaused",false)||!p.getBoolean("auto",false)||pending(this)))return false;
        if(Build.VERSION.SDK_INT>=34 && params.isUserInitiatedJob())setNotification(params,SyncRunner.NOTICE,SyncRunner.notification(this,"正在准备同步…"),JOB_END_NOTIFICATION_POLICY_REMOVE);
        current=params;
        // A previous stopped worker may still be releasing SAF/network handles. Retain this job
        // and wait for its drain, rather than running two engines or losing the resumed task.
        beginWhenDrained(params);return true;
    }
    void beginWhenDrained(JobParameters params){
        if(current!=params)return;
        if(SyncRunner.busy.get()){main.postDelayed(()->beginWhenDrained(params),500);return;}
        boolean manual=params.getJobId()==MANUAL;var p=LocalState.prefs(this);
        if(manual&&!p.getBoolean("taskRequested",false)){current=null;jobFinished(params,false);return;}
        running=SyncRunner.start(this,params.getExtras().getBoolean("full",false),false,manual?params.getExtras().getBoolean("newOnly",false):p.getBoolean("newOnly",false),true,manual&&params.getExtras().getBoolean("unattended",false),manual?params.getExtras().getString("token",""):"",(estimated,transferred)->{
            if(current==params&&Build.VERSION.SDK_INT>=34){
                if(estimated>0)updateEstimatedNetworkBytes(params,JobInfo.NETWORK_BYTES_UNKNOWN,estimated);
                updateTransferredNetworkBytes(params,0,transferred);
            }
        },ended->{
            if(current==params){current=null;running=null;getSystemService(NotificationManager.class).cancel(SyncRunner.NOTICE);jobFinished(params,ended.reschedule&&p.getBoolean("taskRequested",false));}
        });
    }
    @Override public boolean onStopJob(JobParameters params){
        int reason=Build.VERSION.SDK_INT>=31?params.getStopReason():0;var p=LocalState.prefs(this);
        boolean retry=params.getJobId()==MANUAL?RecoveryPolicy.reschedule(p.getBoolean("taskRequested",false),params.getExtras().getBoolean("unattended",false),reason):p.getBoolean("auto",false)&&reason!=1&&reason!=13;
        if(current==params&&running!=null&&running.terminal)retry=retry&&running.reschedule;
        if(current==params){
            current=null;SyncRunner.Cancel own=running;running=null;
            String explanation=RecoveryPolicy.stopReason(reason);
            if(own!=null&&!own.terminal)own.stop(explanation,true,retry);
            p.edit().putInt("lastSystemStop",reason).putLong("lastSystemStopAt",System.currentTimeMillis()).apply();
            if(own==null){p.edit().putString("runState",retry?"waiting_system":"paused").apply();LocalState.status(this,explanation+(retry?"；等待系统安排续传":"；请手动继续"));}
        }
        return retry;
    }
}
