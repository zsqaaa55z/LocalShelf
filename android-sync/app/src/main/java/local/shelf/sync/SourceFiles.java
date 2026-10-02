package local.shelf.sync;

import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.DeadObjectException;
import android.os.ParcelFileDescriptor;
import android.os.Build;
import android.os.Environment;
import android.os.RemoteException;
import android.provider.DocumentsContract;
import java.io.*;
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;
import java.util.function.IntConsumer;

final class SourceFiles {
    record Doc(String id,String name,String mime,long size,long modified,Uri uri) {boolean isDirectory(){return DocumentsContract.Document.MIME_TYPE_DIR.equals(mime);}}
    record FileEntry(String path,Doc doc) {}
    private final ContentResolver resolver;private final Uri root;private final String rootId;
    private final ReadFallback reads;private DirectReadScope directScope;
    SourceFiles(Context c,Uri tree){this(c,tree,LocalState.prefs(c).getBoolean("directRead",true));}
    SourceFiles(Context c,Uri tree,boolean preferDirect){resolver=c.getContentResolver();root=tree;rootId=rootDocumentId(tree);reads=new ReadFallback(preferDirect,directPermission(),supportsDirect(tree));}
    static boolean directPermission(){try{return Build.VERSION.SDK_INT>=30&&Environment.isExternalStorageManager();}catch(SecurityException e){return false;}}
    static boolean supportsDirect(Uri tree){try{return tree!=null&&"com.android.externalstorage.documents".equals(tree.getAuthority())&&"primary:EhViewer/download".equals(rootDocumentId(tree));}catch(IllegalArgumentException e){return false;}}
    static String directSetting(Context c){
        var p=LocalState.prefs(c);if(!p.getBoolean("directRead",true))return "直读已关闭 · 使用原方式（SAF）";
        String tree=p.getString("tree","");if(tree.isBlank())return "优先直读已开启 · 请先授权下载目录";
        if(!supportsDirect(Uri.parse(tree)))return "当前目录不支持直读 · 自动使用原方式（SAF）";
        if(!directPermission())return "优先直读已开启，但尚未授权 · 当前使用原方式（SAF）";
        return "直读已授权 · 下次任务优先直读；打开失败自动回退。实际打开次数见同步进度。";
    }
    String readDescription(){return reads.description();}
    private synchronized DirectReadScope directScope()throws IOException {
        if(directScope==null)directScope=new DirectReadScope(Paths.get("/storage/emulated/0/EhViewer/download"));return directScope;
    }
    private InputStream openDirect(Doc doc)throws IOException {
        if(!Objects.equals(doc.uri.getAuthority(),root.getAuthority())||!Objects.equals(DocumentsContract.getDocumentId(doc.uri),doc.id)||!doc.id.startsWith(rootId+"/"))throw new DirectReadScope.UnsafePathException();
        return directScope().open(doc.id.substring(rootId.length()+1),doc.size,doc.modified);
    }
    static void requireReady(Context c)throws IOException{
        var p=LocalState.prefs(c);
        if(p.getBoolean("sourceChecking",false))throw new IOException("正在检查目录，请稍候");
        if(!p.getString("sourceError","").isBlank())throw new IOException(p.getString("sourceError",""));
        if(p.getString("tree","").isBlank())throw new IOException("请先选择 EhViewer 或 download 目录");
    }
    static String rootDocumentId(Uri uri){
        if(!DocumentsContract.isTreeUri(uri))throw new IllegalArgumentException("需要系统授权的目录 URI");
        try{return DocumentsContract.getDocumentId(uri);}catch(IllegalArgumentException e){return DocumentsContract.getTreeDocumentId(uri);}
    }
    static Uri resolveSelection(Context c,Uri grant,Consumer<String> progress)throws Exception {
        ContentResolver resolver=c.getContentResolver();
        String[] projection={DocumentsContract.Document.COLUMN_DOCUMENT_ID,DocumentsContract.Document.COLUMN_DISPLAY_NAME,DocumentsContract.Document.COLUMN_MIME_TYPE};
        DownloadSelection.Access access=new DownloadSelection.Access(){
            DownloadSelection.Node node(Cursor cur){return new DownloadSelection.Node(cur.getString(0),cur.getString(1),DocumentsContract.Document.MIME_TYPE_DIR.equals(cur.getString(2)));}
            public DownloadSelection.Node read(String id)throws Exception{
                try(Cursor cur=resolver.query(DocumentsContract.buildDocumentUriUsingTree(grant,id),projection,null,null,null)){
                    if(cur==null||!cur.moveToFirst())throw new IOException("目录不可读，请重新授权");return node(cur);
                }
            }
            public List<DownloadSelection.Node> children(String id)throws Exception{
                List<DownloadSelection.Node> out=new ArrayList<>();
                try(Cursor cur=resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(grant,id),projection,null,null,null)){
                    if(cur==null)throw new IOException("EhViewer 目录不可读");
                    while(cur.moveToNext()){
                        if(out.size()>=10000)throw new IOException("所选父目录条目异常多，请确认选择的是 EhViewer");
                        out.add(node(cur));
                        if(out.size()%100==0)progress.accept("正在定位 download · 已读取父目录 "+out.size()+" 项");
                    }
                }return out;
            }
        };
        String id=DownloadSelection.resolve(rootDocumentId(grant),access,progress);
        return DocumentsContract.buildDocumentUriUsingTree(grant,id);
    }
    List<Doc> children(String id)throws Exception {
        return children(id,count->{});
    }
    List<Doc> children(String id,IntConsumer progress)throws Exception {
        Uri uri=DocumentsContract.buildChildDocumentsUriUsingTree(root,id);List<Doc> out=new ArrayList<>();
        try(Cursor cur=resolver.query(uri,new String[]{"document_id","_display_name","mime_type","_size","last_modified"},null,null,null)) {
            if(cur==null)throw new IOException("下载目录不可读，请重新授权");
            while(cur.moveToNext()){
                if(out.size()>=100000)throw new IOException("单个目录文件过多");
                String name=cur.getString(1);OrderRules.validName(name);String docId=cur.getString(0);
                out.add(new Doc(docId,name,cur.getString(2),cur.isNull(3)?-1:cur.getLong(3),cur.isNull(4)?0:cur.getLong(4),DocumentsContract.buildDocumentUriUsingTree(root,docId)));
                if(out.size()%100==0)progress.accept(out.size());
            }
        }progress.accept(out.size());return out;
    }
    Map<String,Doc> directories()throws Exception {
        return directories(count->{});
    }
    Map<String,Doc> directories(IntConsumer progress)throws Exception {
        Map<String,Doc> out=new HashMap<>();for(Doc d:children(rootId,progress))if(d.isDirectory()){if(out.put(d.name,d)!=null)throw new IOException("下载目录名称重复");}return out;
    }
    List<FileEntry> rootFiles()throws Exception {
        List<FileEntry> out=new ArrayList<>();
        for(Doc doc:children(rootId))if(!doc.isDirectory()){
            if(doc.size()<0)throw new IOException("无法取得根文件大小");out.add(new FileEntry(doc.name(),doc));
        }
        out.sort(Comparator.comparing(FileEntry::path));return out;
    }
    List<FileEntry> files(Doc book,SyncRunner.Cancel cancel)throws Exception {
        List<FileEntry> out=new ArrayList<>();scan(book.id,"",0,out,new HashSet<>(),cancel);out.sort(Comparator.comparing(FileEntry::path));return out;
    }
    private void scan(String id,String prefix,int depth,List<FileEntry> out,Set<String> visited,SyncRunner.Cancel cancel)throws Exception {
        cancel.check();if(depth>16 || !visited.add(id))throw new IOException("目录层级异常");
        for(Doc doc:children(id)){
            cancel.check();String path=prefix+doc.name;
            if(doc.isDirectory())scan(doc.id,path+"/",depth+1,out,visited,cancel);
            else{if(doc.size<0)throw new IOException("无法取得文件大小："+path);if(out.size()>=100000)throw new IOException("单本漫画超过文件数量限制");out.add(new FileEntry(path,doc));}
        }
    }
    InputStream open(Doc doc)throws IOException {return reads.open(()->openDirect(doc),()->resolver.openInputStream(doc.uri));}
    ReadSession reader(){return new ReadSession();}
    /** One instance per read worker. Only cancel() may run on another thread. */
    final class ReadSession implements AutoCloseable {
        ContentProviderClient client;volatile CancellationSignal active;volatile boolean cancelled;private InputStream current;
        InputStream open(Doc doc)throws IOException {
            if(cancelled)throw new InterruptedIOException("读取已暂停");
            InputStream opened=reads.open(()->openDirect(doc),()->openSaf(doc));
            InputStream tracked=new FilterInputStream(opened){
                final AtomicBoolean closed=new AtomicBoolean();
                @Override public void close()throws IOException{if(!closed.compareAndSet(false,true))return;try{super.close();}finally{synchronized(ReadSession.this){if(current==this)current=null;active=null;}}}
            };
            synchronized(this){if(!cancelled){current=tracked;return tracked;}}
            tracked.close();throw new InterruptedIOException("读取已暂停");
        }
        private InputStream openSaf(Doc doc)throws IOException {
            if(cancelled)throw new InterruptedIOException("读取已暂停");
            CancellationSignal signal=new CancellationSignal();active=signal;
            if(cancelled)signal.cancel();
            try{
                for(int attempt=0;attempt<2;attempt++){
                    signal.throwIfCanceled();
                    if(client==null){client=resolver.acquireUnstableContentProviderClient(root);if(client==null)throw new FileNotFoundException("文件服务暂不可用");}
                    try{
                        ParcelFileDescriptor fd=client.openFile(doc.uri,"r",signal);
                        if(fd==null)throw new FileNotFoundException("源文件不可读");
                        return new ParcelFileDescriptor.AutoCloseInputStream(fd);
                    }catch(DeadObjectException e){client.close();client=null;if(attempt==1)throw new IOException("文件服务重启，请继续重试",e);}
                }
                throw new IOException("文件服务不可用");
            }catch(RemoteException e){active=null;throw new IOException("文件服务不可用",e);}
            catch(IOException|RuntimeException e){active=null;throw e;}
        }
        void cancel(){InputStream stream;synchronized(this){cancelled=true;stream=current;}CancellationSignal signal=active;if(signal!=null)signal.cancel();if(stream!=null)try{stream.close();}catch(IOException ignored){}}
        boolean unchanged(Doc doc)throws Exception {
            if(cancelled)throw new InterruptedIOException("读取已暂停");
            CancellationSignal signal=new CancellationSignal();active=signal;if(cancelled)signal.cancel();
            try(Cursor cur=resolver.query(doc.uri,new String[]{"_size","last_modified"},null,null,null,signal)){
                return cur!=null&&cur.moveToFirst()&&!cur.isNull(0)&&cur.getLong(0)==doc.size&&(cur.isNull(1)?0:cur.getLong(1))==doc.modified;
            }finally{active=null;}
        }
        @Override public void close(){cancel();if(client!=null){client.close();client=null;}}
    }
    boolean unchanged(Doc doc)throws Exception {
        try(Cursor c=resolver.query(doc.uri,new String[]{"_size","last_modified"},null,null,null)){return c!=null && c.moveToFirst() && !c.isNull(0) && c.getLong(0)==doc.size && (c.isNull(1)?0:c.getLong(1))==doc.modified;}
    }
    static boolean same(List<FileEntry> a,List<FileEntry> b){if(a.size()!=b.size())return false;for(int i=0;i<a.size();i++){FileEntry x=a.get(i),y=b.get(i);if(!x.path.equals(y.path)||x.doc.size!=y.doc.size||x.doc.modified!=y.doc.modified||!x.doc.id.equals(y.doc.id))return false;}return true;}
}
