#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import SwiftUI
import CryptoKit

private final class LocalUpdateFixture:URLProtocol {
    static let owner=String(repeating:"4",count:32),library=String(repeating:"5",count:64),token=String(repeating:"S",count:32)
    static let lock=NSLock()
    static var shift=0,coverVersion=0,pageVersion=0,mode="",bodies:[Int:Data]=[:],calls:[String:Int]=[:],delay:UInt64=0
    private var work:Task<Void,Never>?
    static func configure(shift:Int=0,cover:Int=0,pages:Int=0,mode:String="",delay:UInt64=0){lock.lock();defer{lock.unlock()};self.shift=shift;coverVersion=cover;pageVersion=pages;self.mode=mode;self.delay=delay}
    static func count(_ path:String)->Int{lock.lock();defer{lock.unlock()};return calls[path,default:0]}
    static func resetCounts(){lock.lock();defer{lock.unlock()};calls=[:]}
    static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func tag(_ data:Data)->String{"\""+hash(data)+"\""}
    static func list(offset:Int,size:Int)->BookList {
        let books=(offset..<min(10094,offset+size)).map{rank->Book in
            let id=(rank+shift)%10094+1
            return Book(id:String(id),title:"Synthetic \(id)",rank:rank,available:true,coverIdentity:hash(Data("cover-\(id)-\(id==2 ? coverVersion:0)".utf8)),pageCount:128+(id==2 ? pageVersion:0))
        }
        return BookList(orderVerified:true,total:10094,books:books,orderPolicy:"ehviewer-downloads-time-desc",catalogRevision:hash(Data("order-\(shift)".utf8)),libraryId:library)
    }
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let url=request.url!,path=url.path
        precondition(url.host=="192.168.9.61","synthetic checks must not use a real host")
        Self.lock.lock()
        Self.calls[path,default:0]+=1;let call=Self.calls[path]!,mode=Self.mode,delay=Self.delay
        var body=Data(),status=200,headers:[String:String]=[:],network=false
        let query=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems ?? []
        func value(_ name:String,_ fallback:String)->String{query.first{$0.name==name}?.value ?? fallback}
        if path=="/v2/identity" {
            let nonce=value("nonce","")
            let proof=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(Self.owner)\n\(nonce)".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":Self.owner,"proof":proof])
        }else if path=="/v2/health" {
            body=try! JSONSerialization.data(withJSONObject:["app":"localshelf-reader","version":1,"serverKind":"nas","capabilities":["reader-v1","pair-v2","locate-v1","page-manifest-v1","conditional-manifest-v1","catalog-window-v1"]])
        }else {
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            if path=="/v1/books"{body=try! JSONEncoder().encode(Self.list(offset:Int(value("offset","0"))!,size:Int(value("limit","100"))!))}
            else if path=="/v1/books/window" {
                let anchor=value("anchor",""),size=Int(value("limit","100"))!,id=Int(anchor) ?? 1
                let rank=(id-1-Self.shift+10094)%10094,offset=rank/size*size
                let catalog=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(Self.list(offset:offset,size:size)))
                body=try! JSONSerialization.data(withJSONObject:["offset":mode=="badWindow" ? offset+1:offset,"anchor":anchor,"catalog":catalog],options:.sortedKeys)
                headers["ETag"]=Self.tag(body)
                if request.value(forHTTPHeaderField:"If-None-Match")==headers["ETag"]{status=304;body=Data();Self.calls["304",default:0]+=1}
                if mode=="failedWindow"{status=503;body=Data()}
            }else if path=="/v1/books/1/manifest" {
                if mode=="manifestNetworkOnce",call==2{network=true}
                let pages=(1...3).map{Page(number:$0,sha256:Self.hash(Self.bodies[$0]!),size:Self.bodies[$0]!.count)}
                let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
                body=try! encoder.encode(Pages(pages:pages,id:"1",libraryId:Self.library,contentRevision:Self.hash(Data(pages.map{$0.sha256!}.joined().utf8))))
                headers["ETag"]=Self.tag(body)
                if request.value(forHTTPHeaderField:"If-None-Match")==headers["ETag"]{status=304;body=Data()}
            }else if path.contains("/pages/"),let number=Int(path.split(separator:"/").last!) {
                body=Self.bodies[number]!;headers["ETag"]=Self.tag(body)
                if number==2 {
                    if mode=="networkOnce",call==1{network=true}
                    if mode=="missing"{status=404;headers["X-LocalShelf-Error"]="image_missing"}
                    if mode=="changed"{status=412;headers["X-LocalShelf-Error"]="page_content_changed"}
                    if mode=="busy"{status=503;headers["X-LocalShelf-Error"]="reader_busy"}
                }
            }else{preconditionFailure("unexpected synthetic route \(path)")}
        }
        Self.lock.unlock()
        let send={ [weak self] in
            guard let self else{return}
            if network{self.client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return}
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:body);self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay>0,path=="/v1/books/window"{work=Task{do{try await Task.sleep(nanoseconds:delay);try Task.checkCancellation();send()}catch{}}}else{send()}
    }
    override func stopLoading(){work?.cancel()}
}

