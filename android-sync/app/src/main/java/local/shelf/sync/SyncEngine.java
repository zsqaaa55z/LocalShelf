package local.shelf.sync;

import android.content.Context;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicInteger;

final class SyncEngine {
    interface Progress {void update(String text);}
    final TransferStats stats=new TransferStats();int uploadConcurrency=1,readConcurrency=2;byte[] singleBuffer;final byte[] hashBuffer=new byte[256*1024];boolean batchSupported,pipelineEnabled=true;ReadPipeline.Buffers readBuffers;volatile SourceFiles progressSource;
    final List<Net> batchConnections=new ArrayList<>(2);
    int missingSources;
    synchronized Net batchConnection(int lane)throws Exception {
        if(lane<0||lane>=2)throw new IllegalArgumentException("批量发送连接超出上限");
        while(batchConnections.size()<=lane)batchConnections.add(new Net(c,LocalState.pairing(c),stats,cancel));
        return batchConnections.get(lane);
    }
    synchronized void closeBatchConnections(){for(Net client:batchConnections)try{client.close();}catch(RuntimeException ignored){}batchConnections.clear();}
    final Context c;final SyncRunner.Cancel cancel;final Progress progress;volatile long sent=0;long lastReport=0;int scannedBooks=0,reusedBooks=0,hashedFiles=0;String currentBook="",currentPath="";boolean batchPaused=false;long verifiedBytes=0,verifiedFiles=0;int archiveGroupsDone=0,archiveHashedFiles=0;
    SyncEngine(Context c,SyncRunner.Cancel cancel,Progress progress){this.c=c;this.cancel=cancel;this.progress=progress;}
    synchronized void report(String message){long now=System.currentTimeMillis();if(now-lastReport>=500){lastReport=now;progress.update(message);}}
    synchronized void acknowledged(int count){sent+=count;stats.sent(count);cancel.monitor.acknowledged(count);}
    void estimate(List<SourceFiles.FileEntry> files){long bytes=0;for(var f:files)bytes=Math.addExact(bytes,f.doc().size());cancel.monitor.estimate(bytes);}
    long payloadEstimate(JSONArray books,int start,List<ExtraArchive.Group> groups,int limit){
        // Reuse only a structurally matching snapshot. No full-library rescan just to estimate.
        // It may be stale or count already-present NAS files, so this is NOT a progress denominator.
        try{
            JSONObject report=LocalState.read(c,"migration-report.json"),rows=report.getJSONObject("books"),extra=report.getJSONObject("archives");
            if(report.getInt("bookCount")!=books.length()||rows.length()!=books.length()||extra.length()!=groups.size())return -1;
            long[] mainBytes=new long[books.length()],archiveBytes=new long[groups.size()];
            for(int i=0;i<books.length();i++)mainBytes[i]=rows.getJSONObject(books.getJSONObject(i).getString("id")).getLong("bytes");
            for(int i=0;i<groups.size();i++)archiveBytes[i]=extra.getJSONObject(groups.get(i).id()).getLong("bytes");
            return PayloadEstimate.from(mainBytes,start,archiveBytes,LocalState.prefs(c).getInt("nextArchiveGroup",0),limit);
        }catch(Exception unavailable){return -1;}
    }
    String transferred(){SourceFiles source=progressSource;return stats.summary()+String.format(Locale.CHINA,"\n本批核验 %d 个文件 · %.2f GB · %s",verifiedFiles,verifiedBytes/1e9,batchSupported?"32 MiB 缓冲 / 读取 "+readConcurrency+" 路 / "+(pipelineEnabled?"小文件最多双路；大文件按需重叠（最多 2 路）":"兼容调度")+" / 常规大文件 "+uploadConcurrency+" 路":uploadConcurrency+" 路上传")+(source==null?"":"\n"+source.readDescription());}
    void run(boolean full)throws Exception {run(full,false);}
    void run(boolean full,boolean newOnly)throws Exception {run(full,newOnly,0);}
    void run(boolean full,boolean newOnly,int batchLimit)throws Exception {
        if(batchLimit<0)throw new IllegalArgumentException("批次数量无效");
        newOnly=newOnly&&!full;
        cancel.check();JSONObject connection=LocalState.pairing(c);try(Net net=new Net(c,connection,stats,cancel)){JSONObject health=net.get("/sync/v1/health");
        Set<String> capabilities=new HashSet<>(Catalog.strings(health.optJSONArray("capabilities")==null?new JSONArray():health.getJSONArray("capabilities")));
        boolean canReuse=capabilities.contains("book-reuse-v1"),canArchive=capabilities.contains("extra-archive-v1"),dailyCatalog=capabilities.contains("daily-catalog-v1");
        // Explicit full revalidation keeps status-before-upload, so unchanged
        // files are rehashed but are not sent again merely to audit them.
        batchSupported=capabilities.contains("batch-files-v1")&&!full;
        pipelineEnabled=LocalState.prefs(c).getBoolean("pipelineEnabled",true);
        int readLanes=LocalState.prefs(c).getInt("readConcurrency",2);readConcurrency=readLanes==1||readLanes==4?readLanes:2;
        int requestedLanes=LocalState.prefs(c).getInt("uploadConcurrency",1);
        uploadConcurrency=capabilities.contains("parallel-files-v1")&&(requestedLanes==2||requestedLanes==4)?requestedLanes:1;
        report("正在读取下载顺序…");
        ChangeSummaryStore.clear(c,"正在读取最新清单，准备变化摘要…");
        String backup=LocalState.prefs(c).getString("backup","");
        if(backup.isBlank())throw new IOException("请先导入 EhViewer 完整下载备份");
        JSONObject previous=null;try{previous=LocalState.read(c,"last-synced-order.json");}catch(FileNotFoundException ignored){}
        JSONObject draft=Catalog.importDb(c,Uri.parse(backup));Catalog.save(c,draft);
        ChangeSummary.Analysis changes=ChangeSummaryStore.prepare(c,draft);
        Set<String> affected=IncrementalChanges.affected(previous==null?List.of():Catalog.changeRows(previous),Catalog.changeRows(draft));
        Set<String> completed=Catalog.completedIds(draft);
        JSONObject catalog=Catalog.manifest(draft);JSONArray books=catalog.getJSONArray("books");
        SourceFiles.requireReady(c);
        String tree=LocalState.prefs(c).getString("tree","");if(tree.isBlank())throw new IOException("请先授权 EhViewer 下载目录");
        report("阶段：扫描 · 正在等待系统读取下载目录…");
        SourceFiles source=new SourceFiles(c,Uri.parse(tree));progressSource=source;Map<String,SourceFiles.Doc> dirs=source.directories(count->report("阶段：扫描 · 已读取下载目录 "+count+" 项"));Set<String> matched=new HashSet<>();
        for(int i=0;i<books.length();i++)matched.add(books.getJSONObject(i).getString("directory"));
        long unknown=dirs.keySet().stream().filter(name->!matched.contains(name)).count();
        LocalState.prefs(c).edit().putLong("unknown",unknown).apply();
        List<ExtraArchive.Group> extraGroups=ExtraArchive.groups(dirs,matched);
        if(!canArchive&&(unknown>0||!source.rootFiles().isEmpty()))throw new IOException("NAS 接收端需要升级后才能归档列表外目录和根文件；本次未开始传输");
        // Content hints also change the library revision, so existing iOS page
        // caches do not retain stale pages when GID and list order are unchanged.
        JSONObject observedDirectories=new JSONObject();Map<String,String> contentStamps=new HashMap<>();
        JSONArray draftRows=draft.getJSONArray("rows");for(int i=0;i<draftRows.length();i++){JSONObject row=draftRows.getJSONObject(i);contentStamps.put(row.getString("id"),row.getString("contentStamp"));}
        JSONArray contentHints=new JSONArray();
        for(int i=0;i<books.length();i++){JSONObject b=books.getJSONObject(i);String gid=b.getString("id");SourceFiles.Doc dir=dirs.get(b.getString("directory"));if(dir!=null)observedDirectories.put(gid,dir.modified());contentHints.put(new JSONArray().put(gid).put(contentStamps.get(gid)).put(dir==null?-1:dir.modified()));}
        String auditEpoch=newOnly?"daily":Long.toString(LocalState.prefs(c).getLong("lastSuccess",0));
        String sourceSignals=LocalState.hex(MessageDigest.getInstance("SHA-256").digest((contentHints.toString()+"\n"+auditEpoch).getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        if(dailyCatalog)catalog.put("contentSnapshot",sourceSignals);
        Set<String> missingReady=new HashSet<>();JSONObject stageRequest=catalog;
        if(dailyCatalog){stageRequest=new JSONObject(catalog.toString());JSONArray missingIds=new JSONArray();for(int i=0;i<books.length();i++){JSONObject b=books.getJSONObject(i);if(!dirs.containsKey(b.getString("directory"))){missingIds.put(b.getString("id"));missingReady.add(b.getString("id"));}}stageRequest.put("missingSourceIds",missingIds);}
        JSONObject staged=net.post(dailyCatalog?"/sync/v1/catalog/daily-stage":"/sync/v1/catalog/stage",stageRequest);String revision=staged.getString("revision");
        int retainedBooks=0;
        if(dailyCatalog){JSONObject planned=staged.getJSONObject("catalog");Catalog.validatePlan(catalog,planned);if(!missingReady.equals(new HashSet<>(Catalog.strings(staged.getJSONArray("missingSourceIds")))))throw new IOException("NAS 缺失目录确认不一致");catalog=planned;books=catalog.getJSONArray("books");retainedBooks=staged.optInt("retainedBooks",0);}
        String scope=LocalState.hex(MessageDigest.getInstance("SHA-256").digest((tree+"\n"+connection.getString("certificateSha256")+"\n"+connection.getString("url")).getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        JSONObject directoryStamps=new JSONObject();try{JSONObject old=LocalState.read(c,"daily-directory-stamps.json");if(scope.equals(old.optString("scope")))directoryStamps=old.getJSONObject("values");}catch(FileNotFoundException ignored){}
        long lastSuccess=LocalState.prefs(c).getLong("lastSuccess",0);Set<String> directoryChanges=new HashSet<>();int observedMissing=0;
        for(int i=0;i<books.length();i++){JSONObject b=books.getJSONObject(i);String gid=b.getString("id");SourceFiles.Doc dir=dirs.get(Catalog.sourceDirectory(b));if(dir!=null){long stamp=dir.modified();if(IncrementalChanges.directoryChanged(stamp,directoryStamps.has(gid)?directoryStamps.getLong(gid):null,lastSuccess)){affected.add(gid);directoryChanges.add(gid);}observedDirectories.put(gid,stamp);}else observedMissing++;}
        if(changes!=null)changes=changes.withDirectorySignals(directoryChanges);
        String completionRevision=LocalState.hex(MessageDigest.getInstance("SHA-256").digest(new JSONArray(completed).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        String checkpoint=completionRevision+"\n"+tree+"\n"+revision+"\n"+full+"\n"+newOnly+"\n"+connection.getString("certificateSha256")+"\n"+connection.getString("url")+"\n"+sourceSignals;
        var prefs=LocalState.prefs(c);
        int start=checkpoint.equals(prefs.getString("checkpoint",""))?prefs.getInt("nextBook",0):0;
        if(start<0||start>books.length())start=0;
        Set<String> ready=new HashSet<>(Catalog.strings(staged.getJSONArray("readyIds")));
        for(int i=0;i<start;i++)if(!ready.contains(books.getJSONObject(i).getString("id"))){start=0;break;}
        int missing=start>0?prefs.getInt("missingInCycle",0):0;
        missingSources=missing;
        cancel.monitor.expected(payloadEstimate(books,start,extraGroups,batchLimit));
        if(!prefs.edit().putBoolean("cyclePending",true).putBoolean("cycleFull",full).putBoolean("batchPaused",false).putString("checkpoint",checkpoint).putInt("nextBook",start).putInt("missingInCycle",missing).commit())throw new IOException("手机无法保存同步起点，请检查存储空间");
        try(HashCache cache=new HashCache(c)) {
            Set<String> reused=new HashSet<>();
            if(newOnly&&canReuse){
                Map<String,HashCache.Receipt> receipts=cache.receipts(scope);JSONArray requested=new JSONArray();
                for(int i=start;i<books.length();i++){cancel.check();JSONObject b=books.getJSONObject(i);var old=receipts.get(b.getString("id"));String phone=Catalog.sourceDirectory(b);if(!affected.contains(b.getString("id"))&&completed.contains(b.getString("id"))&&old!=null&&old.directory().equals(phone)&&dirs.containsKey(phone))requested.put(new JSONObject().put("gid",b.getString("id")).put("proof",old.proof()));}
                if(requested.length()>0)reused.addAll(Catalog.strings(net.post("/sync/v1/catalog/reuse",new JSONObject().put("revision",revision).put("books",requested)).getJSONArray("reused")));
                Set<String> asked=new HashSet<>();for(int i=0;i<requested.length();i++)asked.add(requested.getJSONObject(i).getString("gid"));if(!asked.containsAll(reused))throw new IOException("NAS 返回了未知复用记录");
            }
            ChangeSummaryStore.planned(c,changes,reused.size(),start,observedMissing,newOnly&&canReuse);
            for(int index=start;index<books.length();index++) {
                cancel.check();JSONObject book=books.getJSONObject(index);String gid=book.getString("id"),label=(index+1)+" / "+books.length()+" 本";
                cancel.monitor.position(index+1,books.length());
                if(missingReady.contains(gid)){missing++;missingSources=missing;cache.receipt(scope,gid,Catalog.sourceDirectory(book),null);continue;}
                if(reused.contains(gid)){reusedBooks++;continue;}
                if(batchLimit>0&&scannedBooks>=batchLimit){
                    if(!prefs.edit().putInt("nextBook",index).putInt("missingInCycle",missing).putBoolean("batchPaused",true).commit())throw new IOException("手机无法保存批次进度，请检查存储空间");
                    batchPaused=true;progress.update("本批已核验 "+scannedBooks+" 本，已暂停\n清单进度 "+index+" / "+books.length()+" 本 · 本批复用 "+reusedBooks+" 本\n"+transferred()+"\n点击「开始 / 继续同步」处理下一批；全库就绪后统一发布下载顺序。"+(missing>0?"\n注意：已有 "+missing+" 本源目录缺失，尚未备份其文件":""));return;
                }
                currentBook=label+" · "+book.getString("title")+"（ID "+gid+"）";currentPath="";
                scannedBooks++;
                report(label+" · "+book.getString("title")+"\n阶段：扫描 · "+transferred());
                String phoneDirectory=Catalog.sourceDirectory(book);SourceFiles.Doc dir=dirs.get(phoneDirectory);JSONArray inventory=new JSONArray();
                if(dir==null){cache.receipt(scope,gid,book.getString("directory"),null);missing++;missingSources=missing;net.post("/sync/v1/book/commit",new JSONObject().put("revision",revision).put("gid",gid).put("files",inventory));cancel.checkpoint(prefs.edit().putInt("nextBook",index+1).putInt("missingInCycle",missing));continue;}
                long scanStarted=System.nanoTime();List<SourceFiles.FileEntry> files;
                try{files=source.files(dir,cancel);}finally{stats.scan(scanStarted);}
                estimate(files);
                if(batchSupported){
                    inventory=fastFiles(net,source,files,cache,full,revision,gid,label,"/sync/v1/");
                    if(!SourceFiles.same(files,source.files(dir,cancel)))throw new IOException("漫画仍在增加或修改页面，本次不会发布新排序；稍后可继续");
                }else{
                Map<String,HashCache.Hash> hashes=full?Collections.emptyMap():cache.getAll(files);Map<SourceFiles.Doc,String> changedHashes=new HashMap<>();
                int fileIndex=0;
                for(SourceFiles.FileEntry file:files) {
                    cancel.check();currentPath=file.path();SourceFiles.Doc doc=file.doc();String sha=HashCache.matching(hashes,doc);
                    if(sha==null){
                        hashedFiles++;
                        report(label+" · 阶段：校验 "+(++fileIndex)+" / "+files.size()+" 个文件\n"+transferred());
                        MessageDigest md=MessageDigest.getInstance("SHA-256");long read=0;byte[] buffer=hashBuffer;
                        long hashStarted=System.nanoTime();
                        try(InputStream in=source.open(doc)){int n;while((n=in.read(buffer))!=-1){cancel.check();md.update(buffer,0,n);read+=n;}}finally{stats.hash(hashStarted);}
                        if(read!=doc.size() || !source.unchanged(doc))throw new IOException("源文件正在变化，请待下载完成后重试");sha=LocalState.hex(md.digest());changedHashes.put(doc,sha);
                    }else fileIndex++;
                    inventory.put(new JSONObject().put("path",file.path()).put("size",doc.size()).put("sha256",sha));
                }
                cache.putAll(changedHashes);
                JSONArray needed=net.post("/sync/v1/files/status",new JSONObject().put("revision",revision).put("gid",gid).put("files",inventory)).getJSONArray("missing");
                Set<String> uploadPaths=new HashSet<>(Catalog.strings(needed));
                Set<String> expectedPaths=new HashSet<>();for(var file:files)expectedPaths.add(file.path());
                if(!expectedPaths.containsAll(uploadPaths))throw new IOException("NAS 返回了未知文件路径");
                uploadFiles(net,source,files,inventory,uploadPaths,revision,gid,label,"/sync/v1/");
                if((!uploadPaths.isEmpty()||!changedHashes.isEmpty())&&!SourceFiles.same(files,source.files(dir,cancel)))throw new IOException("漫画仍在增加或修改页面，本次不会发布新排序；稍后可继续");
                }
                cancel.check();JSONObject committed=net.post("/sync/v1/book/commit",new JSONObject().put("revision",revision).put("gid",gid).put("files",inventory));
                verifiedFiles+=files.size();for(var f:files)verifiedBytes+=f.doc().size();
                cache.receipt(scope,gid,phoneDirectory,!completed.contains(gid)||committed.isNull("proof")?null:committed.optString("proof",null));
                cancel.checkpoint(prefs.edit().putInt("nextBook",index+1).putInt("missingInCycle",missing));
            }
        }
        cancel.check();JSONObject publication=new JSONObject().put("revision",revision);
        if(canArchive){String archiveRevision=archive(net,source,extraGroups,matched,revision,checkpoint,full,batchLimit);if(batchPaused)return;publication.put("archiveRevision",archiveRevision);}
        report("阶段：完成检查 · 核对主列表顺序与独立归档\n"+transferred());
        JSONObject result=net.post("/sync/v1/catalog/commit",publication);
        JSONArray orderedIds=new JSONArray();for(int i=0;i<books.length();i++)orderedIds.put(books.getJSONObject(i).getString("id"));
        String expectedOrder=LocalState.hex(MessageDigest.getInstance("SHA-256").digest(orderedIds.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        if(!expectedOrder.equals(result.getString("orderSha256")))throw new IOException("NAS 返回的顺序校验不一致，停止同步");
        LocalState.json(c,"last-synced-order.json",draft);
        LocalState.json(c,"daily-directory-stamps.json",new JSONObject().put("scope",scope).put("values",observedDirectories));
        if(!LocalState.prefs(c).edit().putBoolean("cyclePending",false).putBoolean("batchPaused",false).putLong("lastSuccess",System.currentTimeMillis()).putString("lastRevision",result.getString("revision")).putInt("nextBook",0).putInt("missingInCycle",0).remove("archiveCheckpoint").remove("nextArchiveGroup").commit())throw new IOException("NAS 已完成发布，但手机未能保存完成状态；请检查手机存储空间");
        ChangeSummaryStore.published(c);
        progress.update((newOnly?"已完成日常增量；更新顺序并检查新增及受影响漫画，未逐页审计已复用旧漫画":"已完成当前下载清单")+"，共 "+books.length()+" 本\n扫描 "+scannedBooks+" 本 · 复用 "+reusedBooks+" 本\n"+transferred()+(retainedBooks>0?"\n最新清单已移出 "+retainedBooks+" 本；其 NAS 旧文件仍保留":"")+(missing>0?"\n"+missing+" 本源目录缺失，保留列表位置":"")+(canArchive?"\n列表外目录和根文件已独立归档；本批处理 "+archiveGroupsDone+" 组":"")+"\n排序依据：最新导入的 EhViewer 下载列表");
        }finally{closeBatchConnections();}
    }
    String archive(Net net,SourceFiles source,List<ExtraArchive.Group> groups,Set<String> ordered,String revision,String checkpoint,boolean full,int batchLimit)throws Exception {
        String prefix="/sync/v1/archive/";JSONObject manifest=ExtraArchive.manifest(groups,revision);
        JSONObject staged=net.post(prefix+"catalog/stage",manifest);String archiveRevision=staged.getString("revision"),key=checkpoint+"\n"+archiveRevision;
        var prefs=LocalState.prefs(c);int start=key.equals(prefs.getString("archiveCheckpoint",""))?prefs.getInt("nextArchiveGroup",0):0;
        if(start<0||start>groups.size())start=0;
        Set<String> ready=new HashSet<>(Catalog.strings(staged.getJSONArray("readyIds")));
        for(int i=0;i<start;i++)if(!ready.contains(groups.get(i).id())){start=0;break;}
        if(!prefs.edit().putString("archiveCheckpoint",key).putInt("nextArchiveGroup",start).commit())throw new IOException("无法保存归档进度");
        try(HashCache cache=new HashCache(c)){
            for(int index=start;index<groups.size();index++){
                cancel.check();
                if(batchLimit>0&&scannedBooks+archiveGroupsDone>=batchLimit){
                    if(!prefs.edit().putBoolean("batchPaused",true).putInt("nextArchiveGroup",index).commit())throw new IOException("无法保存归档批次进度");
                    batchPaused=true;progress.update("主清单文件已处理；独立归档分批暂停\n归档进度 "+index+" / "+groups.size()+" 组 · 剩余 "+(groups.size()-index)+" 组\n"+transferred()+"\n点击继续；归档完成前不会发布本轮新顺序");return null;
                }
                var group=groups.get(index);String label="独立归档 "+(index+1)+" / "+groups.size()+" 组";
                currentBook=label+" · "+(group.kind().equals("root")?"下载根文件":group.name());currentPath="";
                report("阶段：扫描 · "+currentBook+"\n"+transferred());
                long scanStarted=System.nanoTime();List<SourceFiles.FileEntry> files;
                try{files=ExtraArchive.files(source,group,cancel);}finally{stats.scan(scanStarted);}
                estimate(files);
                JSONArray inventory;
                if(batchSupported){inventory=fastFiles(net,source,files,cache,full,archiveRevision,group.id(),label,prefix);}else{
                Map<String,HashCache.Hash> old=full?Collections.emptyMap():cache.getAll(files);Map<SourceFiles.Doc,String> changed=new HashMap<>();inventory=new JSONArray();
                int indexFile=0;
                for(var file:files){
                    cancel.check();currentPath=file.path();var doc=file.doc();String sha=HashCache.matching(old,doc);indexFile++;
                    if(sha==null){
                        archiveHashedFiles++;report("阶段：校验 · "+label+" · "+indexFile+" / "+files.size()+" 文件\n"+transferred());
                        MessageDigest md=MessageDigest.getInstance("SHA-256");long read=0;byte[] block=hashBuffer;
                        long hashStarted=System.nanoTime();
                        try(InputStream in=source.open(doc)){int n;while((n=in.read(block))!=-1){cancel.check();md.update(block,0,n);read+=n;}}finally{stats.hash(hashStarted);}
                        if(read!=doc.size()||!source.unchanged(doc))throw new IOException("归档源文件正在变化，请稍后重试");
                        sha=LocalState.hex(md.digest());changed.put(doc,sha);
                    }
                    inventory.put(new JSONObject().put("path",file.path()).put("size",doc.size()).put("sha256",sha));
                }
                cache.putAll(changed);
                Set<String> needed=new HashSet<>(Catalog.strings(net.post(prefix+"files/status",new JSONObject().put("revision",archiveRevision).put("gid",group.id()).put("files",inventory)).getJSONArray("missing")));
                Set<String> expected=new HashSet<>();for(var f:files)expected.add(f.path());if(!expected.containsAll(needed))throw new IOException("NAS 返回未知归档文件");
                uploadFiles(net,source,files,inventory,needed,archiveRevision,group.id(),label,prefix);
                }
                if(!SourceFiles.same(files,ExtraArchive.files(source,group,cancel)))throw new IOException("归档目录发生变化，本轮尚未完成；请稍后继续");
                net.post(prefix+"book/commit",new JSONObject().put("revision",archiveRevision).put("gid",group.id()).put("files",inventory));
                verifiedFiles+=files.size();for(var f:files)verifiedBytes+=f.doc().size();archiveGroupsDone++;
                cancel.checkpoint(prefs.edit().putInt("nextArchiveGroup",index+1));
            }
        }
        if(!manifest.toString().equals(ExtraArchive.manifest(ExtraArchive.groups(source.directories(),ordered),revision).toString()))throw new IOException("新增或移除了源目录，请重新继续以更新归档范围");
        JSONObject committed=net.post(prefix+"catalog/commit",new JSONObject().put("revision",archiveRevision));
        if(!archiveRevision.equals(committed.getString("revision"))||!committed.getBoolean("published"))throw new IOException("归档完成回执不一致");
        prefs.edit().putLong("archiveFiles",committed.getLong("files")).putLong("archiveBytes",committed.getLong("bytes")).commit();return archiveRevision;
    }
    record ReadItem(SourceFiles.FileEntry file,String expected){}
    JSONArray fastFiles(Net net,SourceFiles source,List<SourceFiles.FileEntry> files,HashCache cache,boolean full,String revision,String gid,String label,String prefix)throws Exception {
        Map<String,HashCache.Hash> old=full?Collections.emptyMap():cache.getAll(files);
        JSONArray known=new JSONArray(),inventory=new JSONArray();
        for(var file:files){String sha=HashCache.matching(old,file.doc());if(sha!=null)known.put(fileSpec(file,sha));}
        Set<String> knownMissing=known.length()==0?Collections.emptySet():missingFiles(net,prefix,revision,gid,known);
        List<SourceFiles.FileEntry> large=new ArrayList<>();List<ReadItem> small=new ArrayList<>();
        Map<String,String> resultHashes=new HashMap<>();int coldLarge=0;long smallBytes=0;
        for(var file:files){
            cancel.check();currentPath=file.path();var doc=file.doc();String sha=HashCache.matching(old,doc);
            if(sha!=null&&!knownMissing.contains(file.path())){resultHashes.put(file.path(),sha);continue;}
            if(doc.size()<=BatchBuffer.MAX_FILE){
                small.add(new ReadItem(file,sha));smallBytes+=doc.size();
            }else{
                if(sha==null)coldLarge++;
                large.add(file);
            }
        }
        boolean overlap=PipelinePolicy.overlapLarge(pipelineEnabled,uploadConcurrency,coldLarge);
        JSONArray largeInventory=new JSONArray();Map<SourceFiles.Doc,String> largeHashes=new HashMap<>();
        // The compatibility path keeps the previous prehash-all ordering.
        if(!overlap)for(var file:large){
            String sha=HashCache.matching(old,file.doc());
            if(sha==null){sha=hashLarge(source,null,file,label,()->cancel.check());largeHashes.put(file.doc(),sha);}
            resultHashes.put(file.path(),sha);largeInventory.put(fileSpec(file,sha));
        }
        if(!small.isEmpty()){
            final int sendLanes=PipelinePolicy.smallLanes(pipelineEnabled,small.size(),smallBytes);
            if(readBuffers==null)readBuffers=new ReadPipeline.Buffers();
            currentPath="批量读取中；尚未完成的批次可从原断点继续";
            new ReadPipeline<>(small,readConcurrency,item->item.file().doc().size(),()->{
                SourceFiles.ReadSession session=source.reader();
                return new ReadPipeline.Worker<ReadItem>(){
                    public String read(ReadItem item,byte[] buffer,int offset,ReadPipeline.Check stopped)throws Exception {
                        try{
                            String actual=FileRead.into(item.file().doc().size(),buffer,offset,()->session.open(item.file().doc()),stopped::check,stats::source);
                            if(item.expected()!=null&&!item.expected().equals(actual))throw new IOException("源文件内容与缓存校验值不符，请重新校验源文件");
                            return actual;
                        }catch(Exception e){throw new IOException("文件 "+item.file().path()+"："+SyncRunner.friendly(e),e);}
                    }
                    public void cancel(){session.cancel();}
                    public void close(){session.close();}
                };
            },new ReadPipeline.Sink<ReadItem>(){
                final ConcurrentLinkedQueue<Net> clients=new ConcurrentLinkedQueue<>();
                final ThreadLocal<Net> local=new ThreadLocal<>();
                final AtomicInteger nextClient=new AtomicInteger();
                public void send(ReadPipeline.Frame<ReadItem> frame,ReadPipeline.Check stopped)throws Exception {
                    Net sender=net;
                    if(sendLanes>1){sender=local.get();if(sender==null){sender=batchConnection(nextClient.getAndIncrement());clients.add(sender);local.set(sender);}}
                    stopped.check();JSONArray batch=new JSONArray();
                    for(int i=0;i<frame.items.size();i++)batch.put(fileSpec(frame.items.get(i).file(),frame.hashes[i]));
                    sendBatch(sender,prefix,revision,gid,batch,frame.bytes,frame.used,label,stopped);
                }
                public void acknowledge(ReadPipeline.Frame<ReadItem> frame)throws Exception {
                    // Only the caller owns HashCache/resultHashes; ACK order is not page order.
                    Map<SourceFiles.Doc,String> hashes=new HashMap<>();
                    for(int i=0;i<frame.items.size();i++)hashes.put(frame.items.get(i).file().doc(),frame.hashes[i]);
                    cache.putAll(hashes);
                    for(int i=0;i<frame.items.size();i++)resultHashes.put(frame.items.get(i).file().path(),frame.hashes[i]);
                }
                public void abort(){if(sendLanes==1)net.cancelRequest();for(var client:clients)client.cancelRequest();}
                // Connections survive book boundaries; run() closes them after all
                // pipelines drain. A lane is never shared by concurrent workers.
            },()->cancel.check(),began->{stats.prepared(began);report(label+" · 阶段：并行读取 / 批量发送 "+sendLanes+" 路\n"+transferred());},readBuffers,sendLanes).run();
        }
        if(overlap)overlapLarge(source,large,old,cache,resultHashes,revision,gid,label,prefix);
        else{
            cache.putAll(largeHashes);
            if(!large.isEmpty())uploadFiles(net,source,large,largeInventory,missingFiles(net,prefix,revision,gid,largeInventory),revision,gid,label,prefix);
        }
        for(var file:files){String sha=resultHashes.get(file.path());if(sha==null)throw new IOException("本书读取尚未完整，未推进断点");inventory.put(fileSpec(file,sha));}
        return inventory;
    }
    String hashLarge(SourceFiles source,SourceFiles.ReadSession reader,SourceFiles.FileEntry file,String label,ReadPipeline.Check stopped)throws Exception {
        stopped.check();currentPath=file.path();report(label+" · 阶段：较大文件校验"+(reader==null?"":" / 与上传重叠")+"\n"+transferred());
        MessageDigest md=MessageDigest.getInstance("SHA-256");long read=0,began=System.nanoTime();
        try(InputStream in=reader==null?source.open(file.doc()):reader.open(file.doc())){
            int n;while((n=in.read(hashBuffer))!=-1){stopped.check();md.update(hashBuffer,0,n);read+=n;}
        }finally{stats.hash(began);}
        stopped.check();if(read!=file.doc().size()||!(reader==null?source.unchanged(file.doc()):reader.unchanged(file.doc())))throw new IOException("源文件正在变化，请待下载完成后重试");
        return LocalState.hex(md.digest());
    }
    record PreparedLarge(SourceFiles.FileEntry file,String sha){}
    void overlapLarge(SourceFiles source,List<SourceFiles.FileEntry> files,Map<String,HashCache.Hash> old,HashCache cache,Map<String,String> results,String revision,String gid,String label,String prefix)throws Exception {
        SourceFiles.ReadSession hashing=source.reader();
        new PreparedPipeline<SourceFiles.FileEntry,PreparedLarge>(files,Math.min(2,uploadConcurrency),new PreparedPipeline.Prepare<>(){
            public PreparedLarge prepare(SourceFiles.FileEntry file,ReadPipeline.Check stopped)throws Exception {
                String sha=HashCache.matching(old,file.doc());if(sha==null)sha=hashLarge(source,hashing,file,label,stopped);
                return new PreparedLarge(file,sha);
            }
            public void cancel(){hashing.cancel();}public void close(){hashing.close();}
        },()->new PreparedPipeline.Worker<PreparedLarge>(){
            final Net sender=new Net(c,LocalState.pairing(c),stats,cancel);final SourceFiles.ReadSession reader=source.reader();final byte[] buffer=new byte[4*1024*1024];
            public void send(PreparedLarge item,ReadPipeline.Check stopped)throws Exception {
                long began=System.nanoTime();stats.beginUpload(began);
                try{
                    stopped.check();var file=item.file();
                    upload(sender,source,file.doc(),fileSpec(file,item.sha()).put("revision",revision).put("gid",gid),label,prefix,buffer,stopped,reader);
                    stopped.check();if(!reader.unchanged(file.doc()))throw new IOException("同步期间源文件发生变化");
                }catch(Exception e){throw new IOException("文件 "+item.file().path()+"："+SyncRunner.friendly(e),e);}
                finally{stats.upload(began);}
            }
            public void cancel(){reader.cancel();sender.cancelRequest();}
            public void close(){try{reader.close();}finally{sender.close();}}
        },item->{cache.putAll(Collections.singletonMap(item.file().doc(),item.sha()));results.put(item.file().path(),item.sha());},()->cancel.check()).run();
    }
    static JSONObject fileSpec(SourceFiles.FileEntry file,String sha)throws Exception {return new JSONObject().put("path",file.path()).put("size",file.doc().size()).put("sha256",sha);}
    Set<String> missingFiles(Net net,String prefix,String revision,String gid,JSONArray inventory)throws Exception {
        Set<String> expected=new HashSet<>();for(int i=0;i<inventory.length();i++)expected.add(inventory.getJSONObject(i).getString("path"));
        List<String> response=Catalog.strings(net.post(prefix+"files/status",new JSONObject().put("revision",revision).put("gid",gid).put("files",inventory)).getJSONArray("missing"));
        Set<String> missing=new HashSet<>(response);if(missing.size()!=response.size()||!expected.containsAll(missing))throw new IOException("NAS 返回未知或重复文件路径");return missing;
    }
    void sendBatch(Net net,String prefix,String revision,String gid,JSONArray files,byte[] bytes,int used,String label,ReadPipeline.Check stopped)throws Exception {
        if(files.length()==0)return;
        if(files.length()>BatchBuffer.MAX_FILES||used>BatchBuffer.MAX_BYTES)throw new IOException("批量文件超出上限");
        byte[] header=new JSONObject().put("revision",revision).put("gid",gid).put("files",files).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
        long began=System.nanoTime();stats.beginUpload(began);
        try{
            for(int attempt=0;;attempt++){
                stopped.check();report(label+" · 阶段：批量上传 "+files.length()+" 个文件\n"+transferred());
                try{
                    JSONObject result=net.batch(prefix+"files/batch",header,bytes,used);
                    if(result.getInt("confirmedFiles")!=files.length()||result.getLong("confirmedBytes")!=used)throw new IOException("NAS 批量确认不一致");
                    acknowledged(used);stats.batch(files.length());break;
                }catch(IOException e){
                    if(RecoveryPolicy.exhausted(e)||e instanceof Net.Failure f&&!f.retryable()||e instanceof javax.net.ssl.SSLHandshakeException||attempt>=3)throw e;
                    report("批量传输暂时中断，保留缓冲数据重试 "+(attempt+1)+" / 3\n"+SyncRunner.friendly(e));
                    for(int tick=0;tick<(attempt+1)*10;tick++){stopped.check();Thread.sleep(200);}
                }
            }
        }finally{stats.upload(began);}
        // Cache is updated by the caller's acknowledge hook, never a sending worker.
    }
    void upload(Net net,SourceFiles source,SourceFiles.Doc doc,JSONObject spec,String label)throws Exception {upload(net,source,doc,spec,label,"/sync/v1/");}
    void upload(Net net,SourceFiles source,SourceFiles.Doc doc,JSONObject spec,String label,String prefix)throws Exception {
        if(singleBuffer==null)singleBuffer=new byte[4*1024*1024];
        upload(net,source,doc,spec,label,prefix,singleBuffer);
    }
    void upload(Net net,SourceFiles source,SourceFiles.Doc doc,JSONObject spec,String label,String prefix,byte[] buffer)throws Exception {
        upload(net,source,doc,spec,label,prefix,buffer,()->cancel.check(),null);
    }
    void upload(Net net,SourceFiles source,SourceFiles.Doc doc,JSONObject spec,String label,String prefix,byte[] buffer,ReadPipeline.Check stopped,SourceFiles.ReadSession reader)throws Exception {
        Exception last=null;
        for(int attempt=0;attempt<4;attempt++) {
            stopped.check();try {
                JSONObject status=net.post(prefix+"file/begin",spec);if(status.getBoolean("done"))return;
                String id=status.getString("upload");long offset=status.getLong("offset");if(offset<0||offset>doc.size())throw new IOException("NAS 返回无效续传位置");
                try(InputStream in=reader==null?source.open(doc):reader.open(doc)) {
                    long skipped=0;
                    while(skipped<offset){stopped.check();long n=in.skip(offset-skipped);if(n<=0){if(in.read()<0)throw new EOFException("源文件变短");n=1;}skipped+=n;}
                    while(offset<doc.size()) {
                        stopped.check();int wanted=(int)Math.min(buffer.length,doc.size()-offset),count=0;
                        while(count<wanted){stopped.check();int n=in.read(buffer,count,wanted-count);if(n<0)throw new EOFException("源文件未下载完整");count+=n;}
                        long next=net.request(prefix+"file/chunk?upload="+id+"&offset="+offset,buffer,count).getLong("offset");
                        if(next!=offset+count)throw new IOException("NAS 返回无效写入位置");offset=next;acknowledged(count);
                        report(label+" · 阶段：上传文件 "+Math.round(offset*100.0/Math.max(1,doc.size()))+"%\n"+transferred());
                    }
                    if(in.read()!=-1)throw new IOException("源文件正在增长");
                }
                stopped.check();net.post(prefix+"file/finish",new JSONObject().put("upload",id));return;
            }catch(IOException e){stopped.check();if(RecoveryPolicy.exhausted(e)||e instanceof Net.Failure f&&!f.retryable() || e instanceof javax.net.ssl.SSLHandshakeException || e instanceof FileNotFoundException)throw e;last=e;if(attempt==3)break;report("传输暂时中断，正在重试 "+(attempt+1)+" / 4\n"+SyncRunner.friendly(e));for(int tick=0;tick<(attempt+1)*10;tick++){stopped.check();Thread.sleep(200);}}
        }throw last;
    }
    record UploadItem(SourceFiles.Doc doc,String path,JSONObject spec){}
    void uploadFiles(Net control,SourceFiles source,List<SourceFiles.FileEntry> files,JSONArray inventory,Set<String> needed,String revision,String gid,String label,String prefix)throws Exception {
        List<UploadItem> items=new ArrayList<>();
        for(int j=0;j<files.size();j++)if(needed.contains(files.get(j).path())){
            var file=files.get(j);items.add(new UploadItem(file.doc(),file.path(),new JSONObject(inventory.getJSONObject(j).toString()).put("revision",revision).put("gid",gid)));
        }
        if(items.isEmpty())return;
        long began=System.nanoTime();stats.beginUpload(began);
        try{
            if(uploadConcurrency==1){
                for(var item:items){cancel.check();currentPath=item.path();upload(control,source,item.doc(),item.spec(),label,prefix);if(!source.unchanged(item.doc()))throw new IOException("同步期间源文件发生变化，请重试");}
            }else{
                currentPath="并发上传中；具体失败文件见错误信息";
                // Each worker owns its TLS connection and one reusable 4 MiB buffer.
                ParallelFiles.run(items.size(),uploadConcurrency,()->new ParallelFiles.Worker(){
                    final Net net=new Net(c,LocalState.pairing(c),stats,cancel);
                    final byte[] buffer=new byte[4*1024*1024];
                    public void transfer(int index)throws Exception{
                        cancel.check();var item=items.get(index);
                        try{upload(net,source,item.doc(),item.spec(),label,prefix,buffer);if(!source.unchanged(item.doc()))throw new IOException("同步期间源文件发生变化");}
                        catch(Exception e){throw new IOException("文件 "+item.path()+"："+SyncRunner.friendly(e),e);}
                    }
                    public void close(){net.close();}
                });
            }
        }finally{stats.upload(began);}
        cancel.check();
    }
    void preflight()throws Exception {
        JSONObject report=MigrationReport.build(c,cancel,this::report);
        String suffix="";try(Net net=new Net(c,LocalState.pairing(c))){JSONObject health=net.get("/sync/v1/health");long free=health.getLong("freeBytes");suffix=String.format(Locale.CHINA,"\nNAS 剩余 %.2f GB（已同步文件不必再占用一份）",free/1e9);if(health.has("availableForSyncBytes"))suffix+=String.format(Locale.CHINA,"\n保护预留 %.2f GB · 可用于同步 %.2f GB",health.getLong("reserveBytes")/1e9,health.getLong("availableForSyncBytes")/1e9);if(health.optBoolean("spaceWarning",false))suffix+="\n空间余量偏低，接近保护预留时将暂停";}catch(Exception ignored){suffix="\nNAS 未连接，暂未检查剩余空间";}
        progress.update(MigrationReport.summary(report)+suffix);
    }
}
