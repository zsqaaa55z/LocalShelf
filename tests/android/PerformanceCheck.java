package local.shelf;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public class PerformanceCheck {
    static int checks;
    static void check(boolean b,String name){if(!b)throw new AssertionError(name);checks++;System.out.println("PASS "+name);}
    static NavigableMap<Integer,String> pages(int n){TreeMap<Integer,String> map=new TreeMap<>();for(int i=1;i<=n;i++)map.put(i*3,"page"+i);return map;}
    public static void main(String[] args)throws Exception{
        PageIndexes<String> cache=new PageIndexes<>(5,2);AtomicInteger loads=new AtomicInteger();
        var first=cache.get("a",()->{loads.incrementAndGet();return pages(2);});
        check(first.firstKey()==3 && first.lastKey()==6 && first.get(4)==null,"numeric order and gaps preserved");
        try{first.put(1,"bad");throw new AssertionError();}catch(UnsupportedOperationException expected){check(true,"immutable index");}
        cache.get("b",()->pages(2));cache.get("a",()->{throw new AssertionError();});cache.get("c",()->pages(2));
        cache.get("b",()->{loads.incrementAndGet();return pages(2);});
        check(loads.get()==2 && cache.entryCount()<=5,"weighted LRU and hit recency");
        check(cache.get("huge",()->pages(9)).size()==9 && cache.entryCount()<=5,"oversized book usable without retaining over budget");
        try{cache.get("fail",()->{throw new Exception("failure");});}catch(Exception expected){}
        check(cache.get("fail",()->pages(1)).size()==1,"failed load can retry");
        ExecutorService pool=Executors.newFixedThreadPool(8);AtomicInteger active=new AtomicInteger(),peak=new AtomicInteger(),scans=new AtomicInteger();
        CountDownLatch gate=new CountDownLatch(1),started=new CountDownLatch(2);
        try{
            PageIndexes<String> parallel=new PageIndexes<>(20,10);List<Future<?>> jobs=new ArrayList<>();
            for(int i=0;i<8;i++){String key="k"+(i%4);jobs.add(pool.submit(()->{try{return parallel.get(key,()->{scans.incrementAndGet();int a=active.incrementAndGet();peak.accumulateAndGet(a,Math::max);started.countDown();try{if(!gate.await(5,TimeUnit.SECONDS))throw new AssertionError("timeout");return pages(1);}finally{active.decrementAndGet();}});}catch(Exception e){throw new RuntimeException(e);}}));}
            if(!started.await(5,TimeUnit.SECONDS))throw new AssertionError("not started");gate.countDown();for(Future<?> job:jobs)job.get(5,TimeUnit.SECONDS);
            check(scans.get()==4,"same-book index load merged");check(peak.get()<=2,"at most two concurrent index builders");
        }finally{gate.countDown();pool.shutdownNow();}
        check(!IdlePolicy.shouldRest(false,999999,0),"stable mode never idles automatically");
        check(!IdlePolicy.shouldRest(true,59999,0) && IdlePolicy.shouldRest(true,60000,0),"economy idle threshold");
        check(!IdlePolicy.shouldRest(true,70000,65000),"recent transfer resets idle countdown");
        System.out.println(checks+" performance checks passed");
    }
}
