package local.shelf;
import java.util.*;
import java.util.concurrent.*;

/** Weighted LRU, immutable numeric-page maps and merged concurrent loads. */
final class PageIndexes<T> {
    interface Loader<T>{NavigableMap<Integer,T> load()throws Exception;}
    private final int budget,maxBooks;
    private int entries;
    private final LinkedHashMap<String,NavigableMap<Integer,T>> cache=new LinkedHashMap<>(16,0.75f,true);
    private final Map<String,CompletableFuture<NavigableMap<Integer,T>>> flights=new HashMap<>();
    private final Semaphore builders=new Semaphore(2,true);
    private final Map<String,Long> deadlines=new HashMap<>();
    private long generation;
    private final java.util.function.LongSupplier clock;
    private final long ttlNanos;
    PageIndexes(int budget,int maxBooks){this(budget,maxBooks,30_000,System::nanoTime);}
    PageIndexes(int budget,int maxBooks,long ttlMillis,java.util.function.LongSupplier clock){this.budget=budget;this.maxBooks=maxBooks;this.clock=clock;ttlNanos=Math.max(0,ttlMillis)*1_000_000L;}
    NavigableMap<Integer,T> get(String key,Loader<T> loader)throws Exception{
        CompletableFuture<NavigableMap<Integer,T>> future;boolean owner;
        synchronized(this){
            NavigableMap<Integer,T> hit=cache.get(key);if(hit!=null && clock.getAsLong()<deadlines.getOrDefault(key,0L))return hit;
            if(hit!=null){cache.remove(key);entries-=hit.size();deadlines.remove(key);}
            future=flights.get(key);owner=future==null;
            if(owner){future=new CompletableFuture<>();flights.put(key,future);}
        }
        if(owner){
            long ticket; synchronized(this){ticket=generation;}
            boolean acquired=false;
            try{
                builders.acquire();acquired=true;
                NavigableMap<Integer,T> value=Collections.unmodifiableNavigableMap(new TreeMap<>(loader.load()));
                synchronized(this){
                    if(ticket==generation && flights.get(key)==future && value.size()<=budget && maxBooks>0){
                        while(!cache.isEmpty() && (entries+value.size()>budget || cache.size()>=maxBooks)){
                            String oldest=cache.keySet().iterator().next();entries-=cache.remove(oldest).size();deadlines.remove(oldest);
                        }
                        cache.put(key,value);entries+=value.size();deadlines.put(key,clock.getAsLong()+ttlNanos);
                    }
                }
                future.complete(value);
            }catch(Throwable error){future.completeExceptionally(error);}
            finally{if(acquired)builders.release();synchronized(this){if(flights.get(key)==future)flights.remove(key);}}
        }
        try{return future.get();}catch(ExecutionException e){if(e.getCause() instanceof Exception x)throw x;throw new Exception("索引失败",e.getCause());}
    }
    synchronized int entryCount(){return entries;}
    synchronized void invalidate(String key){generation++;NavigableMap<Integer,T> old=cache.remove(key);if(old!=null)entries-=old.size();deadlines.remove(key);flights.remove(key);}
    synchronized void clear(){generation++;cache.clear();deadlines.clear();flights.clear();entries=0;}
}
