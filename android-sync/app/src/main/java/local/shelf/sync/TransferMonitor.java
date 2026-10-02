package local.shelf.sync;

import java.util.*;
import java.util.function.LongSupplier;

/** Contains no title, path, address, ID or credential. Bounded by active connections. */
final class TransferMonitor {
    final LongSupplier clock;
    final Map<Object,Long> waiting=new IdentityHashMap<>();
    String phase="准备同步";long bytes,lastAck=-1,knownBytes,expectedBytes=-1;int completed,position,total;
    TransferMonitor(){this(()->System.nanoTime()/1_000_000);}
    TransferMonitor(LongSupplier clock){this.clock=clock;}
    synchronized void stage(String text){
        if(text.contains("阶段：并行读取"))phase="读取 / 批量上传";
        else if(text.contains("阶段：批量上传")||text.contains("阶段：上传"))phase="上传文件";
        else if(text.contains("阶段：校验")||text.contains("阶段：较大文件校验"))phase="读取 / 校验";
        else if(text.contains("阶段：扫描"))phase="扫描目录";
        else if(text.contains("阶段：完成检查"))phase="核对完成状态";
        else if(text.contains("下载顺序"))phase="准备下载清单";
        else if(text.contains("阶段：迁移预检"))phase="迁移预检";
    }
    synchronized void position(int current,int count){position=current;total=count;}
    synchronized void acknowledged(long count){bytes=Math.addExact(bytes,count);lastAck=clock.getAsLong();}
    synchronized void complete(){completed++;}
    synchronized void estimate(long count){knownBytes=Math.addExact(knownBytes,Math.max(0,count));}
    synchronized void expected(long count){expectedBytes=count;}
    synchronized void waiting(Object owner,long delay){waiting.put(owner,clock.getAsLong()+delay);}
    synchronized void recovered(Object owner){waiting.remove(owner);}
    synchronized long estimatedBytes(){return expectedBytes<0?-1:Math.max(expectedBytes,Math.max(bytes,knownBytes));}
    synchronized long confirmedBytes(){return bytes;}
    synchronized String summary(){
        String first=waiting.isEmpty()?phase:waiting.size()+" 路连接等待重试";
        if(!waiting.isEmpty()){
            long next=Collections.min(waiting.values());
            first+=" · 约 "+Math.max(0,(next-clock.getAsLong()+999)/1000)+" 秒后重试";
        }
        String age=lastAck<0?"尚无上传确认":"距上次上传确认 "+Math.max(0,(clock.getAsLong()-lastAck)/1000)+" 秒";
        return first+(total>0?" · 主清单位置 "+position+" / "+total:"")+
            String.format(Locale.CHINA,"\n本次核验完成 %d 组 · 确认上传 %.2f GB\n%s（校验时可暂无新确认）",completed,bytes/1e9,age);
    }
}
