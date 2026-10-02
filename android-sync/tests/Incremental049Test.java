package local.shelf.sync;

import java.util.*;

public final class Incremental049Test {
    static int checks;
    static void check(boolean yes){if(!yes)throw new AssertionError("incremental check "+checks);checks++;}
    static IncrementalChanges.Row row(String id,long time,String stamp){return new IncrementalChanges.Row(id,"folder-"+id,"book "+id,time,true,stamp);}
    public static void main(String[] args){
        List<IncrementalChanges.Row> old=new ArrayList<>();for(int i=0;i<10073;i++)old.add(row(Integer.toString(i+1),20000-i,"same"));
        long begin=System.nanoTime();Set<String> unchanged=IncrementalChanges.affected(old,old);check(unchanged.isEmpty());
        List<IncrementalChanges.Row> added=new ArrayList<>();for(int i=0;i<100;i++)added.add(row(Integer.toString(20000+i),40000-i,"new"));added.addAll(old);
        Set<String> result=IncrementalChanges.affected(old,added);check(result.size()==100);for(var r:old)check(!result.contains(r.id()));
        List<IncrementalChanges.Row> moved=new ArrayList<>(old);var last=moved.remove(moved.size()-1);moved.add(0,last);
        // EhDB may rotate every TIME in the moved interval. This is not 10,073 content changes.
        List<IncrementalChanges.Row> rotated=new ArrayList<>();for(int i=0;i<moved.size();i++)rotated.add(row(moved.get(i).id(),20000-i,"same"));
        result=IncrementalChanges.affected(old,rotated);check(result.size()==2);check(result.contains(last.id()));
        List<IncrementalChanges.Row> changed=new ArrayList<>(old);changed.set(100,row("101",19900,"pages-changed"));check(IncrementalChanges.affected(old,changed).equals(Set.of("101")));
        changed=new ArrayList<>(old);changed.set(0,row("1",90000,"same"));check(IncrementalChanges.affected(old,changed).equals(Set.of("1")));
        changed=new ArrayList<>(old);changed.set(100,new IncrementalChanges.Row("101","folder-101","book 101",19900,false,"same"));check(IncrementalChanges.affected(old,changed).contains("101"));
        check(IncrementalChanges.affected(List.of(row("1",1,null)),List.of(row("1",1,"new baseline"))).isEmpty());
        check(IncrementalChanges.directoryChanged(200L,100L,100L));check(!IncrementalChanges.directoryChanged(100L,100L,50L));check(IncrementalChanges.directoryChanged(200L,null,100L));check(!IncrementalChanges.directoryChanged(50L,null,100L));check(!IncrementalChanges.directoryChanged(0L,null,100L));
        System.out.println("Incremental049: "+checks+" checks passed; 10,073-book scenarios "+((System.nanoTime()-begin)/1_000_000)+" ms; zero page I/O (pure metadata policy)");
    }
}
