package local.shelf.sync;

import android.content.Context;
import android.net.*;
import javax.net.ssl.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.*;
import org.json.*;
import java.util.concurrent.*;

final class Net implements AutoCloseable {
    static final class Failure extends IOException {
        final int status;final String code;
        Failure(int status,String code){super(explain(code));this.status=status;this.code=code;}
        boolean retryable(){return RecoveryPolicy.temporaryHttp(status,code)||(status==400||status==409)&&(code.equals("offset_conflict")||code.equals("upload_not_found")||code.equals("file_incomplete"));}
    }
    private static final HostnameVerifier PINNED_HOST=(name,session)->true;
    private final Context context; private final JSONObject pairing; private final SSLSocketFactory sockets;private volatile Network boundNetwork;private volatile long networkCheckedAt;private volatile HttpsURLConnection lastConnection;private volatile boolean closed,aborted;private final TransferStats stats;
    private final SyncRunner.Cancel cancellation;
    private HttpsURLConnection reusableConnection;
    private static final ScheduledThreadPoolExecutor GUARD=new ScheduledThreadPoolExecutor(1,r->{Thread t=new Thread(r,"sync-request-guard");t.setDaemon(true);return t;});
    static {GUARD.setRemoveOnCancelPolicy(true);GUARD.setKeepAliveTime(30,TimeUnit.SECONDS);GUARD.allowCoreThreadTimeOut(true);}
    private final ConnectivityManager manager;
    private final ConnectivityManager.NetworkCallback networkChanges=new ConnectivityManager.NetworkCallback(){
        @Override public void onLost(Network network){if(network.equals(boundNetwork)){boundNetwork=null;networkCheckedAt=0;HttpsURLConnection current=lastConnection;if(current!=null)current.disconnect();}}
        @Override public void onCapabilitiesChanged(Network network,NetworkCapabilities caps){if(network.equals(boundNetwork)&&(!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)||caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))){boundNetwork=null;networkCheckedAt=0;}}
    };
    Net(Context c,JSONObject config)throws Exception {
        this(c,config,null);
    }
    Net(Context c,JSONObject config,TransferStats stats)throws Exception {
        this(c,config,stats,null);
    }
    Net(Context c,JSONObject config,TransferStats stats,SyncRunner.Cancel cancellation)throws Exception {
        this.stats=stats;this.cancellation=cancellation;
        validate(config);context=c;pairing=config;
        String pin=config.getString("certificateSha256");
        X509TrustManager trust=new X509TrustManager(){
            public java.security.cert.X509Certificate[] getAcceptedIssuers(){return new java.security.cert.X509Certificate[0];}
            public void checkClientTrusted(java.security.cert.X509Certificate[] chain,String auth)throws CertificateException{throw new CertificateException("client unsupported");}
            public void checkServerTrusted(java.security.cert.X509Certificate[] chain,String auth)throws CertificateException {
                try{if(chain.length<1 || !MessageDigest.isEqual(MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded()),hexBytes(pin)))throw new CertificateException("NAS 证书不匹配，请核对配对文件");chain[0].checkValidity();}
                catch(GeneralSecurityException e){throw new CertificateException("NAS 证书校验失败",e);}
            }
        };
        SSLContext ssl=SSLContext.getInstance("TLS");ssl.init(null,new TrustManager[]{trust},new SecureRandom());sockets=ssl.getSocketFactory();
        manager=context.getSystemService(ConnectivityManager.class);
        manager.registerNetworkCallback(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),networkChanges);
    }
    static byte[] hexBytes(String s){byte[] b=new byte[s.length()/2];for(int i=0;i<b.length;i++)b[i]=(byte)Integer.parseInt(s.substring(i*2,i*2+2),16);return b;}
    static void validate(JSONObject p)throws Exception {
        if(!"localshelf-sync".equals(p.getString("app")) || p.getInt("version")!=1 || !p.getString("token").matches("[a-f0-9]{64}") || !p.getString("certificateSha256").matches("[a-f0-9]{64}"))throw new IOException("请选择 NAS 接收端生成的 pairing.json");
        NasAddress.requireValid(p.getString("url"));
    }
    Network wifi()throws IOException {
        long now=android.os.SystemClock.elapsedRealtime();Network cached=boundNetwork;
        if(cached!=null&&now-networkCheckedAt<5000)return cached;
        if(cached!=null){NetworkCapabilities caps=manager.getNetworkCapabilities(cached);if(isWifi(caps)){networkCheckedAt=now;return cached;}}
        for(Network n:manager.getAllNetworks()){if(isWifi(manager.getNetworkCapabilities(n))){if(cached==null||!cached.equals(n))cached=n;boundNetwork=cached;networkCheckedAt=now;return cached;}}
        boundNetwork=null;networkCheckedAt=0;
        throw new RecoveryLoop.Temporary("等待连接家庭 Wi-Fi；不会使用移动数据",null);
    }
    private static boolean isWifi(NetworkCapabilities caps){return caps!=null&&caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)&&!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN);}
    JSONObject get(String path)throws Exception{return request(path,null);}
    JSONObject post(String path,JSONObject data)throws Exception{return request(path,data.toString().getBytes(StandardCharsets.UTF_8));}
    JSONObject request(String path,byte[] body)throws Exception {
        return request(path,body,body==null?0:body.length);
    }
    JSONObject request(String path,byte[] body,int length)throws Exception {
        long began=System.nanoTime();
        try{return recover(path,body,length,null);}finally{if(stats!=null)stats.request(began);}
    }
    JSONObject perform(String path,byte[] body,int length)throws Exception {
        return perform(path,body,length,null);
    }
    JSONObject batch(String path,byte[] header,byte[] body,int length)throws Exception {
        if(header.length==0||header.length>512*1024||length<0||length>16*1024*1024)throw new IOException("批量上传超过安全上限");
        long began=System.nanoTime();try{return recover(path,body,length,header);}finally{if(stats!=null)stats.request(began);}
    }
    void check()throws InterruptedIOException {
        if(cancellation!=null)cancellation.check();
        if(closed||aborted||Thread.currentThread().isInterrupted())throw new InterruptedIOException("连接操作已停止");
    }
    JSONObject recover(String path,byte[] body,int length,byte[] header)throws Exception {
        return RecoveryLoop.run(cancellation!=null&&cancellation.unattended,()->{
            try{return perform(path,body,length,header);}
            catch(Failure e){if(RecoveryPolicy.temporaryHttp(e.status,e.code))throw new RecoveryLoop.Temporary(e.getMessage(),e);throw e;}
            catch(IOException e){check();if(RecoveryPolicy.temporaryTransport(e))throw new RecoveryLoop.Temporary("Wi-Fi 或 NAS 暂时不可用",e);throw e;}
        },new RecoveryLoop.Control(){
            public void check()throws Exception{Net.this.check();}
            public void waiting(int attempt,long delay){if(cancellation!=null)cancellation.monitor.waiting(Net.this,delay);}
            public void sleep(long millis)throws Exception{Thread.sleep(millis);}
            public void recovered(){if(cancellation!=null)cancellation.monitor.recovered(Net.this);}
        });
    }
    JSONObject perform(String path,byte[] body,int length,byte[] header)throws Exception {
        check();
        if(length<0 || body!=null&&length>body.length)throw new ProtocolException("无效上传长度");
        if(body!=null&&body.length>32*1024*1024)throw new ProtocolException("单本清单过大，已暂停同步");
        String base=pairing.getString("url").replaceAll("/$","");
        HttpsURLConnection conn=(HttpsURLConnection)wifi().openConnection(new URL(base+path),java.net.Proxy.NO_PROXY);
        synchronized(this){if(closed||aborted){conn.disconnect();throw new InterruptedIOException("上传连接已关闭");}lastConnection=conn;}
        conn.setSSLSocketFactory(sockets);conn.setHostnameVerifier(PINNED_HOST); // Exact leaf certificate SHA-256 pin is the identity.
        conn.setInstanceFollowRedirects(false);conn.setConnectTimeout(15000);conn.setReadTimeout(45000);
        if(path.equals("/sync/v1/health")||path.equals("/sync/v1/catalog/commit"))conn.setRequestProperty("Connection","close");
        conn.setRequestProperty("Authorization","Bearer "+pairing.getString("token"));
        boolean completed=false;long deadline=android.os.SystemClock.elapsedRealtime()+180_000;Thread owner=Thread.currentThread();
        java.util.concurrent.atomic.AtomicBoolean expired=new java.util.concurrent.atomic.AtomicBoolean();
        // HttpsURLConnection has no write timeout. A bounded shared watchdog also aborts stalled writes on pause.
        ScheduledFuture<?> guard=GUARD.scheduleWithFixedDelay(()->{
            if((android.os.SystemClock.elapsedRealtime()>=deadline||closed||aborted||owner.isInterrupted()||cancellation!=null&&cancellation.stopped)&&expired.compareAndSet(false,true)){
                Thread abort=new Thread(conn::disconnect,"sync-abort-request");abort.setDaemon(true);abort.start();
            }
        },1,1,TimeUnit.SECONDS);
        try {
            if(body!=null){conn.setRequestMethod("POST");conn.setDoOutput(true);conn.setRequestProperty("Content-Type",header!=null||path.contains("/chunk?")?"application/octet-stream":"application/json");conn.setFixedLengthStreamingMode((long)length+(header==null?0:4+header.length));try(OutputStream out=conn.getOutputStream()){if(header!=null){int n=header.length;out.write(new byte[]{(byte)(n>>>24),(byte)(n>>>16),(byte)(n>>>8),(byte)n});out.write(header);}out.write(body,0,length);}}
            int code=conn.getResponseCode();InputStream stream=code==200?conn.getInputStream():conn.getErrorStream();
            if(stream==null)throw new Failure(code,"HTTP "+code);
            JSONObject result;try(stream){
                byte[] response=readResponse(stream);
                try{result=new JSONObject(new String(response,StandardCharsets.UTF_8));}
                catch(JSONException e){if(RecoveryPolicy.temporaryHttp(code,""))throw new Failure(code,"HTTP "+code);throw e;}
            }
            if(code!=200)throw new Failure(code,result.optString("error","HTTP "+code));
            check();if(expired.get())throw new SocketTimeoutException("单次请求超过三分钟");
            completed=true;return result;
        } finally {guard.cancel(false);if(!completed)conn.disconnect();synchronized(this){if(lastConnection==conn)lastConnection=null;if(completed)reusableConnection=conn;}}
    }
    static byte[] readResponse(InputStream in)throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] block=new byte[65536];int count;
        while((count=in.read(block))!=-1){if(out.size()+count>32*1024*1024)throw new ProtocolException("NAS 响应过大");out.write(block,0,count);}return out.toByteArray();
    }
    void cancelRequest(){aborted=true;HttpsURLConnection current=lastConnection;if(current!=null)current.disconnect();}
    @Override public synchronized void close(){if(closed)return;closed=true;if(lastConnection!=null){lastConnection.disconnect();lastConnection=null;}if(reusableConnection!=null){reusableConnection.disconnect();reusableConnection=null;}manager.unregisterNetworkCallback(networkChanges);}
    static String explain(String code){return switch(code){
        case "unauthorized"->"配对已失效，请重新导入 NAS 配对文件";
        case "nas_space_insufficient","storage_full"->"NAS 剩余空间不足，保留进度后暂停";
        case "backup_omits_existing_books_use_complete_backup"->"旧 NAS 接收端不支持清单移出或新版替换。请确认导入完整 .db，并升级 NAS 同步接收端；已有文件未删除";
        case "directory_owned_by_another_book"->"新旧漫画复用了同一目录；请升级 NAS 同步接收端以分开保存版本，已有文件未覆盖";
        case "version_directory_conflict"->"NAS 新版存储目录冲突，已停止；请先核对目录，不能覆盖旧文件";
        case "ambiguous_download_order","order_not_verified","not_download_order"->"下载顺序尚未核对，NAS 拒绝发布";
        case "hash_mismatch_source_may_be_changing"->"文件校验不一致，可能仍在下载；请暂停 EhViewer 下载后重试";
        case "inventory_not_complete","books_not_verified"->"文件尚未全部校验，书库顺序尚未切换";
        case "existing_directory_changed"->"已有漫画目录映射变化，需要先核对原目录";
        default->"NAS："+code;
    };}
}
