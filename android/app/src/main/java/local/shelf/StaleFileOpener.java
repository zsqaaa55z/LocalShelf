package local.shelf;
import java.io.*;

/** A missing mapping or stale location can trigger one fresh lookup, never a loop. */
final class StaleFileOpener {
    interface Lookup<T>{T get()throws Exception;}
    interface Open<T>{InputStream get(T location)throws Exception;}
    interface Invalidate{void run()throws Exception;}
    static <T> InputStream open(Lookup<T> lookup,Open<T> open,Invalidate invalidate,boolean retryMissing)throws Exception {
        for(int attempt=0;attempt<2;attempt++){
            T value=lookup.get();
            if(value==null&&!retryMissing)return null;
            if(value!=null)try{InputStream stream=open.get(value);if(stream!=null)return stream;}catch(FileNotFoundException stale){}
            if(attempt==0)invalidate.run();
        }
        return null;
    }
}
