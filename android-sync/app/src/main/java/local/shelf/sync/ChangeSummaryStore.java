package local.shelf.sync;

import android.content.Context;
import java.io.FileNotFoundException;
import org.json.JSONObject;

/** Small anonymous UI snapshot; failures must never change a sync outcome. */
final class ChangeSummaryStore {
    static final String KEY="changeSummary0410",HINT="changeSummaryHint0410";
    static void clear(Context c,String message){
        try{LocalState.prefs(c).edit().remove(KEY).putString(HINT,message).apply();}catch(RuntimeException ignored){}
    }
    static ChangeSummary.Analysis prepare(Context c,JSONObject draft){
        try{
            if(!Catalog.unresolved(draft).isEmpty()){clear(c,"有同值顺序待核对，核对完成后生成变化摘要。");return null;}
            JSONObject previous=null;try{previous=LocalState.read(c,"last-synced-order.json");}catch(FileNotFoundException ignored){}
            var result=ChangeSummary.analyze(previous==null?null:Catalog.changeRows(previous),Catalog.changeRows(draft));
            save(c,result.counts(),false,false,0,0,0,false);return result;
        }catch(Exception e){clear(c,"变化摘要暂不可用；不影响原同步校验，请重新导入完整 .db 后重试。");return null;}
    }
    static void planned(Context c,ChangeSummary.Analysis analysis,int reused,int prefix,int missing,boolean enabled){
        if(analysis!=null)save(c,analysis.counts(),true,false,reused,prefix,missing,enabled);
    }
    private static void save(Context c,ChangeSummary.Counts v,boolean planned,boolean published,int reused,int prefix,int missing,boolean enabled){
        try{
            JSONObject value=new JSONObject().put("schema",1).put("known",v.baselineKnown()).put("total",v.total()).put("added",v.added())
                    .put("checks",v.contentChecks()).put("moves",v.orderMoves()).put("removed",v.removed()).put("planned",planned)
                    .put("published",published).put("reused",reused).put("prefix",prefix).put("missing",missing).put("reuseEnabled",enabled);
            LocalState.prefs(c).edit().putString(KEY,value.toString()).remove(HINT).apply();
        }catch(Exception ignored){clear(c,"变化摘要暂不可用；原同步进度不受影响。");}
    }
    static void published(Context c){
        try{
            JSONObject value=new JSONObject(LocalState.prefs(c).getString(KEY,""));
            if(!value.getBoolean("planned"))return;
            value.put("published",true);LocalState.prefs(c).edit().putString(KEY,value.toString()).apply();
        }catch(Exception ignored){}
    }
    static String display(String raw,String fallback){
        if(raw.isEmpty())return fallback;
        try{
            JSONObject v=new JSONObject(raw);if(v.getInt("schema")!=1)throw new IllegalArgumentException();
            var counts=new ChangeSummary.Counts(v.getBoolean("known"),v.getInt("total"),v.getInt("added"),v.getInt("checks"),v.getInt("moves"),v.getInt("removed"));
            return v.getBoolean("planned")?counts.plan(v.getInt("reused"),v.getInt("prefix"),v.getInt("missing"),v.getBoolean("reuseEnabled"),v.getBoolean("published")):counts.preview();
        }catch(Exception ignored){return "变化摘要暂不可用；请重新导入最新完整 .db。";}
    }
}
