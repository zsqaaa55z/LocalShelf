package local.shelf.sync;

import android.app.Instrumentation;
import android.content.*;
import android.os.Bundle;
import android.view.View;
import java.io.*;
import java.security.MessageDigest;
import org.json.*;

/** Isolated package only. No network, jobs, actual directory grants or user data. */
public final class DailyUiChecks extends Instrumentation {
    int checks;StringBuilder log=new StringBuilder();Context c;
    void check(boolean yes,String message){if(!yes)throw new AssertionError(message);checks++;log.append("PASS ").append(message).append('\n');}
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){Bundle result=new Bundle();
        try{
            c=getTargetContext();
            if(!c.getPackageName().equals("local.shelf.sync.dailytest"))throw new SecurityException("refusing non-isolated target");
            File fixture=new File(c.getCacheDir(),"daily-metadata.db");
            try(android.database.sqlite.SQLiteDatabase db=android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(fixture,null)){
                db.execSQL("DROP TABLE IF EXISTS DOWNLOADS");db.execSQL("DROP TABLE IF EXISTS DOWNLOAD_DIRNAME");
                db.execSQL("CREATE TABLE DOWNLOADS(GID INTEGER PRIMARY KEY,TITLE TEXT,TITLE_JPN TEXT,TIME INTEGER,STATE INTEGER,LEGACY INTEGER,TOKEN TEXT,THUMB TEXT)");
                db.execSQL("CREATE TABLE DOWNLOAD_DIRNAME(GID INTEGER,DIRNAME TEXT)");
                db.execSQL("INSERT INTO DOWNLOADS VALUES(1,'Synthetic one',NULL,100,3,0,'synthetic-token','synthetic-thumb')");
                db.execSQL("INSERT INTO DOWNLOADS VALUES(2,'Synthetic two',NULL,90,3,0,'synthetic-token','synthetic-thumb')");
                db.execSQL("INSERT INTO DOWNLOAD_DIRNAME VALUES(1,'one'),(2,'two')");
            }
            JSONObject initial=Catalog.importDb(c,android.net.Uri.fromFile(fixture));
            check(Catalog.completedIds(initial).equals(java.util.Set.of("1","2")),"actual EhViewer schema without PAGES imports correctly");
            check(!initial.getJSONArray("rows").getJSONObject(0).getString("contentStamp").isBlank(),"content signals stored as local hash only");
            try(android.database.sqlite.SQLiteDatabase db=android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(fixture,null)){db.execSQL("UPDATE DOWNLOADS SET TIME=200 WHERE GID=2");}
            JSONObject reordered=Catalog.importDb(c,android.net.Uri.fromFile(fixture));
            check(Catalog.manifest(reordered).getJSONArray("books").getJSONObject(0).getString("id").equals("2"),"latest DB time order imported");
            check(IncrementalChanges.affected(Catalog.changeRows(initial),Catalog.changeRows(reordered)).contains("2"),"redownload move selects affected book");
            LocalState.json(c,"last-synced-order.json",initial);
            var changes=ChangeSummaryStore.prepare(c,reordered);
            check(changes!=null&&changes.added().isEmpty()&&changes.contentChecks().size()==1&&changes.orderMoves()==1,"summary compares with last successful snapshot");
            String preview=LocalState.prefs(c).getString(ChangeSummaryStore.KEY,"");
            check(ChangeSummaryStore.display(preview,"").contains("待 NAS 确认"),"import preview does not invent confirmed reuse");
            ChangeSummaryStore.planned(c,changes.withDirectorySignals(java.util.Set.of("1")),1,1,0,true);
            String planned=LocalState.prefs(c).getString(ChangeSummaryStore.KEY,"");
            check(ChangeSummaryStore.display(planned,"").contains("内容待检查 2 本")&&ChangeSummaryStore.display(planned,"").contains("本轮确认复用 1 本"),"existing directory hints and actual receipt counts appear");
            LocalState.json(c,"last-synced-order.json",reordered);ChangeSummaryStore.published(c);
            check(ChangeSummaryStore.display(LocalState.prefs(c).getString(ChangeSummaryStore.KEY,""),"").contains("本次清单已发布"),"publication persists report rather than recomputing zero changes");
            check(ChangeSummaryStore.prepare(c,reordered).contentChecks().isEmpty(),"new import after success uses advanced baseline");
            JSONObject unresolved=new JSONObject(initial.toString());unresolved.getJSONArray("rows").getJSONObject(1).put("time",100);
            check(ChangeSummaryStore.prepare(c,unresolved)==null&&!LocalState.prefs(c).contains(ChangeSummaryStore.KEY),"unresolved tie clears stale summary without guessed ordering");
            check(ChangeSummaryStore.display("{\"schema\":99}","").contains("暂不可用"),"malformed or unknown report safely degrades");
            LocalState.json(c,"last-synced-order.json",initial);
            try(android.database.sqlite.SQLiteDatabase db=android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(fixture,null)){db.execSQL("ALTER TABLE DOWNLOADS ADD COLUMN PAGES INTEGER");db.execSQL("UPDATE DOWNLOADS SET PAGES=25");}
            JSONObject withPages=Catalog.importDb(c,android.net.Uri.fromFile(fixture));
            try(android.database.sqlite.SQLiteDatabase db=android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(fixture,null)){db.execSQL("UPDATE DOWNLOADS SET PAGES=26 WHERE GID=1");}
            JSONObject changedPages=Catalog.importDb(c,android.net.Uri.fromFile(fixture));
            check(IncrementalChanges.affected(Catalog.changeRows(withPages),Catalog.changeRows(changedPages)).equals(java.util.Set.of("1")),"optional PAGES change selects only that book");
            JSONObject sourcePlan=Catalog.manifest(changedPages),plan=new JSONObject(sourcePlan.toString()).put("retentionPolicy","keep-omitted-files-v1");
            for(int i=0;i<plan.getJSONArray("books").length();i++){JSONObject b=plan.getJSONArray("books").getJSONObject(i);b.put("sourceDirectory",b.getString("directory"));}
            Catalog.validatePlan(sourcePlan,plan);checks++;
            plan.getJSONArray("books").getJSONObject(0).put("title","tampered");
            try{Catalog.validatePlan(sourcePlan,plan);throw new AssertionError("server changed original metadata");}catch(IOException expected){checks++;}
            var p=LocalState.prefs(c);p.edit().clear().commit();
            String tree="content://com.android.externalstorage.documents/tree/primary%3AEhViewer/document/primary%3AEhViewer%2Fdownload";
            p.edit().putString("tree",tree).putString("sourceGrant","synthetic-grant").putString("backup","synthetic-backup").putString("checkpoint","synthetic-checkpoint").putInt("nextBook",10073).putInt("readConcurrency",4).putInt("uploadConcurrency",2).putBoolean("directRead",true).putBoolean("newOnly",false).putInt("batchLimit",500).putInt("bookCount",10073).putInt("tieCount",0).putString("runState","complete").putString("status","上次同步完成").commit();
            LocalState.savePairing(c,new JSONObject().put("app","localshelf-sync").put("version",1).put("token","1".repeat(64)).put("certificateSha256","2".repeat(64)).put("url","https://192.168.254.254:8443"));
            byte[] pairingBefore=java.nio.file.Files.readAllBytes(new File(c.getNoBackupFilesDir(),"pairing.enc").toPath());
            MainActivity activity=(MainActivity)startActivitySync(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));waitForIdleSync();
            runOnMainSync(()->{
                check(activity.advanced.getVisibility()==View.GONE,"advanced collapsed by default");
                check(activity.importBackup.isShown()&&activity.importBackup.isEnabled(),"latest db import visible");
                check(activity.syncNow.isShown()&&activity.syncNow.isEnabled(),"daily sync visible and ready");
                check(activity.syncNow.getText().toString().equals("同步新增与更新"),"daily updates primary action");
                check(activity.changeText.getText().toString().contains("NAS 连接已更新"),"pairing changes invalidate stale summary");
                check(activity.pauseNow.getVisibility()==View.GONE,"no redundant idle pause button");
                check(activity.reviewOrder.getVisibility()==View.GONE,"tie review only when needed");
                check(activity.setupNow.getVisibility()==View.GONE,"existing directory and NAS need no setup");
                check(p.getBoolean("newOnly",false)&&p.getInt("batchLimit",-1)==0,"one-time daily defaults");
                check(p.getString("tree","").equals(tree)&&p.getString("backup","").equals("synthetic-backup")&&p.getString("sourceGrant","").equals("synthetic-grant"),"source backup and grant preserved");
                check(p.getString("checkpoint","").equals("synthetic-checkpoint")&&p.getInt("nextBook",0)==10073,"checkpoint untouched");
                check(p.getInt("readConcurrency",0)==4&&p.getInt("uploadConcurrency",0)==2&&p.getBoolean("directRead",false),"transfer preferences preserved");
                check(!SyncRunner.busy.get()&&!SyncJob.pending(c),"opening UI never starts transfer");
                activity.detailsToggle.performClick();check(activity.advanced.getVisibility()==View.VISIBLE,"advanced disclosure expands");
                check(activity.editNasAddress.getVisibility()==View.VISIBLE&&activity.editNasAddress.isEnabled(),"paired idle device can edit NAS address");
                SyncRunner.busy.set(true);activity.refresh();check(!activity.editNasAddress.isEnabled(),"active work disables address editing");SyncRunner.busy.set(false);activity.refresh();
                p.edit().putBoolean("newOnly",false).putInt("batchLimit",500).commit();activity.refresh();
                check(!p.getBoolean("newOnly",true)&&p.getInt("batchLimit",0)==500,"later explicit advanced choices respected");
                p.edit().putInt("tieCount",1).commit();activity.refresh();check(activity.reviewOrder.isShown()&&!activity.syncNow.isEnabled(),"unresolved order visibly blocks sync");
                p.edit().putInt("tieCount",0).putString("sourceError","测试：授权已失效").commit();activity.refresh();check(activity.setupNow.isShown()&&!activity.syncNow.isEnabled(),"invalid source offers setup instead of upload");
                p.edit().putString("sourceError","").putBoolean("dailyDefaults048",false).putBoolean("cyclePending",true).putBoolean("cycleFull",true).commit();activity.refresh();
                check(!p.getBoolean("dailyDefaults048",true)&&!p.getBoolean("newOnly",true)&&p.getInt("batchLimit",0)==500,"resumable full cycle not changed by upgrade");
                check(activity.syncNow.getText().toString().contains("完整校验"),"full-cycle continuation clearly labeled");
                p.edit().putBoolean("cyclePending",false).putBoolean("cycleFull",false).commit();activity.refresh();
                check(p.getBoolean("dailyDefaults048",false)&&p.getBoolean("newOnly",false)&&p.getInt("batchLimit",-1)==0,"daily defaults adopt after old cycle ends");
                activity.showAdvanced(false);
            });
            check(java.util.Arrays.equals(pairingBefore,java.nio.file.Files.readAllBytes(new File(c.getNoBackupFilesDir(),"pairing.enc").toPath())),"encrypted pairing byte-identical");
            try{LocalState.changeAddress(c,"http://192.168.254.253:8443",candidate->{throw new AssertionError("invalid address reached probe");});throw new AssertionError("invalid address saved");}catch(IOException expected){checks++;}
            try{LocalState.changeAddress(c,"192.168.254.253:9443",candidate->{throw new javax.net.ssl.SSLException("synthetic pin mismatch");});throw new AssertionError("failed probe saved");}catch(javax.net.ssl.SSLException expected){checks++;}
            check(java.util.Arrays.equals(pairingBefore,java.nio.file.Files.readAllBytes(new File(c.getNoBackupFilesDir(),"pairing.enc").toPath())),"invalid address and failed verification preserve old encrypted pairing");
            LocalState.changeAddress(c,"192.168.254.253:9443",candidate->{check(candidate.getString("token").equals("1".repeat(64))&&candidate.getString("certificateSha256").equals("2".repeat(64)),"verification keeps original token and pin");});
            JSONObject changed=LocalState.pairing(c);check(changed.getString("url").equals("https://192.168.254.253:9443")&&changed.getString("token").equals("1".repeat(64))&&changed.getString("certificateSha256").equals("2".repeat(64)),"address saved and original pairing identity retained");
            check(p.getString("tree","").equals(tree)&&p.getString("checkpoint","").equals("synthetic-checkpoint")&&!SyncRunner.busy.get()&&!SyncJob.pending(c),"address edit does not change source checkpoint or start work");
            var savedPlan=ChangeSummaryStore.prepare(c,reordered);
            check(savedPlan!=null,"summary can be prepared offline with synthetic DB only");
            runOnMainSync(()->{p.edit().putInt("bookCount",2).commit();activity.refresh();check(activity.changeText.getText().toString().contains("顺序调整至少 1 本"),"home renders summary");activity.refresh();check(!SyncRunner.busy.get()&&!SyncJob.pending(c),"summary refresh starts no scan or sync");});
            // Draw only our own synthetic window, never other foreground apps.
            final android.graphics.Bitmap[] image=new android.graphics.Bitmap[1];
            runOnMainSync(()->{View root=activity.getWindow().getDecorView();image[0]=android.graphics.Bitmap.createBitmap(root.getWidth(),root.getHeight(),android.graphics.Bitmap.Config.ARGB_8888);root.draw(new android.graphics.Canvas(image[0]));});
            File screenshot=new File(c.getCacheDir(),"daily-home.png");
            try(OutputStream out=new FileOutputStream(screenshot)){image[0].compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}finally{image[0].recycle();}
            result.putString("stream",log+"TOTAL "+checks+" isolated UI checks passed\n");finish(-1,result);
        }catch(Throwable e){StringWriter text=new StringWriter();e.printStackTrace(new PrintWriter(text));result.putString("stream",log+"FAIL\n"+text);finish(0,result);}
    }
}
