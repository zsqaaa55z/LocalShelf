package local.shelf.sync;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.util.*;

final class Catalog {
    static final String QUERY="SELECT d.GID,d.TITLE,d.TITLE_JPN,d.TIME,n.DIRNAME FROM DOWNLOADS d LEFT JOIN DOWNLOAD_DIRNAME n ON d.GID=n.GID ORDER BY d.TIME DESC";
    static JSONObject importDb(Context c,Uri uri)throws Exception {
        File copy=File.createTempFile("eh-order-",".db",c.getCacheDir());
        try {
            try(InputStream in=c.getContentResolver().openInputStream(uri);OutputStream out=new FileOutputStream(copy)) {
                if(in==null)throw new IOException("备份不可读");byte[] buffer=new byte[65536];int n;long count=0;
                while((n=in.read(buffer))!=-1){count+=n;if(count>128L*1024*1024)throw new IOException("备份超过 128 MB");out.write(buffer,0,n);}
            }
            JSONArray rows=new JSONArray();
            try(SQLiteDatabase db=SQLiteDatabase.openDatabase(copy.getPath(),null,SQLiteDatabase.OPEN_READONLY)) {
                try(Cursor integrity=db.rawQuery("PRAGMA quick_check",null)){if(!integrity.moveToFirst()||!"ok".equals(integrity.getString(0)))throw new IOException("备份不完整，请重新导出");}
                boolean hasState=false;Set<String> fields=new HashSet<>();
                try(Cursor columns=db.rawQuery("PRAGMA table_info(DOWNLOADS)",null)){while(columns.moveToNext())fields.add(columns.getString(1).toUpperCase(Locale.ROOT));}hasState=fields.contains("STATE");
                String query=QUERY.replace("d.TIME,n.DIRNAME", "d.TIME,n.DIRNAME,"+(hasState?"d.STATE":"NULL"));
                List<String> metadata=new ArrayList<>();for(String field:new String[]{"PAGES","TOTAL","FINISHED","DOWNLOADED","LEGACY","TOKEN","THUMB"})if(fields.contains(field))metadata.add(field);
                if(!metadata.isEmpty())query=query.replace(" FROM DOWNLOADS",",d."+String.join(",d.",metadata)+" FROM DOWNLOADS");
                try(Cursor cursor=db.rawQuery(query,null)) {
                    while(cursor.moveToNext()) {
                        if(rows.length()>=20000)throw new IOException("下载记录超过 20000 本");
                        if(cursor.getType(0)!=Cursor.FIELD_TYPE_INTEGER || cursor.getType(3)!=Cursor.FIELD_TYPE_INTEGER)throw new IOException("备份缺少有效下载顺序");
                        String title=cursor.getString(2);if(title==null||title.isBlank())title=cursor.getString(1);
                        JSONObject meta=new JSONObject();for(int i=0;i<metadata.size();i++)meta.put(metadata.get(i),cursor.isNull(i+6)?JSONObject.NULL:cursor.getString(i+6));
                        String stamp=LocalState.hex(java.security.MessageDigest.getInstance("SHA-256").digest(meta.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
                        rows.put(new JSONObject().put("id",Long.toString(cursor.getLong(0))).put("title",title).put("time",cursor.getLong(3)).put("directory",cursor.getString(4)).put("downloadComplete",cursor.getType(5)==Cursor.FIELD_TYPE_INTEGER&&cursor.getInt(5)==3).put("contentStamp",stamp));
                    }
                }
            }
            JSONObject draft=new JSONObject().put("rows",rows).put("resolvedTies",new JSONObject());
            // Validate IDs and directories even if time ties remain unresolved.
            var parsed=parse(rows);Map<Long,List<String>> temp=new HashMap<>();for(var r:parsed)temp.computeIfAbsent(r.time(),k->new ArrayList<>()).add(r.id());OrderRules.order(parsed,temp);
            // Keep confirmed positions only for exactly the same time + membership.
            try {
                JSONObject old=LocalState.read(c,"order.json").getJSONObject("resolvedTies");
                for(var group:temp.entrySet()) {
                    JSONArray explicit=old.optJSONArray(Long.toString(group.getKey()));
                    if(explicit!=null && new HashSet<>(strings(explicit)).equals(new HashSet<>(group.getValue())) && explicit.length()==group.getValue().size())draft.getJSONObject("resolvedTies").put(Long.toString(group.getKey()),explicit);
                }
            } catch(FileNotFoundException ignored) {}
            return draft;
        } finally {if(!copy.delete())copy.deleteOnExit();}
    }
    static List<String> strings(JSONArray a)throws JSONException{List<String> out=new ArrayList<>();for(int i=0;i<a.length();i++)out.add(a.getString(i));return out;}
    static List<OrderRules.Row> parse(JSONArray rows)throws JSONException {
        List<OrderRules.Row> out=new ArrayList<>();for(int i=0;i<rows.length();i++){JSONObject r=rows.getJSONObject(i);out.add(new OrderRules.Row(r.getString("id"),r.getString("directory"),r.getString("title"),r.getLong("time")));}return out;
    }
    static TreeMap<Long,List<OrderRules.Row>> unresolved(JSONObject draft)throws Exception {
        TreeMap<Long,List<OrderRules.Row>> groups=new TreeMap<>(Comparator.reverseOrder());
        for(var row:parse(draft.getJSONArray("rows")))groups.computeIfAbsent(row.time(),k->new ArrayList<>()).add(row);
        JSONObject resolved=draft.getJSONObject("resolvedTies");
        groups.entrySet().removeIf(e->e.getValue().size()==1 || resolved.has(Long.toString(e.getKey())));return groups;
    }
    static JSONObject manifest(JSONObject draft)throws Exception {
        JSONObject ties=draft.getJSONObject("resolvedTies");Map<Long,List<String>> resolved=new HashMap<>();
        for(Iterator<String> it=ties.keys();it.hasNext();){String k=it.next();resolved.put(Long.parseLong(k),strings(ties.getJSONArray(k)));}
        List<OrderRules.Row> ordered=OrderRules.order(parse(draft.getJSONArray("rows")),resolved);JSONArray books=new JSONArray();
        for(var r:ordered)books.put(new JSONObject().put("id",r.id()).put("directory",r.directory()).put("title",r.title()).put("time",r.time()).put("rank",books.length()));
        return new JSONObject().put("schema",1).put("orderSource","ehviewer-downloads-time-desc").put("orderVerified",true).put("resolvedTies",ties).put("books",books);
    }
    // Ehviewer_CN_SXJ DownloadInfo.STATE_FINISH == 3; absent/unknown state never skips scanning.
    static Set<String> completedIds(JSONObject draft)throws JSONException{Set<String> result=new TreeSet<>();JSONArray rows=draft.getJSONArray("rows");for(int i=0;i<rows.length();i++){JSONObject row=rows.getJSONObject(i);if(row.optBoolean("downloadComplete",false))result.add(row.getString("id"));}return result;}
    static List<IncrementalChanges.Row> changeRows(JSONObject draft)throws Exception {
        Map<String,JSONObject> byId=new HashMap<>();JSONArray raw=draft.getJSONArray("rows");for(int i=0;i<raw.length();i++)byId.put(raw.getJSONObject(i).getString("id"),raw.getJSONObject(i));
        JSONArray sorted=manifest(draft).getJSONArray("books");List<IncrementalChanges.Row> result=new ArrayList<>();
        for(int i=0;i<sorted.length();i++){JSONObject row=byId.get(sorted.getJSONObject(i).getString("id"));result.add(new IncrementalChanges.Row(row.getString("id"),row.getString("directory"),row.getString("title"),row.getLong("time"),row.optBoolean("downloadComplete",false),row.optString("contentStamp",null)));}return result;
    }
    static String sourceDirectory(JSONObject book)throws JSONException{return book.optString("sourceDirectory",book.getString("directory"));}
    static void validatePlan(JSONObject source,JSONObject planned)throws Exception {
        JSONArray a=source.getJSONArray("books"),b=planned.getJSONArray("books");Set<String> dirs=new HashSet<>();
        if(a.length()!=b.length()||!planned.getBoolean("orderVerified")||!"ehviewer-downloads-time-desc".equals(planned.getString("orderSource"))||!"keep-omitted-files-v1".equals(planned.getString("retentionPolicy")))throw new IOException("NAS 日常同步计划无效");
        for(int i=0;i<a.length();i++){
            JSONObject expected=a.getJSONObject(i),actual=b.getJSONObject(i);String folder=actual.getString("directory");OrderRules.validName(folder);
            if(!dirs.add(folder)||!expected.getString("id").equals(actual.getString("id"))||!expected.getString("title").equals(actual.getString("title"))||expected.getLong("time")!=actual.getLong("time")||actual.getInt("rank")!=i||!expected.getString("directory").equals(actual.getString("sourceDirectory")))throw new IOException("NAS 改变了源清单或顺序，已停止");
        }
    }
    static void save(Context c,JSONObject draft)throws Exception {
        try{JSONObject old=LocalState.read(c,"order.json");if(!old.getJSONArray("rows").toString().equals(draft.getJSONArray("rows").toString()))LocalState.json(c,"previous-order.json",old);}catch(FileNotFoundException ignored){}
        LocalState.json(c,"order.json",draft);
        LocalState.prefs(c).edit().putInt("bookCount",draft.getJSONArray("rows").length()).putInt("tieCount",unresolved(draft).size()).apply();
    }
}
