package local.shelf.sync;

import java.io.*;
import java.nio.channels.ClosedByInterruptException;
import java.util.concurrent.atomic.*;

/** Only retries OPEN failures, never a stream that has already been returned. */
final class ReadFallback {
    interface Opener {InputStream open()throws IOException;}
    private final String unavailable;
    private final AtomicBoolean disabled=new AtomicBoolean();
    final AtomicLong directOpens=new AtomicLong(),safOpens=new AtomicLong(),fallbacks=new AtomicLong();
    ReadFallback(boolean preferred,boolean permission,boolean supported){
        unavailable=!preferred?"直读已关闭":!supported?"此目录不支持直读":!permission?"直读尚未授权":"";
    }
    InputStream open(Opener direct,Opener saf)throws IOException {
        interrupted();
        if(unavailable.isEmpty()&&!disabled.get()){
            try{InputStream in=nonNull(direct.open());directOpens.incrementAndGet();return in;}
            catch(DirectReadScope.UnsafePathException|DirectReadScope.SourceChangedException|InterruptedIOException|ClosedByInterruptException e){throw e;}
            catch(IOException|SecurityException|UnsupportedOperationException e){
                interrupted();disabled.set(true);fallbacks.incrementAndGet();
            }
        }
        interrupted();InputStream in=nonNull(saf.open());safOpens.incrementAndGet();return in;
    }
    private static InputStream nonNull(InputStream in)throws IOException{if(in==null)throw new IOException("源文件不可读");return in;}
    private static void interrupted()throws InterruptedIOException{if(Thread.currentThread().isInterrupted())throw new InterruptedIOException("读取已暂停");}
    String description(){
        String mode=!unavailable.isEmpty()?unavailable+"，使用原方式":disabled.get()?"直读打开失败，本次任务已回退原方式":"优先直读 · 源文件只读";
        return mode+"\n打开次数：直读 "+directOpens.get()+" / 原方式 "+safOpens.get()+(fallbacks.get()>0?" / 回退 "+fallbacks.get():"");
    }
}
