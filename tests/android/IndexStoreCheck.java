package local.shelf;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public class IndexStoreCheck {
    static int checks;
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);checks++;System.out.println("PASS "+message);}
    static IndexStore.Location page(int number){return new IndexStore.Location(String.format("%08d.jpg",number),"image/jpeg","primary:EhViewer/download/123/"+number);}
    static void await(java.util.function.BooleanSupplier test)throws Exception{for(int i=0;i<500;i++){if(test.getAsBoolean())return;Thread.sleep(10);}throw new AssertionError("timeout");}
    public static void main(String[] args)throws Exception {
        Path root=Files.createTempDirectory("localshelf-index-check-");
        try{
            AtomicLong clock=new AtomicLong(1_000_000);
            IndexStore store=new IndexStore(root.resolve("cache").toFile(),8192,clock::get);
            String key=IndexStore.key("tree-A/book-123/pages"),other=IndexStore.key("tree-B/book-123/pages");
            check(key.length()==64&&!key.equals(other),"root and book identity scope the cache");
            check(store.read(key,300000,30000)==null,"initial miss is safe");
            List<IndexStore.Location> entries=List.of(page(1),page(3),page(10));
            store.write(key,entries,store.ticket());
            check(store.read(key,300000,30000).equals(entries),"roundtrip preserves original names and gaps");
            check(new IndexStore(root.resolve("cache").toFile(),8192,clock::get).read(key,300000,30000).equals(entries),"service restart reuses disk metadata");
            check(store.read(other,300000,30000)==null,"different tree cannot reuse location");
            clock.addAndGet(300001);check(store.read(key,300000,30000)==null,"expired page mapping discarded");
            store.write(key,List.of(),store.ticket());clock.addAndGet(30001);check(store.read(key,300000,30000)==null,"empty partial download expires sooner");
            store.write(key,entries,store.ticket());clock.addAndGet(-1);check(store.read(key,300000,30000)==null,"wall clock rollback forces validation");clock.incrementAndGet();
            store.write(key,entries,store.ticket());Path file=root.resolve("cache").resolve(key+".idx");
            byte[] damaged=Files.readAllBytes(file);damaged[damaged.length-1]^=1;Files.write(file,damaged);
            check(store.read(key,300000,30000)==null&&!Files.exists(file),"checksum corruption falls back and removes only index");
            store.write(key,entries,store.ticket());Files.write(file,new byte[]{1,2,3});check(store.read(key,300000,30000)==null,"truncated index safely rejected");
            try{store.write(key,List.of(page(1),page(1)),store.ticket());throw new AssertionError();}catch(IOException expected){check(true,"duplicate page names rejected");}
            try{store.write("../catalog",entries,store.ticket());throw new AssertionError();}catch(IOException expected){check(true,"cache key cannot escape private directory");}
            try{store.write(key,List.of(new IndexStore.Location("../x","image/jpeg","id")),store.ticket());throw new AssertionError();}catch(IOException expected){check(true,"invalid filename rejected");}
            long old=store.ticket();store.invalidate(key);store.write(key,entries,old);check(store.read(key,300000,30000)==null,"single-book invalidation rejects late write");
            old=store.ticket();store.clear();store.write(key,entries,old);check(store.bytes()==0,"clear rejects previously queued writes");
            Path sentinel=root.resolve("cache/catalog.json");Files.writeString(sentinel,"not an index");store.write(key,entries,store.ticket());store.clear();check(Files.readString(sentinel).equals("not an index"),"clear preserves all non-index files");
            for(int i=0;i<100;i++){clock.incrementAndGet();store.write(IndexStore.key("book"+i),entries,store.ticket());}
            check(store.bytes()<=8192,"encoded metadata stays within configured budget");
            check(store.read(IndexStore.key("book99"),300000,30000)!=null && store.read(IndexStore.key("book0"),300000,30000)==null,"oldest metadata evicted before newest");
            IndexStore tiny=new IndexStore(root.resolve("tiny").toFile(),1,clock::get);tiny.write(key,entries,tiny.ticket());check(tiny.bytes()==0,"oversized entry skips persistence");
            AtomicLong ticks=new AtomicLong();PageIndexes<String> expiring=new PageIndexes<>(10,2,30,ticks::get);AtomicInteger builds=new AtomicInteger();
            PageIndexes.Loader<String> loader=()->{TreeMap<Integer,String> map=new TreeMap<>();map.put(builds.incrementAndGet(),"page");return map;};
            expiring.get("partial",loader);ticks.set(29_000_000);expiring.get("partial",loader);check(builds.get()==1,"memory freshness avoids repeated reads before deadline");
            ticks.set(30_000_000);check(expiring.get("partial",loader).containsKey(2)&&builds.get()==2,"expired memory mapping invokes fresh disk/provider lookup");
            Path temp=root.resolve("cache/index-123.tmp");Files.writeString(temp,"interrupted write");new IndexStore(root.resolve("cache").toFile(),8192,clock::get).bytes();check(!Files.exists(temp)&&Files.exists(sentinel),"startup removes only abandoned private temp files");
            // A stale in-flight loader must neither repopulate nor remove a newer flight.
            PageIndexes<String> memory=new PageIndexes<>(100,10);ExecutorService pool=Executors.newFixedThreadPool(2);
            CountDownLatch started=new CountDownLatch(1),gate=new CountDownLatch(1);
            try{
                Future<?> late=pool.submit(()->{try{return memory.get("book",()->{started.countDown();gate.await();TreeMap<Integer,String> m=new TreeMap<>();m.put(1,"old");return m;});}catch(Exception e){throw new RuntimeException(e);}});
                check(started.await(5,TimeUnit.SECONDS),"old scan running before refresh");memory.invalidate("book");
                var fresh=memory.get("book",()->{TreeMap<Integer,String> m=new TreeMap<>();m.put(2,"new");return m;});gate.countDown();late.get(5,TimeUnit.SECONDS);
                check(memory.get("book",()->{throw new AssertionError();}).equals(fresh),"late scan cannot overwrite refreshed index");
                memory.clear();check(memory.entryCount()==0,"memory refresh clears weighted accounting");
            }finally{gate.countDown();pool.shutdownNow();}
            IndexStore asyncStore=new IndexStore(root.resolve("async").toFile(),8192,clock::get);IndexWriter writer=new IndexWriter(asyncStore);
            writer.offer(key,entries,asyncStore.ticket());await(()->writer.pendingEntries()==0);
            check(asyncStore.read(key,300000,30000).equals(entries),"background writer persists metadata");
            writer.offer(key,Collections.nCopies(20001,page(1)),asyncStore.ticket());check(writer.pendingEntries()==0,"metadata write queue rejects oversized job");
            writer.close();writer.offer(other,entries,asyncStore.ticket());check(writer.pendingEntries()==0,"closed writer rejects work without accounting leak");
            check(asyncStore.read(other,300000,30000)==null,"closed writer cannot repopulate cache");
            System.out.println(checks+" index persistence checks passed");
        }finally{try(var paths=Files.walk(root)){for(Path path:paths.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(path);}}
    }
}
