package local.shelf.sync;

import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.security.*;
import java.security.cert.*;
import java.util.*;
import java.util.concurrent.atomic.*;
import javax.net.ssl.*;

/** Actual recovery loop + actual durable receiver. HTTP adapter is JDK, NOT Android Net. */
public final class Recovery047HTTPTest extends Pipeline046HTTPTest {
    static int checks;static void check(boolean value){checks++;if(!value)throw new AssertionError();}
    static class NoDelay implements RecoveryLoop.Control {
        int waits;boolean stopped;
        public void check()throws Exception{if(stopped)throw new InterruptedIOException();}
        public void waiting(int attempt,long delay){waits++;}
        public void sleep(long millis){}
        public void recovered(){}
    }
    static void configure(String[] args)throws Exception{
        base=args[0];token=args[1];pin=args[2];revision=args[3];root=Path.of(args[4]);
        if(!new URI(base).getHost().equals("127.0.0.1"))throw new IllegalArgumentException("synthetic loopback only");
        X509TrustManager trust=new X509TrustManager(){
            public X509Certificate[] getAcceptedIssuers(){return new X509Certificate[0];}
            public void checkClientTrusted(X509Certificate[] c,String t)throws CertificateException{throw new CertificateException();}
            public void checkServerTrusted(X509Certificate[] c,String t)throws CertificateException{
                try{if(c.length==0||!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(c[0].getEncoded())).equals(pin))throw new CertificateException("wrong pin");c[0].checkValidity();}
                catch(GeneralSecurityException e){throw new CertificateException(e);}
            }
        };
        SSLContext context=SSLContext.getInstance("TLS");context.init(null,new TrustManager[]{trust},new SecureRandom());sockets=context.getSocketFactory();
    }
    static void smallReplay()throws Exception{
        var items=source("small");List<String> specs=new ArrayList<>();byte[] payload=new byte[2*1024*1024];int size=0;
        for(var item:items){byte[] file=Files.readAllBytes(item.path());System.arraycopy(file,0,payload,size,file.length);size+=file.length;specs.add(spec(item,HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(file))));}
        final int used=size;byte[] header=json(payload("7",specs));AtomicInteger attempts=new AtomicInteger();NoDelay wait=new NoDelay();
        try(Client client=new Client()){
            String reply=RecoveryLoop.run(true,()->{
                int attempt=attempts.incrementAndGet();
                if(attempt==1)throw new RecoveryLoop.Temporary("synthetic outage before sending",new ConnectException());
                String response=client.batch(header,payload,used);
                if(attempt==2)throw new RecoveryLoop.Temporary("synthetic lost durable ACK",new EOFException());
                return response;
            },wait);
            check(number(reply,"confirmedFiles")==items.size());check(number(reply,"confirmedBytes")==used);
            check(attempts.get()==3&&wait.waits==2);
            client.post("book/commit",json(payload("7",specs)));
        }
        System.out.println("PASS recovery: temporary outage + lost durable batch ACK replays same buffer; exact receiver receipt");
    }
    static void chunkReplay()throws Exception{
        var item=source("large").get(0);String sha=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(item.path())));
        String details=spec(item,sha),full=details.substring(0,details.length()-1)+",\"revision\":"+quote(revision)+",\"gid\":\"3\"}";
        try(Client client=new Client()){
            String begin=client.post("file/begin",json(full));String id=string(begin,"upload");
            byte[] first=Arrays.copyOf(Files.readAllBytes(item.path()),CHUNK);AtomicInteger attempts=new AtomicInteger();NoDelay wait=new NoDelay();
            try{
                RecoveryLoop.run(true,()->{
                    String reply=client.post("file/chunk?upload="+id+"&offset=0",first);
                    if(attempts.incrementAndGet()==1)throw new RecoveryLoop.Temporary("lost chunk ACK",new EOFException());
                    return reply;
                },wait);
                throw new AssertionError("receiver must reject old offset replay");
            }catch(IOException expected){check(expected.getMessage().contains("offset_conflict"));}
            String resumed=client.post("file/begin",json(full));long offset=number(resumed,"offset");check(offset==CHUNK);
            try(InputStream in=Files.newInputStream(item.path())){in.skipNBytes(offset);while(offset<item.size()){
                byte[] bytes=in.readNBytes((int)Math.min(CHUNK,item.size()-offset));String reply=client.post("file/chunk?upload="+id+"&offset="+offset,bytes);offset+=bytes.length;check(number(reply,"offset")==offset);
            }}
            client.post("file/finish",json("{\"upload\":"+quote(id)+"}"));
            check(client.post("file/begin",json(full)).contains("\"done\":true"));
            client.post("book/commit",json(payload("3",List.of(details))));
        }
        System.out.println("PASS recovery: lost chunk ACK -> offset conflict -> authoritative resume; no duplicated bytes");
    }
    public static void main(String[] args)throws Exception {
        configure(args);smallReplay();chunkReplay();
        try(Client client=new Client()){
            client.post("book/commit",json(payload("9",List.of())));
            byte[] publication=json("{\"revision\":"+quote(revision)+"}");AtomicBoolean dropped=new AtomicBoolean();NoDelay wait=new NoDelay();
            String reply=RecoveryLoop.run(true,()->{String result=client.post("catalog/commit",publication);if(!dropped.getAndSet(true))throw new RecoveryLoop.Temporary("lost publication ACK",new EOFException());return result;},wait);
            check(reply.contains("orderSha256")&&wait.waits==1);
        }
        System.out.println("PASS recovery: publish response replay idempotent; "+checks+" network assertions");
    }
}
