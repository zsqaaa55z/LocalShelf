package local.shelf;

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.function.LongSupplier;

// Local UI opens a short-lived enrollment window. Never used as a bearer token.
final class PairingWindow {
    static final long TTL=5*60_000L;
    private final LongSupplier clock;
    private String code;
    private long created;
    private int attempts;
    PairingWindow(LongSupplier clock){this.clock=clock;renew();}
    synchronized void renew(){
        code=String.format(Locale.ROOT,"%06d",new SecureRandom().nextInt(1_000_000));
        created=clock.getAsLong();attempts=0;
    }
    private boolean active(){long age=clock.getAsLong()-created;return code!=null&&attempts<5&&age>=0&&age<TTL;}
    synchronized String display(){return active()?code:"已失效，请生成新码";}
    synchronized boolean exchange(String submitted){
        if(!active())return false;
        attempts++;
        if(submitted==null||!submitted.matches("[0-9]{6}"))return false;
        if(!MessageDigest.isEqual(code.getBytes(StandardCharsets.US_ASCII),submitted.getBytes(StandardCharsets.US_ASCII)))return false;
        code=null;return true; // single-use, including concurrent requests
    }
    synchronized void close(){code=null;}
}
