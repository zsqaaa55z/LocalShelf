import com.google.zxing.*;
import com.google.zxing.common.*;
import com.google.zxing.qrcode.*;

public class PairingQRCheck {
    public static void main(String[] args) throws Exception {
        String payload="{\"app\":\"localshelf\",\"version\":2,\"deviceId\":\"0123456789abcdef0123456789abcdef\",\"address\":\"http://192.168.240.2:8088\",\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\"}";
        BitMatrix matrix=new QRCodeWriter().encode(payload,BarcodeFormat.QR_CODE,720,720);
        int[] pixels=new int[720*720];
        for(int y=0;y<720;y++)for(int x=0;x<720;x++)pixels[y*720+x]=matrix.get(x,y)?0xff000000:0xffffffff;
        String decoded=new QRCodeReader().decode(new BinaryBitmap(new HybridBinarizer(new RGBLuminanceSource(720,720,pixels)))).getText();
        if(!payload.equals(decoded))throw new AssertionError("QR round trip mismatch");
        System.out.println("PASS synthetic pairing QR pixel encode/decode round trip");
    }
}
