package local.shelf;

import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.function.LongSupplier;
import java.util.zip.CRC32;

/** Disposable private metadata only. No image bytes, credentials or imported DB. */
final class IndexStore {
    record Location(String name,String mime,String documentId){}
    private record FileInfo(long bytes,long used){}
    static final int MAX_FILE=4*1024*1024;
    private final File root;
    private final long budget;
    private final LongSupplier clock;
    private final Map<String,FileInfo> files=new HashMap<>();
    private boolean prepared;
    private long bytes,epoch;
    IndexStore(File root){this(root,32L*1024*1024,System::currentTimeMillis);}
    IndexStore(File root,long budget,LongSupplier clock){this.root=root;this.budget=budget;this.clock=clock;}
    static String key(String scope)throws Exception {
        byte[] hash=MessageDigest.getInstance("SHA-256").digest(scope.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        StringBuilder result=new StringBuilder();for(byte b:hash)result.append(String.format(Locale.ROOT,"%02x",b&255));return result.toString();
    }
    private File file(String key)throws IOException{if(!key.matches("[a-f0-9]{64}"))throw new IOException("index key");return new File(root,key+".idx");}
    private void prepare()throws IOException {
        if(prepared)return;if(!root.isDirectory()&&!root.mkdirs())throw new IOException("index directory");
        File[] entries=root.listFiles();if(entries==null)throw new IOException("index directory");
        for(File f:entries){
          if(f.getName().matches("index-[0-9]+\\.tmp")){Files.deleteIfExists(f.toPath());continue;}
          if(f.getName().matches("[a-f0-9]{64}\\.idx") && !Files.isSymbolicLink(f.toPath()) && f.isFile()){
            String key=f.getName().substring(0,64);long size=f.length();files.put(key,new FileInfo(size,f.lastModified()));bytes+=size;
          }
        }
        prepared=true;trim(budget);
    }
    synchronized long ticket(){return epoch;}
    synchronized void cancelPendingWrites(){epoch++;}
    synchronized long bytes()throws IOException{prepare();return bytes;}
    synchronized List<Location> read(String key,long maxAge,long emptyAge)throws IOException {
        prepare();File path=file(key);
        if(!files.containsKey(key))return null;
        try{
            long length=path.length();if(length<24||length>MAX_FILE||Files.isSymbolicLink(path.toPath()))throw new IOException("index size");
            byte[] data=new byte[(int)length];try(DataInputStream input=new DataInputStream(new FileInputStream(path))){input.readFully(data);if(input.read()!=-1)throw new IOException("index changed");}
            if(data.length!=length)throw new IOException("index changed");
            CRC32 crc=new CRC32();crc.update(data,0,data.length-8);
            try(DataInputStream in=new DataInputStream(new ByteArrayInputStream(data))){
                if(in.readInt()!=0x4c534931)throw new IOException("index version");
                long written=in.readLong();int count=in.readInt();if(count<0||count>100000)throw new IOException("index count");
                long age=clock.getAsLong()-written;if(age<0||age>=(count==0?Math.min(maxAge,emptyAge):maxAge))throw new IOException("index expired");
                List<Location> list=new ArrayList<>();Set<String> names=new HashSet<>();
                for(int i=0;i<count;i++){
                    Location item=new Location(in.readUTF(),in.readUTF(),in.readUTF());validate(item);
                    if(!names.add(item.name))throw new IOException("duplicate index name");list.add(item);
                }
                if(in.readLong()!=crc.getValue()||in.available()!=0)throw new IOException("index checksum");
                files.put(key,new FileInfo(length,clock.getAsLong()));return Collections.unmodifiableList(list);
            }
        }catch(IOException|RuntimeException bad){removeFile(key);return null;}
    }
    private static void validate(Location value)throws IOException{
        if(value.name==null||value.name.isEmpty()||value.name.length()>512||value.name.contains("/")||value.name.contains("\\")||value.mime==null||value.mime.length()>256||value.documentId==null||value.documentId.isEmpty()||value.documentId.length()>16000)throw new IOException("index field");
    }
    synchronized void write(String key,List<Location> entries,long ticket)throws IOException {
        if(ticket!=epoch||entries.size()>100000)return;prepare();file(key);
        ByteArrayOutputStream buffer=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(buffer);
        out.writeInt(0x4c534931);out.writeLong(clock.getAsLong());out.writeInt(entries.size());
        Set<String> names=new HashSet<>();
        for(Location item:entries){validate(item);if(!names.add(item.name))throw new IOException("duplicate index name");out.writeUTF(item.name);out.writeUTF(item.mime);out.writeUTF(item.documentId);if(buffer.size()>MAX_FILE-8)return;}
        out.flush();CRC32 crc=new CRC32();crc.update(buffer.toByteArray());out.writeLong(crc.getValue());out.flush();byte[] data=buffer.toByteArray();
        if(data.length>budget||data.length>MAX_FILE)return;
        removeFile(key);trim(budget-data.length);
        File temp=File.createTempFile("index-", ".tmp",root);
        try{
            try(FileOutputStream stream=new FileOutputStream(temp)){stream.write(data);stream.getFD().sync();}
            Files.move(temp.toPath(),file(key).toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
            files.put(key,new FileInfo(data.length,clock.getAsLong()));bytes+=data.length;
        }finally{Files.deleteIfExists(temp.toPath());}
    }
    private void trim(long target)throws IOException {
        if(bytes<=target&&files.size()<20000)return;
        List<String> order=new ArrayList<>(files.keySet());order.sort(Comparator.comparingLong(k->files.get(k).used));
        for(String key:order){if(bytes<=target&&files.size()<20000)break;removeFile(key);}
    }
    private void removeFile(String key)throws IOException {
        Files.deleteIfExists(file(key).toPath());FileInfo old=files.remove(key);if(old!=null)bytes-=old.bytes;
    }
    synchronized void invalidate(String key)throws IOException{prepare();epoch++;removeFile(key);}
    synchronized void clear()throws IOException{prepare();epoch++;for(String key:new ArrayList<>(files.keySet()))removeFile(key);}
}
