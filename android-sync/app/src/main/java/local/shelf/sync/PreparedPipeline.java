package local.shelf.sync;

import java.io.InterruptedIOException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** One preparer, at most two senders, three METADATA slots, one receipt owner.
 * No task per library entry, no whole-file payload buffer, no cross-book work.
 */
final class PreparedPipeline<T,R> {
    interface Prepare<T,R> extends AutoCloseable {
        R prepare(T item,ReadPipeline.Check stopped)throws Exception;
        void cancel();void close();
    }
    interface Worker<R> extends AutoCloseable {
        void send(R item,ReadPipeline.Check stopped)throws Exception;
        void cancel();void close();
    }
    interface Factory<R> {Worker<R> open()throws Exception;}
    interface Receipt<R> {void accept(R item)throws Exception;}
    final List<T> items;final Prepare<T,R> prepare;final Factory<R> factory;final Receipt<R> receipt;final ReadPipeline.Check external;
    final int width;
    final Semaphore slots=new Semaphore(3);
    final Semaphore available=new Semaphore(0);
    final ArrayBlockingQueue<R> ready=new ArrayBlockingQueue<>(3),confirmed=new ArrayBlockingQueue<>(3);
    final ConcurrentLinkedQueue<Worker<R>> workers=new ConcurrentLinkedQueue<>();
    final AtomicReference<Throwable> failure=new AtomicReference<>();
    final AtomicBoolean stopped=new AtomicBoolean(),done=new AtomicBoolean();
    final AtomicInteger owned=new AtomicInteger(),peakOwned=new AtomicInteger();
    PreparedPipeline(List<T> items,int width,Prepare<T,R> prepare,Factory<R> factory,Receipt<R> receipt,ReadPipeline.Check external){
        if(width<1||width>2)throw new IllegalArgumentException("预校验发送仅支持 1 或 2 路");
        this.items=items;this.width=width;this.prepare=prepare;this.factory=factory;this.receipt=receipt;this.external=external;
    }
    void check()throws Exception {
        if(failure.get()!=null)ReadPipeline.rethrow(failure.get());external.check();
        if(stopped.get()||Thread.currentThread().isInterrupted())throw new InterruptedIOException("校验上传已停止");
    }
    void cancelIO(){try{prepare.cancel();}catch(RuntimeException ignored){}for(var worker:workers)try{worker.cancel();}catch(RuntimeException ignored){}}
    void fail(Throwable e){if(failure.compareAndSet(null,e)){stopped.set(true);cancelIO();}}
    void produce(){
        try{
            for(T item:items){
                check();while(!slots.tryAcquire(100,TimeUnit.MILLISECONDS))check();check();
                peakOwned.accumulateAndGet(owned.incrementAndGet(),Math::max);
                R result=Objects.requireNonNull(prepare.prepare(item,this::check));check();ready.add(result);available.release();
            }
        }catch(Throwable e){fail(e);}
        finally{try{prepare.close();}catch(Throwable e){fail(e);}done.set(true);available.release(width);}
    }
    void consume(){
        Worker<R> worker=null;
        try{
            for(;;){
                check();if(!available.tryAcquire(100,TimeUnit.MILLISECONDS))continue;R item=ready.poll();
                if(item==null){if(done.get()&&ready.isEmpty())return;continue;}
                if(worker==null){worker=Objects.requireNonNull(factory.open());workers.add(worker);}
                check();worker.send(item,this::check);check();confirmed.add(item);
            }
        }catch(Throwable e){fail(e);}
        finally{if(worker!=null)try{worker.close();}catch(Throwable e){fail(e);}}
    }
    void run()throws Exception {
        check();if(items.isEmpty()){prepare.close();return;}
        Thread producer=new Thread(this::produce,"localshelf-large-hash");
        List<Thread> senders=new ArrayList<>();
        for(int i=0;i<Math.min(width,items.size());i++)senders.add(new Thread(this::consume,"localshelf-large-send-"+i));
        producer.start();for(Thread sender:senders)sender.start();
        try{
            for(int count=0;count<items.size();){
                check();R item=confirmed.poll(100,TimeUnit.MILLISECONDS);if(item==null)continue;
                check();receipt.accept(item);check();owned.decrementAndGet();slots.release();count++;
            }
        }catch(Throwable e){if(e instanceof InterruptedException)Thread.currentThread().interrupt();fail(e);}
        finally{
            // Normal completion waits for natural worker exit, so no worker can
            // interpret our cleanup as a new cancellation after successful ACKs.
            if(failure.get()!=null){stopped.set(true);cancelIO();producer.interrupt();for(Thread t:senders)t.interrupt();}
            boolean interrupted=Thread.interrupted();List<Thread> all=new ArrayList<>(senders);all.add(producer);
            for(Thread thread:all)while(thread.isAlive())try{thread.join(100);}catch(InterruptedException e){interrupted=true;fail(e);cancelIO();for(Thread t:all)t.interrupt();}
            ready.clear();confirmed.clear();owned.set(0);stopped.set(true);
            if(interrupted)Thread.currentThread().interrupt();
        }
        if(failure.get()!=null)ReadPipeline.rethrow(failure.get());
    }
}
