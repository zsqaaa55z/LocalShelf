package local.shelf.sync;

import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class ReadPipelineTest {
    static int checks;
    static synchronized void check(boolean condition,String message){checks++;if(!condition)throw new AssertionError(message);}
    interface Task {void run()throws Exception;}
    static void reject(Task work)throws Exception{try{work.run();}catch(Exception expected){checks++;return;}throw new AssertionError("expected failure");}
    record Item(int id,int size){}
    static List<Item> items(int count,int size){List<Item> result=new ArrayList<>();for(int i=0;i<count;i++)result.add(new Item(i,size));return result;}
    static byte[] body(Item item){byte[] result=new byte[item.size()];Arrays.fill(result,(byte)item.id());return result;}
    static String sha(byte[] bytes,int offset,int length)throws Exception{MessageDigest d=MessageDigest.getInstance("SHA-256");d.update(bytes,offset,length);return HexFormat.of().formatHex(d.digest());}
    static final class Probe {
        final AtomicInteger factories=new AtomicInteger(),closed=new AtomicInteger(),opens=new AtomicInteger(),active=new AtomicInteger(),peak=new AtomicInteger(),reads=new AtomicInteger(),aborts=new AtomicInteger();
        final List<Integer> sent=new ArrayList<>();final Set<byte[]> buffers=Collections.newSetFromMap(new IdentityHashMap<>());
        final List<FileRead.Metrics> metrics=Collections.synchronizedList(new ArrayList<>());
        volatile int failRead=-1;volatile boolean cancel;int failSend=-1;int sends;
        final CountDownLatch secondPrepared=new CountDownLatch(1),secondBlocked=new CountDownLatch(1),releaseRead=new CountDownLatch(1);
        boolean overlap,blockSecond;
        ReadPipeline.Worker<Item> reader(){
            factories.incrementAndGet();long owner=Thread.currentThread().getId();AtomicBoolean reading=new AtomicBoolean();
            return new ReadPipeline.Worker<>(){
                public String read(Item item,byte[] buffer,int offset,ReadPipeline.Check stopped)throws Exception{
                    check(owner==Thread.currentThread().getId(),"reader stays on its worker thread");check(reading.compareAndSet(false,true),"no concurrent operations on provider client");
                    int n=active.incrementAndGet();peak.accumulateAndGet(n,Math::max);
                    try{
                        if(blockSecond&&item.id()>=64){secondBlocked.countDown();releaseRead.await(3,TimeUnit.SECONDS);stopped.check();}
                        if(item.id()==failRead)throw new IOException("synthetic read failure");
                        String result=FileRead.into(item.size(),buffer,offset,()->{opens.incrementAndGet();return new ByteArrayInputStream(body(item));},stopped::check,metrics::add);
                        reads.incrementAndGet();return result;
                    }finally{active.decrementAndGet();reading.set(false);}
                }
                public void cancel(){releaseRead.countDown();}
                public void close(){check(!reading.get(),"provider closed only after reads drained");closed.incrementAndGet();}
            };
        }
        ReadPipeline.Sink<Item> sink(){return new ReadPipeline.Sink<>(){
            public void send(ReadPipeline.Frame<Item> frame,ReadPipeline.Check stopped)throws Exception{
                int index=sends++;
                if(index==0&&overlap){check(secondPrepared.await(3,TimeUnit.SECONDS),"next buffer prepared while first upload waits");check(reads.get()==128,"no third batch read before buffer acknowledgement");}
                if(index==failSend){if(blockSecond)check(secondBlocked.await(3,TimeUnit.SECONDS),"reader is active when upload fails");throw new IOException("synthetic upload failure");}
                buffers.add(frame.bytes);check(frame.items.size()<=64&&frame.used<=16*1024*1024,"wire bounds");int offset=0;
                for(int i=0;i<frame.items.size();i++){
                    var item=frame.items.get(i);check(frame.offsets[i]==offset,"deterministic offsets");check(frame.hashes[i].equals(sha(frame.bytes,offset,item.size())),"frame hash matches bytes");
                    for(int j=offset;j<offset+item.size();j++)if(frame.bytes[j]!=(byte)item.id())throw new AssertionError("overwritten in-flight frame");
                    offset+=item.size();sent.add(item.id());
                }
                check(offset==frame.used,"exact frame payload length");
            }
            public void abort(){aborts.incrementAndGet();releaseRead.countDown();}
        };}
        void run(List<Item> list,int lanes,ReadPipeline.Buffers memory)throws Exception{
            AtomicInteger prepared=new AtomicInteger();
            new ReadPipeline<>(list,lanes,item->item.size(),this::reader,sink(),()->{if(cancel)throw new InterruptedIOException("synthetic pause");},began->{if(prepared.incrementAndGet()==2)secondPrepared.countDown();},memory).run();
        }
        void drained(ReadPipeline.Buffers memory){check(active.get()==0,"no reads after return");check(factories.get()==closed.get(),"all provider leases closed");check(!memory.leased.get(),"buffers returned only after drain");}
    }
    static void success()throws Exception{
        var memory=new ReadPipeline.Buffers();
        for(int lanes:new int[]{1,2,4}){
            Probe p=new Probe();p.run(items(1000,257),lanes,memory);p.drained(memory);
            check(p.opens.get()==1000&&p.reads.get()==1000,"each file opened exactly once");
            check(p.factories.get()<=lanes&&p.factories.get()>0,"provider lease reused across batches");check(p.peak.get()<=lanes,"bounded reader concurrency");check(p.buffers.size()<=2,"only two data buffers");
            check(p.sent.size()==1000,"all files acknowledged");for(int i=0;i<1000;i++)check(p.sent.get(i)==i,"file order stable");
            for(var m:p.metrics)check(m.complete()&&m.bytes()==257&&m.open()+m.read()+m.hash()+m.close()<=m.total(),"separate timing accounting");
        }
    }
    static void boundaries()throws Exception{
        var memory=new ReadPipeline.Buffers();Probe p=new Probe();List<Item> list=new ArrayList<>();
        for(int i=0;i<9;i++)list.add(new Item(i,4*1024*1024));for(int i=9;i<140;i++)list.add(new Item(i,0));
        p.run(list,2,memory);p.drained(memory);check(p.sent.size()==140,"size and count boundaries plus empty files");
        Probe bad=new Probe();reject(()->bad.run(items(1,4*1024*1024+1),2,memory));bad.drained(memory);check(bad.sent.isEmpty(),"oversized file never sent");
        Probe negative=new Probe();reject(()->negative.run(items(1,-1),2,memory));negative.drained(memory);
        Probe empty=new Probe();empty.run(List.of(),2,memory);check(empty.factories.get()==0&&empty.sends==0,"empty book needs no worker");
        reject(()->empty.run(items(1,0),3,memory));
    }
    static void overlapAndOwnership()throws Exception{
        var memory=new ReadPipeline.Buffers();Probe p=new Probe();p.overlap=true;p.run(items(256,512),2,memory);p.drained(memory);check(p.sent.size()==256,"overlapped data intact");
        Probe again=new Probe();again.run(items(130,512),4,memory);again.drained(memory);check(again.buffers.stream().allMatch(b->b==memory.bytes[0]||b==memory.bytes[1]),"same two allocations reused across books");
        memory.leased.set(true);try{reject(()->new Probe().run(items(1,1),1,memory));}finally{memory.leased.set(false);}
    }
    static void failures()throws Exception{
        var memory=new ReadPipeline.Buffers();
        Probe read=new Probe();read.failRead=5;reject(()->read.run(items(1000,512),4,memory));read.drained(memory);check(read.sent.isEmpty(),"failed first frame never sent");
        Probe send=new Probe();send.failSend=0;send.blockSecond=true;reject(()->send.run(items(1000,512),2,memory));send.drained(memory);check(send.aborts.get()>0,"failure cancels active transport");
        Probe cancel=new Probe();cancel.cancel=true;reject(()->cancel.run(items(1000,512),2,memory));cancel.drained(memory);check(cancel.opens.get()==0,"pre-cancel opens nothing");
        var factoryFailure=new ReadPipeline<>(items(1000,8),2,item->item.size(),()->{throw new IOException("factory unavailable");},new ReadPipeline.Sink<Item>(){public void send(ReadPipeline.Frame<Item> f,ReadPipeline.Check c){throw new AssertionError();}public void abort(){}},()->{},began->{},memory);
        reject(factoryFailure::run);check(!memory.leased.get(),"factory failure releases buffers");
        // An external pause while source IO is active must drain all workers.
        Probe paused=new Probe();paused.blockSecond=true;AtomicReference<Throwable> failure=new AtomicReference<>();
        Thread runner=new Thread(()->{try{paused.run(items(1000,512),2,memory);}catch(Throwable e){failure.set(e);}});
        runner.start();check(paused.secondBlocked.await(3,TimeUnit.SECONDS),"pause fixture entered read");paused.cancel=true;runner.join(5000);
        check(!runner.isAlive()&&failure.get()!=null,"pause completes with error after drain");paused.drained(memory);
        Probe interrupted=new Probe();interrupted.blockSecond=true;AtomicBoolean interruptKept=new AtomicBoolean();
        Thread caller=new Thread(()->{try{interrupted.run(items(1000,512),2,memory);}catch(Exception expected){interruptKept.set(Thread.currentThread().isInterrupted());}});
        caller.start();check(interrupted.secondBlocked.await(3,TimeUnit.SECONDS),"interrupt fixture entered read");caller.interrupt();caller.join(5000);
        check(!caller.isAlive()&&interruptKept.get(),"caller interruption preserved after drain");interrupted.drained(memory);
    }
    static void exactReads()throws Exception{
        byte[] dst=new byte[100];List<FileRead.Metrics> metrics=new ArrayList<>();
        reject(()->FileRead.into(10,dst,0,()->new ByteArrayInputStream(new byte[9]),()->{},metrics::add));check(!metrics.get(metrics.size()-1).complete(),"short file rejected");
        reject(()->FileRead.into(10,dst,0,()->new ByteArrayInputStream(new byte[11]),()->{},metrics::add));
        reject(()->FileRead.into(0,dst,0,()->null,()->{},metrics::add));
        reject(()->FileRead.into(0,dst,0,()->new ByteArrayInputStream(new byte[0]){public void close()throws IOException{throw new IOException("close failed");}},()->{},metrics::add));check(!metrics.get(metrics.size()-1).complete(),"close failure is not success");
        reject(()->FileRead.into(10,dst,95,()->new ByteArrayInputStream(new byte[10]),()->{},metrics::add));
        AtomicInteger closed=new AtomicInteger();reject(()->FileRead.into(10,dst,0,()->new ByteArrayInputStream(new byte[10]){public void close(){closed.incrementAndGet();}},new FileRead.Check(){int n;public void check()throws IOException{if(n++>0)throw new InterruptedIOException();}},metrics::add));check(closed.get()==1,"cancel closes descriptor");
    }
    public static void main(String[] args)throws Exception{success();boundaries();overlapAndOwnership();failures();exactReads();System.out.println("ReadPipeline: "+checks+" checks passed; 1/2/4 readers, two reusable buffers, ordered hashes, overlap and failure/pause drain.");}
}
