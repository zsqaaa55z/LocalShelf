package local.shelf.sync;

import org.json.*;
import java.util.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

final class ExtraArchive {
    record Group(String id,String kind,String name,SourceFiles.Doc doc){}
    static String id(String kind,String name)throws Exception{return LocalState.hex(MessageDigest.getInstance("SHA-256").digest((kind+"\n"+name).getBytes(StandardCharsets.UTF_8)));}
    static List<Group> groups(Map<String,SourceFiles.Doc> dirs,Set<String> ordered)throws Exception {
        List<Group> out=new ArrayList<>();
        // Sorting here schedules independent archives; it never changes reader order.
        for(String name:new TreeSet<>(dirs.keySet()))if(!ordered.contains(name))out.add(new Group(id("directory",name),"directory",name,dirs.get(name)));
        out.add(new Group(id("root",""),"root","",null));return out;
    }
    static JSONObject manifest(List<Group> groups,String revision)throws Exception {
        JSONArray entries=new JSONArray();for(Group g:groups)entries.put(new JSONObject().put("id",g.id()).put("kind",g.kind()).put("name",g.name()));
        return new JSONObject().put("schema",1).put("type","localshelf-extra-v1").put("sourceRevision",revision).put("groups",entries);
    }
    static List<SourceFiles.FileEntry> files(SourceFiles source,Group g,SyncRunner.Cancel cancel)throws Exception {
        return g.kind().equals("root")?source.rootFiles():source.files(g.doc(),cancel);
    }
}
