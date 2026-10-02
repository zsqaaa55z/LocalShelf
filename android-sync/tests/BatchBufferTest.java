package local.shelf.sync;
import java.io.*;
import java.util.*;
import java.security.MessageDigest;

public final class BatchBufferTest {
    static int checks;
    static void check(boolean value){checks++;if(!value)throw new AssertionError("check "+checks);}
    interface Run {void run()throws Exception;}
    static void reject(Run task)throws Exception{try{task.run();}catch(IOException expected){checks++;return;}throw new AssertionError("expected rejection");}
    static String hash(byte[] value)throws Exception{return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value));}
    public static void main(String[] args)throws Exception {
        BatchBuffer b=new BatchBuffer();int[] opens={0},closes={0};byte[] data=new byte[200000];new Random(7).nextBytes(data);
        String sha=b.add(data.length,()->{opens[0]++;return new ByteArrayInputStream(data){public void close(){closes[0]++;}};},()->{});
        check(sha.equals(hash(data)));check(opens[0]==1&&closes[0]==1);check(b.used==data.length&&b.count==1);check(Arrays.equals(Arrays.copyOf(b.bytes,b.used),data));
        b.add(0,()->new ByteArrayInputStream(new byte[0]),()->{});check(b.count==2&&b.used==data.length);
        int before=b.used;
        reject(()->b.add(5,()->new ByteArrayInputStream(new byte[4]),()->{}));check(b.used==before&&b.count==2);
        reject(()->b.add(3,()->new ByteArrayInputStream(new byte[4]),()->{}));check(b.used==before);
        reject(()->b.add(3,()->new ByteArrayInputStream(new byte[3]),()->{throw new IOException("cancel");}));check(b.used==before);
        reject(()->b.add(0,()->null,()->{}));check(b.used==before);
        reject(()->b.add(0,()->new ByteArrayInputStream(new byte[0]){public void close()throws IOException{throw new IOException("close");}},()->{}));check(b.used==before);
        check(!b.fits(-1)&&!b.fits(BatchBuffer.MAX_FILE+1L));
        b.clear();for(int i=0;i<64;i++)b.add(0,()->new ByteArrayInputStream(new byte[0]),()->{});
        check(!b.fits(0));reject(()->b.add(0,()->new ByteArrayInputStream(new byte[0]),()->{}));
        b.clear();byte[] block=new byte[BatchBuffer.MAX_FILE];for(int i=0;i<4;i++)b.add(block.length,()->new ByteArrayInputStream(block),()->{});
        check(b.used==BatchBuffer.MAX_BYTES&&!b.fits(1));check(b.fits(0));
        b.clear();check(b.used==0&&b.count==0&&b.fits(BatchBuffer.MAX_FILE));
        byte[] reused=b.bytes;
        for(int cycle=0;cycle<100;cycle++){b.clear();check(b.bytes==reused);check(b.add(data.length,()->new ByteArrayInputStream(data),()->{}).equals(sha));}
        b.clear();b.add(1,()->new InputStream(){int calls;public int read(byte[] dst,int offset,int length){if(calls++==0)return 0;return -1;}public int read(){return calls++==1?42:-1;}},()->{});check(b.bytes[0]==42);
        System.out.println("BatchBuffer: "+checks+" checks passed; one source open, bounded reusable buffer, exact EOF and cancellation.");
    }
}
