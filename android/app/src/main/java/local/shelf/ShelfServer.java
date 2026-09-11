package local.shelf;

import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import fi.iki.elonen.NanoHTTPD;
import org.json.*;
import java.util.*;
import java.io.*;
import java.security.*;
import java.nio.charset.StandardCharsets;

/** Read-only whitelist API. Client never supplies a filesystem path or content URI. */
final class ShelfServer extends NanoHTTPD {
    final String secret;
    final PairingIdentity pairing;
    final PairingWindow pins=new PairingWindow(android.os.SystemClock::elapsedRealtime);
    final String catalogRevision;
    final String libraryId;
    final ContentResolver resolver;
    record Doc(String name,String mime,Uri uri){}
    static final class Book {
        final String id,title,directoryName;final int rank;volatile Doc directory;
        Book(String id,String title,int rank,String directoryName,Doc directory){this.id=id;this.title=title;this.rank=rank;this.directoryName=directoryName;this.directory=directory;}
        int rank(){return rank;}
    }
    final Uri root;
    final IndexStore indexStore;
    final IndexWriter indexWriter;
    final Set<String> unusableDiskKeys=java.util.concurrent.ConcurrentHashMap.newKeySet();
    final java.util.concurrent.locks.ReentrantReadWriteLock indexLock=new java.util.concurrent.locks.ReentrantReadWriteLock(true);
    final List<Book> books=new ArrayList<>();
    final Map<String,Book> byId=new HashMap<>();
    final CoverLocations<Doc> covers=new CoverLocations<>(1024,android.os.SystemClock::elapsedRealtime);
    final PageIndexes<Doc> pageCache=new PageIndexes<>(20000,32);
    static final java.util.regex.Pattern PAGE_NAME=java.util.regex.Pattern.compile("(?i)[0-9]{8}\\.(jpg|jpeg|png|webp|gif|avif)");
    volatile Runnable activity=()->{};
    ShelfServer(String host,ContentResolver resolver,Uri root,JSONArray manifest,PairingIdentity pairing,IndexStore indexStore)throws Exception{
        super(host,8088);this.resolver=resolver;
        this.root=root;this.indexStore=indexStore;this.indexWriter=new IndexWriter(indexStore);
        libraryId=CoverRevision.library(root.toString());
        this.pairing=pairing;secret=pairing.token;
        byte[] revision=MessageDigest.getInstance("SHA-256").digest((root.toString()+"\n"+manifest.toString()).getBytes(StandardCharsets.UTF_8));
        StringBuilder hex=new StringBuilder();for(byte b:revision)hex.append(String.format(Locale.ROOT,"%02x",b&255));catalogRevision=hex.toString();
        Map<String,Doc> dirs=new HashMap<>();for(Doc d:children(root,DocumentsContract.getTreeDocumentId(root)))if(d.mime.equals(DocumentsContract.Document.MIME_TYPE_DIR))dirs.put(d.name,d);
        Set<Integer> ranks=new HashSet<>();Set<String> used=new HashSet<>();
        if(manifest.length()>20000)throw new IOException("书库超过开发版上限");
        for(int i=0;i<manifest.length();i++){
            JSONObject row=manifest.getJSONObject(i);String id=row.getString("id"),name=row.getString("directory"),title=row.getString("title");int rank=row.getInt("rank");
            String position="（第 "+(i+1)+" 项）";
            if(!id.matches("[0-9]{1,20}")||title.isBlank()||rank<0)throw new IOException("清单字段无效"+position);
            if(!ranks.add(rank))throw new IOException("清单排名重复"+position);
            if(!used.add(name))throw new IOException("清单目录映射重复"+position);
            if(byId.containsKey(id))throw new IOException("清单数字 ID 重复"+position+"，ID="+id);
            // Missing directories retain their original rank and title as placeholders.
            Book b=new Book(id,title,rank,name,dirs.get(name));books.add(b);byId.put(id,b);
        }
        books.sort(Comparator.comparingInt(Book::rank));
    }
    List<Doc> children(Uri tree,String id)throws Exception{
        List<Doc> out=new ArrayList<>();Uri list=DocumentsContract.buildChildDocumentsUriUsingTree(tree,id);
        try(Cursor c=resolver.query(list,new String[]{"document_id","_display_name","mime_type"},null,null,null)){
            if(c==null)throw new IOException("目录不可读");
            while(c.moveToNext()){if(out.size()>=100000)throw new IOException("单目录条目过多");out.add(new Doc(c.getString(1),c.getString(2),DocumentsContract.buildDocumentUriUsingTree(tree,c.getString(0))));}
        }return out;
    }
    int missingCount(){int count=0;for(Book b:books)if(b.directory==null)count++;return count;}
    List<Doc> entries(Book b)throws Exception{if(b.directory==null)throw new FileNotFoundException("local_files_missing");return children(b.directory.uri,DocumentsContract.getDocumentId(b.directory.uri));}
    String indexKey(Book b,String kind)throws Exception{return IndexStore.key(root+"\n"+b.id+"\n"+b.directory.uri+"\n"+kind);}
    IndexStore.Location location(Doc doc){return new IndexStore.Location(doc.name,doc.mime,DocumentsContract.getDocumentId(doc.uri));}
    Doc document(Book book,IndexStore.Location value){return new Doc(value.name(),value.mime(),DocumentsContract.buildDocumentUriUsingTree(book.directory.uri,value.documentId()));}
    void persist(String key,List<IndexStore.Location> entries,long ticket){indexWriter.offer(key,entries,ticket);}
    @Override public void stop(){super.stop();indexWriter.close();}
    void discard(Book b,String kind)throws Exception{String key=indexKey(b,kind);try{indexStore.invalidate(key);}catch(IOException ignored){unusableDiskKeys.add(key);}if(kind.equals("pages"))pageCache.invalidate(b.id);else covers.invalidate(b.id);}
    Doc findCover(Book b)throws Exception{
        if(b.directory==null)return null;
        String key=indexKey(b,"cover");long ticket=indexStore.ticket();
        try{
            List<IndexStore.Location> saved=unusableDiskKeys.contains(key)?null:indexStore.read(key,24*60*60*1000L,30_000);
            if(saved!=null && saved.isEmpty())return null;
            if(saved!=null && saved.size()==1 && saved.get(0).name().equals(".thumb") && !saved.get(0).mime().equals(DocumentsContract.Document.MIME_TYPE_DIR))return document(b,saved.get(0));
        }catch(IOException ignored){}
        Doc cover=scanCover(b);persist(key,cover==null?Collections.emptyList():Collections.singletonList(location(cover)),ticket);return cover;
    }
    Doc scanCover(Book b)throws Exception{
        if(b.directory==null)return null;
        Uri uri=DocumentsContract.buildChildDocumentsUriUsingTree(b.directory.uri,DocumentsContract.getDocumentId(b.directory.uri));
        // Iterate the provider cursor without allocating every page's Doc/Uri.
        try(Cursor c=resolver.query(uri,new String[]{"document_id","_display_name","mime_type"},null,null,null)){
            if(c==null)throw new IOException("目录不可读");int count=0;
            while(c.moveToNext()){
                if(++count>100000)throw new IOException("单目录条目过多");
                if(".thumb".equals(c.getString(1)) && !DocumentsContract.Document.MIME_TYPE_DIR.equals(c.getString(2)))
                    return new Doc(c.getString(1),c.getString(2),DocumentsContract.buildDocumentUriUsingTree(b.directory.uri,c.getString(0)));
            }
        }
        return null;
    }
    InputStream openCover(Book b)throws Exception{
        return StaleFileOpener.open(()->covers.get(b.id,()->findCover(b)),doc->resolver.openInputStream(doc.uri),()->discard(b,"cover"),false);
    }
    String coverIdentity(Book b){return CoverRevision.book(libraryId,b.id,b.directoryName);}
    Response conditionalCover(Book b,String validator)throws Exception {
        for(int attempt=0;attempt<2;attempt++){
            Doc doc=covers.get(b.id,()->findCover(b));if(doc==null)return fail(Response.Status.NOT_FOUND,"missing");
            try {
                String etag=null;
                try(Cursor c=resolver.query(doc.uri,new String[]{DocumentsContract.Document.COLUMN_SIZE,DocumentsContract.Document.COLUMN_LAST_MODIFIED},null,null,null)){
                    if(c!=null && c.moveToFirst() && !c.isNull(0) && !c.isNull(1))etag=CoverRevision.etag(coverIdentity(b),doc.uri.toString(),c.getLong(0),c.getLong(1));
                } catch(Exception unsupported){ /* Provider without metadata: unconditional stream. */ }
                Response result;
                if(CoverRevision.matches(etag,validator))result=newFixedLengthResponse(Response.Status.NOT_MODIFIED,"application/octet-stream","");
                else {
                    InputStream stream=resolver.openInputStream(doc.uri);if(stream==null)throw new FileNotFoundException();
                    result=newChunkedResponse(Response.Status.OK,"application/octet-stream",track(stream));
                }
                if(etag!=null)result.addHeader("ETag",etag);
                return result;
            } catch(FileNotFoundException missing){discard(b,"cover");if(attempt==1)throw missing;}
        }
        return fail(Response.Status.NOT_FOUND,"missing");
    }
    NavigableMap<Integer,Doc> pages(Book b)throws Exception{
        return pageCache.get(b.id,()->{
            String key=indexKey(b,"pages");long ticket=indexStore.ticket();
            try{
                List<IndexStore.Location> saved=unusableDiskKeys.contains(key)?null:indexStore.read(key,300_000,30_000);
                if(saved!=null){
                    TreeMap<Integer,Doc> restored=new TreeMap<>();
                    for(IndexStore.Location item:saved){
                        if(!PAGE_NAME.matcher(item.name()).matches()||item.mime().equals(DocumentsContract.Document.MIME_TYPE_DIR))throw new IOException("cached page name");
                        int number=Integer.parseInt(item.name().substring(0,8));
                        if(number<1||restored.put(number,document(b,item))!=null)throw new IOException("cached page number");
                    }
                    return restored;
                }
            }catch(IOException ignored){try{indexStore.invalidate(key);}catch(IOException unavailable){}ticket=indexStore.ticket();}
            TreeMap<Integer,Doc> indexed=new TreeMap<>();
            Doc cover=null;
            Uri list=DocumentsContract.buildChildDocumentsUriUsingTree(b.directory.uri,DocumentsContract.getDocumentId(b.directory.uri));
            try(Cursor c=resolver.query(list,new String[]{"document_id","_display_name","mime_type"},null,null,null)){
                if(c==null)throw new IOException("目录不可读");int count=0;
                while(c.moveToNext()){
                    if(++count>100000)throw new IOException("单目录条目过多");String name=c.getString(1);
                    if(".thumb".equals(name) && !DocumentsContract.Document.MIME_TYPE_DIR.equals(c.getString(2)))cover=new Doc(name,c.getString(2),DocumentsContract.buildDocumentUriUsingTree(b.directory.uri,c.getString(0)));
                    if(name!=null && PAGE_NAME.matcher(name).matches() && !DocumentsContract.Document.MIME_TYPE_DIR.equals(c.getString(2))){
                        int number=Integer.parseInt(name.substring(0,8));
                        Doc d=new Doc(name,c.getString(2),DocumentsContract.buildDocumentUriUsingTree(b.directory.uri,c.getString(0)));
                        if(number<1||indexed.put(number,d)!=null)throw new IOException("重复或无效页码");
                    }
                }
            }
            if(indexed.size()<=20000){List<IndexStore.Location> saved=new ArrayList<>();for(Doc doc:indexed.values())saved.add(location(doc));persist(key,saved,ticket);}
            // Reuse the same directory enumeration for the cover location.
            persist(indexKey(b,"cover"),cover==null?Collections.emptyList():Collections.singletonList(location(cover)),ticket);
            covers.invalidate(b.id);
            return indexed;
        });
    }
    InputStream openPage(Book b,int number)throws Exception {
        return StaleFileOpener.open(()->pages(b).get(number),doc->resolver.openInputStream(doc.uri),()->discard(b,"pages"),true);
    }
    void refreshIndexes(String id)throws Exception {
        indexLock.writeLock().lock();try{
            if(!id.isEmpty()&&!byId.containsKey(id))throw new IOException("清单内没有此漫画 ID；新增漫画需导入最新 .db");
            Map<String,Doc> dirs=new HashMap<>();for(Doc doc:children(root,DocumentsContract.getTreeDocumentId(root)))if(doc.mime.equals(DocumentsContract.Document.MIME_TYPE_DIR))dirs.put(doc.name,doc);
            // Invalidate before replacing the mapping. Never modify imported ranks.
            if(id.isEmpty()){indexStore.clear();unusableDiskKeys.clear();pageCache.clear();covers.clear();}
            else{Book b=byId.get(id);if(b.directory!=null){discard(b,"pages");discard(b,"cover");}pageCache.invalidate(id);covers.invalidate(id);}
            for(Book b:books)if(id.isEmpty()||b.id.equals(id))b.directory=dirs.get(b.directoryName);
            if(!id.isEmpty()){Book b=byId.get(id);if(b.directory!=null){discard(b,"pages");discard(b,"cover");}}
        }finally{indexLock.writeLock().unlock();}
    }
    InputStream track(InputStream input){
        return new FilterInputStream(input){
            long last;
            void touch(){long now=android.os.SystemClock.elapsedRealtime();if(now-last>=1000){last=now;activity.run();}}
            @Override public int read()throws IOException{touch();return in.read();}
            @Override public int read(byte[] b,int offset,int length)throws IOException{touch();return in.read(b,offset,length);}
        };
    }
    Response json(JSONObject o){return newFixedLengthResponse(Response.Status.OK,"application/json; charset=utf-8",o.toString());}
    Response fail(Response.Status status,String code){return newFixedLengthResponse(status,"application/json","{\"error\":\""+code+"\"}");}
    @Override public Response serve(IHTTPSession s){
        // Enrollment reads only six bytes, outside the catalog's index lock.
        if(s.getUri().equals("/v2/pair"))return PairingEndpoint.serve(s,pins,pairing);
        Response response;
        indexLock.readLock().lock();
        try{
            // Discovery is untrusted: prove possession before iOS sends a bearer token.
            if(s.getUri().equals("/v2/identity") && s.getMethod()==Method.GET){
                String nonce=s.getParms().getOrDefault("nonce","");
                if(!nonce.matches("[a-f0-9]{64}"))return fail(Response.Status.BAD_REQUEST,"challenge");
                Response proof=json(new JSONObject().put("deviceId",pairing.id).put("proof",pairing.proof(nonce)));
                proof.addHeader("Cache-Control","no-store");return proof;
            }
            String auth=s.getHeaders().getOrDefault("authorization","");
            if(!MessageDigest.isEqual(auth.getBytes(StandardCharsets.UTF_8),("Bearer "+secret).getBytes(StandardCharsets.UTF_8)))return fail(Response.Status.UNAUTHORIZED,"unauthorized");
            if(s.getMethod()!=Method.GET)return fail(Response.Status.METHOD_NOT_ALLOWED,"read_only");
            activity.run();
            String[] path=s.getUri().split("/");
            if(s.getUri().equals("/v1/books")){
                int offset=Integer.parseInt(s.getParms().getOrDefault("offset","0"));if(offset<0||offset>books.size())return fail(Response.Status.BAD_REQUEST,"offset");
                int limit=Integer.parseInt(s.getParms().getOrDefault("limit","60"));if(limit<50||limit>500)return fail(Response.Status.BAD_REQUEST,"limit");
                JSONArray list=new JSONArray();for(int i=offset;i<Math.min(offset+limit,books.size());i++){Book b=books.get(i);list.put(new JSONObject().put("id",b.id).put("title",b.title).put("rank",b.rank).put("available",b.directory!=null).put("coverIdentity",coverIdentity(b)));}
                response=json(new JSONObject().put("orderVerified",false).put("orderPolicy","snapshot-query").put("catalogRevision",catalogRevision).put("libraryId",libraryId).put("total",books.size()).put("books",list));
            }else if(path.length>=5&&path[1].equals("v1")&&path[2].equals("books")&&byId.containsKey(path[3])){
                Book b=byId.get(path[3]);
                if(b.directory==null)return fail(Response.Status.NOT_FOUND,"local_files_missing");
                if(path.length==5&&path[4].equals("pages")){
                    JSONArray list=new JSONArray();for(int number:pages(b).keySet())list.put(new JSONObject().put("number",number));response=json(new JSONObject().put("pages",list));
                }else if(path.length==5&&path[4].equals("cover")){
                    response=conditionalCover(b,s.getHeaders().get("if-none-match"));
                }else{
                    if(path.length!=6||!path[4].equals("pages"))return fail(Response.Status.NOT_FOUND,"missing");
                    int number=Integer.parseInt(path[5]);if(number<1||number>99999999)return fail(Response.Status.BAD_REQUEST,"page");
                    InputStream stream=openPage(b,number);if(stream==null)return fail(Response.Status.NOT_FOUND,"missing");
                    response=newChunkedResponse(Response.Status.OK,"application/octet-stream",track(stream));
                }
            }else response=fail(Response.Status.NOT_FOUND,"missing");
        }catch(Exception e){response=fail(Response.Status.INTERNAL_ERROR,"read_failed");}
        finally{indexLock.readLock().unlock();}
        response.addHeader("Cache-Control","no-store");response.addHeader("X-Content-Type-Options","nosniff");return response;
    }
}
