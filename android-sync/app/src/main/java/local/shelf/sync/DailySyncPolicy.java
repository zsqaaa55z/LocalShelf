package local.shelf.sync;

/** One-time UI defaults, never a reset of a running or resumable transfer. */
final class DailySyncPolicy {
    static boolean canAdopt(boolean adopted,boolean busy,boolean pending,boolean cyclePending){
        return !adopted&&!busy&&!pending&&!cyclePending;
    }
    static String action(boolean cyclePending,boolean full,boolean newOnly){
        if(cyclePending)return full?"继续未完成的完整校验":"继续上次同步";
        return newOnly?"同步新增与更新":"检查变化并同步";
    }
    static String compact(String runState,String detail){
        // Never hide the reason for a failure, pause or retry behind the disclosure.
        if("failed".equals(runState)||"paused".equals(runState)||"waiting_system".equals(runState))return detail;
        if(detail==null||detail.isBlank())return "导入最新 .db，然后同步新增漫画。";
        String[] lines=detail.split("\\n");StringBuilder out=new StringBuilder();
        for(int i=0;i<Math.min(2,lines.length);i++){if(i>0)out.append('\n');out.append(lines[i]);}
        for(int i=2;i<lines.length;i++)if(lines[i].contains("缺失")||lines[i].contains("待核对"))out.append('\n').append(lines[i]);
        return out.toString();
    }
}
