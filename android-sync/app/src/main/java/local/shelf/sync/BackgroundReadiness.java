package local.shelf.sync;

import android.app.*;
import android.content.*;
import android.net.Uri;
import android.os.*;
import android.provider.Settings;

final class BackgroundReadiness {
    static String summary(Context c){
        PowerManager power=c.getSystemService(PowerManager.class);
        NotificationManager notifications=c.getSystemService(NotificationManager.class);
        boolean enabled=notifications.areNotificationsEnabled();
        NotificationChannel channel=notifications.getNotificationChannel("sync");
        boolean channelEnabled=channel==null||channel.getImportance()!=NotificationManager.IMPORTANCE_NONE;
        String result="系统通知："+(enabled&&channelEnabled?"已允许":"未允许 / 同步通知频道已关闭")+
            "\n电池优化豁免："+(power.isIgnoringBatteryOptimizations(c.getPackageName())?"已豁免":"未豁免")+
            "\n系统省电模式："+(power.isPowerSaveMode()?"已开启，建议关闭":"未开启")+
            "\n电源状态："+(c.getSystemService(BatteryManager.class).isCharging()?"正在供电 / 已充满":"未在充电")+
            "\n传输机制："+(Build.VERSION.SDK_INT>=34?"系统长时间传输任务（UIDT）":"前台服务兼容模式");
        var p=LocalState.prefs(c);int limit=p.getInt("batchLimit",100);
        result+="\n批次："+(limit==0?"不限数量，连续同步":limit+" 组后主动暂停");
        if(p.contains("lastSystemStop"))result+="\n上次系统停止原因："+RecoveryPolicy.stopReason(p.getInt("lastSystemStop",0));
        return result+"\n\nHyperOS 的「无限制」「后台自启动」和最近任务锁定需手动核对，App 无法可靠读取全部厂商设置。\n\n建议接电、通风散热，允许通知并关闭省电模式。不要清理本应用或在系统任务管理器中点停止。系统仍可因温度、内存等情况中止；息屏不等于永久保活。";
    }
    static void show(Activity a){new AlertDialog.Builder(a).setTitle("长时间上传检查").setMessage(summary(a))
        .setPositiveButton("应用设置",(d,w)->open(a,new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:"+a.getPackageName()))))
        .setNeutralButton("电池优化",(d,w)->open(a,new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
        .setNegativeButton("关闭",null).show();}
    static void notifications(Activity a){open(a,new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,a.getPackageName()));}
    static void open(Activity a,Intent intent){try{a.startActivity(intent);}catch(ActivityNotFoundException|SecurityException e){new AlertDialog.Builder(a).setMessage("系统未提供此入口，请到设置中搜索「书库同步」，检查电池与通知权限。").setPositiveButton("知道了",null).show();}}
}
