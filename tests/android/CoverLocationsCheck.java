package local.shelf;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public class CoverLocationsCheck {
    static int checks;
    static void check(boolean value,String name){if(!value)throw new AssertionError(name);checks++;System.out.println("PASS "+name);}
    public static void main(String[] args)throws Exception{
        AtomicLong now=new AtomicLong();AtomicInteger scans=new AtomicInteger();
        CoverLocations<String> c=new CoverLocations<>(2,now::get);
        CoverLocations.Lookup<String> scan=()->{scans.incrementAndGet();return "uri-a";};
        c.get("a",scan);c.get("a",scan);check(scans.get()==1,"repeat cover avoids re-scan");
        now.set(300_000);c.get("a",scan);check(scans.get()==2,"positive TTL refresh");
        c.invalidate("a");c.get("a",scan);check(scans.get()==3,"stale URI invalidation");
        c.get("b",()->"b");c.get("a",scan);c.get("c",()->"c");
        AtomicInteger bScans=new AtomicInteger();c.get("b",()->{bScans.incrementAndGet();return "b";});
        check(c.size()==2 && bScans.get()==1,"LRU capacity bounded");
        AtomicInteger missing=new AtomicInteger();CoverLocations.Lookup<String> absent=()->{missing.incrementAndGet();return null;};
        c.get("missing",absent);c.get("missing",absent);check(missing.get()==1,"negative cache");
        now.addAndGet(30_000);c.get("missing",absent);check(missing.get()==2,"missing cover rechecked after TTL");
        try{c.get("error",()->{throw new Exception("query failed");});}catch(Exception expected){}
        check("recovered".equals(c.get("error",()->"recovered")),"failed query not cached as missing");
        CoverLocations<String> fresh=new CoverLocations<>(2,now::get);
        check("new-root".equals(fresh.get("a",()->"new-root")),"new server has isolated cache");
        ExecutorService pool=Executors.newFixedThreadPool(8);
        CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
        AtomicInteger concurrentScans=new AtomicInteger();
        try{
            java.util.List<Future<String>> futures=new java.util.ArrayList<>();
            for(int i=0;i<8;i++)futures.add(pool.submit(()->fresh.get("shared",()->{concurrentScans.incrementAndGet();entered.countDown();if(!release.await(5,TimeUnit.SECONDS))throw new AssertionError("timeout");return "one";})));
            if(!entered.await(5,TimeUnit.SECONDS))throw new AssertionError("lookup never started");release.countDown();
            for(Future<String> f:futures)if(!f.get(5,TimeUnit.SECONDS).equals("one"))throw new AssertionError();
            check(concurrentScans.get()==1,"concurrent same-book lookups merged");
        }finally{release.countDown();pool.shutdownNow();}
        System.out.println(checks+" cover location checks passed");
    }
}
