package local.shelf;
import fi.iki.elonen.NanoHTTPD;
import java.nio.charset.StandardCharsets;
import static fi.iki.elonen.NanoHTTPD.*;

final class PairingEndpoint {
    static Response serve(IHTTPSession s,PairingWindow pins,PairingIdentity identity){
        Response response;
        try{
            if(s.getMethod()!=Method.POST||s.getHeaders().containsKey("origin")||s.getHeaders().containsKey("transfer-encoding")||!"6".equals(s.getHeaders().get("content-length"))){
                response=fail(Response.Status.BAD_REQUEST,"pair_request");
            }else{
                byte[] body=new byte[6];int offset=0;
                while(offset<body.length){int read=s.getInputStream().read(body,offset,body.length-offset);if(read<0)break;offset+=read;}
                if(offset!=6||!pins.exchange(new String(body,StandardCharsets.US_ASCII)))response=fail(Response.Status.UNAUTHORIZED,"pair_code_expired_or_invalid");
                else response=newFixedLengthResponse(Response.Status.OK,"application/json","{\"app\":\"localshelf\",\"version\":2,\"deviceId\":\""+identity.id+"\",\"token\":\""+identity.token+"\"}");
            }
        }catch(Exception e){response=fail(Response.Status.BAD_REQUEST,"pair_request");}
        response.addHeader("Cache-Control","no-store");response.addHeader("X-Content-Type-Options","nosniff");response.closeConnection(true);return response;
    }
    private static Response fail(Response.Status status,String message){return newFixedLengthResponse(status,"application/json","{\"error\":\""+message+"\"}");}
}
