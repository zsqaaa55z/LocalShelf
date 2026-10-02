package local.shelf.sync;

import android.content.Context;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.util.*;

final class MigrationReport {
    static JSONObject totals(List<SourceFiles.FileEntry> files)throws Exception {
        long bytes=0;for(var f:files)bytes=Math.addExact(bytes,f.doc().size());return new JSONObject().put("files",files.size()).put("bytes",bytes);
    }
    static Map<String,JSONObject> rows(JSONObject draft)throws Exception {
        Map<String,JSONObject> map=new HashMap<>();for(int i=0;i<draft.getJSONArray("rows").length();i++){JSONObject r=draft.getJSONArray("rows").getJSONObject(i);map.put(r.getString("id"),r);}return map;
    }
    static JSONObject differences(JSONObject current,JSONObject previous)throws Exception {
        JSONObject diff=new JSONObject();if(previous==null)return diff.put("baselineAvailable",false);
        var before=rows(previous);var after=rows(current);JSONArray added=new JSONArray(),removed=new JSONArray(),changed=new JSONArray();
        for(String id:new TreeSet<>(after.keySet())){if(!before.containsKey(id))added.put(id);else if(!before.get(id).getString("directory").equals(after.get(id).getString("directory"))||before.get(id).getLong("time")!=after.get(id).getLong("time"))changed.put(id);}
        for(String id:new TreeSet<>(before.keySet()))if(!after.containsKey(id))removed.put(id);
        return diff.put("baselineAvailable",true).put("addedIds",added).put("removedIds",removed).put("changedMappingOrTimeIds",changed);
    }
    static JSONObject build(Context c,SyncRunner.Cancel cancel,SyncEngine.Progress progress)throws Exception {
        SourceFiles.requireReady(c);
        String backup=LocalState.prefs(c).getString("backup","");if(backup.isBlank())throw new IOException("请先选择 EhViewer 完整下载备份");
        JSONObject old=null;String basis="无历史基准";
        for(String file:new String[]{"last-synced-order.json","previous-order.json","order.json"})try{old=LocalState.read(c,file);basis=file;break;}catch(FileNotFoundException ignored){}
        JSONObject draft=Catalog.importDb(c,Uri.parse(backup));Catalog.save(c,draft);
        String tree=LocalState.prefs(c).getString("tree","");if(tree.isBlank())throw new IOException("请先授权下载目录");
        progress.update("阶段：迁移预检 · 正在等待系统读取下载目录…");
        SourceFiles source=new SourceFiles(c,Uri.parse(tree));var dirs=source.directories(count->progress.update("阶段：迁移预检 · 已读取下载目录 "+count+" 项"));Set<String> ordered=new HashSet<>();
        JSONObject books=new JSONObject(),archives=new JSONObject();JSONArray missing=new JSONArray(),empty=new JSONArray(),outside=new JSONArray();
        long totalBytes=0,totalFiles=0,archiveBytes=0;JSONArray rows=draft.getJSONArray("rows");
        for(int i=0;i<rows.length();i++){
            cancel.check();JSONObject row=rows.getJSONObject(i);String name=row.getString("directory"),id=row.getString("id");ordered.add(name);var dir=dirs.get(name);JSONObject t;
            if(dir==null){missing.put(new JSONObject().put("id",id).put("directory",name));t=new JSONObject().put("files",0).put("bytes",0);}
            else{t=totals(source.files(dir,cancel));if(t.getLong("files")==0)empty.put(new JSONObject().put("id",id).put("directory",name));}
            books.put(id,t);totalBytes=Math.addExact(totalBytes,t.getLong("bytes"));totalFiles=Math.addExact(totalFiles,t.getLong("files"));
            if(i%25==0)progress.update(String.format(Locale.CHINA,"阶段：迁移预检 · 下载记录 %d / %d\n已统计 %.2f GB · %d 个文件",i+1,rows.length(),totalBytes/1e9,totalFiles));
        }
        JSONObject rootTotals=null;List<ExtraArchive.Group> groups=ExtraArchive.groups(dirs,ordered);
        for(var group:groups){
            cancel.check();JSONObject t=totals(ExtraArchive.files(source,group,cancel));archives.put(group.id(),t);
            if(group.kind().equals("root"))rootTotals=t;else outside.put(new JSONObject().put("id",group.id()).put("directory",group.name()).put("files",t.getLong("files")).put("bytes",t.getLong("bytes")));
            totalBytes=Math.addExact(totalBytes,t.getLong("bytes"));totalFiles=Math.addExact(totalFiles,t.getLong("files"));archiveBytes=Math.addExact(archiveBytes,t.getLong("bytes"));
            progress.update(String.format(Locale.CHINA,"阶段：迁移预检 · 独立归档\n已统计 %.2f GB · %d 个文件",totalBytes/1e9,totalFiles));
        }
        JSONObject ties=new JSONObject();int tiedRecords=0;for(var e:Catalog.unresolved(draft).entrySet()){ties.put(Long.toString(e.getKey()),e.getValue().size());tiedRecords+=e.getValue().size();}
        JSONObject result=new JSONObject().put("schema",1).put("createdAtMillis",System.currentTimeMillis()).put("bookCount",rows.length())
            .put("comparisonBasis",basis).put("differences",differences(draft,old)).put("books",books).put("archives",archives)
            .put("missingDirectories",missing).put("missingDirectoryCount",missing.length()).put("emptyDirectories",empty).put("emptyDirectoryCount",empty.length())
            .put("unmappedDirectories",outside).put("unmappedDirectoryCount",outside.length()).put("archiveBytes",archiveBytes)
            .put("rootFileCount",rootTotals.getLong("files")).put("rootBytes",rootTotals.getLong("bytes"))
            .put("totalSourceFiles",totalFiles).put("totalSourceBytes",totalBytes).put("unresolvedTimeGroups",ties).put("unresolvedTimeRecords",tiedRecords)
            .put("note","只读文件数量和容量快照；不是文件哈希验收，也不证明旧记录缺失的图片已备份。列表外目录单独归档，不进入主下载顺序。");
        cancel.check();LocalState.json(c,"migration-report.json",result);return result;
    }
    static String summary(JSONObject r)throws Exception {
        JSONObject d=r.getJSONObject("differences");String diff=d.getBoolean("baselineAvailable")?"\n相对已有基准：新增 "+d.getJSONArray("addedIds").length()+" · 移除 "+d.getJSONArray("removedIds").length()+" · 时间/目录变化 "+d.getJSONArray("changedMappingOrTimeIds").length():"\n暂无历史基准，未推断哪些是新增记录";
        return String.format(Locale.CHINA,"迁移预检完成 · %.2f GB · %d 个文件\n主清单 %d 本 · 缺失目录 %d · 空目录 %d\n独立归档 %d 个目录 + %d 个根文件 · %.2f GB\n待确认顺序 %d 条",r.getLong("totalSourceBytes")/1e9,r.getLong("totalSourceFiles"),r.getInt("bookCount"),r.getInt("missingDirectoryCount"),r.getInt("emptyDirectoryCount"),r.getInt("unmappedDirectoryCount"),r.getLong("rootFileCount"),r.getLong("archiveBytes")/1e9,r.getInt("unresolvedTimeRecords"))+diff+"\n可导出完整差异报告；本次没有上传漫画。";
    }
}
