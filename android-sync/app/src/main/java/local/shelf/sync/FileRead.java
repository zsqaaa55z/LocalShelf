package local.shelf.sync;

import java.io.*;
import java.security.MessageDigest;

/** Exact-length single-pass read with separately measured open/read/hash/close. */
final class FileRead {
    interface Opener {InputStream open()throws Exception;}
    interface Check {void check()throws Exception;}
    interface Observer {void measured(Metrics metrics);}
    record Metrics(long total,long open,long read,long hash,long close,long bytes,boolean complete){}
    static String into(long length,byte[] buffer,int offset,Opener opener,Check cancel,Observer observer)throws Exception {
        if(length<0||length>BatchBuffer.MAX_FILE||offset<0||length>buffer.length-offset)throw new IOException("读取范围无效");
        long began=System.nanoTime(),opened=0,readTime=0,hashTime=0,closed=0,bytes=0;boolean complete=false;
        MessageDigest digest=MessageDigest.getInstance("SHA-256");InputStream in=null;
        try{
            cancel.check();long tick=System.nanoTime();
            try{in=opener.open();if(in==null)throw new IOException("源文件不可读");}finally{opened+=System.nanoTime()-tick;}
            while(bytes<length){
                cancel.check();int at=offset+(int)bytes,n;tick=System.nanoTime();
                try{n=in.read(buffer,at,(int)Math.min(256*1024,length-bytes));if(n==0){int one=in.read();if(one<0)n=-1;else{buffer[at]=(byte)one;n=1;}}}finally{readTime+=System.nanoTime()-tick;}
                if(n<0)throw new EOFException("源文件变短，请等待下载完成");
                tick=System.nanoTime();digest.update(buffer,at,n);hashTime+=System.nanoTime()-tick;bytes+=n;
            }
            cancel.check();tick=System.nanoTime();int extra;
            try{extra=in.read();}finally{readTime+=System.nanoTime()-tick;}
            if(extra!=-1)throw new IOException("源文件正在增长，请等待下载完成");
            tick=System.nanoTime();byte[] hash=digest.digest();hashTime+=System.nanoTime()-tick;
            StringBuilder result=new StringBuilder(64);for(byte value:hash)result.append(Character.forDigit((value>>>4)&15,16)).append(Character.forDigit(value&15,16));
            complete=true;return result.toString();
        }finally{
            try{if(in!=null){long tick=System.nanoTime();try{in.close();}catch(Exception e){complete=false;throw e;}finally{closed=System.nanoTime()-tick;}}}
            finally{observer.measured(new Metrics(System.nanoTime()-began,opened,readTime,hashTime,closed,bytes,complete));}
        }
    }
}
