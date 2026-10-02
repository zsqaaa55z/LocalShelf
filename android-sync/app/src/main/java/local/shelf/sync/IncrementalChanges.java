package local.shelf.sync;

import java.util.*;

/** O(n) metadata comparison; never opens page files or treats rank shifts as edits. */
final class IncrementalChanges {
    record Row(String id,String directory,String title,long time,boolean complete,String contentStamp) {}
    static Set<String> affected(List<Row> previous,List<Row> current){
        Map<String,Row> old=new HashMap<>();long newest=Long.MIN_VALUE;
        for(Row row:previous){old.put(row.id(),row);newest=Math.max(newest,row.time());}
        Set<String> common=new HashSet<>();for(Row row:current)if(old.containsKey(row.id()))common.add(row.id());
        // Compare neighbours among common IDs. Adding 100 books to the front
        // does not make all 10,000 older books "changed". A move checks only
        // the moved boundary and its neighbours, using cached file hashes.
        Map<String,String> predecessor=new HashMap<>();String before="";
        for(Row row:previous)if(common.contains(row.id())){predecessor.put(row.id(),before);before=row.id();}
        Set<String> result=new HashSet<>();before="";
        for(Row row:current){
            Row prior=old.get(row.id());
            if(prior==null||contentCheck(prior,row,newest))result.add(row.id());
            if(common.contains(row.id())){
                if(!Objects.equals(predecessor.get(row.id()),before))result.add(row.id());
                before=row.id();
            }
        }
        return result;
    }
    // Keep content hints separate from the extra neighbours checked after a move.
    static boolean contentCheck(Row prior,Row row,long newest){
        return !row.complete()||!prior.complete()||!row.directory().equals(prior.directory())||!row.title().equals(prior.title())
                ||prior.contentStamp()!=null&&!Objects.equals(prior.contentStamp(),row.contentStamp())
                ||row.time()!=prior.time()&&row.time()>newest;
    }
    static boolean directoryChanged(long current,Long previous,long lastSuccess){
        // Directory mtime is an extra signal, not a proof of file equality.
        return current>0&&(previous!=null?previous!=current:lastSuccess>0&&current>lastSuccess);
    }
}
