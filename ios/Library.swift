import Foundation
import SwiftUI
import UIKit

@MainActor final class Library: ObservableObject {
    let covers:SmartCoverPipeline
    @Published var coversHidden=UserDefaults.standard.bool(forKey:"shelf.hideCovers") {
        didSet {
            guard coversHidden != oldValue else{return}
            UserDefaults.standard.set(coversHidden,forKey:"shelf.hideCovers")
            cancelCoverPrefetch();covers.reset(keepCache:true);coverEpoch+=1
            if !coversHidden{scheduleCoverPrefetch(anchor:lastCoverAnchor ?? 0)}
        }
    }
    let coverDisk:CoverDiskCache
    @Published private(set) var coverEpoch=0
    @Published private(set) var cacheUsage="正在统计…"
    @Published private(set) var cacheBusy=false
    @Published private(set) var diskEnabled=false
    @Published private(set) var cacheMessage=""
    private var coverScope:String?,coverRevision:String?
    private var serverThumbnails=false
    private var serverManifests=false
    private var serverConditionalManifests=false
    private var serverCatalogWindows=false
    private var relatedCapabilities=Set<String>()
    private var relatedBrowsing=false
    private var windowRefreshing=false
    private var windowValidator:(path:String,etag:String,revision:Int)?
    private var viewportBook:String?
    private var viewportActivity=0
    private var shelfInteracting=false
    private(set) var anchorPreservingRevision = -1
    let bodyDisk:BodyDiskCache
    private var manifestLoads:[String:(UUID,Task<Pages,Error>)]=[:]
    private var catalogPages=CatalogPageCache()
    private var catalogOwner:String?
    let catalogDisk:CatalogDiskStore
    @Published private(set) var catalogStatus=""
    @Published private(set) var browsingCachedCatalog=false
    private var cachedLibraryID:String?
    private var lastLiveCatalog:BookList?
    private var catalogTask:Task<Void,Never>?
    private var catalogTaskID=UUID()
    var canBrowseCatalog:Bool{base != nil || browsingCachedCatalog}
    private var pageLists=PageListCache()
    private var pageListEpoch=0
    private var pageListRequests:[String:UUID]=[:]
    private var coverStatsTask:Task<Void,Never>?
    private var prefetchTask:Task<Void,Never>?
    private var prefetchGeneration=0
    private var lastCoverAnchor:Int?
    private var coverScreenCount=8
    private var reading=false,foreground=true
    @Published var address=""
    @Published var secret=""
    private(set) var booksRevision=0
    @Published var books:[Book]=[]{didSet{booksRevision+=1}}
    @Published var total=0
    @Published var pageIndex=0
    @Published var pageSize=100
    var pageCount:Int { PagingRules.count(total:total,size:pageSize) }
    @Published var orderNotice=""
    @Published var error=""
    @Published var loading=false
    @Published private(set) var startupPending=true
    var showStartupPlaceholder:Bool{startupPending && books.isEmpty && error.isEmpty}
    var coverDisplayScope:String?{coverScope}
    @Published private(set) var paired:PairingCode?
    @Published private(set) var serverTarget=ServerTarget.selected
    @Published private(set) var shelfSource=ShelfSource.selected
    @Published private(set) var manualAvailable=false
    @Published private(set) var switchingShelf=false
    @Published private(set) var restoredBookID:String?
    private func wirePath(_ path:String)->String{shelfSource.path(path,target:serverTarget)}
    private var positionKey:String{"shelf.position."+(paired?.deviceId ?? "unpaired")+"."+shelfSource.rawValue}
    func selectShelf(_ source:ShelfSource)async {
        guard serverTarget == .nas,source != shelfSource,!reading,!relatedBrowsing,!loading,!switchingShelf else{return}
        switchingShelf=true;defer{switchingShelf=false;if Task.isCancelled{loading=false}}
        UserDefaults.standard.set(pageIndex,forKey:positionKey+".page")
        UserDefaults.standard.set(viewportBook,forKey:positionKey+".anchor")
        generation+=1;automatic?.cancel();automatic=nil;discovery.stop();cancelCoverPrefetch();cancelCatalogWork()
        shelfSource=source;UserDefaults.standard.set(source.rawValue,forKey:"shelf.source")
        let page=UserDefaults.standard.integer(forKey:positionKey+".page"),anchor=UserDefaults.standard.string(forKey:positionKey+".anchor")
        base=nil;activeToken="";books=[];total=0;pageIndex=0;restoredBookID=nil
        catalogPages.clear();catalogOwner=nil;configureCoverScope(device:nil,revision:nil,force:true)
        viewportBook=nil;windowValidator=nil;locatedBookID=nil;locateMessage="";error="";orderNotice=""
        browsingCachedCatalog=false;cachedLibraryID=nil;lastLiveCatalog=nil;catalogStatus="";covers.cacheOnly=false
        let ticket=generation
        loading=true
        await restoreLocalCatalog()
        guard ticket==generation,foreground,!Task.isCancelled else{return}
        loading=false
        let expected=generation+1
        await reconnect()
        guard expected==generation,foreground,!Task.isCancelled else{return}
        if base != nil || browsingCachedCatalog {
            await loadPage(min(max(0,page),pageCount-1))
            restoredBookID=books.first(where:{$0.id==anchor})?.id ?? books.first?.id
        }
        setForeground(foreground)
    }
    @Published private(set) var recentReading:RecentReading?
    private(set) var recentScope:String?
    private(set) var recentRevision=0
    @Published private(set) var locatingRecent=false
    @Published private(set) var locateMessage=""
    @Published private(set) var locatedBookID:String?
    @Published private(set) var pairingStatus="首次连接后，将记住这台书库服务器"
    private var activeToken=""
    private var generation=0
    private var automatic:Task<Void,Never>?
    private let discovery=AndroidDiscovery()
    var base:URL?
    private let transport:LimitedHTTP
    private let metadata:MetadataParser
    private let loadPair:()throws->PairingCode?
    private let savePair:(PairingCode)throws->Void
    private let removePair:()throws->Void
    private let lookup:((String)async->[String])?
    init(transport:LimitedHTTP=LimitedHTTP(),loadPair:(()throws->PairingCode?)?=nil,savePair:((PairingCode)throws->Void)?=nil,removePair:(()throws->Void)?=nil,lookup:((String)async->[String])?=nil,metadata:MetadataParser = .shared,catalogDisk:CatalogDiskStore=CatalogDiskStore(),coverDisk:CoverDiskCache?=nil,bodyDisk:BodyDiskCache=BodyDiskCache()){
        self.bodyDisk=bodyDisk
        let disk=coverDisk ?? CoverDiskCache();self.coverDisk=disk;covers=SmartCoverPipeline(disk:disk)
        self.catalogDisk=catalogDisk;self.transport=transport;self.metadata=metadata;self.loadPair=loadPair ?? {try PairingKeychain.load(account:ServerTarget.selected.rawValue)}
        self.savePair=savePair ?? {try PairingKeychain.save($0,account:ServerTarget.selected.rawValue)};self.removePair=removePair ?? {try PairingKeychain.remove(account:ServerTarget.selected.rawValue)};self.lookup=lookup
        covers.changed={[weak self] in self?.scheduleCacheStats()}
        covers.variantLoad={[weak self] path,etag,pixels in guard let self else{throw CancellationError()};return try await self.coverResponse(path,etag:etag,pixels:pixels)}
    }
    deinit{transport.close()}
    func diagnoseConnection()async->ConnectionDiagnosticReport {
        let saved=paired ?? (try? loadPair())
        return await ConnectionDiagnostics.run(address:address.isEmpty ? (saved?.address ?? ""):address,code:saved,source:shelfSource)
    }
    private func scheduleCacheStats(){
        guard coverStatsTask==nil else{return}
        coverStatsTask=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:2_000_000_000)}catch{return}
            guard let self else{return};coverStatsTask=nil;await refreshCacheUsage()
        }
    }
    func refreshCacheUsage()async{
        do{let bytes=try await coverDisk.usage(),bodyBytes=try await bodyDisk.usage(),indexing=await coverDisk.isIndexing();guard !Task.isCancelled else{return};cacheUsage=(indexing ? "索引整理中 · 已统计 ":"")+ByteCountFormatter.string(fromByteCount:Int64(bytes+bodyBytes),countStyle:.decimal)+" / 2 GB";if indexing{scheduleCacheStats()}}
        catch{if !Task.isCancelled{cacheUsage="磁盘缓存暂不可用，仍可联网加载"}}
    }
    func clearCoverCache()async{
        guard !cacheBusy else{return};cacheBusy=true;coverStatsTask?.cancel();coverStatsTask=nil
        cancelCoverPrefetch();covers.suspend(true);covers.reset()
        clearPageLists()
        do{try await bodyDisk.clear();try await coverDisk.clear();cacheMessage="已清空封面和近期正文；正在使用的文件会在播放器释放后清除"}catch{cacheMessage="部分缓存无法清除，请解锁手机或稍后重试"}
        await refreshCacheUsage();cacheBusy=false;covers.suspend(reading || !foreground);coverEpoch+=1
        scheduleCoverPrefetch(anchor:lastCoverAnchor ?? 0)
    }
    private func configureCoverScope(device:String?,revision:String?,libraryID:String?=nil,bookIdentities:[Book]=[],force:Bool=false){
        var resumeScope=device.flatMap{device in libraryID.map{device+"\n"+$0}}
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--shelf-demo"){resumeScope="synthetic-shelf-v1"}
        #endif
        if resumeScope != recentScope {
            recentScope=resumeScope
            if let resumeScope{ReadingProgress.register(scope:resumeScope,server:serverTarget)}
            setRecent(resumeScope.flatMap{RecentReading.load(scope:$0)})
        }
        if var recent=recentReading,let book=bookIdentities.first(where:{$0.id==recent.book.id}),book != recent.book {
            recent.book=book;setRecent(recent);recent.save()
        }
        let scope:String? = device.flatMap{device in (libraryID ?? revision).map{device+"\n"+$0}}
        let stableIdentities=scope != nil && libraryID != nil && bookIdentities.allSatisfy{$0.coverIdentity != nil}
        let changed=force || scope != coverScope || (!stableIdentities && revision != coverRevision)
        cancelCoverPrefetch();lastCoverAnchor=nil;coverScope=scope;diskEnabled=scope != nil
        coverRevision=revision
        let identities=Dictionary(uniqueKeysWithValues:bookIdentities.compactMap{book in book.coverIdentity.map{("/v1/books/\(book.id)/cover",$0)}})
        covers.configureScope(scope,revision:revision ?? "",identities:identities)
        if changed{coverEpoch+=1;clearPageLists()}
        pageLists.configure(catalogOwner==nil ? nil:scope.flatMap{scope in serverManifests ? scope:revision.map{scope+"\n"+$0}})
    }
    private func setRecent(_ recent:RecentReading?){
        guard recent != recentReading else{return};recentRevision+=1;recentReading=recent
    }
    func rememberReading(book:Book,pages:[Page],index:Int,scope:String?){
        guard let scope,scope==recentScope,pages.indices.contains(index) else{return}
        let value=RecentReading(scope:scope,book:book,pageNumber:pages[index].number,position:index,pageCount:pages.count)
        guard value.valid else{return};ReadingProgress.save(value.pageNumber,scope:scope,id:book.id);value.save();locateMessage="";setRecent(value)
    }
    func selectServer(_ target:ServerTarget)async {
        guard target != serverTarget,!reading,!loading else{return}
        generation+=1;automatic?.cancel();automatic=nil;discovery.stop();cancelCoverPrefetch();cancelCatalogWork()
        // Keep credentials and disk caches for BOTH sources. Never auto-fallback.
        UserDefaults.standard.set(target.rawValue,forKey:"server.selected");serverTarget=target;manualAvailable=false
        base=nil;activeToken="";paired=nil;address="";secret="";books=[];total=0;pageIndex=0
        catalogPages.clear();catalogOwner=nil;configureCoverScope(device:nil,revision:nil,force:true)
        locatedBookID=nil;locateMessage="";error=""
        browsingCachedCatalog=false;cachedLibraryID=nil;lastLiveCatalog=nil;catalogStatus="";covers.cacheOnly=false
        do{paired=try loadPair();address=paired?.address ?? ""}catch{self.error="无法读取保存的配对，请解锁手机后重试。"}
        pairingStatus=paired==nil ? "请配对"+target.title:"正在连接"+target.title
        setForeground(foreground)
    }
    func resetReadingProgress()->Int {
        let count=ReadingProgress.reset();setRecent(nil);locatedBookID=nil;locateMessage="";return count
    }
    func updateCoverViewport(_ size:CGSize,columns:Int=2){
        let columns=min(3,max(2,columns))
        // The edge overlay no longer reserves a separate column for its rail.
        let width=max(1,(size.width-32-CGFloat(columns-1)*12)/CGFloat(columns))
        let rows=max(1,Int(ceil(size.height/(width*1.5+68))))
        covers.nearCount=columns
        let target=Int(width*UIScreen.main.scale)
        let pixels=target<=320 ? 320 : (target<=480 ? 480:640)
        if covers.pixelSize != pixels{covers.pixelSize=pixels;covers.reset();coverEpoch+=1}
        let count=min(18,max(4,columns*rows));guard count != coverScreenCount else{return}
        coverScreenCount=count;scheduleCoverPrefetch(anchor:lastCoverAnchor ?? 0)
    }
    func cancelCoverPrefetch(){
        prefetchGeneration+=1;prefetchTask?.cancel();prefetchTask=nil
        covers.prefetch([]){_ in throw CancellationError()}
    }
    func scheduleCoverPrefetch(anchor:Int){
        let direction=anchor<(lastCoverAnchor ?? anchor) ? -1 : 1;lastCoverAnchor=anchor
        cancelCoverPrefetch()
        guard !coversHidden,foreground,!reading,!relatedBrowsing,!cacheBusy,!books.isEmpty else{return}
        let paths=CoverRules.prefetch(anchor:anchor,count:books.count,screen:coverScreenCount,direction:direction).filter{!books[$0].isMissing}.map{"/v1/books/\(books[$0].id)/cover"}
        let ticket=prefetchGeneration
        prefetchTask=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:150_000_000)}catch{return}
            guard let self,!coversHidden,ticket==prefetchGeneration,foreground,!reading,!relatedBrowsing,!cacheBusy else{return}
            covers.prefetch(paths){[weak self] path in guard let self else{throw CancellationError()};return try await data(path)}
        }
    }
    func setReading(_ value:Bool){if reading != value{viewportActivity+=1};reading=value;cancelCoverPrefetch();covers.suspend(value || !foreground || cacheBusy);if value{cancelCatalogWork()}else{scheduleCatalogSave()}}
    func setShelfInteracting(_ value:Bool){if shelfInteracting != value{viewportActivity+=1};shelfInteracting=value}
    func recordVisibleBook(_ id:String?){if viewportBook != id{viewportActivity+=1};viewportBook=id}
    var relatedContext:String{"\(generation)\n\(serverTarget.rawValue)\n\(base?.absoluteString ?? "")\n\(recentScope ?? "")"}
    func supportsRelated(_ kind:RelatedKind)->Bool{serverTarget == .nas && base != nil && relatedCapabilities.contains(kind.rawValue)}
    func setRelatedBrowsing(_ value:Bool){
        guard relatedBrowsing != value else{return};relatedBrowsing=value;viewportActivity+=1;cancelCoverPrefetch()
        if value{cancelCatalogWork()}
        else{
            registerRelatedCovers([]);scheduleCoverPrefetch(anchor:lastCoverAnchor ?? 0);scheduleCatalogSave()
        }
    }
    func registerRelatedCovers(_ related:[Book]){
        guard let scope=coverScope else{return}
        var identities=[String:String]()
        for book in books+related{if let identity=book.coverIdentity{identities["/v1/books/\(book.id)/cover"]=identity}}
        covers.configureScope(scope,revision:coverRevision ?? "",identities:identities)
    }
    private func relatedData(_ path:String,kind:RelatedKind)async throws->(Data,String){
        guard supportsRelated(kind),let base,let library=cachedLibraryID else{throw RelatedLoadError.unavailable}
        let context=relatedContext
        guard let url=URL(string:wirePath(path),relativeTo:base) else{throw LibraryError.malformed}
        var request=URLRequest(url:url);request.timeoutInterval=12
        request.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
        let data=try await transport.data(request,limit:8*1024*1024)
        try Task.checkCancellation();guard context==relatedContext else{throw CancellationError()}
        return(data,library)
    }
    func relatedOptions(book:String,kind:RelatedKind)async throws->RelatedOptions {
        guard book.range(of:"\\A[1-9][0-9]{0,18}\\z",options:.regularExpression) != nil else{throw LibraryError.malformed}
        let context=relatedContext
        let evidence=relatedEvidence(kind:kind,prefix:"?")
        let (data,library)=try await relatedData("/v1/books/\(book)/\(kind.rawValue)"+evidence,kind:kind)
        let result=try await metadata.relatedOptions(data,book:book,kind:kind,library:library)
        try Task.checkCancellation();guard context==relatedContext else{throw CancellationError()};return result
    }
    func relatedResult(book:String,kind:RelatedKind,choice:String,page:Int,size:Int)async throws->RelatedResult {
        guard book.range(of:"\\A[1-9][0-9]{0,18}\\z",options:.regularExpression) != nil,
              choice.range(of:"\\A[a-f0-9]{64}\\z",options:.regularExpression) != nil,
              (0...400).contains(page),(50...500).contains(size),size%50==0 else{throw LibraryError.malformed}
        let context=relatedContext
        let evidence=relatedEvidence(kind:kind,prefix:"&")
        let(data,library)=try await relatedData("/v1/books/\(book)/\(kind.rawValue)/\(choice)?offset=\(page*size)&limit=\(size)"+evidence,kind:kind)
        let result=try await metadata.relatedResult(data,book:book,kind:kind,choice:choice,size:size,offset:page*size,library:library)
        try Task.checkCancellation();guard context==relatedContext else{throw CancellationError()};return result
    }

    private func relatedEvidence(kind:RelatedKind,prefix:String)->String{
        if relatedCapabilities.contains("related-evidence-v3"){
            return prefix+"evidence=3"+(kind == .authors && relatedCapabilities.contains("author-credit-fallback-v1") ? "&credit=1":"")+(relatedCapabilities.contains("related-relaxed-v1") ? "&relaxed=1":"")
        }
        return kind == .authors && relatedCapabilities.contains("author-evidence-v2") ? prefix+"includePossible=1":""
    }

    // A bounded, authenticated current-page check. It never sets global loading,
    // disconnects an active reader, or fetches all 10,000 books to locate an ID.
    func refreshVisibleCatalog()async {
        guard serverTarget == .nas,serverCatalogWindows,foreground,!reading,!relatedBrowsing,!loading,!shelfInteracting,!windowRefreshing,
              let base,let libraryID=cachedLibraryID,let owner=catalogOwner else{return}
        let ticket=generation,revision=booksRevision,page=pageIndex,size=pageSize,activity=viewportActivity
        let anchor=books.first(where:{$0.id==viewportBook})?.id ?? books.first?.id ?? ""
        let path="/v1/books/window?anchor=\(anchor)&offset=\(page*size)&limit=\(size)"
        guard let url=URL(string:wirePath(path),relativeTo:base) else{return}
        let candidate=windowValidator.flatMap{$0.path==path && $0.revision==revision ? $0.etag:nil}
        var request=URLRequest(url:url);request.timeoutInterval=8
        request.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
        if let candidate{request.setValue(candidate,forHTTPHeaderField:"If-None-Match")}
        windowRefreshing=true;defer{windowRefreshing=false}
        func stillCurrent()->Bool{!Task.isCancelled && ticket==generation && revision==booksRevision && page==pageIndex && size==pageSize && activity==viewportActivity && foreground && !reading && !loading && !shelfInteracting && self.base==base}
        do {
            let response=try await transport.response(request,limit:8*1024*1024,priority:URLSessionTask.lowPriority,allowNotModified:candidate != nil)
            guard stillCurrent(),let etag=response.etag,ManifestValidator.valid(etag) else{return}
            if response.status==304{guard response.data.isEmpty,etag==candidate else{throw LibraryError.malformed};return}
            let (window,validated)=try await metadata.window(response.data,size:size,anchor:anchor,library:libraryID)
            guard stillCurrent() else{return}
            let list=window.catalog,newPage=window.offset/size
            catalogPages.clear();catalogPages.store(validated,owner:owner)
            let changed=books != list.books || total != list.total || pageIndex != newPage || coverRevision != list.catalogRevision
            if changed {
                configureCoverScope(device:owner,revision:list.catalogRevision,libraryID:list.libraryId,bookIdentities:list.books)
                // Only this content transaction may preserve an anchor across a
                // page boundary. Explicit next/previous/jump still starts at top.
                anchorPreservingRevision=booksRevision+1
                pageIndex=newPage;total=list.total;books=list.books
                viewportBook=window.anchor ?? list.books.first?.id
                orderNotice=list.orderVerified ? "":"列表采用备份查询顺序，同值记录位置待核对；漫画内按数字页码阅读。"
                scheduleCoverPrefetch(anchor:list.books.firstIndex(where:{$0.id==viewportBook}) ?? 0)
            }
            lastLiveCatalog=list;windowValidator=(path,etag,booksRevision)
            scheduleCatalogSave()
        }catch{
            // A failed background check retains the last complete display.
            // The next foreground interval retries; no clearing or silent reorder.
            if stillCurrent(){windowValidator=nil}
        }
    }

    private func cancelCatalogWork(){catalogTaskID=UUID();catalogTask?.cancel();catalogTask=nil}
    func restoreLocalCatalog()async {
        guard serverTarget == .nas,base==nil,books.isEmpty,let owner=paired?.deviceId else{return}
        let ticket=generation
        do {
            guard let saved=try await catalogDisk.page(owner:owner,page:0,size:pageSize,source:shelfSource),ticket==generation,!Task.isCancelled,base==nil,paired?.deviceId==owner else{return}
            catalogOwner=owner;cachedLibraryID=saved.list.libraryId
            browsingCachedCatalog=true;covers.cacheOnly=true
            configureCoverScope(device:owner,revision:saved.list.catalogRevision,libraryID:saved.list.libraryId,bookIdentities:saved.list.books,force:true)
            books=saved.list.books;total=saved.list.total;pageIndex=0
            startupPending=false
            catalogStatus="本地目录预览 · 正在核对 NAS；正文需连接后阅读"
        }catch{if ticket==generation{catalogStatus="本地目录暂不可用，联网后可重新建立"}}
    }
    private func scheduleCatalogSave(){
        guard serverTarget == .nas,foreground,!reading,!relatedBrowsing,base != nil,lastLiveCatalog != nil,catalogTask==nil else{return}
        let id=UUID();catalogTaskID=id
        catalogTask=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:1_500_000_000)}catch{return}
            guard let self,id==catalogTaskID else{return}
            await saveLocalCatalog(force:false)
            if id==catalogTaskID{catalogTask=nil}
        }
    }
    func refreshLocalCatalog()async{
        cancelCatalogWork();let id=catalogTaskID
        let task=Task<Void,Never>{[weak self] in if let self{await saveLocalCatalog(force:true)}}
        catalogTask=task
        await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
        if id==catalogTaskID{catalogTask=nil}
    }
    private func saveLocalCatalog(force:Bool)async {
        guard serverTarget == .nas,foreground,!reading,!loading,let url=base,let owner=paired?.deviceId,let known=lastLiveCatalog else{return}
        let ticket=generation,id=catalogTaskID,token=activeToken
        var stage:CatalogDiskStore.Ticket?
        func live()throws{try Task.checkCancellation();guard ticket==generation,id==catalogTaskID,foreground,!reading,!loading,base==url,paired?.deviceId==owner else{throw CancellationError()}}
        func fetch(_ offset:Int,_ size:Int)async throws->BookList {
            try live();var request=URLRequest(url:URL(string:wirePath("/v1/books?offset=\(offset)&limit=\(size)"),relativeTo:url)!)
            request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.timeoutInterval=10
            // Background metadata failure must not disconnect an active reader.
            let result=try await metadata.catalog(transport.data(request,limit:8*1024*1024,priority:URLSessionTask.lowPriority),page:offset/size,size:size).list
            try live();return result
        }
        do {
            if !force,let saved=try await catalogDisk.page(owner:owner,library:known.libraryId,page:0,size:50),CatalogLocator.sameSnapshot(saved.list,known),Date().timeIntervalSince(saved.received)<15*60 {
                try live();catalogStatus="本地目录已保存 · \(saved.list.total) 本";return
            }
            let first=try await fetch(0,500)
            guard first.orderVerified,first.libraryId==known.libraryId else{throw LibraryError.unverifiedOrder}
            let staging=try await catalogDisk.begin(owner:owner,first:first);stage=staging;try live()
            catalogStatus="保存本地目录 \(first.books.count) / \(first.total) · 不下载正文"
            var offset=first.books.count
            while offset<first.total {
                try await Task.sleep(nanoseconds:150_000_000);try live()
                let page=try await fetch(offset,500)
                try await catalogDisk.append(page,offset:offset,ticket:staging);try live()
                offset+=page.books.count;catalogStatus="保存本地目录 \(offset) / \(first.total) · 不下载正文"
            }
            let confirmed=try await fetch(0,50);try live()
            try await catalogDisk.commit(staging,confirmed:confirmed);stage=nil
            try live();catalogStatus="本地目录已保存 · \(first.total) 本"
        }catch {
            if let stage{try? await catalogDisk.abort(stage)}
            if ticket==generation,id==catalogTaskID {
                catalogStatus=error is CancellationError ? "本地目录更新已暂停，保留上次完整目录":"本地目录尚未更新，保留上次完整目录；可稍后重试"
            }
        }
    }
    func prioritizePage(_ path:String){transport.prioritizePage(wirePath(path))}
    func coverResponse(_ path:String,etag:String?,pixels:Int=480)async throws->LimitedHTTP.Payload {
        guard !coversHidden else{throw CancellationError()}
        #if DEBUG && targetEnvironment(simulator)
        if !ProcessInfo.processInfo.arguments.contains("--nas-thumbnail-contract-checks"),ProcessInfo.processInfo.arguments.contains(where:{$0.hasSuffix("-checks") || $0.hasSuffix("-demo")}){return LimitedHTTP.Payload(data:try await data(path),status:200,etag:nil)}
        #endif
        guard let route=CoverRequest.path(path,pixels:pixels,thumbnails:serverTarget == .nas && serverThumbnails),let base,let url=URL(string:wirePath(route),relativeTo:base) else{throw LibraryError.unsafeAddress}
        let ticket=generation
        var request=URLRequest(url:url);request.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
        if let etag,CoverRecord.validETag(etag){request.setValue(etag,forHTTPHeaderField:"If-None-Match")}
        do {
            var result=try await transport.response(request,limit:8*1024*1024,allowNotModified:etag != nil)
            // A requested derivative can still be an original-file fallback.
            // The decoder must independently validate format and dimensions.
            if serverTarget == .nas && serverThumbnails{result.thumbnailPixels=pixels<=320 ? 320:(pixels<=480 ? 480:640)}
            try Task.checkCancellation();guard ticket==generation else{throw CancellationError()};return result
        }catch{
            recordReadFailure(error,ticket:ticket)
            throw error
        }
    }
    func data(_ path:String,priority:Float=URLSessionTask.defaultPriority,retryPage:Bool=false) async throws -> Data {
        if coversHidden,path.hasSuffix("/cover"){throw CancellationError()}
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--scheduling-checks"){ReaderDemo.requests[path,default:0]+=1;return ReaderDemo.data(path)}
        if ProcessInfo.processInfo.arguments.contains("--fail-page-image"),path.contains("/pages/"){throw LibraryError.malformed}
        if ProcessInfo.processInfo.arguments.contains("--changed-page-image"),path.contains("/pages/"){throw PageReadFailure.changed}
        if ProcessInfo.processInfo.arguments.contains("--animation-checks") || ProcessInfo.processInfo.arguments.contains("--animation-policy-checks") || ProcessInfo.processInfo.arguments.contains("--animation-demo"){ReaderDemo.requests[path,default:0]+=1;return ReaderDemo.animationData(path)}
        if ProcessInfo.processInfo.arguments.contains("--shelf-demo") || ProcessInfo.processInfo.arguments.contains("--shelf-jump-checks") {
            if path.hasPrefix("/v1/books?") {
                ReaderDemo.requests["shelf-list",default:0]+=1
                let items=URLComponents(string:"http://fixture"+path)!.queryItems!
                let offset=Int(items.first{$0.name=="offset"}!.value!)!,limit=Int(items.first{$0.name=="limit"}!.value!)!
                let books=(offset..<min(10071,offset+limit)).map{Book(id:String($0+1),title:"合成封面 · 第 \($0+1) 本",rank:$0,pageCount:[24,128,768,64,256,1024][$0%6])}
                return try JSONEncoder().encode(BookList(orderVerified:!ProcessInfo.processInfo.arguments.contains("--order-notice-demo"),total:10071,books:books,orderPolicy:"snapshot-query"))
            }
            return ReaderDemo.data(path)
        }
        if ProcessInfo.processInfo.arguments.contains("--reader-demo") || ProcessInfo.processInfo.arguments.contains("--performance-checks") || ProcessInfo.processInfo.arguments.contains("--native-pager-checks") || ProcessInfo.processInfo.arguments.contains("--rapid-pager-checks") {ReaderDemo.requests[path,default:0]+=1;return ReaderDemo.data(path)}
        #endif
        guard let base else {throw LibraryError.unsafeAddress}
        guard let url=URL(string:wirePath(path),relativeTo:base) else {throw LibraryError.malformed}
        var r=URLRequest(url:url);r.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
        let limit=path.hasSuffix("/cover") ? 8*1024*1024 : (path.hasSuffix("/pages") || path.hasSuffix("/manifest") || path.hasPrefix("/v1/books?") ? 8*1024*1024 : 50*1024*1024)
        let ticket=generation
        do{
            let isPage=path.range(of:"^/v1/books/[1-9][0-9]{0,18}/pages/[1-9][0-9]{0,7}$",options:.regularExpression) != nil
            for attempt in 0...1 {
                do {
                    let value:Data
                    if serverTarget == .nas,serverManifests,isPage {value=try await cachedBody(path,request:r,priority:priority)}
                    else{value=try await transport.data(r,limit:limit,priority:priority)}
                    try Task.checkCancellation();guard ticket==generation else{throw CancellationError()};return value
                }catch{
                    guard retryPage,isPage,attempt==0,PageReadFailure.classify(error).automaticRetry else{throw error}
                    try await Task.sleep(nanoseconds:400_000_000)
                    guard ticket==generation,self.base==base else{throw CancellationError()}
                }
            }
            throw CancellationError()
        }catch{
            recordReadFailure(error,ticket:ticket)
            throw error
        }
    }
    /// A stale request must never disconnect a newer foreground/server session.
    /// HTTP rejections, decoding failures and cancellation are not connectivity loss.
    private func recordReadFailure(_ error:Error,ticket:Int) {
        guard ticket==generation,paired != nil,let network=error as? URLError,
              [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.timedOut,.cannotFindHost].contains(network.code) else{return}
        base=nil;pairingStatus="连接中断，正在等待"+serverTarget.title+"恢复…"
    }
    private func verify(_ code:PairingCode,at address:String)async throws->URL {
        let url=try LibraryRules.address(address)
        let nonce=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        var request=URLRequest(url:URL(string:"/v2/identity?nonce="+nonce,relativeTo:url)!);request.timeoutInterval=3
        let proof=try JSONDecoder().decode(IdentityProof.self,from:await transport.data(request,limit:2048))
        guard PairingProof.verify(proof,code:code,nonce:nonce) else{throw LibraryError.malformed};return url
    }
    private func establish(_ code:PairingCode,at address:String,ticket:Int)async throws {
        var supportsThumbnails=false,supportsManifests=false,supportsConditionalManifests=false,supportsCatalogWindows=false
        var supportsRelated=Set<String>()
        let url=try await (code.version==2 ? verify(code,at:address) : LibraryRules.address(address))
        try Task.checkCancellation();guard ticket==generation else{throw CancellationError()}
        if serverTarget == .nas {
            let request=URLRequest(url:URL(string:"/v2/health",relativeTo:url)!)
            let service=try JSONDecoder().decode(ReaderService.self,from:await transport.data(request,limit:4096))
            try Task.checkCancellation();guard ticket==generation else{throw CancellationError()}
            guard service.compatible else{throw ServerFailure.incompatible}
            manualAvailable=service.capabilities.contains("manual-library-v1")
            guard shelfSource != .manual || manualAvailable else{throw ServerFailure.manualUnsupported}
            supportsThumbnails=service.thumbnails
            supportsManifests=service.pageManifests
            supportsConditionalManifests=service.conditionalManifests
            supportsCatalogWindows=service.catalogWindows
            supportsRelated=Set(RelatedKind.allCases.filter{service.related($0)}.map(\.rawValue))
            if service.related(.authors),service.capabilities.contains("author-evidence-v2"){supportsRelated.insert("author-evidence-v2")}
            if service.capabilities.contains("related-evidence-v3"){supportsRelated.insert("related-evidence-v3")}
            if service.related(.authors),service.capabilities.contains("related-evidence-v3"),service.capabilities.contains("author-credit-fallback-v1"){supportsRelated.insert("author-credit-fallback-v1")}
            if service.capabilities.contains("related-evidence-v3"),service.capabilities.contains("related-relaxed-v1"){supportsRelated.insert("related-relaxed-v1")}
            try Task.checkCancellation();guard ticket==generation else{throw CancellationError()}
            // A consumed PIN must not be lost when the first migration is not yet
            // published. Persist only AFTER identity and compatibility verification.
            let saved=PairingCode(app:"localshelf",version:2,address:address,token:code.token,deviceId:code.deviceId)
            let replacing=paired?.deviceId != saved.deviceId
            try savePair(saved);paired=saved;self.address=address
            if replacing {
                base=nil;activeToken="";books=[];total=0;pageIndex=0;catalogPages.clear();catalogOwner=nil
                configureCoverScope(device:nil,revision:nil,force:true);locatedBookID=nil;locateMessage=""
            }
        }
        let size=pageSize
        var request=URLRequest(url:URL(string:wirePath("/v1/books?offset=0&limit=\(size)"),relativeTo:url)!)
        request.setValue("Bearer "+code.token,forHTTPHeaderField:"Authorization");request.timeoutInterval=8
        let validated=try await metadata.catalog(transport.data(request,limit:8*1024*1024),page:0,size:size)
        let list=validated.list
        guard serverTarget != .nas || shelfSource.accepts(list) else{throw LibraryError.malformed}
        try Task.checkCancellation();guard ticket==generation else{throw CancellationError()}
        if code.version==2 {
            let saved=PairingCode(app:"localshelf",version:2,address:address,token:code.token,deviceId:code.deviceId)
            try savePair(saved);paired=saved;pairingStatus="已连接"+serverTarget.title+" · 下次自动连接"
        }else {pairingStatus="旧版临时连接：升级安卓并扫码一次，才能自动重连"}
        serverThumbnails=supportsThumbnails
        serverManifests=supportsManifests
        serverConditionalManifests=supportsConditionalManifests
        serverCatalogWindows=supportsCatalogWindows;windowValidator=nil;viewportBook=nil
        relatedCapabilities=supportsRelated
        browsingCachedCatalog=false;covers.cacheOnly=false;cachedLibraryID=list.libraryId;lastLiveCatalog=list
        catalogOwner=code.version==2 ? code.deviceId:nil
        catalogPages.clear() // every verified reconnect establishes a fresh snapshot
        catalogPages.store(validated,owner:catalogOwner)
        configureCoverScope(device:code.version==2 ? code.deviceId : nil,revision:list.catalogRevision,libraryID:list.libraryId,bookIdentities:list.books,force:true);base=url;activeToken=code.token
        self.address=address;secret=code.token;books=list.books;total=list.total;pageIndex=0;error=""
        orderNotice=list.orderVerified ? "" : "列表采用备份查询顺序，同值记录位置待核对；漫画内按数字页码阅读。"
        scheduleCoverPrefetch(anchor:0)
        scheduleCatalogSave()
    }
    func connect(code:PairingCode? = nil) async {
        guard !loading else{return};generation+=1;let ticket=generation;loading=true
        defer{if generation==ticket{loading=false;startupPending=false}}
        do {
            let candidate=code ?? PairingCode(app:"localshelf",version:1,address:address.trimmingCharacters(in:.whitespacesAndNewlines),token:secret)
            let checked=try PairingCode.parse(String(decoding:JSONEncoder().encode(candidate),as:UTF8.self))
            guard checked.version==2 || paired==nil else{throw LibraryError.malformed}
            guard serverTarget == .android || checked.version==2 else{throw ServerFailure.incompatible}
            try await establish(checked,at:checked.address,ticket:ticket)
        }catch{if ticket==generation{self.error=(error as? ServerFailure)?.errorDescription ?? "连接失败或身份无法验证。请确认书库服务已开启、地址正确且两端处于同一局域网。"}}
    }
    func connect(pin:String)async{
        await connectCredential(pin,passwordMode:false)
    }
    func connect(password:String)async{
        await connectCredential(password,passwordMode:true)
    }
    private func connectCredential(_ input:String,passwordMode:Bool)async{
        guard !loading else{return};generation+=1;let ticket=generation;loading=true
        defer{if generation==ticket{loading=false;startupPending=false}}
        do{
            guard !passwordMode || serverTarget == .nas else{throw ServerFailure.incompatible}
            let body=try passwordMode ? NASPassword.body(input):PairingPIN.body(input)
            let host=address.trimmingCharacters(in:.whitespacesAndNewlines)
            let base=try LibraryRules.address(host)
            if serverTarget == .nas {
                let service:ReaderService
                do{
                    service=try JSONDecoder().decode(ReaderService.self,from:await transport.data(URLRequest(url:URL(string:"/v2/health",relativeTo:base)!),limit:4096))
                    guard service.compatible else{throw ServerFailure.incompatible}
                }catch let error as URLError{throw error}catch{throw ServerFailure.incompatible}
                if passwordMode && !service.passwordPairing{throw ServerFailure.passwordUnsupported}
                if !passwordMode && service.passwordPairing{throw ServerFailure.passwordRequired}
            }
            try Task.checkCancellation();guard generation==ticket else{return}
            var request=URLRequest(url:URL(string:passwordMode ? "/v2/password-pair":"/v2/pair",relativeTo:base)!);request.httpMethod="POST"
            request.httpBody=body;request.setValue("text/plain; charset=utf-8",forHTTPHeaderField:"Content-Type");request.timeoutInterval=8
            let code=try PairingPIN.response(await transport.data(request,limit:2048),address:host)
            try Task.checkCancellation();guard generation==ticket else{return}
            try await establish(code,at:host,ticket:ticket)
        }catch{if generation==ticket{
            if passwordMode,case ServerFailure.status(403)=error{self.error="密码不正确，请重新输入 NAS 阅读密码。"}
            else{self.error=(error as? ServerFailure)?.errorDescription ?? (passwordMode ? "连接失败：请确认同一局域网、NAS 阅读地址及密码（8–128 字节）。":"配对失败：请确认同一局域网、正确的阅读地址。六位码有效 5 分钟，最多尝试 5 次；失效后请在服务端生成新码。")}
        }}
    }
    func forget(){
        do{try removePair()}catch{self.error="无法移除钥匙串配对，请解锁手机后重试。";return}
        setRecent(nil);recentScope=nil
        locatingRecent=false;locatedBookID=nil;locateMessage=""
        generation+=1;discovery.stop();paired=nil;base=nil;activeToken="";address="";secret=""
        cancelCatalogWork();browsingCachedCatalog=false;cachedLibraryID=nil;lastLiveCatalog=nil;catalogStatus="";covers.cacheOnly=false
        catalogPages.clear();catalogOwner=nil
        configureCoverScope(device:nil,revision:nil,force:true);books=[];total=0;pageIndex=0;loading=false;error="";orderNotice=""
        pairingStatus="已解除当前服务器配对；阅读记录和其他服务器配对保留。撤销凭据需在服务端操作。"
    }
    func setForeground(_ foreground:Bool){
        if self.foreground != foreground{viewportActivity+=1}
        self.foreground=foreground;cancelCoverPrefetch();covers.suspend(reading || !foreground || cacheBusy)
        if !foreground {
            cancelCatalogWork()
            automatic?.cancel();automatic=nil;discovery.stop();generation+=1;catalogPages.clear();clearPageLists();loading=false;return
        }
        if !reading{scheduleCoverPrefetch(anchor:lastCoverAnchor ?? 0)}
        guard automatic==nil else{return}
        automatic=Task{[weak self] in
            guard let self else{return}
            if paired==nil {
                do{paired=try loadPair();if paired != nil{address=paired!.address;pairingStatus="已记住"+serverTarget.title+" · 正在连接…"}}
                catch{self.error="无法读取配对，请解锁 iPhone 后重试；不会自动覆盖原配对。"}
            }
            await restoreLocalCatalog()
            if !books.isEmpty || paired==nil{startupPending=false}
            // Check the stored endpoint on each foreground entry; never blindly send its token.
            if let saved=paired,let base {
                let ticket=generation
                do{_=try await verify(saved,at:base.absoluteString)}catch{if !Task.isCancelled,ticket==generation{self.base=nil}}
            }
            while !Task.isCancelled {
                if base==nil{await reconnect()}
                else{await refreshVisibleCatalog();scheduleCatalogSave()}
                if !Task.isCancelled{startupPending=false}
                do{try await Task.sleep(nanoseconds:15_000_000_000)}catch{break}
            }
        }
    }
    func reconnect()async {
        guard let saved=paired,!loading,!Task.isCancelled else{return}
        generation+=1;let ticket=generation;loading=true;pairingStatus="正在连接"+serverTarget.title+"…"
        defer{if ticket==generation{loading=false}}
        do{try await establish(saved,at:saved.address,ticket:ticket);return}catch{
            if serverTarget == .nas,ticket==generation,!Task.isCancelled{
                base=nil;pairingStatus="等待 NAS 阅读服务 · 前台每 15 秒重试"
                self.error=(error as? ServerFailure)?.errorDescription ?? "NAS 地址暂不可达或身份无法验证，请检查阅读容器、局域网地址及本地网络权限。";return
            }
        }
        guard ticket==generation,!Task.isCancelled else{return}
        let addresses: [String]
        if let lookup {addresses=await lookup(saved.deviceId!)}else{addresses=await discovery.addresses(for:saved.deviceId!)}
        for address in addresses where address != saved.address {
            guard ticket==generation,!Task.isCancelled else{return}
            do{try await establish(saved,at:address,ticket:ticket);return}catch{}
        }
        guard ticket==generation,!Task.isCancelled else{return}
        base=nil;pairingStatus="等待安卓开启共享 · 前台每 15 秒重试"
        error="请确认同一 Wi-Fi、安卓共享已开启，并允许 iPhone 本地网络权限。若路由器屏蔽自动发现，可重扫一次；若安卓重置了配对，请重新扫码。"
    }
    func more() async { await loadPage(0,force:true) }
    private func clearPageLists(){pageLists.clear();pageListEpoch+=1;pageListRequests.removeAll();for (_,task) in manifestLoads.values{task.cancel()};manifestLoads.removeAll()}
    func trimCatalog(){catalogPages.clear();clearPageLists()}
    func invalidatePageList(_ book:String){pageLists.invalidate(book);pageListRequests.removeValue(forKey:book)}
    private func cachedBody(_ path:String,request:URLRequest,priority:Float)async throws->Data{
        guard let scope=coverScope,!cacheBusy else{return try await transport.data(request,limit:50*1024*1024,priority:priority)}
        let parts=path.split(separator:"/"),book=String(parts[2]),number=Int(parts[4])!
        let generation=generation,epoch=pageListEpoch
        let manifest:Pages
        if let saved=pageLists.value(book){manifest=saved}
        else if let pending=manifestLoads[book]{manifest=try await pending.1.value}
        else{
            let id=UUID(),task=Task{try await self.pageList(book,recordConnectionFailure:false)};manifestLoads[book]=(id,task)
            defer{if manifestLoads[book]?.0==id{manifestLoads.removeValue(forKey:book)}}
            manifest=try await task.value
        }
        try Task.checkCancellation()
        guard generation==self.generation,epoch==pageListEpoch,scope==coverScope else{throw CancellationError()}
        guard manifest.libraryId==cachedLibraryID else{throw LibraryError.malformed}
        guard let page=manifest.pages.first(where:{$0.number==number}) else{throw PageReadFailure.changed}
        guard let sha=page.sha256,let size=page.size else{throw LibraryError.malformed}
        guard size>0,size<=50*1024*1024 else{throw LibraryError.malformed}
        var request=request;request.setValue("\""+sha+"\"",forHTTPHeaderField:"If-Match")
        if let data=try? await bodyDisk.value(scope:scope,sha:sha,size:size){
            try Task.checkCancellation();guard generation==self.generation,epoch==pageListEpoch else{throw CancellationError()};return data
        }
        let reservation:BodyDiskCache.Ticket
        do{
            _ = try await coverDisk.usage()
            guard await !coverDisk.isIndexing() else{throw CocoaError(.fileWriteOutOfSpace)}
            reservation=try await bodyDisk.begin(scope:scope,sha:sha,size:size)
        }catch{
            try Task.checkCancellation()
            return try await transport.data(request,limit:50*1024*1024,priority:priority)
        }
        do{
            let sink=try await bodyDisk.sink(reservation)
            _ = try await transport.response(request,limit:size,priority:priority,sink:sink)
            try Task.checkCancellation()
            guard generation==self.generation,epoch==pageListEpoch,!cacheBusy else{throw CancellationError()}
            let data=try await bodyDisk.commit(reservation);scheduleCacheStats();return data
        }catch{
            await bodyDisk.abort(reservation)
            try Task.checkCancellation()
            if error is CocoaError,epoch==pageListEpoch,generation==self.generation{return try await transport.data(request,limit:50*1024*1024,priority:priority)}
            throw error
        }
    }
    func pageList(_ book:String,force:Bool=false,recordConnectionFailure:Bool=true)async throws->Pages {
        try Task.checkCancellation()
        guard book.range(of:"^[0-9]{1,20}$",options:.regularExpression) != nil else{throw LibraryError.malformed}
        if force{pageLists.invalidate(book)}
        if !force,!(serverTarget == .nas && serverManifests),base != nil,let cached=pageLists.value(book){return cached}
        let ticket=generation,epoch=pageListEpoch,request=UUID()
        pageListRequests[book]=request
        defer{if pageListRequests[book]==request{pageListRequests.removeValue(forKey:book)}}
        do {
            let manifest=serverTarget == .nas && serverManifests
            let result:PageListCache.Validated,etag:String?
            if manifest,serverConditionalManifests {
                guard let base,let url=URL(string:wirePath("/v1/books/\(book)/manifest"),relativeTo:base) else{throw LibraryError.unsafeAddress}
                let candidate=force ? nil:pageLists.candidate(book)
                var wire=URLRequest(url:url);wire.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
                if let candidate{wire.setValue(candidate.etag,forHTTPHeaderField:"If-None-Match")}
                let reply=try await transport.response(wire,limit:8*1024*1024,allowNotModified:candidate != nil)
                try Task.checkCancellation()
                guard ticket==generation,epoch==pageListEpoch,pageListRequests[book]==request else{throw CancellationError()}
                if reply.status==304 {
                    guard let candidate,reply.data.isEmpty,reply.etag==candidate.etag else{throw LibraryError.malformed}
                    result=candidate.value;etag=candidate.etag
                }else{
                    result=try await metadata.preparedManifest(reply.data,etag:reply.etag);etag=reply.etag
                }
            }else{
                result=try await metadata.preparedPages(data("/v1/books/\(book)/"+(manifest ? "manifest":"pages")));etag=nil
            }
            try Task.checkCancellation()
            guard ticket==generation,epoch==pageListEpoch,pageListRequests[book]==request else{throw CancellationError()}
            if manifest{guard result.value.id==book,result.value.libraryId==cachedLibraryID,result.value.contentRevision != nil else{throw LibraryError.malformed}}
            pageLists.store(result,book:book,etag:etag);return result.value
        }catch{
            if pageListRequests[book]==request{pageLists.invalidate(book)}
            if recordConnectionFailure{recordReadFailure(error,ticket:ticket)}
            throw error
        }
    }
    func loadPage(_ target:Int,force:Bool=false) async {
        let ticket=generation
        guard !loading else{return};loading=true;defer{if ticket==generation{loading=false}}
        locatedBookID=nil;locateMessage=""
        cancelCoverPrefetch()
        let requestedSize=pageSize
        let target=max(0,target)
        do {
            guard (0...400).contains(target),(50...500).contains(requestedSize),requestedSize%50==0 else{throw LibraryError.malformed}
            if browsingCachedCatalog,base==nil,let owner=paired?.deviceId {
                guard let saved=try await catalogDisk.page(owner:owner,library:cachedLibraryID,page:target,size:requestedSize,source:shelfSource),ticket==generation,!Task.isCancelled else{throw LibraryError.malformed}
                configureCoverScope(device:owner,revision:saved.list.catalogRevision,libraryID:saved.list.libraryId,bookIdentities:saved.list.books)
                books=saved.list.books;total=saved.list.total;pageIndex=target;return
            }
            if force{catalogPages.clear();clearPageLists()}
            let page:BookList
            if base != nil,let cached=catalogPages.value(page:target,size:requestedSize){page=cached}
            else {
                let loaded=try await metadata.catalog(data("/v1/books?offset=\(target*requestedSize)&limit=\(requestedSize)"),page:target,size:requestedSize)
                try Task.checkCancellation();guard ticket==generation else{return}
                catalogPages.store(loaded,owner:catalogOwner)
                page=loaded.list
            }
            guard ticket==generation,!Task.isCancelled else{return}
            guard serverTarget != .nas || shelfSource.accepts(page) else{throw LibraryError.malformed}
            configureCoverScope(device:paired?.deviceId,revision:page.catalogRevision,libraryID:page.libraryId,bookIdentities:page.books)
            books=page.books;total=page.total;pageIndex=target;error=""
            orderNotice = page.orderVerified ? "" : "列表采用备份查询顺序，同值记录位置待核对；漫画内按数字页码阅读。"
            lastCoverAnchor=nil;scheduleCoverPrefetch(anchor:0)
        }catch{if ticket==generation{catalogPages.clear();self.error=(error as? ServerFailure)?.errorDescription ?? "连接或顺序校验失败。请检查书库服务、局域网连接及清单。";if paired != nil{base=nil}}}
    }
    func locateRecentBook()async->Int? {
        guard let recent=recentReading,let scope=recentScope,scope==recent.scope,base != nil,!loading else{return nil}
        let ticket=generation,size=pageSize
        loading=true;locatingRecent=true;locateMessage="正在核对书库位置…";cancelCoverPrefetch()
        defer{if generation==ticket{loading=false;locatingRecent=false}}
        do {
            let match:CatalogLocator.Match?
            if serverTarget == .nas {
                let position=try JSONDecoder().decode(LocatedBook.self,from:await data("/v1/books/\(recent.book.id)/position"))
                guard position.id==recent.book.id,(0..<20000).contains(position.offset),paired?.deviceId.map({$0+"\n"+position.libraryId})==scope else{throw LibraryError.malformed}
                let page=position.offset/size
                let result=try await metadata.catalog(data("/v1/books?offset=\(page*size)&limit=\(size)"),page:page,size:size).list
                guard result.catalogRevision==position.catalogRevision,result.libraryId==position.libraryId,result.books.indices.contains(position.offset%size),result.books[position.offset%size].id==position.id else{throw LibraryError.unverifiedOrder}
                match=CatalogLocator.Match(book:result.books[position.offset%size],offset:position.offset,snapshot:result)
            }else{match=try await CatalogLocator.find(id:recent.book.id,rankHint:recent.book.rank){page,batch in
                try Task.checkCancellation()
                guard ticket==self.generation,self.recentScope==scope,self.recentReading?.book.id==recent.book.id else{throw CancellationError()}
                let result=try await self.metadata.catalog(self.data("/v1/books?offset=\(page*batch)&limit=\(batch)"),page:page,size:batch)
                if let device=self.paired?.deviceId,result.list.libraryId.map({device+"\n"+$0}) != scope{throw LibraryError.unverifiedOrder}
                return result.list
            }}
            try Task.checkCancellation();guard ticket==generation,recentScope==scope,recentReading?.book.id==recent.book.id else{return nil}
            guard let match else{locateMessage="最新清单中未找到这本漫画，当前书库位置未改变。";return nil}
            let target=match.offset/size,local=match.offset%size
            let result=try await metadata.catalog(data("/v1/books?offset=\(target*size)&limit=\(size)"),page:target,size:size)
            try Task.checkCancellation();guard ticket==generation,recentScope==scope,recentReading?.book.id==recent.book.id else{return nil}
            guard CatalogLocator.sameSnapshot(match.snapshot,result.list),result.list.books.indices.contains(local),result.list.books[local].id==recent.book.id else{throw LibraryError.unverifiedOrder}
            catalogPages.clear();catalogPages.store(result,owner:catalogOwner)
            configureCoverScope(device:paired?.deviceId,revision:result.list.catalogRevision,libraryID:result.list.libraryId,bookIdentities:result.list.books)
            locatedBookID=recent.book.id
            books=result.list.books;total=result.list.total;pageIndex=target;error=""
            orderNotice=result.list.orderVerified ? "":"列表采用备份查询顺序，同值记录位置待核对；漫画内按数字页码阅读。"
            locateMessage="已定位到第 \(target+1) 页，第 \(local+1) 本"
            scheduleCoverPrefetch(anchor:local)
            return local
        }catch{
            if ticket==generation{locateMessage=Task.isCancelled ? "已取消定位，原书库位置保留。":"定位未完成，连接或清单可能已变化，请重试。"}
            return nil
        }
    }
}
