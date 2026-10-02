package local.shelf.sync;

import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Deterministic latch-based tests of the actual production Java schedulers. */
public final class Pipeline046Test {
    static int checks;
    static synchronized void check(boolean yes,String label){checks++;if(!yes)throw new AssertionError(label);}
    interface Task {void run()throws Exception;}
    static void reject(Task task)throws Exception{try{task.run();}catch(Exception expected){checks++;return;}throw new AssertionError("expected failure");}
    static void await(CountDownLatch latch)throws Exception{check(latch.await(4,TimeUnit.SECONDS),"latch deadline");}
    static void join(Thread thread)throws Exception{thread.join(5000);check(!thread.isAlive(),"thread drained");}
    static List<Integer> items(int count){List<Integer> out=new ArrayList<>();for(int i=0;i<count;i++)out.add(i);return out;}
    static String sha(byte[] bytes,int offset,int size)throws Exception{var hash=MessageDigest.getInstance("SHA-256");hash.update(bytes,offset,size);return HexFormat.of().formatHex(hash.digest());}
    static ReadPipeline.Factory<Integer> reader(){return ()->new ReadPipeline.Worker<>(){
        public String read(Integer item,byte[] bytes,int offset,ReadPipeline.Check stop)throws Exception{stop.check();Arrays.fill(bytes,offset,offset+32,(byte)(int)item);return sha(bytes,offset,32);}
        public void cancel(){}public void close(){}
    };}
    static void dualBuffersAndReceiptOwner()throws Exception{
        var buffers=new ReadPipeline.Buffers();Thread owner=Thread.currentThread();
        CountDownLatch both=new CountDownLatch(2),secondAcknowledged=new CountDownLatch(1);
        List<Integer> acknowledgements=new ArrayList<>();AtomicInteger active=new AtomicInteger(),peak=new AtomicInteger();Set<byte[]> used=ConcurrentHashMap.newKeySet();
        Map<byte[],Boolean> inUse=new ConcurrentHashMap<>();
        new ReadPipeline<>(items(257),4,i->32,reader(),new ReadPipeline.Sink<Integer>(){
            public void send(ReadPipeline.Frame<Integer> frame,ReadPipeline.Check stopped)throws Exception{
                int first=frame.items.get(0);used.add(frame.bytes);check(inUse.putIfAbsent(frame.bytes,true)==null,"exclusive send buffer");
                peak.accumulateAndGet(active.incrementAndGet(),Math::max);
                try{
                    if(first<128){both.countDown();await(both);if(first==0)await(secondAcknowledged);}
                    for(int i=0;i<frame.items.size();i++){stopped.check();check(frame.hashes[i].equals(sha(frame.bytes,frame.offsets[i],32)),"buffer not overwritten");}
                }finally{active.decrementAndGet();inUse.remove(frame.bytes);}
            }
            public void acknowledge(ReadPipeline.Frame<Integer> frame){
                check(Thread.currentThread()==owner,"receipt/cache is caller-owned");check(!inUse.containsKey(frame.bytes),"send exited before reuse");
                acknowledgements.addAll(frame.items);if(frame.items.get(0)==64)secondAcknowledged.countDown();
            }
            public void abort(){secondAcknowledged.countDown();both.countDown();both.countDown();}
            public void close(){check(active.get()==0,"clients close after senders exit");}
        },()->{},t->{},buffers,2).run();
        check(peak.get()==2&&used.size()==2,"exactly two lanes and existing two buffers");
        check(acknowledgements.get(0)==64,"out-of-order ACK actually exercised");
        Collections.sort(acknowledgements);check(acknowledgements.equals(items(257)),"inventory can retain original order with every ID exactly once");
        check(!buffers.leased.get(),"lease released");
    }
    static void smallFailureAndPause(boolean pause)throws Exception{
        var buffers=new ReadPipeline.Buffers();CountDownLatch both=new CountDownLatch(2),release=new CountDownLatch(1);
        AtomicBoolean cancel=new AtomicBoolean(),keepInterrupt=new AtomicBoolean();AtomicReference<Throwable> failure=new AtomicReference<>();AtomicInteger active=new AtomicInteger(),closed=new AtomicInteger();
        var sink=new ReadPipeline.Sink<Integer>(){
            public void send(ReadPipeline.Frame<Integer> frame,ReadPipeline.Check stopped)throws Exception{
                active.incrementAndGet();try{both.countDown();await(both);if(!pause&&frame.items.get(0)==0)throw new IOException("synthetic send failure");release.await();stopped.check();}finally{active.decrementAndGet();}
            }
            public void acknowledge(ReadPipeline.Frame<Integer> f){throw new AssertionError("failed/unacknowledged frame must not update cache");}
            public void abort(){release.countDown();}
            public void close(){check(active.get()==0,"failure closes after drain");closed.incrementAndGet();}
        };
        Thread caller=new Thread(()->{try{new ReadPipeline<>(items(10000),4,i->32,reader(),sink,()->{if(cancel.get())throw new InterruptedIOException();},t->{},buffers,2).run();}catch(Throwable e){failure.set(e);keepInterrupt.set(Thread.currentThread().isInterrupted());}});
        caller.start();await(both);if(pause){check(buffers.leased.get(),"buffers retained while requests active");caller.interrupt();}
        join(caller);check(failure.get()!=null&&active.get()==0&&closed.get()==1&&!buffers.leased.get(),"stop/failure fully drained");
        if(pause)check(keepInterrupt.get(),"interruption preserved");
    }
    static void smallReceiptFailure()throws Exception{
        var memory=new ReadPipeline.Buffers();AtomicInteger aborts=new AtomicInteger();
        reject(()->new ReadPipeline<>(items(200),2,i->32,reader(),new ReadPipeline.Sink<Integer>(){
            public void send(ReadPipeline.Frame<Integer> f,ReadPipeline.Check stop)throws Exception{stop.check();}
            public void acknowledge(ReadPipeline.Frame<Integer> f)throws Exception{throw new IOException("synthetic cache FULL");}
            public void abort(){aborts.incrementAndGet();}
        },()->{},t->{},memory,2).run());
        check(aborts.get()>0&&!memory.leased.get(),"receipt failure aborts senders and releases only after drain");
    }
    static final class LargeProbe {
        AtomicInteger prepared=new AtomicInteger(),sent=new AtomicInteger(),active=new AtomicInteger(),closed=new AtomicInteger(),prepareClosed=new AtomicInteger();
        CountDownLatch firstSending=new CountDownLatch(1),nextPrepared=new CountDownLatch(1),release=new CountDownLatch(1);
        AtomicBoolean stop=new AtomicBoolean();boolean block,failPrepare,failSend,failReceipt,overlap;Thread owner;
        List<Integer> received=new ArrayList<>();
        PreparedPipeline<Integer,Integer> make(int count){
            owner=Thread.currentThread();return new PreparedPipeline<>(items(count),2,new PreparedPipeline.Prepare<>(){
                public Integer prepare(Integer item,ReadPipeline.Check stopped)throws Exception{
                    if(failPrepare&&item==2)throw new IOException("hash failed");
                    if(overlap&&item==1)await(firstSending);prepared.incrementAndGet();if(item==1)nextPrepared.countDown();return item;
                }
                public void cancel(){release.countDown();nextPrepared.countDown();firstSending.countDown();}
                public void close(){prepareClosed.incrementAndGet();}
            },()->new PreparedPipeline.Worker<Integer>(){
                public void send(Integer item,ReadPipeline.Check stopped)throws Exception{
                    active.incrementAndGet();try{firstSending.countDown();if(overlap&&item==0)await(nextPrepared);if(failSend&&item==0)throw new IOException("send failed");if(block)release.await();stopped.check();sent.incrementAndGet();}finally{active.decrementAndGet();}
                }
                public void cancel(){release.countDown();}
                public void close(){closed.incrementAndGet();}
            },item->{check(Thread.currentThread()==owner,"large receipt owner");if(failReceipt)throw new IOException("cache failed");received.add(item);},()->{if(stop.get())throw new InterruptedIOException();});
        }
    }
    static void largePipeline()throws Exception{
        LargeProbe p=new LargeProbe();p.overlap=true;var pipe=p.make(10000);pipe.run();
        Collections.sort(p.received);check(p.received.equals(items(10000)),"10000 metadata items exactly once");
        check(pipe.peakOwned.get()<=3&&pipe.owned.get()==0&&p.active.get()==0&&p.prepareClosed.get()==1,"bounded slots and drained preparer");
        for(int mode=0;mode<3;mode++){
            LargeProbe fail=new LargeProbe();fail.failPrepare=mode==0;fail.failSend=mode==1;fail.failReceipt=mode==2;var failed=fail.make(10000);reject(failed::run);
            check(fail.active.get()==0&&failed.owned.get()==0&&fail.prepareClosed.get()==1,"failure joins all workers");
        }
        LargeProbe paused=new LargeProbe();paused.block=true;AtomicReference<Throwable> error=new AtomicReference<>();AtomicReference<PreparedPipeline<Integer,Integer>> running=new AtomicReference<>();
        Thread caller=new Thread(()->{try{var work=paused.make(10000);running.set(work);work.run();}catch(Throwable e){error.set(e);}});
        caller.start();await(paused.firstSending);paused.stop.set(true);join(caller);
        check(error.get()!=null&&paused.active.get()==0&&running.get().peakOwned.get()<=3,"external pause cancels active I/O and drains");
        LargeProbe pre=new LargeProbe();pre.stop.set(true);reject(()->pre.make(5).run());check(pre.prepared.get()==0&&pre.sent.get()==0,"pre-cancel performs no work");
        LargeProbe factory=new LargeProbe();var failingFactory=new PreparedPipeline<Integer,Integer>(items(5),2,new PreparedPipeline.Prepare<>(){
            public Integer prepare(Integer i,ReadPipeline.Check stop){return i;}public void cancel(){}public void close(){}
        },()->{throw new IOException("factory failure");},i->{throw new AssertionError();},()->{});reject(failingFactory::run);
    }
    static void policyAndTiming(){
        check(PipelinePolicy.smallLanes(true,64,16L*1024*1024)==1,"one batch stays single");
        check(PipelinePolicy.smallLanes(true,65,65)==2&&PipelinePolicy.smallLanes(true,5,20L*1024*1024)==2,"count OR bytes enables dual");
        check(PipelinePolicy.smallLanes(false,10000,1024)==1,"compatibility switch");
        check(!PipelinePolicy.overlapLarge(true,2,1)&&!PipelinePolicy.overlapLarge(true,1,5)&&!PipelinePolicy.overlapLarge(false,4,5),"single/cached/off gates");
        check(PipelinePolicy.overlapLarge(true,2,2),"multiple cold files eligible");
        AtomicLong clock=new AtomicLong();TransferStats stats=new TransferStats(clock::get);
        stats.beginUpload(0);clock.set(10);stats.beginUpload(10);clock.set(20);stats.upload(0);clock.set(30);
        check(stats.snapshot().get("uploadWallNs")==30,"overlap counted once while another sender remains");stats.upload(10);
        clock.set(50);stats.beginUpload(50);clock.set(60);stats.upload(50);
        check(stats.snapshot().get("uploadWallNs")==40,"disjoint active periods exclude idle gap");
        check(stats.snapshot().get("elapsedNs")==60,"full elapsed remains wall clock");
        stats.request(20);stats.request(30);check(stats.snapshot().get("requestThreadNs")==70,"thread request cumulative remains distinct");
    }
    public static void main(String[] args)throws Exception{
        policyAndTiming();dualBuffersAndReceiptOwner();smallFailureAndPause(false);smallFailureAndPause(true);smallReceiptFailure();largePipeline();
        System.out.println("Pipeline046: "+checks+" checks passed; dual buffers, caller-owned receipts, bounded prehash, pause/failure drain, union timing.");
    }
}
