package local.shelf;
import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.net.*;
import android.net.nsd.*;
import android.os.*;
import java.net.Inet4Address;
import java.util.concurrent.*;
import org.json.JSONArray;
import java.nio.charset.StandardCharsets;

public class BridgeService extends Service {
    static volatile String state="共享已停止",host="",secret="";
    static volatile boolean running=false;
    static volatile String deviceId="";
    static volatile PairingWindow pairingWindow;
    private NsdManager.RegistrationListener discovery;
    private String discoveryState="";
    private ShelfServer server;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler main=new Handler(Looper.getMainLooper());
    private boolean destroyed=false,starting=false;
    private boolean refreshing=false;
    private String indexNotice="";
    private PowerManager.WakeLock wake;
    private boolean economy=false,resting=false;
    private long lastTraffic;
    private String summary="";
    private final Runnable idleCheck=new Runnable(){public void run(){
        if(destroyed||!running||!economy)return;
        if(IdlePolicy.shouldRest(true,SystemClock.elapsedRealtime(),lastTraffic)){
            if(wake!=null&&wake.isHeld())wake.release();
            if(!resting){resting=true;publishMode();}
        }
        main.postDelayed(this,10_000);
    }};
    private void traffic(){
        if(destroyed||!running||!economy)return;
        long now=SystemClock.elapsedRealtime();if(now-lastTraffic<1000)return;lastTraffic=now;
        wake.acquire(90_000);
        if(resting){resting=false;publishMode();}
    }
    private void publishMode(){
        String mode=!economy?"稳定共享 · 保持唤醒":resting?"省电待机 · 锁屏连接可能延迟":"省电模式 · 传输活跃";
        state=summary+"\n"+mode+"\n"+discoveryState+(indexNotice.isEmpty()?"":"\n"+indexNotice);
        getSystemService(NotificationManager.class).notify(7,notification(mode+" · 点此查看配对码"));
    }
    private ConnectivityManager.NetworkCallback callback;
    private Network network;
    private void advertise(){
        NsdManager nsd=getSystemService(NsdManager.class);
        NsdServiceInfo info=new NsdServiceInfo();info.setServiceName("LocalShelf-"+deviceId);info.setServiceType("_localshelf._tcp.");info.setPort(8088);if(Build.VERSION.SDK_INT>=33)info.setNetwork(network);info.setAttribute("id",deviceId);info.setAttribute("v","2");
        discovery=new NsdManager.RegistrationListener(){
            public void onServiceRegistered(NsdServiceInfo i){main.post(()->{if(!destroyed){discoveryState="自动发现已开启 · 配对后无需重复扫码";publishMode();}});}
            public void onRegistrationFailed(NsdServiceInfo i,int code){main.post(()->{if(!destroyed){discoveryState="自动发现不可用 · 可使用原地址或重新扫码";publishMode();}});}
            public void onServiceUnregistered(NsdServiceInfo i){}
            public void onUnregistrationFailed(NsdServiceInfo i,int code){}
        };
        try{nsd.registerService(info,NsdManager.PROTOCOL_DNS_SD,discovery);}catch(Exception e){discoveryState="自动发现不可用 · 可使用原地址或重新扫码";}
    }
    @Override public IBinder onBind(Intent i){return null;}
    Notification notification(String message){
        PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,BridgeService.class).setAction("stop"),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this,"bridge").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("LocalShelf · "+(running?"桥接已开启":"桥接启动中")).setContentText(message).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE).addAction(new Notification.Action.Builder(null,"停止共享",stop).build()).build();
    }
    @Override public int onStartCommand(Intent intent,int flags,int id){
        if(intent!=null&&"stop".equals(intent.getAction())){state="共享已停止";stopSelf();return START_NOT_STICKY;}
        if(intent!=null&&"renew-pair-code".equals(intent.getAction())){
            if(running&&server!=null)server.pins.renew();else if(!starting)stopSelf();
            return START_NOT_STICKY;
        }
        if(intent!=null&&"refresh-index".equals(intent.getAction())){
            if(!running||server==null){if(!starting)stopSelf();return START_NOT_STICKY;}
            if(refreshing)return START_NOT_STICKY;
            String requestedBook=intent.getStringExtra("book-id");final String book=requestedBook==null?"":requestedBook;
            if(!book.isEmpty()&&!book.matches("[0-9]{1,20}"))return START_NOT_STICKY;
            refreshing=true;indexNotice="正在刷新索引记录…";publishMode();
            final ShelfServer target=server;
            worker.execute(()->{
                String result;try{target.refreshIndexes(book);result="索引已刷新；iPhone 请退出并重新打开漫画。新增漫画仍需导入 .db。";}catch(Exception error){result="索引刷新失败："+error.getMessage();}
                final String message=result;main.post(()->{if(destroyed)return;refreshing=false;indexNotice=message;summary="桥接已开启 · "+target.books.size()+" 本 · "+target.missingCount()+" 项文件夹缺失";publishMode();});
            });return START_NOT_STICKY;
        }
        if(starting||running)return START_NOT_STICKY;starting=true;
        getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("bridge","局域网桥接状态",NotificationManager.IMPORTANCE_LOW));
        state="正在建立书库索引…";startForeground(7,notification("正在索引，可离开页面"),ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        try{
            ConnectivityManager cm=getSystemService(ConnectivityManager.class);network=cm.getActiveNetwork();NetworkCapabilities caps=cm.getNetworkCapabilities(network);LinkProperties lp=cm.getLinkProperties(network);
            if(caps==null||!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)||caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)||lp==null)throw new Exception("请连接私人 Wi-Fi；暂不支持 VPN 接口");
            String address=null;for(LinkAddress a:lp.getLinkAddresses())if(a.getAddress() instanceof Inet4Address&&a.getAddress().isSiteLocalAddress())address=a.getAddress().getHostAddress();
            if(address==null)throw new Exception("未取得私人 Wi-Fi IPv4 地址");final String bind=address;
            String root=getSharedPreferences("shelf",0).getString("root",null);if(root==null)throw new Exception("请先授权目录");
            callback=new ConnectivityManager.NetworkCallback(){
                public void onLost(Network n){if(n.equals(network))main.post(()->{state="Wi-Fi 已断开，请重新开启共享";stopSelf();});}
                public void onLinkPropertiesChanged(Network n,LinkProperties p){if(n.equals(network)&&p.getLinkAddresses().stream().noneMatch(a->a.getAddress().getHostAddress().equals(bind)))main.post(()->{state="Wi-Fi 地址改变，请重新开启共享；配对仍保留";stopSelf();});}
            };cm.registerNetworkCallback(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),callback);
            worker.execute(()->{try{
                byte[] bytes;try(java.io.InputStream in=new android.util.AtomicFile(getFileStreamPath("catalog.json")).openRead()){bytes=BoundedInput.read(in,8*1024*1024+1);}if(bytes.length>8*1024*1024)throw new Exception("清单过大");
                ShelfServer ready=new ShelfServer(bind,getContentResolver(),Uri.parse(root),new JSONArray(new String(bytes,StandardCharsets.UTF_8)),PairingStore.load(this),new IndexStore(new java.io.File(getCacheDir(),"file-index-v1")));
                main.post(()->{if(destroyed)return;try{ready.start(5000,false);server=ready;host=bind;secret=ready.secret;running=true;
                    economy=getSharedPreferences("shelf",0).getBoolean("economy",false);resting=false;lastTraffic=SystemClock.elapsedRealtime();
                    wake=getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"LocalShelf:bridge");wake.setReferenceCounted(false);
                    if(economy){wake.acquire(90_000);main.postDelayed(idleCheck,10_000);}else{wake.acquire();}
                    if(economy)ready.activity=()->main.post(this::traffic);
                    deviceId=ready.pairing.id;pairingWindow=ready.pins;discoveryState="正在发布自动发现…";advertise();
                    summary="桥接已开启 · "+ready.books.size()+" 本 · "+ready.missingCount()+" 项文件夹缺失";publishMode();
                }catch(Exception e){state="启动失败："+e.getMessage();stopSelf();}});
            }catch(Exception e){main.post(()->{if(!destroyed){state="索引失败："+e.getMessage();stopSelf();}});}});
        }catch(Exception e){state=e.getMessage();stopSelf();}return START_NOT_STICKY;
    }
    @Override public void onDestroy(){destroyed=true;if(server!=null)server.pins.close();pairingWindow=null;main.removeCallbacks(idleCheck);if(discovery!=null)try{getSystemService(NsdManager.class).unregisterService(discovery);}catch(Exception ignored){}if(server!=null){server.activity=()->{};server.stop();}if(wake!=null&&wake.isHeld())wake.release();if(callback!=null)try{getSystemService(ConnectivityManager.class).unregisterNetworkCallback(callback);}catch(Exception ignored){}worker.shutdownNow();running=false;host="";secret="";deviceId="";if(state.startsWith("桥接已开启")||state.startsWith("正在"))state="共享已停止";stopForeground(STOP_FOREGROUND_REMOVE);super.onDestroy();}
}
