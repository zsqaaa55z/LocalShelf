package local.shelf;
import android.content.Context;
import android.security.keystore.*;
import android.util.AtomicFile;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** App-private, backup-excluded ciphertext; encryption key never leaves Android Keystore. */
final class PairingStore {
    private static final String ALIAS="localshelf.pairing.v2";
    private static SecretKey key()throws Exception{
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        if(store.containsAlias(ALIAS))return (SecretKey)store.getKey(ALIAS,null);
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());return generator.generateKey();
    }
    private static AtomicFile file(Context context){return new AtomicFile(new File(context.getNoBackupFilesDir(),"pairing.enc"));}
    static synchronized PairingIdentity load(Context context)throws Exception{
        AtomicFile file=file(context);
        byte[] bytes;try(InputStream in=file.openRead()){bytes=BoundedInput.read(in,1025);}
        catch(FileNotFoundException missing){
            if(file.getBaseFile().exists())throw missing;
            PairingIdentity fresh=PairingIdentity.create();save(context,fresh);return fresh;
        }
        if(bytes.length<29||bytes.length>1024)throw new IOException("配对存储损坏，请重置配对");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,bytes,0,12));
        String[] parts=new String(cipher.doFinal(bytes,12,bytes.length-12),StandardCharsets.UTF_8).split("\n",-1);
        if(parts.length!=2)throw new IOException("配对字段无效");return new PairingIdentity(parts[0],parts[1]);
    }
    private static void save(Context context,PairingIdentity value)throws Exception{
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
        AtomicFile file=file(context);FileOutputStream out=null;
        try{out=file.startWrite();out.write(cipher.getIV());out.write(cipher.doFinal((value.id+"\n"+value.token).getBytes(StandardCharsets.UTF_8)));file.finishWrite(out);}
        catch(Exception e){if(out!=null)file.failWrite(out);throw e;}
    }
    static synchronized void rotate(Context context)throws Exception{save(context,PairingIdentity.create());}
}
