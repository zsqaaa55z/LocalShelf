package local.shelf;
import fi.iki.elonen.NanoHTTPD;
import java.net.*;
import java.nio.charset.StandardCharsets;
public class PairingEndpointCheck {
    static int checks;
    static void check(boolean ok){if(!ok)throw new AssertionError("HTTP check "+(checks+1));checks++;}
    static int request(int port,String method,String data,boolean origin,boolean chunked)throws Exception{
        try(Socket socket=new Socket("127.0.0.1",port)){
            socket.setSoTimeout(3000);
            String header=method+" /v2/pair HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n";
            if(origin)header+="Origin: http://untrusted.example\r\n";
            if(data!=null)header+=chunked?"Transfer-Encoding: chunked\r\n":"Content-Length: "+data.length()+"\r\n";
            String body=data==null?"":chunked?Integer.toHexString(data.length())+"\r\n"+data+"\r\n0\r\n\r\n":data;
            socket.getOutputStream().write((header+"\r\n"+body).getBytes(StandardCharsets.US_ASCII));
            String response=new String(socket.getInputStream().readAllBytes(),StandardCharsets.UTF_8);
            int status=Integer.parseInt(response.split(" ")[1]);check(response.toLowerCase().contains("cache-control: no-store"));
            if(status==200)check(response.contains("\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\""));else check(!response.contains("token"));
            return status;
        }
    }
    public static void main(String[] args)throws Exception{
        PairingWindow pins=new PairingWindow(()->System.nanoTime()/1_000_000L);
        PairingIdentity identity=new PairingIdentity("0123456789abcdef0123456789abcdef","abcdefghijklmnopqrstuvwxyzABCDEF");
        NanoHTTPD server=new NanoHTTPD("127.0.0.1",0){public Response serve(IHTTPSession s){return PairingEndpoint.serve(s,pins,identity);}};
        server.start(3000,false);int port=server.getListeningPort();
        try{
            String code=pins.display();check(request(port,"GET",null,false,false)==400);
            check(request(port,"POST",code,true,false)==400);
            check(request(port,"POST","1234567",false,false)==400);
            check(request(port,"POST",code,false,true)==400);
            check(request(port,"POST",code,false,false)==200);
            check(request(port,"POST",code,false,false)==401);
            pins.renew();code=pins.display();String wrong=code.equals("000000")?"111111":"000000";
            for(int i=0;i<5;i++)check(request(port,"POST",wrong,false,false)==401);
            check(request(port,"POST",code,false,false)==401);
        }finally{server.stop();}
        System.out.println(checks+" real HTTP enrollment checks passed");
    }
}
