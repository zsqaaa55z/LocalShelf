package local.shelf.sync;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.AtomicFile;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import android.security.keystore.*;
import org.json.*;

final class LocalState {
    static SharedPreferences prefs(Context c){return c.getSharedPreferences("sync",Context.MODE_PRIVATE);}
    static byte[] bounded(InputStream in,int max)throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buffer=new byte[65536];int n;
        while((n=in.read(buffer))!=-1){if(out.size()+n>max)throw new IOException("文件超过允许大小");out.write(buffer,0,n);}return out.toByteArray();
    }
    static synchronized void write(Context c,String name,byte[] bytes)throws IOException {
        AtomicFile file=new AtomicFile(new File(c.getNoBackupFilesDir(),name));FileOutputStream out=null;
        try{out=file.startWrite();out.write(bytes);file.finishWrite(out);}catch(IOException e){if(out!=null)file.failWrite(out);throw e;}
    }
    static synchronized JSONObject read(Context c,String name)throws Exception {
        try(InputStream in=new AtomicFile(new File(c.getNoBackupFilesDir(),name)).openRead()){return new JSONObject(new String(bounded(in,32*1024*1024),StandardCharsets.UTF_8));}
    }
    static void json(Context c,String name,JSONObject value)throws IOException{write(c,name,value.toString().getBytes(StandardCharsets.UTF_8));}
    static SecretKey key()throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);String alias="localshelf.sync.pairing";
        if(store.containsAlias(alias))return (SecretKey)store.getKey(alias,null);
        KeyGenerator gen=KeyGenerator.getInstance("AES","AndroidKeyStore");
        gen.init(new KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());return gen.generateKey();
    }
    static void savePairing(Context c,JSONObject value)throws Exception {
        Net.validate(value);Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
        ByteArrayOutputStream out=new ByteArrayOutputStream();out.write(cipher.getIV());out.write(cipher.doFinal(value.toString().getBytes(StandardCharsets.UTF_8)));write(c,"pairing.enc",out.toByteArray());
        ChangeSummaryStore.clear(c,"NAS 连接已更新，请导入最新 .db 后更新变化摘要。");
    }
    static JSONObject pairing(Context c)throws Exception {
        byte[] raw;try(InputStream in=new AtomicFile(new File(c.getNoBackupFilesDir(),"pairing.enc")).openRead()){raw=bounded(in,8192);}
        if(raw.length<29)throw new IOException("配对信息损坏，请重新导入");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,raw,0,12));
        JSONObject result=new JSONObject(new String(cipher.doFinal(raw,12,raw.length-12),StandardCharsets.UTF_8));Net.validate(result);return result;
    }
    interface PairingProbe {void verify(JSONObject candidate)throws Exception;}
    static void changeAddress(Context c,String address,PairingProbe probe)throws Exception {
        String normalized=NasAddress.normalize(address);
        JSONObject original=pairing(c),candidate=new JSONObject(original.toString());
        candidate.put("url",normalized);Net.validate(candidate);
        // The caller verifies HTTPS using the ORIGINAL pin and token before any write.
        probe.verify(new JSONObject(candidate.toString()));
        if(!pairing(c).toString().equals(original.toString()))throw new IOException("配对已变化，请重新打开地址设置");
        savePairing(c,candidate);
    }
    static void status(Context c,String value){prefs(c).edit().putString("status",value).putLong("statusTime",System.currentTimeMillis()).apply();}
    static String hex(byte[] data){char[] digits="0123456789abcdef".toCharArray(),out=new char[data.length*2];for(int i=0;i<data.length;i++){int v=data[i]&255;out[i*2]=digits[v>>>4];out[i*2+1]=digits[v&15];}return new String(out);}
}
