package local.shelf.sync;
import java.io.IOException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public class ParallelFilesTest {
    static void check(boolean value){if(!value)throw new AssertionError();}
    public static void main(String[] args)throws Exception{
        for(int lanes:new int[]{1,2,4}){
            AtomicInteger active=new AtomicInteger(),peak=new AtomicInteger(),closed=new AtomicInteger();AtomicIntegerArray visits=new AtomicIntegerArray(1000);
            ParallelFiles.run(1000,lanes,()->new ParallelFiles.Worker(){
                public void transfer(int i)throws Exception{int n=active.incrementAndGet();peak.accumulateAndGet(n,Math::max);try{visits.incrementAndGet(i);Thread.sleep(1);}finally{active.decrementAndGet();}}
                public void close(){closed.incrementAndGet();}
            });
            check(active.get()==0&&peak.get()<=lanes&&closed.get()>=lanes);for(int i=0;i<1000;i++)check(visits.get(i)==1);
        }
        AtomicInteger live=new AtomicInteger();CountDownLatch failure=new CountDownLatch(1);
        try{ParallelFiles.run(100,4,()->new ParallelFiles.Worker(){
            public void transfer(int i)throws Exception{live.incrementAndGet();try{if(i==0){failure.countDown();throw new IOException("synthetic failure");}failure.await();Thread.sleep(5000);}finally{live.decrementAndGet();}}
            public void close(){}
        });throw new AssertionError("failure swallowed");}catch(IOException expected){}
        check(live.get()==0);
        CountDownLatch entered=new CountDownLatch(1);AtomicBoolean cancelled=new AtomicBoolean();
        Thread caller=new Thread(()->{
            try{ParallelFiles.run(100,2,()->new ParallelFiles.Worker(){
                public void transfer(int i)throws Exception{live.incrementAndGet();try{entered.countDown();Thread.sleep(10000);}finally{live.decrementAndGet();}}
                public void close(){}
            });}catch(InterruptedException expected){cancelled.set(true);}catch(Exception e){throw new RuntimeException(e);}
        });caller.start();check(entered.await(2,TimeUnit.SECONDS));caller.interrupt();caller.join(3000);check(!caller.isAlive()&&cancelled.get()&&live.get()==0);
        AtomicInteger created=new AtomicInteger();ParallelFiles.run(0,4,()->{created.incrementAndGet();throw new AssertionError();});check(created.get()==0);
        try{ParallelFiles.run(1,3,()->null);throw new AssertionError();}catch(IllegalArgumentException expected){}
        try{ParallelFiles.run(20,4,()->{throw new IOException("constructor failed");});throw new AssertionError();}catch(IOException expected){}
        TransferStats stats=new TransferStats();stats.sent(1024);long t=System.nanoTime();stats.scan(t);stats.hash(t);stats.upload(t);stats.request(t);check(stats.summary().contains("请求 1 次"));
        System.out.println("ParallelFiles: 1/2/4 lanes, 3000 exactly-once jobs, failure/cancellation drain, empty, limits, factory failure, metrics PASS");
    }
}
