package local.shelf.sync;

import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Bounded workers, not one queued task per image. Drains before returning. */
final class ParallelFiles {
    interface Worker extends AutoCloseable {void transfer(int index)throws Exception; void close();}
    interface Factory {Worker open()throws Exception;}
    static void run(int count,int concurrency,Factory factory)throws Exception {
        if(count<0 || concurrency!=1&&concurrency!=2&&concurrency!=4)throw new IllegalArgumentException("Invalid transfer limit");
        if(count==0)return;
        int width=Math.min(count,concurrency);
        ExecutorService pool=Executors.newFixedThreadPool(width);
        CompletionService<Void> completed=new ExecutorCompletionService<>(pool);
        CopyOnWriteArrayList<Worker> workers=new CopyOnWriteArrayList<>();
        AtomicInteger next=new AtomicInteger();AtomicBoolean failed=new AtomicBoolean();
        try {
            for(int lane=0;lane<width;lane++)completed.submit(()->{
                try(Worker worker=factory.open()){
                    workers.add(worker);
                    while(!failed.get()&&!Thread.currentThread().isInterrupted()){
                        int index=next.getAndIncrement();if(index>=count)break;
                        worker.transfer(index);
                    }
                }catch(Exception e){failed.set(true);throw e;}
                return null;
            });
            for(int lane=0;lane<width;lane++){
                try{completed.take().get();}
                catch(ExecutionException e){if(e.getCause() instanceof Exception cause)throw cause;throw new RuntimeException(e.getCause());}
            }
        }finally{
            failed.set(true);
            for(Worker worker:workers)worker.close();
            pool.shutdownNow();
            // Do not advance book checkpoints or permit a new sync while a
            // cancelled worker can still write. Preserve interruption afterwards.
            boolean interrupted=false;
            while(!pool.isTerminated())try{pool.awaitTermination(1,TimeUnit.SECONDS);}catch(InterruptedException e){interrupted=true;}
            if(interrupted)Thread.currentThread().interrupt();
        }
    }
}
