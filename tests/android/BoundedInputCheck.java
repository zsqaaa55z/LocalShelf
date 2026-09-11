package local.shelf;
import java.io.*;
import java.util.Arrays;

public class BoundedInputCheck {
    static int count;
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);count++;System.out.println("PASS "+message);}
    public static void main(String[] args)throws Exception {
        byte[] bytes={1,2,3};
        check(Arrays.equals(BoundedInput.read(new ByteArrayInputStream(bytes),10),bytes),"short input stops at EOF");
        ByteArrayInputStream stream=new ByteArrayInputStream(bytes);
        check(Arrays.equals(BoundedInput.read(stream,2),new byte[]{1,2})&&stream.read()==3,"limit does not consume extra bytes");
        check(BoundedInput.read(new ByteArrayInputStream(bytes),0).length==0,"zero limit returns empty data");
        InputStream zeroRead=new ByteArrayInputStream(bytes){public int read(byte[] b,int off,int len){return 0;}};
        check(Arrays.equals(BoundedInput.read(zeroRead,3),bytes),"zero-byte reads cannot cause infinite loop");
        byte[] large=new byte[20000];Arrays.fill(large,(byte)7);
        check(Arrays.equals(BoundedInput.read(new ByteArrayInputStream(large),20000),large),"chunk boundaries preserve exact data");
        try{BoundedInput.read(new ByteArrayInputStream(bytes),-1);throw new AssertionError();}catch(IllegalArgumentException expected){check(true,"negative limit rejected");}
        System.out.println(count+" bounded read checks passed");
    }
}
