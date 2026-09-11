package local.shelf;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

final class PairingIdentity {
    final String id,token;
    PairingIdentity(String id,String token){
        if(!id.matches("[a-f0-9]{32}")||!token.matches("[A-Za-z0-9_-]{32}"))throw new IllegalArgumentException("invalid pairing");
        this.id=id;this.token=token;
    }
    static PairingIdentity create(){byte[] bytes=new byte[24];new SecureRandom().nextBytes(bytes);return new PairingIdentity(UUID.randomUUID().toString().replace("-",""),Base64.getUrlEncoder().withoutPadding().encodeToString(bytes));}
    String proof(String nonce)throws Exception{
        if(!nonce.matches("[a-f0-9]{64}"))throw new IllegalArgumentException("invalid challenge");
        Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(token.getBytes(StandardCharsets.UTF_8),"HmacSHA256"));
        byte[] digest=mac.doFinal(("localshelf-server-v2\n"+id+"\n"+nonce).getBytes(StandardCharsets.UTF_8));
        StringBuilder hex=new StringBuilder();for(byte b:digest)hex.append(String.format(Locale.ROOT,"%02x",b&255));return hex.toString();
    }
}
