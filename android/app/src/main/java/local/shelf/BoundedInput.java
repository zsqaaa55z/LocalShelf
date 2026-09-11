package local.shelf;
import java.io.*;

/** API 29-compatible bounded read. Caller retains ownership of the stream. */
final class BoundedInput {
    static byte[] read(InputStream input,int limit)throws IOException {
        if(limit<0)throw new IllegalArgumentException("negative limit");
        ByteArrayOutputStream output=new ByteArrayOutputStream(Math.min(limit,8192));
        byte[] buffer=new byte[Math.min(limit,8192)];int remaining=limit;
        while(remaining>0){
            int count=input.read(buffer,0,Math.min(buffer.length,remaining));
            if(count<0)break;
            if(count==0){int value=input.read();if(value<0)break;output.write(value);remaining--;}
            else{output.write(buffer,0,count);remaining-=count;}
        }
        return output.toByteArray();
    }
}
