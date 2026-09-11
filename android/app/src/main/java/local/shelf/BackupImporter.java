package local.shelf;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.util.*;

/** Reads an explicitly selected export, never the live EhViewer private database. */
final class BackupImporter {
    static final String QUERY = "SELECT d.GID,d.TITLE,d.TITLE_JPN,d.TIME,n.DIRNAME FROM DOWNLOADS d LEFT JOIN DOWNLOAD_DIRNAME n ON d.GID=n.GID ORDER BY d.TIME DESC";
    static JSONArray read(Context context, Uri source, boolean japanese) throws Exception {
        File copy=File.createTempFile("shelf-import-", ".db", context.getCacheDir());
        try {
            try(InputStream in=context.getContentResolver().openInputStream(source); OutputStream out=new FileOutputStream(copy)){
                if(in==null)throw new IOException("无法打开备份");
                byte[] buffer=new byte[65536]; long total=0;int n;
                while((n=in.read(buffer))!=-1){total+=n;if(total>128L*1024*1024)throw new IOException("备份超过 128 MB 上限");out.write(buffer,0,n);}
            }
            try(SQLiteDatabase db=SQLiteDatabase.openDatabase(copy.getPath(),null,SQLiteDatabase.OPEN_READONLY)) {
                // No migration or upstream ORM: no writes, no history/token queries.
                for(String table:new String[]{"DOWNLOADS","DOWNLOAD_DIRNAME"}) {
                    try(Cursor c=db.rawQuery("SELECT type FROM sqlite_master WHERE name=?",new String[]{table})){
                        if(!c.moveToFirst()||!"table".equals(c.getString(0)))throw new IOException("不是支持的 EhViewer 数据备份");
                    }
                }
                JSONArray books=new JSONArray();Set<String> dirs=new HashSet<>();
                try(Cursor c=db.rawQuery(QUERY,null)){
                    while(c.moveToNext()){
                        if(books.length()>=20000)throw new IOException("下载记录超过开发版上限");
                        long gid=c.getLong(0),time=c.getLong(3);String title=c.getString(japanese?2:1),fallback=c.getString(japanese?1:2),dir=c.getString(4);
                        if(c.isNull(3))throw new IOException("排序值缺失，无法导入");
                        // Preserve this query's returned order for ties; do not invent a secondary sort.
                        if(title==null||title.isBlank())title=fallback;
                        if(gid<=0||title==null||title.isBlank()||dir==null||dir.isBlank()||dir.equals(".")||dir.equals("..")||dir.contains("/")||dir.contains("\\")||!dirs.add(dir))throw new IOException("标题或目录映射缺失/重复，不能无损还原");
                        books.put(new JSONObject().put("id",Long.toString(gid)).put("title",title).put("directory",dir).put("rank",books.length()));
                    }
                }
                return books;
            }
        } finally { if(!copy.delete())copy.deleteOnExit(); }
    }
}
