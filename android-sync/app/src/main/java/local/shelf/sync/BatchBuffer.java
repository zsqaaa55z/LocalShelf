package local.shelf.sync;

import java.io.*;
import java.security.MessageDigest;

/** One bounded allocation, reused after each durable batch acknowledgement. */
final class BatchBuffer {
    static final int MAX_FILES=64, MAX_FILE=4*1024*1024, MAX_BYTES=16*1024*1024;
    interface Opener {InputStream open()throws Exception;}
    interface Check {void check()throws Exception;}
    final byte[] bytes=new byte[MAX_BYTES];
    int used, count;
    boolean fits(long size){return size>=0&&size<=MAX_FILE&&count<MAX_FILES&&size<=MAX_BYTES-used;}
    String add(long size,Opener opener,Check cancel)throws Exception {
        if(!fits(size))throw new IOException("批量缓冲区已满或文件过大");
        int length=(int)size, read=0;MessageDigest digest=MessageDigest.getInstance("SHA-256");
        try(InputStream in=opener.open()){
            if(in==null)throw new IOException("源文件不可读");
            while(read<length){
                cancel.check();int n=in.read(bytes,used+read,Math.min(256*1024,length-read));
                if(n<0)throw new EOFException("源文件变短，请等待下载完成");
                if(n==0){int value=in.read();if(value<0)throw new EOFException("源文件变短");bytes[used+read]=(byte)value;n=1;}
                digest.update(bytes,used+read,n);read+=n;
            }
            cancel.check();if(in.read()!=-1)throw new IOException("源文件正在增长，请等待下载完成");
        }
        // Commit only after exact EOF and successful close; failed adds are reusable.
        used+=length;count++;
        byte[] hash=digest.digest();StringBuilder out=new StringBuilder(64);
        for(byte value:hash)out.append(Character.forDigit((value>>>4)&15,16)).append(Character.forDigit(value&15,16));
        return out.toString();
    }
    void clear(){used=0;count=0;}
}
