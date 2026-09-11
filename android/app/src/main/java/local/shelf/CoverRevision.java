package local.shelf;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Metadata-only weak validators: never hash all image bytes or enumerate the library. */
final class CoverRevision {
    static String hash(String value) {
        try {
            byte[] digest=MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            char[] hex=new char[digest.length*2];String alphabet="0123456789abcdef";
            for(int i=0;i<digest.length;i++){int valueByte=digest[i]&255;hex[i*2]=alphabet.charAt(valueByte>>>4);hex[i*2+1]=alphabet.charAt(valueByte&15);}return new String(hex);
        } catch(Exception e){throw new IllegalStateException(e);}
    }
    static String library(String root){return hash("library-v2\n"+root);}
    static String book(String library,String id,String directory){return hash(library+"\n"+id+"\n"+directory);}
    static String etag(String identity,String document,long size,long modified){
        // Unknown metadata must never yield a false 304.
        return size>=0 && modified>0 ? "W/\""+hash(identity+"\n"+document+"\n"+size+"\n"+modified)+"\"" : null;
    }
    static boolean matches(String validator,String header){return validator!=null && validator.equals(header);}
}
