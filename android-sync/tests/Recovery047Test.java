package local.shelf.sync;

import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import javax.net.ssl.*;

public final class Recovery047Test {
    static int checks;
    static synchronized void check(boolean condition,String label){checks++;if(!condition)throw new AssertionError(label);}
    interface Task{void run()throws Exception;}
    static Exception rejects(Task task)throws Exception {try{task.run();}catch(Exception e){checks++;return e;}throw new AssertionError("expected failure");}
    static class FakeControl implements RecoveryLoop.Control {
        final List<Long> delays=new ArrayList<>();long slept;int recoveries,checksCount;boolean cancelled;
        public void check()throws Exception{checksCount++;if(cancelled)throw new InterruptedIOException("pause");}
        public void waiting(int attempt,long delay){delays.add(delay);}
        public void sleep(long millis){Recovery047Test.check(millis<=250,"cancellation slice bound");slept+=millis;}
        public void recovered(){recoveries++;}
    }
    static void policy() {
        for(int status:new int[]{408,429,500,502,503,504})check(RecoveryPolicy.temporaryHttp(status,"temporary"),"temporary HTTP");
        for(int status:new int[]{200,301,400,401,403,404,409,422,501,505,507})check(!RecoveryPolicy.temporaryHttp(status,""),"no blind retry");
        for(String fatal:new String[]{"hash_mismatch_source_may_be_changing","storage_full","nas_space_insufficient","inventory_not_complete","order_not_verified","unauthorized","existing_directory_changed","backup_omits_existing_books_use_complete_backup"})
            for(int status:new int[]{400,500,503,507})check(!RecoveryPolicy.temporaryHttp(status,fatal),"fatal semantic beats HTTP");
        for(IOException error:new IOException[]{new SSLHandshakeException("pin"),new SSLPeerUnverifiedException("cert"),new SSLException("TLS"),new ProtocolException("oversized"),new FileNotFoundException("source"),new InterruptedIOException("pause"),new IOException(new SSLHandshakeException("nested pin"))})
            check(!RecoveryPolicy.temporaryTransport(error),"TLS/protocol/cancel fail closed");
        for(IOException error:new IOException[]{new SocketException(),new SocketTimeoutException(),new UnknownHostException(),new EOFException(),new IOException("stream disconnected")})
            check(RecoveryPolicy.temporaryTransport(error),"transport boundary transient");
        check(RecoveryPolicy.cancellation(new IOException("wrapped",new InterruptedIOException())),"system cancellation chain recognised");
        check(!RecoveryPolicy.cancellation(new IOException("source changed")),"concurrent system stop must not disguise source failure");
        for(int reason=0;reason<=99;reason++){
            check(!RecoveryPolicy.reschedule(false,true,reason),"manual pause final");
            check(!RecoveryPolicy.reschedule(true,false,reason),"mode off final");
            check(RecoveryPolicy.reschedule(true,true,reason)==(reason!=1&&reason!=13),"system retry only when requested");
            check(!RecoveryPolicy.stopReason(reason).isBlank(),"stop diagnostic includes unknown future reason");
        }
    }
    static void loops()throws Exception {
        byte[] retained=new byte[16*1024*1024];FakeControl c=new FakeControl();AtomicInteger calls=new AtomicInteger();
        Object result=RecoveryLoop.run(true,()->{check(retained.length==16*1024*1024,"same bounded payload");if(calls.incrementAndGet()<4)throw new RecoveryLoop.Temporary("synthetic",null);return retained;},c);
        check(result==retained&&calls.get()==4,"request reuses exact body");
        check(c.delays.equals(List.of(15000L,30000L,60000L))&&c.slept==105000,"exponential delays without real waiting");
        check(c.recoveries==1,"waiting indicator cleared");
        FakeControl exhausted=new FakeControl();AtomicInteger tries=new AtomicInteger();
        Exception failure=rejects(()->RecoveryLoop.run(true,()->{tries.incrementAndGet();throw new RecoveryLoop.Temporary("offline",null);},exhausted));
        check(failure instanceof RecoveryLoop.Exhausted&&tries.get()==8,"bounded per-request attempts, then scheduler");
        check(exhausted.slept==1_065_000L&&Collections.max(exhausted.delays)==300000,"17m45 simulated backoff capped at 5m");
        check(RecoveryPolicy.exhausted(new IOException("file wrapper",failure)),"cause preserved through pipeline");
        FakeControl off=new FakeControl();rejects(()->RecoveryLoop.run(false,()->{throw new RecoveryLoop.Temporary("offline",null);},off));check(off.slept==0,"off never waits");
        FakeControl fatal=new FakeControl();Exception pin=new SSLHandshakeException("wrong pin");
        check(rejects(()->RecoveryLoop.run(true,()->{throw pin;},fatal))==pin&&fatal.slept==0,"fatal never becomes temporary");
        FakeControl pause=new FakeControl(){public void sleep(long millis){super.sleep(millis);cancelled=true;}};
        rejects(()->RecoveryLoop.run(true,()->{throw new RecoveryLoop.Temporary("offline",null);},pause));
        check(pause.slept==250&&pause.recoveries==1,"pause exits at next cancellation slice");
        FakeControl precancel=new FakeControl();precancel.cancelled=true;AtomicInteger writes=new AtomicInteger();
        rejects(()->RecoveryLoop.run(true,()->writes.incrementAndGet(),precancel));check(writes.get()==0,"pre-cancel cannot upload");
        FakeControl after=new FakeControl();rejects(()->RecoveryLoop.run(true,()->{after.cancelled=true;return 1;},after));
        check(after.recoveries==1,"post-response pause checked before acknowledgement");
    }
    static void monitor()throws Exception {
        AtomicLong clock=new AtomicLong();TransferMonitor m=new TransferMonitor(clock::get);
        m.stage("私人标题 credential-secret 阶段：较大文件校验");check(m.summary().contains("读取 / 校验")&&!m.summary().contains("私人")&&!m.summary().contains("secret"),"whitelist notification, no private content");
        clock.set(3_600_000);check(m.confirmedBytes()==0&&m.summary().contains("尚无上传确认"),"clock never fabricates progress");
        m.acknowledged(1024);clock.addAndGet(5000);check(m.summary().contains("5 秒"),"actual last acknowledgement age");
        Object one=new Object(),two=new Object();m.waiting(one,30000);m.waiting(two,15000);check(m.summary().contains("2 路")&&m.summary().contains("15 秒"),"parallel waiting bounded by owners");
        m.recovered(two);check(m.summary().contains("1 路"),"one recovery cannot erase another wait");
        m.acknowledged(1024);m.complete();m.position(100,10000);m.estimate(10000);
        check(m.confirmedBytes()==2048&&m.estimatedBytes()==-1,"partial scan is not a whole-task estimate");
        m.expected(1000000);check(m.estimatedBytes()==1000000,"matching preflight used only as estimate");
        m.recovered(one);check(m.waiting.isEmpty(),"connections released");
        check(m.summary().contains("100 / 10000")&&m.summary().contains("完成 1 组"),"catalog position is not completed count");
        for(int n=0;n<10000;n++){m.waiting(one,300000);m.recovered(one);}check(m.waiting.isEmpty(),"no accumulation per file");
    }
    static void budget(){
        check(TaskBudget.remaining(100,37)==63,"restart does not reset 100-book budget");
        check(TaskBudget.exhausted(100,100)&&TaskBudget.remaining(100,100)==0,"finite exhausted not unlimited");
        check(TaskBudget.exhausted(100,101),"overshoot defensive");
        check(!TaskBudget.exhausted(0,100000)&&TaskBudget.remaining(0,100000)==0,"explicit unlimited");
        for(int used=0;used<=100;used++)check(TaskBudget.remaining(100,used)+used==100,"every durable checkpoint preserves budget");
        check(PayloadEstimate.from(new long[]{10,20,30},1,new long[]{100,200},0,2)==50,"finite task estimate only remaining books");
        check(PayloadEstimate.from(new long[]{10,20,30},1,new long[]{100,200},1,0)==250,"resume estimate includes remaining archive");
        check(PayloadEstimate.from(new long[]{Long.MAX_VALUE,1},0,new long[]{},0,0)==-1,"overflow means unknown");
        check(PayloadEstimate.from(new long[]{-1},0,new long[]{},0,0)==-1,"invalid means unknown");
    }
    static void twoLanesAndPause()throws Exception{
        CountDownLatch waiting=new CountDownLatch(2),release=new CountDownLatch(1);AtomicBoolean stop=new AtomicBoolean();AtomicInteger exits=new AtomicInteger();
        Thread[] threads=new Thread[2];
        for(int i=0;i<2;i++){threads[i]=new Thread(()->{
            try{RecoveryLoop.run(true,()->{throw new RecoveryLoop.Temporary("offline",null);},new RecoveryLoop.Control(){
                public void check()throws Exception{if(stop.get())throw new InterruptedIOException();}
                public void waiting(int attempt,long delay){waiting.countDown();}
                public void sleep(long millis)throws Exception{release.await();}
                public void recovered(){exits.incrementAndGet();}
            });throw new AssertionError("not cancelled");}catch(Exception expected){}
        });threads[i].start();}
        check(waiting.await(3,TimeUnit.SECONDS),"both network lanes can independently wait");stop.set(true);release.countDown();
        for(Thread thread:threads){thread.join(3000);check(!thread.isAlive(),"all recovery lanes drain");}
        check(exits.get()==2,"both wait indicators cleaned");
    }
    public static void main(String[] args)throws Exception{policy();loops();monitor();budget();twoLanesAndPause();System.out.println("Recovery047: "+checks+" checks passed; bounded retry, TLS/storage fail-closed, pause, two lanes, notification evidence and finite budget.");}
}
