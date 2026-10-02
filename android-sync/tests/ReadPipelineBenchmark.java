package local.shelf.sync;

import java.io.*;
import java.security.MessageDigest;
import java.util.*;

/** Controlled wait simulation only, not phone/SAF/NAS throughput. */
public final class ReadPipelineBenchmark {
    record Item(int id,int size){}
    static final int COUNT=256,SIZE=128*1024,OPEN_MS=12,UPLOAD_MS=160;
    static final byte[] DATA=new byte[SIZE];
    static final List<Item> ITEMS=new ArrayList<>();
    static String expected;
    static InputStream open()throws Exception{Thread.sleep(OPEN_MS);return new ByteArrayInputStream(DATA);}
    static void verify(byte[] bytes,int offset,int count,String hash)throws Exception{
        MessageDigest d=MessageDigest.getInstance("SHA-256");d.update(bytes,offset,count);
        if(!HexFormat.of().formatHex(d.digest()).equals(hash)||!hash.equals(expected))throw new AssertionError("content mismatch");
    }
    static double baseline()throws Exception{
        BatchBuffer buffer=new BatchBuffer();List<String> hashes=new ArrayList<>();long began=System.nanoTime();
        for(var item:ITEMS){hashes.add(buffer.add(item.size(),ReadPipelineBenchmark::open,()->{}));
            if(buffer.count==64){Thread.sleep(UPLOAD_MS);for(int i=0;i<hashes.size();i++)verify(buffer.bytes,i*SIZE,SIZE,hashes.get(i));hashes.clear();buffer.clear();}
        }return (System.nanoTime()-began)/1e9;
    }
    static double pipeline(int lanes,ReadPipeline.Buffers memory)throws Exception{
        long began=System.nanoTime();
        new ReadPipeline<>(ITEMS,lanes,item->item.size(),()->new ReadPipeline.Worker<Item>(){
            public String read(Item item,byte[] bytes,int offset,ReadPipeline.Check cancel)throws Exception{return FileRead.into(item.size(),bytes,offset,ReadPipelineBenchmark::open,cancel::check,m->{});}
            public void cancel(){}
            public void close(){}
        },new ReadPipeline.Sink<Item>(){
            public void send(ReadPipeline.Frame<Item> frame,ReadPipeline.Check cancel)throws Exception{Thread.sleep(UPLOAD_MS);for(int i=0;i<frame.items.size();i++)verify(frame.bytes,frame.offsets[i],frame.items.get(i).size(),frame.hashes[i]);}
            public void abort(){}
        },()->{},beganPrepare->{},memory).run();
        return (System.nanoTime()-began)/1e9;
    }
    public static void main(String[] args)throws Exception{
        new Random(44).nextBytes(DATA);expected=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(DATA));for(int i=0;i<COUNT;i++)ITEMS.add(new Item(i,SIZE));
        var memory=new ReadPipeline.Buffers();
        for(int trial=1;trial<=2;trial++)for(int lanes:trial==1?new int[]{0,1,2,4}:new int[]{4,2,1,0}){
            double seconds=lanes==0?baseline():pipeline(lanes,memory);
            System.out.printf(Locale.ROOT,"{\"trial\":%d,\"mode\":\"%s\",\"readers\":%d,\"files\":%d,\"fileBytes\":%d,\"simulatedOpenMs\":%d,\"simulatedBatchUploadMs\":%d,\"seconds\":%.3f,\"MBps\":%.2f,\"hashesVerified\":%d}%n",trial,lanes==0?"043-sequential":"044-pipeline",Math.max(1,lanes),COUNT,SIZE,OPEN_MS,UPLOAD_MS,seconds,COUNT*(double)SIZE/1e6/seconds,COUNT);
        }
    }
}