@MainActor enum LocalUpdateChecks {
    static func run()async {
        var checks=0
        func pass(_ ok:Bool,_ message:String){precondition(ok,message);checks+=1;print("PASS "+message);fflush(stdout)}
        func wait(_ condition:()->Bool)async{for _ in 0..<1000{if condition(){return};try? await Task.sleep(for:.milliseconds(5))};preconditionFailure("synthetic operation timed out")}
        let defaults=UserDefaults.standard,selected=defaults.object(forKey:"server.selected"),hidden=defaults.object(forKey:"shelf.hideCovers")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("local-update-checks-"+UUID().uuidString)
        defer{defaults.set(selected,forKey:"server.selected");defaults.set(hidden,forKey:"shelf.hideCovers");try? FileManager.default.removeItem(at:root)}
        defaults.set("nas",forKey:"server.selected");defaults.set(true,forKey:"shelf.hideCovers")
        for number in 1...3 {
            let data=UIGraphicsImageRenderer(size:CGSize(width:32,height:48)).pngData{context in UIColor(hue:CGFloat(number)/4,saturation:0.8,brightness:0.8,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:32,height:48))}
            LocalUpdateFixture.bodies[number]=data
        }
        func make()async->Library {
            let directory=root.appendingPathComponent(UUID().uuidString)
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[LocalUpdateFixture.self]
            let client=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in},removePair:{},catalogDisk:CatalogDiskStore(root:directory.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:directory.appendingPathComponent("covers")),bodyDisk:BodyDiskCache(root:directory.appendingPathComponent("body")))
            client.setForeground(false)
            await client.connect(code:PairingCode(app:"localshelf",version:2,address:"http://192.168.9.61:8089",token:LocalUpdateFixture.token,deviceId:LocalUpdateFixture.owner))
            precondition(client.base != nil)
            return client
        }
        do {
            for mode in ["networkOnce","missing","busy","changed"] {
                LocalUpdateFixture.configure(mode:mode);LocalUpdateFixture.resetCounts()
                let client=await make(),cache=ReadingCache(),pages=try await client.pageList("1").pages
                cache.update(library:client,book:"1",pages:pages,index:1)
                await wait{cache.images[1] != nil && cache.images[3] != nil && (cache.images[2] != nil || cache.failed.contains(2))}
                let first=cache.images[1],last=cache.images[3]
                pass(LocalUpdateFixture.count("/v1/books/1/manifest")==1,"\(mode): failure does not refetch a manifest")
                let expectedCalls=["networkOnce","busy"].contains(mode) ? 2:1
                pass(LocalUpdateFixture.count("/v1/books/1/pages/2")==expectedCalls,"\(mode): automatic retries are bounded to one")
                if mode=="networkOnce"{pass(cache.images[2] != nil && client.base != nil,"transient page recovery retains verified connection")}
                else{pass(cache.failures[2] == (mode=="missing" ? .missing:mode=="changed" ? .changed:.busy),"\(mode): precise failure reason")}
                LocalUpdateFixture.configure()
                if mode=="changed" {
                    let refreshed=try await client.pageList("1",force:true)
                    cache.reconcilePages(refreshed.pages);cache.update(library:client,book:"1",pages:refreshed.pages,index:1)
                }else{cache.retry(2)}
                await wait{cache.images[2] != nil}
                pass(cache.images[1] === first && cache.images[3] === last,"\(mode): retry preserves neighboring bitmaps")
                cache.clear();client.setForeground(false)
            }
            // A same-number replacement discards only that page, not its neighbors.
            LocalUpdateFixture.configure()
            let reader=await make(),cache=ReadingCache(),pages=try await reader.pageList("1").pages
            cache.update(library:reader,book:"1",pages:pages,index:1);await wait{cache.images.count==3}
            let left=cache.images[1],right=cache.images[3]
            var changed=pages;changed[1]=Page(number:2,sha256:String(repeating:"f",count:64),size:10)
            cache.reconcilePages(changed)
            pass(cache.images[2]==nil && cache.images[1] === left && cache.images[3] === right,"changed hash evicts only the corresponding page")
            cache.clear();reader.setForeground(false)

            LocalUpdateFixture.resetCounts();LocalUpdateFixture.configure(mode:"manifestNetworkOnce")
            let retryClient=await make(),retryCache=ReadingCache(),retryPages=try await retryClient.pageList("1").pages
            retryClient.invalidatePageList("1")
            retryCache.update(library:retryClient,book:"1",pages:retryPages,index:1)
            await wait{retryCache.images.count==3}
            pass(retryClient.base != nil && LocalUpdateFixture.count("/v1/books/1/manifest")==3,"page-scoped retry also recovers one transient manifest failure without disconnecting")
            retryCache.clear();retryClient.setForeground(false)

            LocalUpdateFixture.configure();let staticPage=LocalUpdateFixture.bodies[2]!
            LocalUpdateFixture.bodies[2]=ReaderDemo.animationData("1")
            let gifClient=await make(),gifCache=ReadingCache(),gifPages=try await gifClient.pageList("1").pages
            gifCache.update(library:gifClient,book:"1",pages:gifPages,index:1);await wait{gifCache.images.count==3 && gifCache.animated.contains(2)}
            let gifPager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844))
            gifPager.configure(cache:gifCache,pages:gifPages,index:1,resetID:0,pageRevision:UUID());gifPager.layoutIfNeeded()
            await wait{gifPager.animationPlayer.key=="2"}
            let starts=gifPager.animationPlayer.playbackStarts
            gifCache.reconcilePages(gifPages);gifPager.configure(cache:gifCache,pages:gifPages,index:1,resetID:1,pageRevision:UUID())
            pass(gifPager.animationPlayer.key=="2" && gifPager.animationPlayer.playbackStarts==starts,"unchanged GIF manifest retains current player")
            var replacement=gifPages;replacement[1]=Page(number:2,sha256:String(repeating:"f",count:64),size:5)
            gifCache.reconcilePages(replacement);gifPager.configure(cache:gifCache,pages:replacement,index:1,resetID:2,pageRevision:UUID())
            pass(gifPager.animationPlayer.key==nil,"same-number changed GIF stops its obsolete player before reuse")
            gifPager.dispose();gifCache.clear();gifClient.setForeground(false);LocalUpdateFixture.bodies[2]=staticPage

            let pipeline=SmartCoverPipeline(),coverPath="/v1/books/2/cover"
            var coverCalls=0,coverDeliveries=0
            pipeline.variantLoad={_,_,_ in
                coverCalls+=1;let data=LocalUpdateFixture.bodies[1]!
                try await Task.sleep(for:.milliseconds(100))
                return LimitedHTTP.Payload(data:data,status:200,etag:LocalUpdateFixture.tag(data))
            }
            let coverHash=String(repeating:"a",count:64)
            pipeline.configureScope("synthetic",revision:"first",identities:[coverPath:coverHash])
            func subscribe(){pipeline.subscribe(coverPath,id:UUID(),load:{preconditionFailure("variant loader required")}){result in if case .success=result{coverDeliveries+=1}}}
            subscribe();await wait{coverCalls==1}
            pipeline.configureScope("synthetic",revision:"reordered",identities:[coverPath:coverHash]);subscribe()
            await wait{coverDeliveries==2}
            pass(coverCalls==1,"catalog reorder preserves and coalesces in-flight cover subscribers")
            pipeline.configureScope("synthetic",revision:"reorderedAgain",identities:[coverPath:coverHash]);subscribe()
            pass(coverCalls==1 && coverDeliveries==3,"unchanged cover hash reuses memory without revalidation on reorder")
            pipeline.configureScope("synthetic",revision:"reorderedAgain",identities:[coverPath:String(repeating:"b",count:64)]);subscribe()
            await wait{coverDeliveries==4}
            pass(coverCalls==2,"changed cover hash reloads just that cover")
            pipeline.reset()

            for size in [50,500] {
                LocalUpdateFixture.configure()
                let client=await make();client.pageSize=size;await client.loadPage(2)
                let grid=CollectionShelfController(),scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
                let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:402,height:874);window.rootViewController=grid;window.isHidden=false
                grid.loadViewIfNeeded();grid.view.frame=window.bounds
                let header=AnyView(Text("Synthetic library").frame(height:100))
                grid.configure(library:client,columns:3,header:header,seek:ShelfSeek(index:20))
                await wait{!grid.isUpdating};grid.collection.layoutIfNeeded();await Task.yield()
                let rect=CGRect(origin:grid.collection.contentOffset,size:grid.collection.bounds.size)
                let first=grid.layout.layoutAttributesForElements(in:rect)!.filter{$0.representedElementCategory == .cell && $0.frame.maxY>rect.minY+1}.sorted{$0.indexPath.item<$1.indexPath.item}.first!
                let anchor=client.books[first.indexPath.item].id,anchorY=first.frame.minY-rect.minY
                client.recordVisibleBook(anchor)
                client.setForeground(true)
                try? await Task.sleep(for:.milliseconds(150)) // allow the real foreground loop's first check
                await client.refreshVisibleCatalog()
                let initial=client.booksRevision,etagHits=LocalUpdateFixture.count("304"),fullLists=LocalUpdateFixture.count("/v1/books")
                await client.refreshVisibleCatalog()
                pass(client.booksRevision==initial && LocalUpdateFixture.count("304")>etagHits,"\(size): unchanged window is 304 with zero UI publication")
                pass(LocalUpdateFixture.count("/v1/books")==fullLists,"\(size): current-page check does not download full catalog")
                let epoch=client.coverEpoch
                client.recordVisibleBook(anchor);LocalUpdateFixture.configure(shift:size+10)
                await client.refreshVisibleCatalog()
                pass(client.pageIndex==1 && client.books.contains{$0.id==anchor},"\(size): reorder keeps stable anchor across page boundary")
                pass(client.coverEpoch==epoch && client.anchorPreservingRevision==client.booksRevision,"\(size): reorder preserves image epoch and marks anchor transaction")
                grid.configure(library:client,columns:3,header:header,seek:nil)
                await wait{!grid.isUpdating};grid.collection.layoutIfNeeded();await Task.yield()
                let index=grid.displayedIDs.firstIndex(of:anchor)!,frame=grid.layout.layoutAttributesForItem(at:IndexPath(item:index,section:0))!.frame
                pass(abs(frame.minY-grid.collection.contentOffset.y-anchorY)<1,"\(size): real UIKit layout preserves anchor within one point across page boundary")
                let stable=client.books,rev=client.booksRevision
                for mode in ["failedWindow","badWindow"] {
                    LocalUpdateFixture.configure(shift:size+10,mode:mode);await client.refreshVisibleCatalog()
                    pass(client.books==stable && client.booksRevision==rev && client.base != nil,"\(size): \(mode) retains complete display and connection")
                }
                LocalUpdateFixture.configure(shift:size+11)
                client.setReading(true);let count=LocalUpdateFixture.count("/v1/books/window");await client.refreshVisibleCatalog()
                pass(LocalUpdateFixture.count("/v1/books/window")==count,"\(size): active reading does not check or reorder library")
                client.setReading(false);client.setShelfInteracting(true);await client.refreshVisibleCatalog()
                pass(LocalUpdateFixture.count("/v1/books/window")==count,"\(size): active drag does not check or reorder library")
                client.setShelfInteracting(false)
                LocalUpdateFixture.configure(shift:size+11,delay:200_000_000)
                let job=Task{await client.refreshVisibleCatalog()};await wait{LocalUpdateFixture.count("/v1/books/window")>count}
                client.setReading(true);await job.value
                pass(client.books==stable,"\(size): response started before reader opens is discarded")
                client.setForeground(false)
                grid.dispose();window.isHidden=true;window.rootViewController=nil
            }
            LocalUpdateFixture.configure()
            let coverClient=await make();coverClient.setForeground(true)
            try? await Task.sleep(for:.milliseconds(150));await coverClient.refreshVisibleCatalog()
            let oldCovers=coverClient.books.map(\.coverIdentity),oldEpoch=coverClient.coverEpoch
            LocalUpdateFixture.configure(cover:1);await coverClient.refreshVisibleCatalog()
            pass(zip(oldCovers,coverClient.books.map(\.coverIdentity)).filter{$0 != $1}.count==1 && coverClient.coverEpoch==oldEpoch,"same catalog revision updates exactly one changed cover identity")
            let preservedCovers=coverClient.books.map(\.coverIdentity),oldRevision=coverClient.booksRevision
            LocalUpdateFixture.configure(cover:1,pages:12);await coverClient.refreshVisibleCatalog()
            pass(coverClient.books.first{$0.id=="2"}?.pageCount==140 && coverClient.booksRevision != oldRevision,"same catalog revision refreshes page-count-only metadata")
            pass(coverClient.books.map(\.coverIdentity)==preservedCovers && coverClient.coverEpoch==oldEpoch,"page-count refresh retains all cover identities and cache epoch")
            coverClient.setForeground(false)
            pass(PageReadFailure.header(status:404,code:"arbitrary_server_text")==nil,"unknown server error never becomes displayed text")
            pass(!PageReadFailure.invalid.automaticRetry && !PageReadFailure.missing.automaticRetry,"corrupt and missing files never loop")
        }catch{preconditionFailure("local update checks failed: \(error)")}
        print("\(checks) local update checks passed")
    }
}
#endif
