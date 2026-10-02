package local.shelf.sync;

import java.util.*;

/** Display-only metadata analysis. No Android, file, network, or transfer dependencies. */
final class ChangeSummary {
    record Analysis(boolean baselineKnown,Set<String> current,Set<String> added,Set<String> contentChecks,int orderMoves,int removed){
        Analysis {
            current=Set.copyOf(current);added=Set.copyOf(added);contentChecks=Set.copyOf(contentChecks);
        }
        Analysis withDirectorySignals(Set<String> signals){
            if(!baselineKnown)return this;
            Set<String> checks=new HashSet<>(contentChecks);
            for(String id:signals)if(current.contains(id)&&!added.contains(id))checks.add(id);
            return new Analysis(true,current,added,checks,orderMoves,removed);
        }
        Counts counts(){return new Counts(baselineKnown,current.size(),added.size(),contentChecks.size(),orderMoves,removed);}
    }
    record Counts(boolean baselineKnown,int total,int added,int contentChecks,int orderMoves,int removed){
        Counts {
            if(total<0||total>20000||added<0||contentChecks<0||orderMoves<0||removed<0||removed>20000
                    ||added+contentChecks>total||orderMoves>total-added)throw new IllegalArgumentException("Invalid summary counts");
        }
        String headline(){
            if(!baselineKnown)return "当前清单 "+total+" 本；尚无上次成功同步基线，暂不能判断新增、内容或排序变化。";
            String text="新增 "+added+" 本 · 内容待检查 "+contentChecks+" 本\n"+(orderMoves==0?"旧漫画相对顺序未变化":"顺序调整至少 "+orderMoves+" 本");
            if(removed>0)text+="\n清单移出 "+removed+" 本（不删除 NAS 原文件）";
            return text;
        }
        String preview(){
            return "清单预估 · 尚未同步\n"+headline()+(baselineKnown?"\n其余 "+(total-added-contentChecks)+" 本未见内容变化，复用结果待 NAS 确认。":"");
        }
        String plan(int reused,int previouslyProcessed,int missing,boolean reuseEnabled,boolean published){
            if(reused<0||previouslyProcessed<0||missing<0||reused+previouslyProcessed>total||missing>total)throw new IllegalArgumentException("Invalid run counts");
            String text=(published?"本次清单已发布":"本次同步对照")+"\n"+headline();
            text+=reuseEnabled?"\nNAS 本轮确认复用 "+reused+" 本已有校验结果。":"\n本轮未启用旧漫画快速复用，按所选校验模式执行。";
            if(previouslyProcessed>0)text+="\n本轮开始前已有 "+previouslyProcessed+" 本完成处理，不重复计入复用数量。";
            if(missing>0)text+="\n源目录缺失 "+missing+" 本，已有 NAS 内容仍保留。";
            return text;
        }
    }
    static Analysis analyze(List<IncrementalChanges.Row> previous,List<IncrementalChanges.Row> current){
        if(current.size()>20000||previous!=null&&previous.size()>20000)throw new IllegalArgumentException("Summary too large");
        Set<String> ids=new HashSet<>();for(var row:current)if(!ids.add(row.id()))throw new IllegalArgumentException("Duplicate current ID");
        if(previous==null)return new Analysis(false,ids,Set.of(),Set.of(),0,0);
        Map<String,IncrementalChanges.Row> old=new HashMap<>();Map<String,Integer> positions=new HashMap<>();long newest=Long.MIN_VALUE;
        for(int i=0;i<previous.size();i++){var row=previous.get(i);if(old.put(row.id(),row)!=null)throw new IllegalArgumentException("Duplicate previous ID");positions.put(row.id(),i);newest=Math.max(newest,row.time());}
        Set<String> added=new HashSet<>(),checks=new HashSet<>();int common=0,length=0;int[] tails=new int[current.size()];
        for(var row:current){
            var prior=old.get(row.id());
            if(prior==null){added.add(row.id());continue;}
            if(IncrementalChanges.contentCheck(prior,row,newest))checks.add(row.id());
            int position=positions.get(row.id()),low=0,high=length;
            // Common IDs only: additions/deletions cannot inflate the move count.
            // N - LIS gives a minimum number of moves, not the user's click history.
            while(low<high){int middle=(low+high)>>>1;if(tails[middle]<position)low=middle+1;else high=middle;}
            tails[low]=position;if(low==length)length++;common++;
        }
        return new Analysis(true,ids,added,checks,common-length,old.size()-common);
    }
    static final String HELP="与本机上次成功同步的完整清单对照，不与上一次导入比较。\n\n新增：之前没有的漫画 ID；新版本使用新 ID 时也算新增。\n\n内容待检查：下载状态、标题、目录或内容字段出现变化信号，不表示已确认图片变化；同步时会结合原本就要读取的顶层目录时间更新数量，不为摘要额外扫描图片。\n\n顺序调整：只比较两份清单共有漫画的相对顺序，显示实现新顺序至少需要移动的本数，不是点击次数；新增或移出造成的整体位移不计入。同一本可以同时有内容和顺序变化，两项不要相加。\n\n未见内容变化不保证一定复用；少量排序边界、没有有效回执或 NAS 未确认的漫画仍会检查。连接后显示本轮 NAS 实际确认的复用数；续传前已处理的部分单独列出。\n\n清单移出不会删除 NAS 原文件。这里只统计主清单，不包括独立归档，也不是全库完整性审计。";
}
