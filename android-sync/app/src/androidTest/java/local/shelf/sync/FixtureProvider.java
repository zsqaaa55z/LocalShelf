package local.shelf.sync;

import android.database.*;
import android.os.*;
import android.provider.DocumentsContract;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.net.Uri;
import java.io.*;
import java.util.*;

/** Exposes only synthetic fixtures in the TEST application's cache, never user storage. */
public final class FixtureProvider extends ContentProvider {
    static final String AUTH="local.shelf.sync.test.documents";
    File root;int largeCount=10000;long largeRoots,largeChildren,largeOpens;
    @Override public boolean onCreate(){root=new File(getContext().getCacheDir(),"synthetic-books");root.mkdirs();return true;}
    File file(String id)throws FileNotFoundException{try{File f=id.equals("root")?root:new File(root,id);if(!f.getCanonicalPath().startsWith(root.getCanonicalPath()+"/")&&!f.equals(root))throw new FileNotFoundException();return f;}catch(IOException e){throw new FileNotFoundException();}}
    String[] columns(String[] projection){return projection==null?new String[]{"document_id","_display_name","mime_type","_size","last_modified","flags"}:projection;}
    void add(MatrixCursor c,File f)throws FileNotFoundException{
        String id=f.equals(root)?"root":root.toPath().relativize(f.toPath()).toString();MatrixCursor.RowBuilder row=c.newRow();
        for(String col:c.getColumnNames())row.add(switch(col){case "document_id"->id;case "_display_name"->f.getName();case "mime_type"->f.isDirectory()?DocumentsContract.Document.MIME_TYPE_DIR:"application/octet-stream";case "_size"->f.length();case "last_modified"->f.lastModified();case "flags"->0;default->null;});
    }
    public Cursor queryDocument(String id,String[] projection)throws FileNotFoundException{MatrixCursor c=new MatrixCursor(columns(projection));File f=file(id);if(!f.exists())throw new FileNotFoundException();add(c,f);return c;}
    public Cursor queryChildDocuments(String parent,String[] projection,String sort)throws FileNotFoundException{MatrixCursor c=new MatrixCursor(columns(projection));File[] children=file(parent).listFiles();if(children!=null){Arrays.sort(children,Comparator.comparing(File::getName).reversed());for(File f:children)add(c,f);}return c;}
    Cursor largeQuery(String id,String[] projection,boolean children){
        MatrixCursor out=new MatrixCursor(columns(projection));
        if(children&&id.equals("large")){largeRoots++;for(int i=1;i<=largeCount;i++)largeRow(out,"large/"+i,i+"-synthetic",true);}
        else if(children){largeChildren++;for(int i=0;i<100;i++){String name=String.format(java.util.Locale.ROOT,"%08d.jpg",i);largeRow(out,id+"/"+name,name,false);}}
        else largeRow(out,id,id.substring(id.lastIndexOf('/')+1),!id.endsWith(".jpg"));
        return out;
    }
    void largeRow(MatrixCursor out,String id,String name,boolean dir){MatrixCursor.RowBuilder row=out.newRow();for(String col:out.getColumnNames())row.add(switch(col){case "document_id"->id;case "_display_name"->name;case "mime_type"->dir?DocumentsContract.Document.MIME_TYPE_DIR:"image/jpeg";case "_size"->dir?0:1;case "last_modified"->1000;case "flags"->0;default->null;});}
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort){try{String doc=DocumentsContract.getDocumentId(uri);if(doc.equals("large")||doc.startsWith("large/"))return largeQuery(doc,projection,uri.getLastPathSegment().equals("children"));return uri.getLastPathSegment().equals("children")?queryChildDocuments(DocumentsContract.getDocumentId(uri),projection,sort):queryDocument(DocumentsContract.getDocumentId(uri),projection);}catch(FileNotFoundException e){return null;}}
    @Override public String getType(Uri uri){return "application/octet-stream";}
    @Override public Uri insert(Uri uri,ContentValues values){throw new UnsupportedOperationException();}
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException();}
    @Override public int delete(Uri uri,String selection,String[] args){throw new UnsupportedOperationException();}
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{if(!mode.equals("r"))throw new FileNotFoundException("read only");if(DocumentsContract.getDocumentId(uri).startsWith("large/")){largeOpens++;try{ParcelFileDescriptor[] pipe=ParcelFileDescriptor.createPipe();try(OutputStream out=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])){out.write(1);}return pipe[0];}catch(IOException e){throw new FileNotFoundException();}}return ParcelFileDescriptor.open(file(DocumentsContract.getDocumentId(uri)),ParcelFileDescriptor.MODE_READ_ONLY);}
    @Override public Bundle call(String method,String arg,Bundle extras){
        if(method.startsWith("large-")){
            if(method.equals("large-setup")){largeCount=10000;getContext().grantUriPermission("local.shelf.sync",DocumentsContract.buildTreeDocumentUri(AUTH,"large"),android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION|android.content.Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);}
            if(method.equals("large-add-book"))largeCount=10001;
            Bundle result=new Bundle();result.putLong("rootQueries",largeRoots);result.putLong("bookQueries",largeChildren);result.putLong("fileOpens",largeOpens);
            if(method.equals("large-reset")||method.equals("large-setup")){largeRoots=0;largeChildren=0;largeOpens=0;}
            return result;
        }
        if(method.equals("fixture-soak")||method.equals("fixture-probe")){try{try(FileOutputStream out=new FileOutputStream(new File(root,"7-漫画/00000001.jpg"))){byte[] block=new byte[1024*1024];for(int i=0;i<block.length;i++)block[i]=(byte)(i%251);for(int i=0;i<(method.equals("fixture-probe")?12:256);i++)out.write(block);}return new Bundle();}catch(IOException e){throw new IllegalStateException(e);}}
        if(method.equals("fixture-root")){try{new File(root,".nomedia").createNewFile();return new Bundle();}catch(IOException e){throw new IllegalStateException(e);}}
        if(method.equals("fixture-add-page")){try{try(FileOutputStream out=new FileOutputStream(new File(root,"7-漫画/00000002.jpg"))){out.write("synthetic added page".getBytes());}return new Bundle();}catch(IOException e){throw new IllegalStateException(e);}}
        if(method.equals("fixture-setup")){try{File added=new File(root,"7-漫画/00000002.jpg");if(added.exists()&&!added.delete())throw new IOException("Cannot reset synthetic added page");for(String id:new String[]{"7","3","9","11","99"}){File d=new File(root,id+"-漫画");d.mkdirs();try(FileOutputStream out=new FileOutputStream(new File(d,"00000001.jpg"))){byte[] data=new byte[id.equals("7")?6*1024*1024:20000];for(int i=0;i<data.length;i++)data[i]=(byte)(i%251);out.write(data);}try(FileOutputStream out=new FileOutputStream(new File(d,".thumb"))){out.write("synthetic thumb".getBytes());}}getContext().grantUriPermission("local.shelf.sync",DocumentsContract.buildTreeDocumentUri(AUTH,"root"),android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION|android.content.Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);return new Bundle();}catch(IOException e){throw new IllegalStateException(e);}}
        return super.call(method,arg,extras);
    }
}
