package local.shelf;

import java.util.LinkedHashMap;
import java.util.function.LongSupplier;

/** Bounded metadata-only cache. Per-key stripes merge concurrent directory lookups. */
final class CoverLocations<T> {
    interface Lookup<T> { T run() throws Exception; }
    private record Entry<T>(T value,long expires){}
    private final LinkedHashMap<String,Entry<T>> values=new LinkedHashMap<>(16,0.75f,true);
    private final Object[] stripes=new Object[32];
    private final int capacity;
    private final LongSupplier clock;
    CoverLocations(int capacity,LongSupplier clock){this.capacity=capacity;this.clock=clock;for(int i=0;i<stripes.length;i++)stripes[i]=new Object();}
    T get(String key,Lookup<T> lookup)throws Exception{
        synchronized(stripes[(key.hashCode()&0x7fffffff)%stripes.length]){
            long now=clock.getAsLong();
            synchronized(values){Entry<T> e=values.get(key);if(e!=null && now<e.expires)return e.value;}
            T value=lookup.run(); // Failed queries are not cached as missing.
            synchronized(values){
                values.put(key,new Entry<>(value,clock.getAsLong()+(value==null?30_000:300_000)));
                while(values.size()>capacity)values.remove(values.keySet().iterator().next());
            }
            return value;
        }
    }
    void invalidate(String key){synchronized(values){values.remove(key);}}
    void clear(){synchronized(values){values.clear();}}
    int size(){synchronized(values){return values.size();}}
}
