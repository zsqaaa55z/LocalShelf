package local.shelf.sync;

import java.io.InterruptedIOException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.function.ToLongFunction;

/** Two owned buffers, persistent per-worker readers, ordered durable handoff.
 * Reader completion order never determines file order. No task per library file.
 */
final class ReadPipeline<T> {
    interface Check {void check()throws Exception;}
    interface Worker<T> extends AutoCloseable {
        String read(T item,byte[] buffer,int offset,Check cancel)throws Exception;
        void cancel(); // Cancel active IO only; never close the provider here.
        void close(); // Called only after all read tasks have exited.
    }
    interface Factory<T> {Worker<T> open()throws Exception;}
    interface Sink<T> {
        void send(Frame<T> frame,Check cancel)throws Exception; // One call per owned frame; may overlap on two lanes.
        default void acknowledge(Frame<T> frame)throws Exception {} // Caller thread ONLY, before buffer reuse.
        void abort();
        default void close()throws Exception {} // After every sender and reader has exited.
    }
    interface Prepared {void measured(long began);}
    static final class Buffers {
        final byte[][] bytes={new byte[BatchBuffer.MAX_BYTES],new byte[BatchBuffer.MAX_BYTES]};
        final AtomicBoolean leased=new AtomicBoolean();
    }
    static final class Frame<T> {
        final byte[] bytes;
        final List<T> items=new ArrayList<>(BatchBuffer.MAX_FILES);
        final int[] offsets=new int[BatchBuffer.MAX_FILES];
        final String[] hashes=new String[BatchBuffer.MAX_FILES];
        int used;
        Frame(byte[] bytes){this.bytes=bytes;}
        void clear(){items.clear();Arrays.fill(hashes,null);used=0;}
    }
    final List<T> items;final int width;final ToLongFunction<T> size;final Factory<T> factory;final Sink<T> sink;final Check external;final Prepared prepared;
    final Buffers buffers;final int sendWidth;
    final ArrayBlockingQueue<Frame<T>> free=new ArrayBlockingQueue<>(2),ready=new ArrayBlockingQueue<>(1);
    final Semaphore available=new Semaphore(0);
    final ConcurrentLinkedQueue<Worker<T>> workers=new ConcurrentLinkedQueue<>();
    final AtomicReference<Throwable> failure=new AtomicReference<>();
    final AtomicBoolean stopping=new AtomicBoolean(),done=new AtomicBoolean();
    ReadPipeline(List<T> items,int width,ToLongFunction<T> size,Factory<T> factory,Sink<T> sink,Check external,Prepared prepared,Buffers buffers){
        this(items,width,size,factory,sink,external,prepared,buffers,1);
    }
    ReadPipeline(List<T> items,int width,ToLongFunction<T> size,Factory<T> factory,Sink<T> sink,Check external,Prepared prepared,Buffers buffers,int sendWidth){
        if(width!=1&&width!=2&&width!=4)throw new IllegalArgumentException("读取并发必须为 1、2 或 4");
        if(sendWidth!=1&&sendWidth!=2)throw new IllegalArgumentException("批量发送仅支持 1 或 2 路");
        this.items=items;this.width=width;this.size=size;this.factory=factory;this.sink=sink;this.external=external;this.prepared=prepared;
        this.buffers=buffers;this.sendWidth=sendWidth;
    }
    static void rethrow(Throwable error)throws Exception {if(error instanceof Exception e)throw e;if(error instanceof Error e)throw e;throw new RuntimeException(error);}
    void check()throws Exception {
        Throwable error=failure.get();if(error!=null)rethrow(error);
        external.check();if(stopping.get()||Thread.currentThread().isInterrupted())throw new InterruptedIOException("读取已停止");
    }
    void cancelReaders(){for(var reader:workers)try{reader.cancel();}catch(RuntimeException ignored){}}
    void fail(Throwable error){
        if(failure.compareAndSet(null,error)){stopping.set(true);cancelReaders();try{sink.abort();}catch(RuntimeException ignored){}}
    }
    Frame<T> nextFree()throws Exception {for(;;){check();Frame<T> frame=free.poll(100,TimeUnit.MILLISECONDS);if(frame!=null)return frame;}}
    void produce(){
        ExecutorService pool=Executors.newFixedThreadPool(width,r->{Thread t=new Thread(r,"localshelf-source-read");t.setDaemon(true);return t;});
        ThreadLocal<Worker<T>> local=new ThreadLocal<>();
        try{
            int next=0;
            while(next<items.size()){
                Frame<T> frame=nextFree();frame.clear();
                while(next<items.size()&&frame.items.size()<BatchBuffer.MAX_FILES){
                    T item=items.get(next);long length=size.applyAsLong(item);
                    if(length<0||length>BatchBuffer.MAX_FILE)throw new IllegalArgumentException("非小文件不能进入读取流水线");
                    if(length>frame.bytes.length-frame.used)break;
                    frame.offsets[frame.items.size()]=frame.used;frame.items.add(item);frame.used+=(int)length;next++;
                }
                long began=System.nanoTime();AtomicInteger index=new AtomicInteger();List<Future<?>> active=new ArrayList<>(width);
                for(int lane=0;lane<Math.min(width,frame.items.size());lane++)active.add(pool.submit(()->{
                    try{
                        check();Worker<T> reader=local.get();if(reader==null){reader=factory.open();if(reader==null)throw new IllegalStateException("读取连接为空");local.set(reader);workers.add(reader);}
                        for(;;){check();int i=index.getAndIncrement();if(i>=frame.items.size())break;
                            String sha=reader.read(frame.items.get(i),frame.bytes,frame.offsets[i],this::check);
                            if(sha==null||!sha.matches("[a-f0-9]{64}"))throw new IllegalStateException("读取未返回有效校验值");frame.hashes[i]=sha;
                        }
                    }catch(Throwable e){fail(e);throw new CompletionException(e);}
                }));
                for(Future<?> task:active){for(;;){check();try{task.get(100,TimeUnit.MILLISECONDS);break;}catch(TimeoutException ignored){}}}
                prepared.measured(began);check();
                while(!ready.offer(frame,100,TimeUnit.MILLISECONDS))check();
                available.release();
            }
        }catch(Throwable e){fail(e instanceof ExecutionException&&e.getCause()!=null?e.getCause():e);}
        finally{
            if(stopping.get())cancelReaders();pool.shutdownNow();boolean interrupted=Thread.interrupted();
            while(!pool.isTerminated())try{pool.awaitTermination(100,TimeUnit.MILLISECONDS);}catch(InterruptedException e){interrupted=true;cancelReaders();}
            // ContentProviderClient must not be closed while read/open is active.
            for(var reader:workers)try{reader.close();}catch(Throwable e){fail(e);}
            done.set(true);available.release();if(interrupted)Thread.currentThread().interrupt();
        }
    }
    void run()throws Exception {
        check();if(items.isEmpty())return;
        if(!buffers.leased.compareAndSet(false,true))throw new IllegalStateException("读取缓冲仍在使用");
        free.add(new Frame<>(buffers.bytes[0]));free.add(new Frame<>(buffers.bytes[1]));
        ArrayBlockingQueue<Frame<T>> confirmed=new ArrayBlockingQueue<>(2);
        ExecutorService senders=Executors.newFixedThreadPool(sendWidth);
        Thread producer=new Thread(this::produce,"localshelf-read-prepare");producer.start();
        int inFlight=0;
        try{
            for(;;){
                check();Frame<T> receipt=confirmed.poll();
                if(receipt!=null){sink.acknowledge(receipt);check();free.add(receipt);inFlight--;}
                Frame<T> frame=ready.poll();
                if(frame!=null){
                    inFlight++;senders.submit(()->{
                        try{check();sink.send(frame,this::check);check();confirmed.add(frame);}
                        catch(Throwable e){fail(e);}
                        finally{available.release();}
                    });
                }
                if(done.get()&&inFlight==0&&ready.isEmpty()){check();break;}
                if(receipt==null&&frame==null)available.tryAcquire(100,TimeUnit.MILLISECONDS);
            }
        }catch(Throwable e){if(e instanceof InterruptedException)Thread.currentThread().interrupt();fail(e);}
        finally{
            stopping.set(true);if(!done.get()){cancelReaders();producer.interrupt();}
            senders.shutdownNow();
            boolean interrupted=Thread.interrupted();
            while(producer.isAlive())try{producer.join(100);}catch(InterruptedException e){interrupted=true;fail(e);cancelReaders();}
            while(!senders.isTerminated())try{senders.awaitTermination(100,TimeUnit.MILLISECONDS);}catch(InterruptedException e){interrupted=true;fail(e);}
            try{sink.close();}catch(Throwable e){fail(e);}
            free.clear();ready.clear();confirmed.clear();buffers.leased.set(false);if(interrupted)Thread.currentThread().interrupt();
        }
        if(failure.get()!=null)rethrow(failure.get());
    }
}
