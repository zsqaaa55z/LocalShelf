package local.shelf.sync;

import java.util.*;

public final class ChangeSummaryTest {
    static int checks;
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);checks++;}
    static IncrementalChanges.Row row(int id,long time,String stamp){return new IncrementalChanges.Row(""+id,"dir-"+id,"Book "+id,time,true,stamp);}
    static List<IncrementalChanges.Row> books(int count){List<IncrementalChanges.Row> out=new ArrayList<>();for(int i=0;i<count;i++)out.add(row(i+1,20000-i,"same"));return out;}
    static List<IncrementalChanges.Row> rotateTimes(List<IncrementalChanges.Row> source){List<IncrementalChanges.Row> out=new ArrayList<>();for(int i=0;i<source.size();i++){var row=source.get(i);out.add(row(Integer.parseInt(row.id()),20000-i,row.contentStamp()));}return out;}
    static void rejected(Runnable work){try{work.run();throw new AssertionError("must reject invalid counts/IDs");}catch(IllegalArgumentException expected){checks++;}}
    static int independentLcs(List<IncrementalChanges.Row> a,List<IncrementalChanges.Row> b){int[][] lengths=new int[a.size()+1][b.size()+1];for(int i=1;i<=a.size();i++)for(int j=1;j<=b.size();j++)lengths[i][j]=a.get(i-1).id().equals(b.get(j-1).id())?lengths[i-1][j-1]+1:Math.max(lengths[i-1][j],lengths[i][j-1]);return lengths[a.size()][b.size()];}
    static void permutations(List<IncrementalChanges.Row> initial,List<IncrementalChanges.Row> current,int index){
        if(index==current.size()){var result=ChangeSummary.analyze(initial,current);check(result.orderMoves()==initial.size()-independentLcs(initial,current),"minimum move count matches independent LCS");return;}
        for(int i=index;i<current.size();i++){Collections.swap(current,index,i);permutations(initial,current,index+1);Collections.swap(current,index,i);}
    }
    public static void main(String[] args){
        var old=books(10073);long began=System.nanoTime();var same=ChangeSummary.analyze(old,old).counts();
        check(same.added()==0&&same.contentChecks()==0&&same.orderMoves()==0,"unchanged library");
        var insert=new ArrayList<IncrementalChanges.Row>();for(int i=0;i<100;i++)insert.add(row(30000+i,50000-i,"new"));insert.addAll(old);
        var summary=ChangeSummary.analyze(old,insert);check(summary.counts().added()==100&&summary.orderMoves()==0&&summary.contentChecks().isEmpty(),"100 inserts do not mark 10073 old books moved or changed");
        var move=new ArrayList<>(old);move.add(0,move.remove(move.size()-1));summary=ChangeSummary.analyze(old,rotateTimes(move));
        check(summary.orderMoves()==1&&summary.contentChecks().isEmpty(),"EhDB TIME rotation is one minimum move, not 10073 edits");
        check(IncrementalChanges.affected(old,rotateTimes(move)).size()==2,"existing safety-boundary scan remains unchanged");
        move=new ArrayList<>(old);move.add(move.remove(0));check(ChangeSummary.analyze(old,rotateTimes(move)).orderMoves()==1,"front to back");
        check(ChangeSummary.analyze(old,old.subList(100,old.size())).orderMoves()==0,"deletions do not inflate moves");
        check(ChangeSummary.analyze(old,old.subList(100,old.size())).removed()==100,"removed entries counted separately");
        var small=books(50);var sample=new ArrayList<IncrementalChanges.Row>();for(int i=0;i<12;i++)sample.add(row(30000+i,50000-i,"new"));
        var reordered=new ArrayList<>(small.subList(42,50));reordered.addAll(small.subList(0,42));reordered=new ArrayList<>(rotateTimes(reordered));
        for(int i=10;i<13;i++){var item=reordered.get(i);reordered.set(i,row(Integer.parseInt(item.id()),item.time(),"updated"));}sample.addAll(reordered);
        summary=ChangeSummary.analyze(small,sample);check(summary.added().size()==12&&summary.contentChecks().size()==3&&summary.orderMoves()==8,"requested 12 new / 3 checks / 8 minimum moves example");
        var extra=summary.withDirectorySignals(Set.of("1","30000","not-present"));check(extra.contentChecks().size()==4,"directory signal augments checks but not new/absent IDs");
        check(summary.contentChecks().size()==3,"analysis immutable");
        var bumped=new ArrayList<>(small);bumped.set(0,row(1,999999,"same"));check(ChangeSummary.analyze(small,bumped).contentChecks().equals(Set.of("1")),"redownload time bump remains content hint");
        check(ChangeSummary.analyze(List.of(row(1,10,null)),List.of(row(1,10,"first-stamp"))).contentChecks().isEmpty(),"legacy baseline does not force full scan");
        var unknown=ChangeSummary.analyze(null,small).counts();check(!unknown.baselineKnown()&&unknown.added()==0&&unknown.preview().contains("暂不能判断"),"unknown baseline not called all new");
        var empty=ChangeSummary.analyze(List.of(),small).counts();check(empty.baselineKnown()&&empty.added()==50,"known empty baseline distinguishes new books");
        check(summary.counts().preview().contains("待 NAS 确认"),"preview never claims actual receipt reuse");
        check(summary.counts().plan(20,4,2,true,false).contains("NAS 本轮确认复用 20 本"),"live receipt count");
        check(summary.counts().plan(0,0,0,false,false).contains("未启用"),"full scan does not claim reuse");
        check(summary.counts().plan(0,0,0,true,true).contains("已发布"),"published summary retains original changes");
        rejected(()->new ChangeSummary.Counts(true,2,2,1,0,0));
        rejected(()->new ChangeSummary.Counts(true,2,1,0,2,0));
        rejected(()->same.plan(10074,0,0,true,false));
        rejected(()->ChangeSummary.analyze(List.of(small.get(0),small.get(0)),small));
        rejected(()->ChangeSummary.analyze(small,List.of(small.get(0),small.get(0))));
        var seven=books(7);permutations(seven,new ArrayList<>(seven),0);
        var random=new Random(410);for(int i=0;i<300;i++){var changed=new ArrayList<>(seven);Collections.shuffle(changed,random);changed.removeIf(v->random.nextBoolean());changed.add(row(99,99999,"new"));var result=ChangeSummary.analyze(seven,changed);int common=changed.size()-1;check(result.orderMoves()==common-independentLcs(seven,changed),"mixed insert/remove/reorder property");}
        System.out.println("ChangeSummary: "+checks+" assertions passed; "+((System.nanoTime()-began)/1_000_000)+" ms; metadata only, no page I/O");
    }
}
