package local.shelf;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** One writer; queued + active metadata is bounded. A cache miss is always safe. */
final class IndexWriter implements AutoCloseable {
    final IndexStore store;
    private final AtomicInteger retained=new AtomicInteger();
    private final ThreadPoolExecutor executor=new ThreadPoolExecutor(1,1,0,TimeUnit.SECONDS,new ArrayBlockingQueue<>(16),r->{Thread t=new Thread(r,"localshelf-index-writer");t.setDaemon(true);t.setPriority(Thread.MIN_PRIORITY);return t;},new ThreadPoolExecutor.AbortPolicy());
    IndexWriter(IndexStore store){this.store=store;}
    private final class Work implements Runnable {
        final String key;final List<IndexStore.Location> entries;final long ticket;final int cost;
        Work(String key,List<IndexStore.Location> entries,long ticket,int cost){this.key=key;this.entries=Collections.unmodifiableList(new ArrayList<>(entries));this.ticket=ticket;this.cost=cost;}
        public void run(){try{store.write(key,entries,ticket);}catch(Exception ignored){}finally{retained.addAndGet(-cost);}}
        void dropped(){retained.addAndGet(-cost);}
    }
    void offer(String key,List<IndexStore.Location> entries,long ticket){
        int cost=Math.max(1,entries.size()),old;
        do{old=retained.get();if(cost>20000-old)return;}while(!retained.compareAndSet(old,old+cost));
        Work job=new Work(key,entries,ticket,cost);
        try{executor.execute(job);}catch(RejectedExecutionException full){job.dropped();}
    }
    int pendingEntries(){return retained.get();}
    public void close(){store.cancelPendingWrites();for(Runnable job:executor.shutdownNow())((Work)job).dropped();}
}
