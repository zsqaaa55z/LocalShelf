package local.shelf.sync;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import java.util.*;

final class HashCache implements AutoCloseable {
    final SQLiteDatabase db;
    final Map<String,Map<String,Receipt>> receiptCache=new HashMap<>();
    record Hash(long size,long modified,String sha) {}
    record Receipt(String directory,String proof) {}
    HashCache(Context c){db=SQLiteDatabase.openOrCreateDatabase(new java.io.File(c.getNoBackupFilesDir(),"hash-cache.db"),null);db.execSQL("CREATE TABLE IF NOT EXISTS hashes(uri TEXT PRIMARY KEY,size INTEGER,modified INTEGER,sha TEXT)");db.execSQL("CREATE TABLE IF NOT EXISTS receipts(scope TEXT,gid TEXT,directory TEXT,proof TEXT,PRIMARY KEY(scope,gid))");}
    Map<String,Hash> getAll(List<SourceFiles.FileEntry> files){
        Map<String,Hash> result=new HashMap<>();
        for(int start=0;start<files.size();start+=400){
            int count=Math.min(400,files.size()-start);String[] args=new String[count];
            for(int i=0;i<count;i++)args[i]=files.get(start+i).doc().uri().toString();
            String placeholders=String.join(",",Collections.nCopies(count,"?"));
            try(Cursor c=db.rawQuery("SELECT uri,size,modified,sha FROM hashes WHERE uri IN ("+placeholders+")",args)){
                while(c.moveToNext())result.put(c.getString(0),new Hash(c.getLong(1),c.getLong(2),c.getString(3)));
            }
        }return result;
    }
    static String matching(Map<String,Hash> values,SourceFiles.Doc doc){Hash h=values.get(doc.uri().toString());return doc.modified()>0&&h!=null&&h.size==doc.size()&&h.modified==doc.modified()?h.sha:null;}
    void putAll(Map<SourceFiles.Doc,String> values){
        if(values.isEmpty())return;
        db.beginTransaction();try{for(var item:values.entrySet()){var doc=item.getKey();db.execSQL("INSERT OR REPLACE INTO hashes VALUES(?,?,?,?)",new Object[]{doc.uri().toString(),doc.size(),doc.modified(),item.getValue()});}db.setTransactionSuccessful();}finally{db.endTransaction();}
    }
    Map<String,Receipt> receipts(String scope){if(receiptCache.containsKey(scope))return receiptCache.get(scope);Map<String,Receipt> result=new HashMap<>();try(Cursor c=db.rawQuery("SELECT gid,directory,proof FROM receipts WHERE scope=?",new String[]{scope})){while(c.moveToNext())result.put(c.getString(0),new Receipt(c.getString(1),c.getString(2)));}receiptCache.put(scope,result);return result;}
    void receipt(String scope,String gid,String directory,String proof){
        Map<String,Receipt> saved=receipts(scope);Receipt old=saved.get(gid);
        if(proof==null||!proof.matches("[a-f0-9]{64}")){if(old!=null){db.delete("receipts","scope=? AND gid=?",new String[]{scope,gid});saved.remove(gid);}return;}
        Receipt next=new Receipt(directory,proof);if(next.equals(old))return;
        db.execSQL("INSERT OR REPLACE INTO receipts VALUES(?,?,?,?)",new Object[]{scope,gid,directory,proof});saved.put(gid,next);
    }
    public void close(){db.close();}
}
