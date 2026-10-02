package local.shelf.sync;

import java.io.*;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;

/** Resolves only already-enumerated files; never lists or writes the source. */
final class DirectReadScope {
    static final class UnsafePathException extends IOException {
        UnsafePathException(){super("源文件路径异常，已停止读取；请重新检查目录");}
    }
    static final class SourceChangedException extends IOException {
        SourceChangedException(){super("源文件大小或修改时间变化，已停止读取；请暂停下载后重新检查");}
    }
    private final Path root;
    DirectReadScope(Path selectedRoot)throws IOException {
        root=selectedRoot.toAbsolutePath().normalize();
        // Android's /storage/emulated/0 may be a platform alias. Refuse symlinks
        // at the app-selected EhViewer/download levels, not system ancestors.
        requireDirectory(root.getParent());requireDirectory(root);
    }
    private static void requireDirectory(Path p)throws IOException {
        BasicFileAttributes a=Files.readAttributes(p,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
        if(a.isSymbolicLink()||!a.isDirectory())throw new UnsafePathException();
    }
    InputStream open(String relative,long expectedSize,long expectedModified)throws IOException {
        if(relative==null||relative.isEmpty()||relative.startsWith("/")||relative.indexOf('\\')>=0)throw new UnsafePathException();
        String[] parts=relative.split("/",-1);
        if(parts.length>18)throw new UnsafePathException();
        for(String part:parts){
            if(part.isEmpty()||part.equals(".")||part.equals(".."))throw new UnsafePathException();
            for(int i=0;i<part.length();i++)if(Character.isISOControl(part.charAt(i)))throw new UnsafePathException();
        }
        requireDirectory(root.getParent());requireDirectory(root);
        Path file=root;
        for(int i=0;i<parts.length;i++){
            file=file.resolve(parts[i]);
            if(i<parts.length-1)requireDirectory(file);
        }
        if(!file.normalize().startsWith(root)||!file.toRealPath().startsWith(root.toRealPath()))throw new UnsafePathException();
        BasicFileAttributes before=Files.readAttributes(file,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
        validate(before,expectedSize);validateModified(file,expectedModified);
        FileChannel channel=FileChannel.open(file,StandardOpenOption.READ,LinkOption.NOFOLLOW_LINKS);
        try{
            BasicFileAttributes after=Files.readAttributes(file,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
            validate(after,expectedSize);validateModified(file,expectedModified);
            if(channel.size()!=expectedSize||!java.util.Objects.equals(before.fileKey(),after.fileKey()))throw new SourceChangedException();
            return Channels.newInputStream(channel);
        }catch(IOException|RuntimeException e){try{channel.close();}catch(IOException close){e.addSuppressed(close);}throw e;}
    }
    private static void validate(BasicFileAttributes a,long size)throws IOException {
        if(a.isSymbolicLink()||!a.isRegularFile())throw new UnsafePathException();
        if(size<0||a.size()!=size)throw new SourceChangedException();
    }
    private static void validateModified(Path file,long expected)throws IOException {
        // On the tested Android runtime NIO BasicFileAttributes truncates mtime
        // to seconds, while the document provider / java.io.File retain millis.
        // Use the provider-compatible API, still comparing EXACT milliseconds.
        if(expected>0&&file.toFile().lastModified()!=expected)throw new SourceChangedException();
    }
}
