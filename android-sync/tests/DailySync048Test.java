package local.shelf.sync;

public final class DailySync048Test {
    static int checks;
    static void check(boolean yes){if(!yes)throw new AssertionError("daily sync check "+checks);checks++;}
    public static void main(String[] args){
        for(int mask=0;mask<16;mask++)check(DailySyncPolicy.canAdopt((mask&1)!=0,(mask&2)!=0,(mask&4)!=0,(mask&8)!=0)==(mask==0));
        check(DailySyncPolicy.action(false,false,true).equals("同步新增与更新"));
        check(DailySyncPolicy.action(false,false,false).equals("检查变化并同步"));
        check(DailySyncPolicy.action(true,false,true).equals("继续上次同步"));
        check(DailySyncPolicy.action(true,true,true).contains("完整校验"));
        String details="已完成新增同步\n扫描 2 本 · 复用 10000 本\n诊断细节\n2 本源目录缺失，保留列表位置";
        check(!DailySyncPolicy.compact("complete",details).contains("诊断细节"));
        check(DailySyncPolicy.compact("complete",details).contains("缺失"));
        for(String state:new String[]{"failed","paused","waiting_system"})check(DailySyncPolicy.compact(state,details).equals(details));
        check(DailySyncPolicy.compact("complete",null).contains(".db"));
        check(DailySyncPolicy.compact("complete","").contains("新增"));
        System.out.println("DailySync048: "+checks+" checks passed");
    }
}
