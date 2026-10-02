package local.shelf.sync;

import java.io.*;
import java.nio.channels.ClosedByInterruptException;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class DirectReadTest {
    static int checks;
    static void check(boolean value,String label){checks++;if(!value)throw new AssertionError(label);}
    interface Task {void run()throws Exception;}
    static void fails(Class<? extends Throwable> type,Task task)throws Exception {
        try{task.run();}catch(Throwable t){check(type.isInstance(t),"expected "+type.getSimpleName()+", got "+t.getClass().getSimpleName());return;}
        throw new AssertionError("expected "+type.getSimpleName());
    }
    static InputStream bytes(){return new ByteArrayInputStream(new byte[]{1,2,3});}
    static void routeTests()throws Exception {
        for(boolean[] flags:new boolean[][]{{false,true,true},{true,false,true},{true,true,false}}){
            ReadFallback route=new ReadFallback(flags[0],flags[1],flags[2]);
            try(InputStream in=route.open(()->{throw new AssertionError("ineligible direct attempted");},DirectReadTest::bytes)){check(in.read()==1,"SAF content");}
            check(route.directOpens.get()==0&&route.safOpens.get()==1,"ineligible counts");
        }
        ReadFallback direct=new ReadFallback(true,true,true);
        try(InputStream in=direct.open(DirectReadTest::bytes,()->{throw new AssertionError("SAF attempted");})){check(in.read()==1,"direct content");}
        check(direct.directOpens.get()==1&&direct.safOpens.get()==0,"direct counts");
        for(Throwable failure:List.of(new FileNotFoundException(),new IOException(),new SecurityException(),new UnsupportedOperationException())){
            ReadFallback route=new ReadFallback(true,true,true);AtomicInteger attempts=new AtomicInteger();
            ReadFallback.Opener fail=()->{attempts.incrementAndGet();if(failure instanceof IOException io)throw io;throw (RuntimeException)failure;};
            for(int i=0;i<20;i++)try(InputStream in=route.open(fail,DirectReadTest::bytes)){check(in.read()==1,"fallback content");}
            check(attempts.get()==1&&route.fallbacks.get()==1&&route.safOpens.get()==20,"circuit stays on SAF");
        }
        for(IOException fatal:List.of(new DirectReadScope.UnsafePathException(),new DirectReadScope.SourceChangedException(),new InterruptedIOException(),new ClosedByInterruptException())){
            ReadFallback route=new ReadFallback(true,true,true);
            fails(fatal.getClass(),()->route.open(()->{throw fatal;},()->{throw new AssertionError("fatal error masked");}));
            check(route.fallbacks.get()==0&&route.safOpens.get()==0,"fatal not retried");
        }
        ReadFallback route=new ReadFallback(true,true,true);
        fails(IOException.class,()->route.open(()->{throw new IOException();},()->{throw new IOException("SAF also failed");}));
        ReadFallback late=new ReadFallback(true,true,true);AtomicInteger saf=new AtomicInteger();
        try(InputStream in=late.open(()->new InputStream(){public int read()throws IOException{throw new IOException("mid-stream");}},()->{saf.incrementAndGet();return bytes();})){
            fails(IOException.class,in::read);
        }
        check(saf.get()==0&&late.fallbacks.get()==0,"no mid-stream retry");
        Thread.currentThread().interrupt();
        try{fails(InterruptedIOException.class,()->new ReadFallback(true,true,true).open(()->{throw new AssertionError();},()->{throw new AssertionError();}));}
        finally{Thread.interrupted();}
        ReadFallback parallel=new ReadFallback(true,true,true);AtomicInteger attempts=new AtomicInteger();CyclicBarrier barrier=new CyclicBarrier(4);ExecutorService pool=Executors.newFixedThreadPool(4);
        try{
            List<Future<?>> jobs=new ArrayList<>();
            for(int lane=0;lane<4;lane++)jobs.add(pool.submit(()->{
                for(int i=0;i<100;i++)try(InputStream in=parallel.open(()->{attempts.incrementAndGet();try{barrier.await(3,TimeUnit.SECONDS);}catch(Exception e){throw new IOException(e);}throw new IOException("access unavailable");},DirectReadTest::bytes)){if(in.read()!=1)throw new AssertionError();}
                catch(IOException e){throw new UncheckedIOException(e);}
            }));
            for(Future<?> job:jobs)job.get(10,TimeUnit.SECONDS);
            check(attempts.get()==4&&parallel.safOpens.get()==400,"at most already-in-flight failures across four lanes");
        }finally{pool.shutdownNow();pool.awaitTermination(5,TimeUnit.SECONDS);}
    }
    static byte[] digest(InputStream in)throws Exception {try(in){MessageDigest md=MessageDigest.getInstance("SHA-256");byte[] block=new byte[65536];for(int n;(n=in.read(block))!=-1;)md.update(block,0,n);return md.digest();}}
    static void scopeTests()throws Exception {
        Path fixture=Files.createTempDirectory("localshelf-direct-045-test-");Path root=Files.createDirectories(fixture.resolve("EhViewer/download"));
        Path book=Files.createDirectory(root.resolve("sample"));Path file=book.resolve("001.bin");byte[] body=new byte[5*1024*1024+17];new Random(4).nextBytes(body);Files.write(file,body);
        Files.setLastModifiedTime(file,java.nio.file.attribute.FileTime.fromMillis(1700000000648L));
        long modified=Files.getLastModifiedTime(file).toMillis();check(modified%1000==648,"fixture includes subsecond timestamp");byte[] expected=MessageDigest.getInstance("SHA-256").digest(body);
        DirectReadScope scope=new DirectReadScope(root);
        for(int i=0;i<4;i++)check(Arrays.equals(expected,digest(scope.open("sample/001.bin",body.length,modified))),"large streamed file matches");
        check(Files.getLastModifiedTime(file).toMillis()==modified&&Arrays.equals(expected,digest(Files.newInputStream(file))),"source content and mtime untouched");
        for(String invalid:new String[]{"","/sample/001.bin","../001.bin","sample/../001.bin","sample//001.bin","sample/./001.bin","sample\\001.bin","sample/001.bin/","sample/\u0000x","sample/\nx"})
            fails(DirectReadScope.UnsafePathException.class,()->scope.open(invalid,body.length,modified));
        fails(DirectReadScope.SourceChangedException.class,()->scope.open("sample/001.bin",body.length-1,modified));
        fails(DirectReadScope.SourceChangedException.class,()->scope.open("sample/001.bin",body.length,modified+1));
        fails(DirectReadScope.SourceChangedException.class,()->scope.open("sample/001.bin",body.length,modified/1000*1000));
        fails(DirectReadScope.SourceChangedException.class,()->scope.open("sample/001.bin",-1,modified));
        fails(DirectReadScope.UnsafePathException.class,()->scope.open("sample",0,0));
        Files.createSymbolicLink(book.resolve("inside-link"),file);
        fails(DirectReadScope.UnsafePathException.class,()->scope.open("sample/inside-link",body.length,modified));
        Files.createSymbolicLink(root.resolve("dir-link"),book);
        fails(DirectReadScope.UnsafePathException.class,()->scope.open("dir-link/001.bin",body.length,modified));
        Path outside=fixture.resolve("outside.bin");Files.write(outside,new byte[]{7});Files.createSymbolicLink(book.resolve("outside-link"),outside);
        fails(DirectReadScope.UnsafePathException.class,()->scope.open("sample/outside-link",1,0));
        Path empty=book.resolve("empty");Files.createFile(empty);try(InputStream in=scope.open("sample/empty",0,0)){check(in.read()==-1,"empty file");}
        String deep="sample/"+"d/".repeat(16)+"file";Path deepFile=root.resolve(deep);Files.createDirectories(deepFile.getParent());Files.write(deepFile,new byte[]{4});
        try(InputStream in=scope.open(deep,1,0)){check(in.read()==4,"existing scanner depth remains supported");}
        fails(DirectReadScope.UnsafePathException.class,()->scope.open("sample/"+"d/".repeat(17)+"file",1,0));
        ReadFallback fallback=new ReadFallback(true,true,true);
        try(InputStream in=fallback.open(()->scope.open("sample/missing",1,0),DirectReadTest::bytes)){check(in.read()==1&&fallback.fallbacks.get()==1,"missing direct file uses SAF");}
        check(Files.size(outside)==1&&Files.readAllBytes(outside)[0]==7,"outside untouched");
        // Test fixture cleanup only; never follows symlinks or touches user source.
        try(var paths=Files.walk(fixture)){for(Path p:paths.sorted(Comparator.reverseOrder()).toList())Files.delete(p);}
    }
    public static void main(String[] args)throws Exception {routeTests();scopeTests();System.out.println("DirectReadTest passed: "+checks+" checks");}
}
