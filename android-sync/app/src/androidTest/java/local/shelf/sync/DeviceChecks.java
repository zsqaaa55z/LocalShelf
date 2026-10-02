package local.shelf.sync;

import android.app.Instrumentation;
import android.content.*;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.util.Base64;
import java.io.*;
import java.nio.charset.StandardCharsets;
import org.json.*;

public final class DeviceChecks extends Instrumentation {
    Bundle args;int checks=0;StringBuilder log=new StringBuilder();Context c;
    @Override public void onCreate(Bundle arguments){super.onCreate(arguments);args=arguments;start();}
    void check(boolean condition,String name){if(!condition)throw new AssertionError(name);checks++;log.append("PASS ").append(name).append('\n');Bundle status=new Bundle();status.putString("stream","PASS "+name+"\n");sendStatus(0,status);}
    interface Checked{void run()throws Exception;}
    void reject(Checked work,String name)throws Exception{try{work.run();throw new AssertionError("accepted: "+name);}catch(IllegalArgumentException|IOException expected){check(true,name);}}
    File backup(boolean tied,boolean extra)throws Exception{
        File file=new File(c.getCacheDir(),"synthetic-export.db");SQLiteDatabase.deleteDatabase(file);
        try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(file,null)){
            db.execSQL("CREATE TABLE DOWNLOADS(GID INTEGER PRIMARY KEY,TITLE TEXT,TITLE_JPN TEXT,TIME INTEGER,STATE INTEGER)");db.execSQL("CREATE TABLE DOWNLOAD_DIRNAME(GID INTEGER PRIMARY KEY,DIRNAME TEXT)");
            String[] ids=extra?new String[]{"11","7","3","9"}:new String[]{"7","3","9"};
            for(int i=0;i<ids.length;i++){long time=1000-i;if(tied&&i==1)time=1000;db.execSQL("INSERT INTO DOWNLOADS VALUES(?,?,?,?,?)",new Object[]{Long.parseLong(ids[i]),"synthetic "+ids[i],"合成漫画 "+ids[i],time,3});db.execSQL("INSERT INTO DOWNLOAD_DIRNAME VALUES(?,?)",new Object[]{Long.parseLong(ids[i]),ids[i]+"-漫画"});}
            // Deliberately include unrelated data to verify the importer never exports it.
            db.execSQL("CREATE TABLE ACCOUNT(token TEXT)");db.execSQL("INSERT INTO ACCOUNT VALUES('synthetic-secret-never-export')");
        }return file;
    }
    @Override public void onStart(){
        c=getTargetContext();Bundle result=new Bundle();
        try{
            if("true".equals(args.getString("performance"))){result.putString("stream",LargeLibraryChecks.run(c,args).toString(2));finish(-1,result);return;}
            if("true".equals(args.getString("cleanup"))){
                if(!LocalState.prefs(c).getString("tree","").equals("content://"+FixtureProvider.AUTH+"/tree/root"))throw new IllegalStateException("配置不是本次合成测试，拒绝清理");
                SyncJob.pause(c);
                for(String name:new String[]{"migration-report.json","previous-order.json","last-synced-order.json","order.json","order.json.bak","order.json.new","pairing.enc","pairing.enc.bak","pairing.enc.new","hash-cache.db","hash-cache.db-wal","hash-cache.db-shm","hash-cache.db-journal"}){File file=new File(c.getNoBackupFilesDir(),name);if(file.exists()&&!file.delete())throw new IOException("无法清理测试文件 "+name);}
                SQLiteDatabase.deleteDatabase(new File(c.getCacheDir(),"synthetic-export.db"));
                java.security.KeyStore keys=java.security.KeyStore.getInstance("AndroidKeyStore");keys.load(null);keys.deleteEntry("localshelf.sync.pairing");
                if(!LocalState.prefs(c).edit().clear().commit())throw new IOException("测试偏好清理未完成");
                result.putString("stream","PASS only synthetic test configuration removed\n");finish(-1,result);return;
            }
            String priorTree=LocalState.prefs(c).getString("tree","");
            if((!priorTree.isEmpty()&&!priorTree.contains(FixtureProvider.AUTH)) || (priorTree.isEmpty()&&new File(c.getNoBackupFilesDir(),"pairing.enc").exists()))throw new IllegalStateException("拒绝覆盖真实配置；请使用干净的测试安装");
            if("true".equals(args.getString("archiveOffline"))){archiveOffline(result);return;}
            if(args.containsKey("stabilityPhase")){stability(args.getString("stabilityPhase"),result);return;}
            JSONObject draft=Catalog.importDb(c,Uri.fromFile(backup(false,false)));JSONObject manifest=Catalog.manifest(draft);
            check(manifest.getJSONArray("books").getJSONObject(0).getString("id").equals("7"),"real SQLite importer follows TIME, not GID");
            check(!manifest.toString().contains("synthetic-secret"),"catalog excludes account data");Catalog.save(c,draft);
            JSONObject ties=Catalog.importDb(c,Uri.fromFile(backup(true,false)));check(Catalog.unresolved(ties).size()==1,"duplicate TIME detected on Android SQLite");reject(()->Catalog.manifest(ties),"unresolved order cannot publish");
            ties.getJSONObject("resolvedTies").put("1000",new JSONArray().put("7").put("3"));check(Catalog.manifest(ties).getJSONArray("books").getJSONObject(1).getString("id").equals("3"),"explicit tied order retained");Catalog.save(c,ties);
            check(Catalog.unresolved(Catalog.importDb(c,Uri.fromFile(backup(true,false)))).isEmpty(),"confirmed tie survives reimport");
            draft=Catalog.importDb(c,Uri.fromFile(backup(false,false)));Catalog.save(c,draft);
            Uri tree=DocumentsContract.buildTreeDocumentUri(FixtureProvider.AUTH,"root");
            SourceFiles source=new SourceFiles(c,tree);var dirs=source.directories();check(dirs.size()==5,"SAF provider enumeration on Android");var files=source.files(dirs.get("7-漫画"),new SyncRunner.Cancel());check(files.size()==2 && files.get(0).path().equals(".thumb"),"hidden files included in source inventory");
            try(InputStream in=source.open(files.get(0).doc())){check(in.read()!=-1,"SAF read-only stream opens");}
            JSONObject pairing=new JSONObject(new String(Base64.decode(args.getString("fixture"),Base64.DEFAULT),StandardCharsets.UTF_8));LocalState.savePairing(c,pairing);check(LocalState.pairing(c).getString("token").equals(pairing.getString("token")),"Keystore encrypted pairing roundtrip");
            JSONObject wrong=new JSONObject(pairing.toString()).put("certificateSha256","0".repeat(64));reject(()->new Net(c,wrong).get("/sync/v1/health"),"incorrect TLS certificate pin rejected");
            check(new Net(c,pairing).get("/sync/v1/health").getInt("protocol")==1,"real Wi-Fi HTTPS connection to synthetic receiver");
            LocalState.prefs(c).edit().putString("tree",tree.toString()).putString("backup",Uri.fromFile(new File(c.getCacheDir(),"synthetic-export.db")).toString()).commit();
            JSONObject initial=Catalog.manifest(draft);Net net=new Net(c,pairing);String rev=net.post("/sync/v1/catalog/stage",initial).getString("revision");
            var page=files.stream().filter(f->f.path().equals("00000001.jpg")).findFirst().get();java.security.MessageDigest hash=java.security.MessageDigest.getInstance("SHA-256");try(InputStream in=source.open(page.doc())){byte[] buffer=new byte[65536];int n;while((n=in.read(buffer))!=-1)hash.update(buffer,0,n);}
            JSONObject fileSpec=new JSONObject().put("revision",rev).put("gid","7").put("path",page.path()).put("size",page.doc().size()).put("sha256",LocalState.hex(hash.digest()));
            SyncRunner.Cancel cancel=new SyncRunner.Cancel();SyncEngine first=new SyncEngine(c,cancel,s->{if(s.contains("上传文件"))cancel.stopped=true;});
            reject(()->first.upload(net,source,page.doc(),fileSpec,"synthetic"),"manual pause interrupts actual chunk upload");
            check(net.post("/sync/v1/file/begin",fileSpec).getLong("offset")==4*1024*1024,"large file preserves exactly one 4 MiB chunk before resume");
            SyncEngine batch1=new SyncEngine(c,new SyncRunner.Cancel(),s->{});batch1.run(true,false,1);
            check(batch1.batchPaused&&LocalState.prefs(c).getInt("nextBook",0)==1,"first batch checkpoints exactly one verified book");
            check(new Net(c,pairing).get("/sync/v1/health").isNull("activeRevision"),"partial first migration never publishes an incomplete order");
            check(LocalState.prefs(c).getBoolean("batchPaused",false)&&LocalState.prefs(c).getBoolean("cycleFull",false),"batch pause and full-audit mode survive process recreation");
            SyncEngine batch2=new SyncEngine(c,new SyncRunner.Cancel(),s->{});batch2.run(true,false,1);
            check(batch2.scannedBooks==1&&LocalState.prefs(c).getInt("nextBook",0)==2,"second batch starts after the first confirmed book");
            SyncEngine resumed=new SyncEngine(c,new SyncRunner.Cancel(),s->{});resumed.run(true,false,1);for(int pass=0;pass<10&&LocalState.prefs(c).getBoolean("cyclePending",false);pass++)new SyncEngine(c,new SyncRunner.Cancel(),s->{}).run(true,false,1);check(LocalState.prefs(c).getLong("lastSuccess",0)>0,"paused Wi-Fi upload resumes and publishes exact order");
            check(!LocalState.prefs(c).getBoolean("batchPaused",true)&&!LocalState.prefs(c).getBoolean("cyclePending",true),"final batch clears pause only after exact-order publication");
            check(LocalState.prefs(c).getLong("unknown",0)==2,"unlisted directories archived separately from main order");
            SyncEngine duplicate=new SyncEngine(c,new SyncRunner.Cancel(),s->{});duplicate.run(false);check(duplicate.sent==0,"repeat sync uploads zero image bytes");
            backup(false,true);SyncEngine next=new SyncEngine(c,new SyncRunner.Cancel(),s->{});next.run(false);check(LocalState.prefs(c).getInt("bookCount",0)==4,"updated backup imports new comic automatically");
            check(LocalState.prefs(c).getLong("unknown",0)==1,"unlisted directory never guessed into download order");
            check(Catalog.manifest(LocalState.read(c,"order.json")).getJSONArray("books").getJSONObject(0).getString("id").equals("11"),"new download leads list with old relative order preserved");
            SyncEngine fast=new SyncEngine(c,new SyncRunner.Cancel(),s->{});fast.run(false,true,1);
            check(fast.scannedBooks==0&&fast.reusedBooks==4&&fast.sent==0,"new-only sync reuses verified old books without opening their folders");
            check(!LocalState.prefs(c).getBoolean("newOnly",false),"new-only mode remains opt-in");
            try(HashCache cache=new HashCache(c)){check(cache.receipts("different-nas-or-tree").isEmpty(),"receipts isolated by NAS identity and source tree");cache.db.execSQL("UPDATE receipts SET proof=? WHERE gid='7'",new Object[]{"0".repeat(64)});}
            SyncEngine stale=new SyncEngine(c,new SyncRunner.Cancel(),s->{});stale.run(false,true);
            check(stale.scannedBooks==1&&stale.reusedBooks==3&&stale.sent==0,"stale NAS receipt falls back to scanning exactly one book");
            c.getContentResolver().call(Uri.parse("content://"+FixtureProvider.AUTH),"fixture-add-page",null,null);
            SyncEngine skipOld=new SyncEngine(c,new SyncRunner.Cancel(),s->{});skipOld.run(false,true);
            check(skipOld.scannedBooks==0&&skipOld.sent==0,"new-only mode explicitly does not audit old-page edits");
            SyncEngine audit=new SyncEngine(c,new SyncRunner.Cancel(),s->{});audit.run(false);
            check(audit.scannedBooks==4&&audit.hashedFiles==1&&audit.sent>0,"normal audit finds old-book added page and hashes only new file");
            SyncEngine forced=new SyncEngine(c,new SyncRunner.Cancel(),s->{});forced.run(true,true);
            check(forced.scannedBooks==4&&forced.reusedBooks==0&&forced.hashedFiles==9,"full verification overrides quick mode and rereads every source file");
            SyncEngine stable=new SyncEngine(c,new SyncRunner.Cancel(),s->{});stable.run(false);
            check(stable.hashedFiles==0&&stable.sent==0,"unchanged full audit uses batched hash cache without rereading images");
            File exported=new File(c.getCacheDir(),"synthetic-export.db");
            try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(exported,null)){db.execSQL("UPDATE DOWNLOADS SET STATE=2 WHERE GID=7");}
            SyncEngine pending=new SyncEngine(c,new SyncRunner.Cancel(),s->{});pending.run(false,true);
            check(pending.scannedBooks==1&&pending.reusedBooks==3,"unfinished EhViewer download is never skipped by quick mode");
            try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(exported,null)){db.execSQL("UPDATE DOWNLOADS SET STATE=3 WHERE GID=7");}
            SyncEngine finished=new SyncEngine(c,new SyncRunner.Cancel(),s->{});finished.run(false,true);
            check(finished.scannedBooks==1&&finished.reusedBooks==3,"newly finished book must be scanned before acquiring a reuse receipt");
            try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(exported,null)){db.execSQL("ALTER TABLE DOWNLOADS RENAME TO DOWNLOADS_WITH_STATE");db.execSQL("CREATE TABLE DOWNLOADS AS SELECT GID,TITLE,TITLE_JPN,TIME FROM DOWNLOADS_WITH_STATE");}
            SyncEngine legacy=new SyncEngine(c,new SyncRunner.Cancel(),s->{});legacy.run(false,true);
            check(legacy.scannedBooks==4&&legacy.reusedBooks==0,"backup without completion state conservatively scans every book");
            try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(exported,null)){db.execSQL("DROP TABLE DOWNLOADS");db.execSQL("ALTER TABLE DOWNLOADS_WITH_STATE RENAME TO DOWNLOADS");}
            try(Net repeated=new Net(c,pairing)){for(int i=0;i<100;i++)repeated.post("/sync/v1/catalog/stage",Catalog.manifest(LocalState.read(c,"order.json")));}
            check(true,"100 successive pooled HTTPS requests do not exhaust server connection slots");
            check(!new Net.Failure(507,"storage_full").retryable()&&!new Net.Failure(400,"nas_space_insufficient").retryable(),"disk full stops immediately instead of retrying four times");
            check(!new Net.Failure(401,"unauthorized").retryable()&&new Net.Failure(400,"offset_conflict").retryable()&&new Net.Failure(503,"busy").retryable(),"retry policy distinguishes permanent errors and recoverable offsets");
            var activity=startActivitySync(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK));
            check(activity!=null,"main activity launches on actual Android 16");
            long before=LocalState.prefs(c).getLong("lastSuccess",0);
            runOnMainSync(()->SyncJob.manual(c,false,false));long until=System.currentTimeMillis()+90000;
            while(System.currentTimeMillis()<until&&LocalState.prefs(c).getLong("lastSuccess",0)<=before)Thread.sleep(100);
            check(LocalState.prefs(c).getLong("lastSuccess",0)>before,"user-initiated Android job completes real Wi-Fi sync");
            runOnMainSync(()->SyncJob.automatic(c,true));check(c.getSystemService(android.app.job.JobScheduler.class).getPendingJob(SyncJob.AUTO).isRequireCharging(),"automatic job requires charging");
            runOnMainSync(()->SyncJob.automatic(c,false));check(c.getSystemService(android.app.job.JobScheduler.class).getPendingJob(SyncJob.AUTO)==null,"automatic job can be disabled");
            log.append("TOTAL ").append(checks).append(" device checks passed\n");result.putString("stream",log.toString());finish(-1,result);
        }catch(Throwable e){StringWriter out=new StringWriter();e.printStackTrace(new PrintWriter(out));result.putString("stream",log+"FAIL\n"+out);finish(0,result);}
    }
    void archiveOffline(Bundle result)throws Exception {
        Uri provider=Uri.parse("content://"+FixtureProvider.AUTH);
        c.getContentResolver().call(provider,"fixture-setup",null,null);
        c.getContentResolver().call(provider,"fixture-root",null,null);
        Uri tree=DocumentsContract.buildTreeDocumentUri(FixtureProvider.AUTH,"root");
        File exported=backup(false,false);
        LocalState.prefs(c).edit().putString("tree",tree.toString()).putString("backup",Uri.fromFile(exported).toString()).commit();
        SourceFiles source=new SourceFiles(c,tree);var dirs=source.directories();
        var groups=ExtraArchive.groups(dirs,new java.util.HashSet<>(java.util.List.of("7-漫画","3-漫画","9-漫画")));
        check(groups.size()==3,"two unlisted directories and one root group stay outside main list");
        check(groups.stream().noneMatch(g->g.name().equals("7-漫画")),"ordered directory never duplicated into archive");
        check(ExtraArchive.id("root","").equals("53175bcc0524f37b47062fafdda28e3f8eb91d519ca0a184ca71bbebe72f969a"),"archive identity matches receiver SHA-256 protocol");
        check(source.rootFiles().size()==1&&source.rootFiles().get(0).doc().size()==0,"zero-byte hidden root file included");
        var draft=Catalog.importDb(c,Uri.fromFile(exported));LocalState.json(c,"last-synced-order.json",draft);
        java.util.ArrayList<String> progress=new java.util.ArrayList<>();
        var report=MigrationReport.build(c,new SyncRunner.Cancel(),progress::add);
        check(report.getInt("totalSourceFiles")==11,"preflight covers all ten synthetic book files plus root file");
        check(report.getLong("totalSourceBytes")==6*1024*1024+80000+5*"synthetic thumb".length(),"preflight byte totals include both archives");
        check(report.getInt("unmappedDirectoryCount")==2&&report.getJSONObject("archives").length()==3,"report exposes independently auditable archive groups");
        check(report.getJSONObject("differences").getJSONArray("addedIds").length()==0,"unchanged imported list reports zero additions");
        check(!new File(c.getNoBackupFilesDir(),"pairing.enc").exists(),"preflight works without NAS pairing or network");
        check(progress.stream().anyMatch(v->v.contains("迁移预检")),"preflight reports its phase while scanning");
        backup(true,true);
        try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(exported,null)){db.execSQL("INSERT INTO DOWNLOADS VALUES(12,'missing','missing',900,3)");db.execSQL("INSERT INTO DOWNLOAD_DIRNAME VALUES(12,'12-missing')");}
        report=MigrationReport.build(c,new SyncRunner.Cancel(),v->{});
        check(report.getInt("missingDirectoryCount")==1&&report.getInt("emptyDirectoryCount")==0,"missing directories distinguished from existing directories");
        check(report.getInt("unresolvedTimeRecords")==2,"preflight reports tied times without guessing order");
        check(report.getJSONObject("differences").getJSONArray("addedIds").length()==2,"comparison uses last successful sync baseline");
        check(report.getInt("unmappedDirectoryCount")==1,"newly listed folder moves out of independent archive plan");
        check(report.getLong("totalSourceFiles")==11,"reclassification preserves total source coverage");
        String saved=LocalState.read(c,"migration-report.json").toString();SyncRunner.Cancel cancelled=new SyncRunner.Cancel();cancelled.stopped=true;
        reject(()->MigrationReport.build(c,cancelled,v->{}),"cancelled preflight stops without uploading");
        check(LocalState.read(c,"migration-report.json").toString().equals(saved),"cancelled scan does not replace complete saved report");
        check(!new Net.Failure(507,"storage_full").retryable()&&new Net.Failure(503,"busy").retryable(),"disk full and transient receiver errors have different retry policy");
        SyncEngine engine=new SyncEngine(c,new SyncRunner.Cancel(),v->{});engine.sent=4000000;engine.verifiedFiles=3;engine.verifiedBytes=6000000;
        check(engine.transferred().contains("确认上传")&&engine.transferred().contains("核验 3"),"progress separates acknowledged upload from verified files");
        result.putString("stream",log+"TOTAL "+checks+" offline archive checks passed\n");finish(-1,result);
    }
    void stability(String phase,Bundle result)throws Exception {
        if(phase.equals("crash")||phase.equals("soak")){
            SyncJob.pause(c);LocalState.prefs(c).edit().clear().commit();
            JSONObject pairing=new JSONObject(new String(Base64.decode(args.getString("fixture"),Base64.DEFAULT),StandardCharsets.UTF_8));LocalState.savePairing(c,pairing);
            Catalog.save(c,Catalog.importDb(c,Uri.fromFile(backup(false,false))));
            LocalState.prefs(c).edit().putString("tree",DocumentsContract.buildTreeDocumentUri(FixtureProvider.AUTH,"root").toString()).putString("backup",Uri.fromFile(new File(c.getCacheDir(),"synthetic-export.db")).toString()).putInt("batchLimit",0).commit();
        }
        if(phase.equals("probe")){
            JSONObject pairing=new JSONObject(new String(Base64.decode(args.getString("fixture"),Base64.DEFAULT),StandardCharsets.UTF_8));
            try(Net net=new Net(c,pairing)){
                String rev=net.post("/sync/v1/catalog/stage",Catalog.manifest(LocalState.read(c,"order.json"))).getString("revision");
                SourceFiles source=new SourceFiles(c,DocumentsContract.buildTreeDocumentUri(FixtureProvider.AUTH,"root"));
                var doc=source.files(source.directories().get("7-漫画"),new SyncRunner.Cancel()).stream().filter(f->f.path().endsWith(".jpg")).findFirst().get().doc();
                java.security.MessageDigest md=java.security.MessageDigest.getInstance("SHA-256");try(InputStream in=source.open(doc)){byte[] block=new byte[65536];int n;while((n=in.read(block))!=-1)md.update(block,0,n);}
                JSONObject spec=new JSONObject().put("revision",rev).put("gid","7").put("path","00000001.jpg").put("size",doc.size()).put("sha256",LocalState.hex(md.digest()));
                new SyncEngine(c,new SyncRunner.Cancel(),message->{Bundle status=new Bundle();status.putString("stream",message+"\n");sendStatus(0,status);}).upload(net,source,doc,spec,"probe");
                check(true,"delayed receiver response probe succeeds");
            }
        }
        if(phase.equals("offline")){
            check(SyncRunner.friendly(new java.net.ConnectException("raw technical error")).contains("Wi-Fi"),"connection failures explain local-network reachability in Chinese");
            check(SyncRunner.friendly(new java.net.SocketTimeoutException("raw technical error")).contains("超时"),"timeouts explain recovery in Chinese");
            ActivityMonitor monitor=addMonitor(MainActivity.class.getName(),null,false);
            MainActivity activity;
            try{
                c.startActivity(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK));
                activity=(MainActivity)waitForMonitorWithTimeout(monitor,15000);
                if(activity==null)throw new IOException("界面启动超时：请解锁手机并保持同步 App 可见后重试");
            }finally{removeMonitor(monitor);}
            long layoutDeadline=System.currentTimeMillis()+5000;boolean[] laidOut={false};
            do{runOnMainSync(()->laidOut[0]=activity.content.getWidth()>0&&activity.content.getHeight()>0);if(!laidOut[0])Thread.sleep(100);}while(!laidOut[0]&&System.currentTimeMillis()<layoutDeadline);
            if(!laidOut[0])throw new IOException("界面布局未完成，未生成预览");
            runOnMainSync(()->{
                activity.refresh();check(activity.batch.getSelectedItemPosition()==0,"clean installation defaults to 100-book batches");
                android.graphics.Bitmap bitmap=android.graphics.Bitmap.createBitmap(activity.content.getWidth(),activity.content.getHeight(),android.graphics.Bitmap.Config.ARGB_8888);
                android.graphics.Canvas canvas=new android.graphics.Canvas(bitmap);canvas.drawColor(android.graphics.Color.rgb(244,246,242));activity.content.draw(canvas);
                try(FileOutputStream out=new FileOutputStream(new File(c.getCacheDir(),"ui-v030.png"))){bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}catch(IOException e){throw new RuntimeException(e);}finally{bitmap.recycle();}
            });
        }
        File marker=new File(c.getCacheDir(),"stability-marker");
        if(phase.equals("crash")){
            marker.delete();final SyncEngine[] holder=new SyncEngine[1];
            SyncRunner.Cancel cancel=new SyncRunner.Cancel(){@Override void check()throws java.io.InterruptedIOException{super.check();if(holder[0]!=null&&holder[0].sent>=4*1024*1024){try{try(FileOutputStream out=new FileOutputStream(marker)){out.write("chunk-acknowledged".getBytes());out.getFD().sync();}while(true)Thread.sleep(500);}catch(Exception e){throw new RuntimeException(e);}}}};
            SyncEngine engine=new SyncEngine(c,cancel,message->{});holder[0]=engine;
            engine.run(false);throw new AssertionError("crash controller did not kill the process");
        }
        if(phase.equals("resume")){
            if(!marker.isFile())throw new AssertionError("missing crash marker");
            SyncEngine engine=new SyncEngine(c,new SyncRunner.Cancel(),message->{});engine.run(false);
            check(engine.sent==2*1024*1024+80000+4*"synthetic thumb".length(),"force-stopped phone resumes after acknowledged 4 MiB without resending it");
            check(LocalState.prefs(c).getLong("lastSuccess",0)>0,"force-stop recovery verifies and publishes full download order");marker.delete();
        }
        if(phase.equals("soak")){
            var activity=startActivitySync(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK));
            runOnMainSync(()->SyncJob.manual(c,false,false));long until=System.currentTimeMillis()+15*60*1000L;
            while(System.currentTimeMillis()<until&&LocalState.prefs(c).getLong("lastSuccess",0)==0){Thread.sleep(500);if(LocalState.prefs(c).getString("runState","").equals("failed"))throw new AssertionError(LocalState.prefs(c).getString("status",""));}
            check(LocalState.prefs(c).getLong("lastSuccess",0)>0,"screen-off user-initiated job completes throttled synthetic transfer");
        }
        result.putString("stream",log.toString());finish(-1,result);
    }

}
