package local.shelf.sync;

import java.util.Locale;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.function.LongSupplier;

/** Anonymous counters for this run only; durations use a monotonic clock. */
final class TransferStats {
    private final LongSupplier clock;private final long start;
    private int activeUploads;
    private long scan,hash,upload,uploadStarted,requests,requestCount,bytes;
    private long batchCount,batchFiles;
    private long sourceOpen,sourceRead,sourceSHA,sourceClose,sourceFiles,sourceBytes,prepare;
    TransferStats(){this(System::nanoTime);}
    TransferStats(LongSupplier clock){this.clock=clock;start=clock.getAsLong();}
    synchronized void source(FileRead.Metrics m){hash+=m.total();sourceOpen+=m.open();sourceRead+=m.read();sourceSHA+=m.hash();sourceClose+=m.close();sourceFiles++;sourceBytes+=m.bytes();}
    synchronized void prepared(long began){prepare+=clock.getAsLong()-began;}
    synchronized void batch(int count){batchCount++;batchFiles+=count;}
    synchronized void scan(long began){scan+=clock.getAsLong()-began;}
    synchronized void hash(long began){hash+=clock.getAsLong()-began;}
    synchronized void beginUpload(long began){if(activeUploads++==0)uploadStarted=began;else uploadStarted=Math.min(uploadStarted,began);}
    synchronized void upload(long began){
        long now=clock.getAsLong();
        if(activeUploads>0){if(--activeUploads==0){upload+=now-uploadStarted;uploadStarted=0;}}
        else upload+=Math.max(0,now-began); // Legacy one-shot timing callers.
    }
    synchronized void request(long began){requests+=clock.getAsLong()-began;requestCount++;}
    synchronized void sent(int count){bytes+=count;}
    synchronized Map<String,Long> snapshot(){
        Map<String,Long> out=new LinkedHashMap<>();long now=clock.getAsLong();
        out.put("elapsedNs",Math.max(0,now-start));out.put("confirmedBytes",bytes);out.put("scanNs",scan);out.put("hashThreadNs",hash);
        out.put("uploadWallNs",upload+(activeUploads==0?0:now-uploadStarted));out.put("requestThreadNs",requests);out.put("requests",requestCount);
        out.put("batches",batchCount);out.put("batchFiles",batchFiles);out.put("prepareNs",prepare);out.put("sourceFiles",sourceFiles);
        out.put("sourceOpenNs",sourceOpen);out.put("sourceReadNs",sourceRead);out.put("sourceSHANs",sourceSHA);out.put("sourceCloseNs",sourceClose);return out;
    }
    synchronized String summary(){
        double elapsed=Math.max(1e-9,(clock.getAsLong()-start)/1e9);
        long uploadElapsed=upload+(activeUploads==0?0:clock.getAsLong()-uploadStarted);
        return String.format(Locale.CHINA,"本次确认上传 %.2f GB · 全流程平均 %.1f MB/s\n扫描 %.1fs · 读校验累计 %.1fs · 上传活动 %.1fs（重叠只计一次）\n请求 %d 次 · 请求累计 %.1fs（并发时不等于实际用时）",
            bytes/1e9,bytes/1e6/elapsed,scan/1e9,hash/1e9,uploadElapsed/1e9,requestCount,requests/1e9)+(batchCount==0?"":String.format(Locale.CHINA,"\n批量确认 %d 次 · %d 个文件",batchCount,batchFiles))+(sourceFiles==0?"":String.format(Locale.CHINA,"\n读取线程累计：打开 %.1fs / 读取 %.1fs / SHA %.1fs / 关闭 %.1fs\n准备批次墙钟 %.1fs（与上传重叠，不可相加）",sourceOpen/1e9,sourceRead/1e9,sourceSHA/1e9,sourceClose/1e9,prepare/1e9));
    }
}
