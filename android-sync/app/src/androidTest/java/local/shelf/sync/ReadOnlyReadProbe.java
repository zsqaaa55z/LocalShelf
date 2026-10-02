package local.shelf.sync;

import android.app.Instrumentation;
import android.content.*;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.os.*;
import android.provider.DocumentsContract;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.*;

/** Explicitly invoked, paused-device diagnostic. Never invokes SyncEngine or the NAS. */
public final class ReadOnlyReadProbe extends Instrumentation {
    static final int MAX_FILES=512;
    static final long MAX_BYTES=128L*1024*1024;
    static final String ROOT_ID="primary:EhViewer/download";
    Bundle args;Context c;boolean production;
    record Sample(SourceFiles.Doc doc,String relative,String sha){}
    @Override public void onCreate(Bundle arguments){super.onCreate(arguments);args=arguments;start();}
    void emit(JSONObject value){Bundle b=new Bundle();b.putString("stream",value+"\n");sendStatus(0,b);}
    void idle()throws IOException {
        var p=LocalState.prefs(c);String state=p.getString("runState","");
        if(!Set.of("batch","paused","complete").contains(state)||p.getBoolean("auto",false)||SyncRunner.busy.get())throw new IOException("PROBE_REQUIRES_PAUSED_SYNC");
    }
    Map<String,String> fingerprint()throws Exception {
        Map<String,String> result=new TreeMap<>();
        for(String name:List.of("no_backup/order.json","no_backup/pairing.enc","no_backup/hash-cache.db","shared_prefs/sync.xml")){
            File file=new File(c.getApplicationInfo().dataDir,name);MessageDigest md=MessageDigest.getInstance("SHA-256");
            try(InputStream in=new FileInputStream(file)){byte[] b=new byte[65536];int n;while((n=in.read(b))!=-1)md.update(b,0,n);}
            result.put(name,LocalState.hex(md.digest()));
        }return result;
    }
    List<Sample> sample(Uri tree)throws Exception {
        List<Sample> out=new ArrayList<>();long bytes=0;
        // Only query the existing app-local index. Do not enumerate the download root or any book folder.
        File file=new File(c.getNoBackupFilesDir(),"hash-cache.db");
        try(SQLiteDatabase db=SQLiteDatabase.openDatabase(file.getPath(),null,SQLiteDatabase.OPEN_READONLY)){
            long count;try(Cursor cur=db.rawQuery("SELECT COUNT(*) FROM hashes WHERE size BETWEEN 65536 AND 1048576",null)){if(!cur.moveToFirst())throw new IOException("EMPTY_INDEX");count=cur.getLong(0);}
            int stride=(int)Math.max(1,count/MAX_FILES);
            try(Cursor cur=db.rawQuery("SELECT uri,size,modified,sha FROM hashes WHERE size BETWEEN 65536 AND 1048576 AND rowid % ? = 0 ORDER BY rowid LIMIT 1024",new String[]{Integer.toString(stride)})){
                while(cur.moveToNext()&&out.size()<MAX_FILES){
                    Uri uri=Uri.parse(cur.getString(0));
                    if(!"content".equals(uri.getScheme())||!"com.android.externalstorage.documents".equals(uri.getAuthority()))continue;
                    String id=DocumentsContract.getDocumentId(uri);
                    if(!id.startsWith(ROOT_ID+"/"))continue;
                    String relative=id.substring(ROOT_ID.length()+1);
                    for(String part:relative.split("/",-1))OrderRules.validName(part);
                    long size=cur.getLong(1);String sha=cur.getString(3);
                    if(size>MAX_BYTES-bytes||sha==null||!sha.matches("[a-f0-9]{64}"))continue;
                    out.add(new Sample(new SourceFiles.Doc(id,"sample","application/octet-stream",size,cur.getLong(2),DocumentsContract.buildDocumentUriUsingTree(tree,id)),relative,sha));bytes+=size;
                }
            }
        }
        if(out.size()<64)throw new IOException("INSUFFICIENT_CONFIRMED_SAMPLES");
        return out;
    }
    void exportSample(List<Sample> samples)throws Exception {
        JSONArray values=new JSONArray();
        for(var sample:samples)values.put(new JSONObject().put("relative",sample.relative()).put("size",sample.doc().size()).put("sha256",sample.sha()));
        JSONObject manifest=new JSONObject().put("schema",1).put("root","/storage/emulated/0/EhViewer/download").put("files",values);
        // Sole diagnostic output: names remain local, never appear in instrumentation output.
        File destination=new File(c.getCacheDir(),"readonly-probe-sample.json");
        try(OutputStream out=new FileOutputStream(destination)){out.write(manifest.toString().getBytes(StandardCharsets.UTF_8));}
    }
    int batteryTemperature(){Intent i=c.registerReceiver(null,new IntentFilter(Intent.ACTION_BATTERY_CHANGED));return i==null?-1:i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE,-1);}
    JSONObject metadata(SourceFiles source,List<Sample> samples)throws Exception {
        JSONArray details=new JSONArray();long deadline=SystemClock.elapsedRealtime()+15000;
        for(int i=0;i<Math.min(8,samples.size());i++){
            idle();if(SystemClock.elapsedRealtime()>deadline)throw new InterruptedIOException("METADATA_TIMEOUT");
            Sample s=samples.get(i);File f=new File("/storage/emulated/0/EhViewer/download",s.relative());
            var a=java.nio.file.Files.readAttributes(f.toPath(),java.nio.file.attribute.BasicFileAttributes.class,java.nio.file.LinkOption.NOFOLLOW_LINKS);
            var b=java.nio.file.Files.readAttributes(f.toPath(),java.nio.file.attribute.BasicFileAttributes.class,java.nio.file.LinkOption.NOFOLLOW_LINKS);
            details.put(new JSONObject().put("sample",i).put("sizeMatches",a.size()==s.doc().size()).put("providerMatchesCache",source.unchanged(s.doc()))
                .put("nioMillisMinusCache",a.lastModifiedTime().toMillis()-s.doc().modified()).put("ioMillisMinusCache",f.lastModified()-s.doc().modified())
                .put("fileKeyStable",Objects.equals(a.fileKey(),b.fileKey())).put("mtimeStable",a.lastModifiedTime().equals(b.lastModifiedTime())).put("regular",a.isRegularFile()&&!a.isSymbolicLink()));
        }
        return new JSONObject().put("phase","metadata-only").put("samples",details).put("networkRequests",0);
    }
    JSONObject run(SourceFiles source,List<Sample> samples,int width,ReadPipeline.Buffers buffers,String phase)throws Exception {
        PowerManager power=c.getSystemService(PowerManager.class);
        AtomicBoolean stopped=new AtomicBoolean();AtomicReference<ReadPipeline<Sample>> running=new AtomicReference<>();
        AtomicInteger peakThermal=new AtomicInteger(power.getCurrentThermalStatus()),peakTemperature=new AtomicInteger(batteryTemperature());
        long deadline=SystemClock.elapsedRealtime()+90000;
        LongAdder opens=new LongAdder(),reads=new LongAdder(),hashes=new LongAdder(),closes=new LongAdder(),bytes=new LongAdder();
        AtomicInteger completed=new AtomicInteger(),opened=new AtomicInteger(),peakOpened=new AtomicInteger();
        ScheduledExecutorService guard=Executors.newSingleThreadScheduledExecutor();
        Runnable guardCheck=()->{
            try{
                peakThermal.accumulateAndGet(power.getCurrentThermalStatus(),Math::max);peakTemperature.accumulateAndGet(batteryTemperature(),Math::max);
                idle();if(SystemClock.elapsedRealtime()>deadline||peakThermal.get()>=PowerManager.THERMAL_STATUS_MODERATE||peakTemperature.get()>=400)stopped.set(true);
            }catch(Exception e){stopped.set(true);}
            if(stopped.get()){var p=running.get();if(p!=null)p.fail(new InterruptedIOException("PROBE_GUARD_STOP"));}
        };
        guardCheck.run();if(stopped.get()){guard.shutdownNow();throw new InterruptedIOException("PROBE_PRECONDITION_STOP");}
        guard.scheduleAtFixedRate(guardCheck,1,1,TimeUnit.SECONDS);
        ReadPipeline.Check check=()->{if(stopped.get()||SystemClock.elapsedRealtime()>deadline)throw new InterruptedIOException("PROBE_GUARD_STOP");};
        try{
            ReadPipeline<Sample> pipeline=new ReadPipeline<>(samples,width,s->s.doc().size(),()->{
                SourceFiles.ReadSession reader=source.reader();
                return new ReadPipeline.Worker<Sample>(){
                    public String read(Sample s,byte[] buffer,int offset,ReadPipeline.Check cancel)throws Exception {
                        return FileRead.into(s.doc().size(),buffer,offset,()->{
                            InputStream in=reader.open(s.doc());peakOpened.accumulateAndGet(opened.incrementAndGet(),Math::max);
                            return new FilterInputStream(in){@Override public void close()throws IOException{try{super.close();}finally{opened.decrementAndGet();}}};
                        },cancel::check,m->{opens.add(m.open());reads.add(m.read());hashes.add(m.hash());closes.add(m.close());bytes.add(m.bytes());});
                    }
                    public void cancel(){reader.cancel();}public void close(){reader.close();}
                };
            },new ReadPipeline.Sink<Sample>(){
                public void send(ReadPipeline.Frame<Sample> frame,ReadPipeline.Check cancel)throws Exception {
                    for(int i=0;i<frame.items.size();i++){cancel.check();if(!frame.items.get(i).sha().equals(frame.hashes[i]))throw new IOException("SAMPLE_HASH_MISMATCH");completed.incrementAndGet();}
                }
                public void abort(){}
            },check,began->{},buffers);
            running.set(pipeline);long began=System.nanoTime();pipeline.run();double seconds=(System.nanoTime()-began)/1e9;
            if(opened.get()!=0||peakOpened.get()>width||completed.get()!=samples.size())throw new IOException("PROBE_BOUNDS_FAILED");
            return new JSONObject().put("phase",phase).put("mode",production?"production":"SAF").put("readStatus",source.readDescription()).put("readers",width).put("files",completed.get()).put("bytes",bytes.sum())
                .put("seconds",seconds).put("readHashMBps",bytes.sum()/1e6/seconds).put("openSecondsSum",opens.sum()/1e9).put("readSecondsSum",reads.sum()/1e9)
                .put("hashSecondsSum",hashes.sum()/1e9).put("closeSecondsSum",closes.sum()/1e9).put("peakOpenFiles",peakOpened.get())
                .put("peakThermalStatus",peakThermal.get()).put("peakBatteryTemperatureTenthsC",peakTemperature.get());
        }finally{guard.shutdownNow();guard.awaitTermination(3,TimeUnit.SECONDS);}
    }
    @Override public void onStart(){
        c=getTargetContext();Bundle result=new Bundle();Map<String,String> before=null;
        try{
            if(args==null||!"true".equals(args.getString("confirmReadOnly")))throw new IOException("EXPLICIT_READ_ONLY_CONFIRMATION_REQUIRED");
            idle();before=fingerprint();Uri tree=Uri.parse(LocalState.prefs(c).getString("tree",""));
            if(!"com.android.externalstorage.documents".equals(tree.getAuthority())||!ROOT_ID.equals(SourceFiles.rootDocumentId(tree)))throw new IOException("UNEXPECTED_ROOT");
            production="production".equals(args.getString("mode"));
            SourceFiles source=production?new SourceFiles(c,tree):new SourceFiles(c,tree,false);List<Sample> samples=sample(tree);exportSample(samples);
            if("true".equals(args.getString("metadataOnly"))){
                JSONObject details=metadata(source,samples);idle();boolean unchanged=before.equals(fingerprint());
                result.putString("stream",details.put("success",unchanged).put("appStateUnchanged",unchanged).toString()+"\n");finish(unchanged?-1:0,result);return;
            }
            ReadPipeline.Buffers buffers=new ReadPipeline.Buffers();JSONArray rounds=new JSONArray();
            emit(new JSONObject().put("phase","sample-ready").put("files",samples.size()).put("maxBufferMiB",32).put("rootEnumerations",0).put("networkRequests",0));
            JSONObject smoke=run(source,samples.subList(0,8),2,buffers,"8-file-smoke");emit(smoke);
            for(int readers:new int[]{2,4,4,2}){JSONObject round=run(source,samples,readers,buffers,"matched-sample");rounds.put(round);emit(round);}
            idle();if(!before.equals(fingerprint()))throw new IOException("APP_STATE_CHANGED");
            result.putString("stream",new JSONObject().put("success",true).put("appStateUnchanged",true).put("networkRequests",0).put("rounds",rounds).toString()+"\n");finish(-1,result);
        }catch(Throwable e){
            boolean unchanged=false;try{unchanged=before!=null&&before.equals(fingerprint());}catch(Exception ignored){}
            result.putString("stream","{\"success\":false,\"errorType\":\""+e.getClass().getSimpleName()+"\",\"appStateUnchanged\":"+unchanged+"}\n");finish(0,result);
        }
    }
}
