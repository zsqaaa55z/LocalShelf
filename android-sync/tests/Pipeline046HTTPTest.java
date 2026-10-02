package local.shelf.sync;

import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.*;
import javax.net.ssl.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.regex.*;

/** Production Java schedulers -> frozen receiver over pinned loopback TLS.
 * Synthetic test transport only; Android Net/Wi-Fi binding is not emulated.
 */
public class Pipeline046HTTPTest {
    static String base,token,pin,revision;static SSLSocketFactory sockets;static Path root;
    static final int CHUNK=4*1024*1024;
    static String quote(String s){if(!s.matches("[a-zA-Z0-9_.-]+"))throw new IllegalArgumentException();return "\""+s+"\"";}
    static long number(String json,String key){var m=Pattern.compile("\""+key+"\"\\s*:\\s*(\\d+)").matcher(json);if(!m.find())throw new AssertionError("missing number "+key);return Long.parseLong(m.group(1));}
    static String string(String json,String key){var m=Pattern.compile("\""+key+"\"\\s*:\\s*\"([^\"]+)\"").matcher(json);if(!m.find())throw new AssertionError("missing string "+key);return m.group(1);}
    static byte[] json(String s){return s.getBytes(StandardCharsets.UTF_8);}
    static final class Client implements AutoCloseable {
        volatile HttpsURLConnection active;
        String post(String route,byte[]... parts)throws Exception{
            HttpsURLConnection conn=(HttpsURLConnection)new URL(base+"/sync/v1/"+route).openConnection(Proxy.NO_PROXY);active=conn;
            conn.setSSLSocketFactory(sockets);conn.setHostnameVerifier((host,session)->host.equals("127.0.0.1"));
            conn.setConnectTimeout(5000);conn.setReadTimeout(10000);conn.setInstanceFollowRedirects(false);
            conn.setRequestMethod("POST");conn.setRequestProperty("Authorization","Bearer "+token);conn.setDoOutput(true);
            int size=0;for(byte[] part:parts)size+=part.length;conn.setFixedLengthStreamingMode(size);
            try(OutputStream out=conn.getOutputStream()){for(byte[] part:parts)out.write(part);}
            int code=conn.getResponseCode();String response;
            try(InputStream in=code==200?conn.getInputStream():conn.getErrorStream()){response=new String(in.readAllBytes(),StandardCharsets.UTF_8);}
            if(code!=200)throw new IOException("HTTP "+code+" "+response);return response;
        }
        // Send the exact owned slice without copying a whole batch.
        String batch(byte[] header,byte[] bytes,int used)throws Exception{
            HttpsURLConnection conn=(HttpsURLConnection)new URL(base+"/sync/v1/files/batch").openConnection(Proxy.NO_PROXY);active=conn;
            conn.setSSLSocketFactory(sockets);conn.setHostnameVerifier((host,session)->host.equals("127.0.0.1"));
            conn.setConnectTimeout(5000);conn.setReadTimeout(10000);conn.setInstanceFollowRedirects(false);
            conn.setRequestMethod("POST");conn.setRequestProperty("Authorization","Bearer "+token);conn.setDoOutput(true);
            conn.setFixedLengthStreamingMode(4+header.length+used);
            try(DataOutputStream out=new DataOutputStream(conn.getOutputStream())){out.writeInt(header.length);out.write(header);out.write(bytes,0,used);}
            int code=conn.getResponseCode();String response;try(InputStream in=code==200?conn.getInputStream():conn.getErrorStream()){response=new String(in.readAllBytes(),StandardCharsets.UTF_8);}
            if(code!=200)throw new IOException("HTTP "+code+" "+response);return response;
        }
        public void close(){if(active!=null)active.disconnect();}
    }
    record Item(Path path,long size){}
    record Hashed(Item item,String sha){}
    static List<Item> source(String folder)throws Exception{
        List<Item> files=new ArrayList<>();try(var list=Files.list(root.resolve(folder))){for(Path p:list.sorted().toList())files.add(new Item(p,Files.size(p)));}return files;
    }
    static String spec(Item item,String sha){return "{\"path\":"+quote(item.path.getFileName().toString())+",\"size\":"+item.size+",\"sha256\":"+quote(sha)+"}";}
    static String payload(String gid,List<String> specs){return "{\"revision\":"+quote(revision)+",\"gid\":"+quote(gid)+",\"files\":["+String.join(",",specs)+"]}";}
    static void small()throws Exception{
        List<Item> items=source("small");Map<String,String> inventory=new HashMap<>();Thread owner=Thread.currentThread();
        ConcurrentLinkedQueue<Client> clients=new ConcurrentLinkedQueue<>();ThreadLocal<Client> local=ThreadLocal.withInitial(()->{Client client=new Client();clients.add(client);return client;});
        AtomicBoolean dropped=new AtomicBoolean();
        new ReadPipeline<>(items,4,Item::size,()->new ReadPipeline.Worker<Item>(){
            public String read(Item item,byte[] buffer,int offset,ReadPipeline.Check stop)throws Exception{return FileRead.into(item.size,buffer,offset,()->Files.newInputStream(item.path),stop::check,m->{});}
            public void cancel(){}public void close(){}
        },new ReadPipeline.Sink<Item>(){
            public void send(ReadPipeline.Frame<Item> f,ReadPipeline.Check stop)throws Exception{
                List<String> specs=new ArrayList<>();for(int i=0;i<f.items.size();i++)specs.add(spec(f.items.get(i),f.hashes[i]));byte[] header=json(payload("7",specs));
                String reply=local.get().batch(header,f.bytes,f.used);
                // Deliberately ignore one durable ACK, replay exactly the same buffer.
                if(dropped.compareAndSet(false,true))reply=local.get().batch(header,f.bytes,f.used);
                if(number(reply,"confirmedFiles")!=f.items.size()||number(reply,"confirmedBytes")!=f.used)throw new AssertionError("batch receipt mismatch");
            }
            public void acknowledge(ReadPipeline.Frame<Item> f){if(Thread.currentThread()!=owner)throw new AssertionError("owner");for(int i=0;i<f.items.size();i++)inventory.put(f.items.get(i).path.toString(),f.hashes[i]);}
            public void abort(){for(Client c:clients)c.close();}public void close(){abort();}
        },()->{},t->{},new ReadPipeline.Buffers(),2).run();
        List<String> specs=new ArrayList<>();for(Item item:items)specs.add(spec(item,Objects.requireNonNull(inventory.get(item.path.toString()))));
        try(Client c=new Client()){String reply=c.post("book/commit",json(payload("7",specs)));if(number(reply,"verifiedFiles")!=items.size())throw new AssertionError();}
        System.out.println("PASS Java dual small batches + lost ACK replay + original inventory; files="+items.size());
    }
    static void large()throws Exception{
        List<Item> items=source("large");Map<String,String> inventory=new HashMap<>();
        new PreparedPipeline<Item,Hashed>(items,2,new PreparedPipeline.Prepare<>(){
            final byte[] buffer=new byte[256*1024];
            public Hashed prepare(Item item,ReadPipeline.Check stop)throws Exception{
                var hash=MessageDigest.getInstance("SHA-256");try(InputStream in=Files.newInputStream(item.path)){int n;while((n=in.read(buffer))!=-1){stop.check();hash.update(buffer,0,n);}}
                return new Hashed(item,HexFormat.of().formatHex(hash.digest()));
            }
            public void cancel(){}public void close(){}
        },()->new PreparedPipeline.Worker<Hashed>(){
            final Client client=new Client();final byte[] buffer=new byte[CHUNK];
            public void send(Hashed value,ReadPipeline.Check stop)throws Exception{
                Item item=value.item;String details=spec(item,value.sha);String full=details.substring(0,details.length()-1)+",\"revision\":"+quote(revision)+",\"gid\":\"3\"}";
                String begin=client.post("file/begin",json(full));if(begin.contains("\"done\":true"))return;
                String id=string(begin,"upload");long offset=number(begin,"offset");
                try(InputStream in=Files.newInputStream(item.path)){in.skipNBytes(offset);while(offset<item.size){stop.check();int count=(int)Math.min(CHUNK,item.size-offset);new DataInputStream(in).readFully(buffer,0,count);
                    // Only the final short 1 MiB tail is copied in this test transport.
                    String reply=client.post("file/chunk?upload="+id+"&offset="+offset,count==buffer.length?buffer:Arrays.copyOf(buffer,count));
                    offset+=count;if(number(reply,"offset")!=offset)throw new AssertionError();}}
                client.post("file/finish",json("{\"upload\":"+quote(id)+"}"));
            }
            public void cancel(){client.close();}public void close(){client.close();}
        },item->inventory.put(item.item.path.toString(),item.sha),()->{}).run();
        List<String> specs=new ArrayList<>();for(Item item:items)specs.add(spec(item,Objects.requireNonNull(inventory.get(item.path.toString()))));
        try(Client c=new Client()){String reply=c.post("book/commit",json(payload("3",specs)));if(number(reply,"verifiedFiles")!=items.size())throw new AssertionError();}
        System.out.println("PASS Java bounded large prehash/upload + receiver resumed chunk; files="+items.size());
    }
    public static void main(String[] args)throws Exception{
        base=args[0];token=args[1];pin=args[2];revision=args[3];root=Path.of(args[4]);
        if(!new URI(base).getHost().equals("127.0.0.1"))throw new IllegalArgumentException("Loopback synthetic fixtures only");
        X509TrustManager trust=new X509TrustManager(){
            public X509Certificate[] getAcceptedIssuers(){return new X509Certificate[0];}
            public void checkClientTrusted(X509Certificate[] cert,String type)throws CertificateException{throw new CertificateException();}
            public void checkServerTrusted(X509Certificate[] chain,String type)throws CertificateException{try{if(chain.length==0||!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded())).equals(pin))throw new CertificateException("pin mismatch");chain[0].checkValidity();}catch(GeneralSecurityException e){throw new CertificateException(e);}}
        };
        SSLContext ssl=SSLContext.getInstance("TLS");ssl.init(null,new TrustManager[]{trust},new SecureRandom());sockets=ssl.getSocketFactory();
        small();large();try(Client c=new Client()){c.post("book/commit",json(payload("9",List.of())));c.post("catalog/commit",json("{\"revision\":"+quote(revision)+"}"));}
    }
}
