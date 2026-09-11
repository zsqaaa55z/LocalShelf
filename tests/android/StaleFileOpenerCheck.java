package local.shelf;
import java.io.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

public class StaleFileOpenerCheck {
    static int checks;
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);checks++;System.out.println("PASS "+message);}
    static InputStream bytes(String value){return new ByteArrayInputStream(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    public static void main(String[] args)throws Exception {
        AtomicInteger invalidations=new AtomicInteger(),lookups=new AtomicInteger();
        try(InputStream in=StaleFileOpener.open(()->{lookups.incrementAndGet();return "valid";},StaleFileOpenerCheck::bytes,invalidations::incrementAndGet,true)){
            check(new String(in.readAllBytes()).equals("valid")&&lookups.get()==1&&invalidations.get()==0,"valid location streams without rescanning");
        }
        lookups.set(0);invalidations.set(0);
        try(InputStream in=StaleFileOpener.open(()->lookups.incrementAndGet()==1?"old":"new",location->{if(location.equals("old"))throw new FileNotFoundException();return bytes(location);},invalidations::incrementAndGet,true)){
            check(new String(in.readAllBytes()).equals("new")&&invalidations.get()==1,"deleted old URI is refreshed once and new file opens");
        }
        lookups.set(0);invalidations.set(0);
        try(InputStream in=StaleFileOpener.open(()->lookups.incrementAndGet()==1?null:"downloaded",StaleFileOpenerCheck::bytes,invalidations::incrementAndGet,true)){
            check(in!=null&&invalidations.get()==1,"newly downloaded page missing from old index is discovered");
        }
        lookups.set(0);invalidations.set(0);
        check(StaleFileOpener.open(()->{lookups.incrementAndGet();return "removed";},value->{throw new FileNotFoundException();},invalidations::incrementAndGet,true)==null&&lookups.get()==2&&invalidations.get()==1,"permanently deleted page ends after two lookups");
        lookups.set(0);invalidations.set(0);
        check(StaleFileOpener.open(()->{lookups.incrementAndGet();return null;},StaleFileOpenerCheck::bytes,invalidations::incrementAndGet,false)==null&&lookups.get()==1&&invalidations.get()==0,"missing cover keeps negative-cache behavior");
        invalidations.set(0);
        try{StaleFileOpener.open(()->"denied",value->{throw new SecurityException("permission revoked");},invalidations::incrementAndGet,true);throw new AssertionError();}catch(SecurityException expected){check(invalidations.get()==0,"revoked permission is not disguised as stale metadata");}
        invalidations.set(0);
        check(StaleFileOpener.open(()->"null-stream",value->null,invalidations::incrementAndGet,true)==null&&invalidations.get()==1,"null stream retries once without leaking a stream");
        PageIndexes<String> cache=new PageIndexes<>(10,2);AtomicInteger scans=new AtomicInteger();
        StaleFileOpener.Lookup<String> lookup=()->cache.get("book",()->{TreeMap<Integer,String> map=new TreeMap<>();if(scans.incrementAndGet()>1)map.put(3,"new-page-3");else map.put(1,"old-page-1");return map;}).get(3);
        try(InputStream in=StaleFileOpener.open(lookup,StaleFileOpenerCheck::bytes,()->cache.invalidate("book"),true)){
            check(new String(in.readAllBytes()).equals("new-page-3")&&scans.get()==2,"real page cache invalidation reloads partial download and preserves numeric gap");
        }
        System.out.println(checks+" stale file recovery checks passed");
    }
}
