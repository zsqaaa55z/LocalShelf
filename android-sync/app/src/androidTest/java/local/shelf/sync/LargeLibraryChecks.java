package local.shelf.sync;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.os.*;
import android.provider.DocumentsContract;
import android.util.Base64;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;

/** Large synthetic provider / isolated cache only. Does not change real app settings. */
final class LargeLibraryChecks {
    static final Uri PROVIDER=Uri.parse("content://"+FixtureProvider.AUTH);
    static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    static String hash(String value)throws Exception{return LocalState.hex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}
    static Bundle call(Context c,String method){return c.getContentResolver().call(PROVIDER,method,null,null);}
    static JSONObject counts(Bundle b)throws Exception{return new JSONObject().put("rootQueries",b.getLong("rootQueries")).put("bookQueries",b.getLong("bookQueries")).put("fileOpens",b.getLong("fileOpens"));}
    static double elapsed(long start){return (SystemClock.elapsedRealtime()-start)/1000.0;}
    static void backup(File file,boolean added){
        SQLiteDatabase.deleteDatabase(file);
        try(SQLiteDatabase db=SQLiteDatabase.openOrCreateDatabase(file,null)){
            db.execSQL("CREATE TABLE DOWNLOADS(GID INTEGER PRIMARY KEY,TITLE TEXT,TITLE_JPN TEXT,TIME INTEGER,STATE INTEGER)");db.execSQL("CREATE TABLE DOWNLOAD_DIRNAME(GID INTEGER PRIMARY KEY,DIRNAME TEXT)");
            db.beginTransaction();try{for(int i=1;i<=(added?10001:10000);i++){db.execSQL("INSERT INTO DOWNLOADS VALUES(?,?,?,?,?)",new Object[]{i,"Synthetic book "+i,"Synthetic book "+i,i==10001?30000:20000-i,3});db.execSQL("INSERT INTO DOWNLOAD_DIRNAME VALUES(?,?)",new Object[]{i,i+"-synthetic"});}db.setTransactionSuccessful();}finally{db.endTransaction();}
        }
    }
    static JSONObject run(Context original,Bundle args)throws Exception{
        File directory=new File(original.getCacheDir(),"large-library-performance");require(!directory.exists(),"Isolated performance directory already exists");require(directory.mkdirs(),"Cannot create isolated test directory");
        Context c=new ContextWrapper(original){public File getNoBackupFilesDir(){return directory;}public File getCacheDir(){return directory;}public SharedPreferences getSharedPreferences(String name,int mode){return original.getSharedPreferences("large-performance-"+name,mode);}};
        try{
            LocalState.prefs(c).edit().clear().commit();call(c,"large-setup");
            JSONObject result=new JSONObject().put("books",10000).put("virtualImages",1000000).put("dataset","virtual SAF documents and seeded successful receipts; no real comic data");
            Uri tree=DocumentsContract.buildTreeDocumentUri(FixtureProvider.AUTH,"large");SourceFiles source=new SourceFiles(c,tree);long start=SystemClock.elapsedRealtime();var dirs=source.directories();long count=0;
            for(var dir:dirs.values())count+=source.files(dir,new SyncRunner.Cancel()).size();
            require(dirs.size()==10000&&count==1000000,"Large provider count mismatch");result.put("fullMetadataScanSeconds",elapsed(start)).put("fullMetadataCounts",counts(call(c,"large-stats")));
            List<SourceFiles.FileEntry> sample=new ArrayList<>();Map<SourceFiles.Doc,String> hashes=new HashMap<>();
            for(int i=0;i<5000;i++){var doc=new SourceFiles.Doc("hash-"+i,"page.jpg","image/jpeg",1,1000,Uri.parse("content://"+FixtureProvider.AUTH+"/hash-benchmark/"+i));sample.add(new SourceFiles.FileEntry("page-"+i,doc));hashes.put(doc,"1".repeat(64));}
            try(HashCache cache=new HashCache(c)){
                cache.putAll(hashes);start=SystemClock.elapsedRealtime();
                for(var entry:sample){var doc=entry.doc();try(Cursor cursor=cache.db.rawQuery("SELECT sha FROM hashes WHERE uri=? AND size=? AND modified=?",new String[]{doc.uri().toString(),"1","1000"})){require(cursor.moveToFirst(),"Missing baseline hash");cache.db.execSQL("INSERT OR REPLACE INTO hashes VALUES(?,?,?,?)",new Object[]{doc.uri().toString(),1,1000,cursor.getString(0)});}}
                result.put("oldCache5000Seconds",elapsed(start));start=SystemClock.elapsedRealtime();var loaded=cache.getAll(sample);for(var entry:sample)require(HashCache.matching(loaded,entry.doc())!=null,"Missing optimized hash");result.put("newCache5000Seconds",elapsed(start));
                var zero=new SourceFiles.Doc("zero","zero","image/jpeg",1,0,sample.get(0).doc().uri());require(HashCache.matching(loaded,zero)==null,"Unknown mtime must not reuse hash");
            }
            JSONObject pairing=new JSONObject(new String(Base64.decode(args.getString("fixture"),Base64.DEFAULT),StandardCharsets.UTF_8));LocalState.savePairing(c,pairing);
            File db=new File(directory,"large-export.db");backup(db,false);LocalState.prefs(c).edit().putString("tree",tree.toString()).putString("backup",Uri.fromFile(db).toString()).commit();
            String scope=hash(tree+"\n"+pairing.getString("certificateSha256")+"\n"+pairing.getString("url"));
            try(HashCache cache=new HashCache(c)){cache.db.beginTransaction();try{for(int i=1;i<=10000;i++)cache.receipt(scope,Integer.toString(i),i+"-synthetic",hash("large-test-"+i));cache.db.setTransactionSuccessful();}finally{cache.db.endTransaction();}}
            call(c,"large-reset");start=SystemClock.elapsedRealtime();SyncEngine fast=new SyncEngine(c,new SyncRunner.Cancel(),s->{});fast.run(false,true);Bundle stats=call(c,"large-stats");
            require(fast.reusedBooks==10000&&fast.scannedBooks==0&&fast.sent==0&&stats.getLong("bookQueries")==0&&stats.getLong("fileOpens")==0,"Quick mode scanned old book content");result.put("quick10000Seconds",elapsed(start)).put("quickCounts",counts(stats));
            backup(db,true);call(c,"large-add-book");call(c,"large-reset");start=SystemClock.elapsedRealtime();SyncEngine added=new SyncEngine(c,new SyncRunner.Cancel(),s->{});added.run(false,true);stats=call(c,"large-stats");
            require(added.reusedBooks==10000&&added.scannedBooks==1&&added.sent==100&&stats.getLong("bookQueries")==2,"Added book did not limit source scan to one book");
            JSONArray books=Catalog.manifest(LocalState.read(c,"order.json")).getJSONArray("books");require(books.length()==10001&&books.getJSONObject(0).getString("id").equals("10001")&&books.getJSONObject(10000).getString("id").equals("10000"),"Large library order changed");
            result.put("oneNewBookSeconds",elapsed(start)).put("oneNewBookCounts",counts(stats)).put("newBookBytes",added.sent).put("orderVerified",true).put("processPssMiB",Debug.getPss()/1024.0).put("result","PASS");return result;
        }finally{
            LocalState.prefs(c).edit().clear().commit();
            try(var paths=java.nio.file.Files.walk(directory.toPath())){for(var path:paths.sorted(Comparator.reverseOrder()).toList())java.nio.file.Files.delete(path);}
        }
    }
}
