#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import SwiftUI
import CryptoKit

final class CachedNASFixture:URLProtocol {
    static let owner=String(repeating:"1",count:32),library=String(repeating:"2",count:64),token=String(repeating:"T",count:32)
    static let lock=NSLock()
    private static var ready=false,revision="a",failOffset:Int?,changeAtConfirm=false
    private static var requests=0
    private static var delay=0.0,cover:Data?
    private var delivery:Task<Void,Never>?
    static func configure(ready:Bool,revision:String="a",failOffset:Int?=nil,changeAtConfirm:Bool=false,delay:Double=0,cover:Data?=nil){lock.lock();defer{lock.unlock()};self.ready=ready;self.revision=revision;self.failOffset=failOffset;self.changeAtConfirm=changeAtConfirm;self.delay=delay;self.cover=cover}
    static func calls()->Int{lock.lock();defer{lock.unlock()};return requests}
    static func page(_ offset:Int,_ size:Int,revision:String="a")->BookList {
        BookList(orderVerified:true,total:600,books:(offset..<min(offset+size,600)).map{Book(id:String($0+1),title:"Synthetic \($0+1)",rank:$0,available:$0%23 != 0,coverIdentity:String(repeating:"b",count:64))},orderPolicy:"ehviewer-downloads-time-desc",catalogRevision:String(repeating:revision,count:64),libraryId:library)
    }
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.lock.lock();let ready=Self.ready,revision=Self.revision,failOffset=Self.failOffset,change=Self.changeAtConfirm,delay=Self.delay,cover=Self.cover;Self.requests+=1;Self.lock.unlock()
        let url=request.url!;var status=200,body=Data()
        if url.path=="/v2/identity" {
            let nonce=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first!.value!
            let proof=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(Self.owner)\n\(nonce)".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":Self.owner,"proof":proof])
        }else if url.path=="/v2/health" {
            body=try! JSONSerialization.data(withJSONObject:["app":"localshelf-reader","version":1,"serverKind":"nas","capabilities":["reader-v1","pair-v2","locate-v1"]])
        }else if url.path=="/v1/books" {
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            let query=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
            let offset=Int(query.first{$0.name=="offset"}!.value!)!,size=Int(query.first{$0.name=="limit"}!.value!)!
            if !ready || offset==failOffset{status=503}else{body=try! JSONEncoder().encode(Self.page(offset,size,revision:change && size==50 ? "f":revision))}
        }else if url.path.hasSuffix("/cover"),let cover{body=cover}
        else{preconditionFailure("metadata checks must not request images")}
        let send={ [weak self] in
            guard let self else{return}
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:body);self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay>0,url.path=="/v1/books"{delivery=Task{do{try await Task.sleep(for:.seconds(delay));guard !Task.isCancelled else{return};send()}catch{}}}
        else{send()}
    }
    override func stopLoading(){delivery?.cancel();delivery=nil}
}

enum NASLibraryCacheChecks {
    @MainActor static func run()async {
        var checks=0
        func pass(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS \(label)")}
        let defaults=UserDefaults.standard,keys=["server.selected","shelf.hideCovers","reading.serverScope.nas","reading.scope."+ReadingProgress.hash(CachedNASFixture.owner+"\n"+CachedNASFixture.library)]
        let savedDefaults=keys.map{defaults.object(forKey:$0)}
        defaults.set("nas",forKey:"server.selected")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("nas-catalog-checks-"+UUID().uuidString)
        defer{for (key,value) in zip(keys,savedDefaults){if let value{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}};try? FileManager.default.removeItem(at:root)}
        let store=CatalogDiskStore(root:root.appendingPathComponent("catalog")),disk=CoverDiskCache(root:root.appendingPathComponent("covers"))
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CachedNASFixture.self]
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.9.45:8089",token:CachedNASFixture.token,deviceId:CachedNASFixture.owner)
        let client=Library(transport:LimitedHTTP(configuration:config),loadPair:{code},savePair:{_ in},removePair:{},lookup:{_ in []},catalogDisk:store,coverDisk:disk)
        client.setForeground(false)
        client.coversHidden=true // Metadata-only fixture; cover behavior is isolated below.
        do {
            let ticket=try await store.begin(owner:CachedNASFixture.owner,first:CachedNASFixture.page(0,500))
            try await store.append(CachedNASFixture.page(500,500),offset:500,ticket:ticket)
            try await store.commit(ticket,confirmed:CachedNASFixture.page(0,50))
            CachedNASFixture.configure(ready:false);await client.connect(code:code)
            pass(client.base==nil,"unpublished server is not marked connected")
            let before=CachedNASFixture.calls();await client.restoreLocalCatalog()
            pass(client.browsingCachedCatalog && client.total==600 && client.books.count==100,"saved metadata appears without live catalog")
            await client.loadPage(5)
            pass(client.books.first?.id=="501" && client.pageIndex==5 && CachedNASFixture.calls()==before,"offline catalog pagination performs no network requests")
            client.pageSize=50;await client.loadPage(1)
            pass(client.books.first?.id=="51" && client.books.count==50,"offline page size respects stored original ordering")
            pass(client.covers.cacheOnly && client.base==nil,"metadata preview cannot enable image networking")
            await client.loadPage(0) // A verified reconnect restores page zero.
            client.coversHidden=false;client.covers.suspend(true)
            let previewCell=ShelfCoverCell(frame:CGRect(x:0,y:0,width:120,height:230))
            let previewBook=client.books.first{$0.id=="2"}!,bitmap=UIImage(systemName:"book.closed")!
            previewCell.configure(book:previewBook,library:client);previewCell.picture.image=bitmap
            CachedNASFixture.configure(ready:true);await client.connect(code:code)
            pass(client.base != nil && !client.browsingCachedCatalog && !client.covers.cacheOnly,"verified connection replaces preview with live metadata")
            previewCell.configure(book:client.books.first{$0.id=="2"}!,library:client)
            pass(previewCell.picture.image === bitmap,"same signed cover identity retains visible pixels across preview-to-live epoch change")
            var changedCover=previewBook;changedCover.coverIdentity=String(repeating:"c",count:64)
            previewCell.configure(book:changedCover,library:client)
            pass(previewCell.picture.image==nil,"changed cover identity never retains the old bitmap")
            previewCell.picture.image=bitmap;client.coversHidden=true;previewCell.configure(book:changedCover,library:client)
            pass(previewCell.picture.image==nil,"privacy hiding wins over retained startup pixels")
            previewCell.stop()
            client.setForeground(true)
            await client.refreshLocalCatalog()
            pass(client.catalogStatus.contains("600 本"),"live full snapshot commits only after final version confirmation")
            CachedNASFixture.configure(ready:true,revision:"e",failOffset:500)
            await client.refreshLocalCatalog()
            pass(try await store.page(owner:CachedNASFixture.owner,page:0,size:50)?.list.catalogRevision==String(repeating:"a",count:64),"failed background batch retains old complete snapshot")
            pass(client.base != nil,"background catalog failure does not disconnect live reader")
            CachedNASFixture.configure(ready:true,revision:"e",changeAtConfirm:true)
            await client.refreshLocalCatalog()
            pass(try await store.page(owner:CachedNASFixture.owner,page:0,size:50)?.list.catalogRevision==String(repeating:"a",count:64),"publication change during download cannot mix directory generations")
            client.setForeground(false);client.forget()
            pass(client.books.isEmpty && !client.browsingCachedCatalog && !client.canBrowseCatalog,"unpair removes visible preview but not saved private metadata")
            let fresh=Library(loadPair:{nil},savePair:{_ in},removePair:{},catalogDisk:store)
            pass(fresh.showStartupPlaceholder,"a fresh shelf has an explicit startup state instead of premature empty connection UI")
            fresh.setForeground(true)
            for _ in 0..<100{if !fresh.startupPending{break};try await Task.sleep(for:.milliseconds(5))}
            pass(!fresh.startupPending && !fresh.showStartupPlaceholder && fresh.books.isEmpty,"no saved pairing resolves startup without an artificial splash timer")
            fresh.setForeground(false)

            let path="/v1/books/2/cover",scope="synthetic/preview",identity=String(repeating:"b",count:64)
            let key=CoverRules.key(scope:scope+"\n"+identity+"\nthumbnail-v2-480",path:path)!
            let sample=ReaderDemo.data("1"),record=CoverRecord(bytes:sample,thumbnail:false,etag:nil,checked:Date(timeIntervalSinceNow:-100000),revision:"old")
            try await disk.put(record.packed(),key:key,ticket:await disk.ticket())
            let pipeline=SmartCoverPipeline(disk:disk);pipeline.configureScope(scope,revision:"new",identities:[path:identity]);pipeline.cacheOnly=true
            var network=0,displayed=0,failures=0
            pipeline.conditionalLoad={_,_ in network+=1;return .init(data:sample,status:200,etag:nil)}
            pipeline.subscribe(path,id:UUID(),load:{preconditionFailure()}){if case .success=$0{displayed+=1}}
            for _ in 0..<500{if pipeline.idle{break};try await Task.sleep(nanoseconds:10_000_000)}
            pass(displayed>0 && network==0,"stale disk cover displays in preview without revalidation network")
            pipeline.subscribe("/v1/books/3/cover",id:UUID(),load:{preconditionFailure()}){if case .failure=$0{failures+=1}}
            for _ in 0..<500{if pipeline.idle{break};try await Task.sleep(nanoseconds:10_000_000)}
            pass(failures==1 && network==0,"uncached preview cover stays a placeholder without network")
            pipeline.cacheOnly=false;pipeline.subscribe(path,id:UUID(),load:{preconditionFailure()}){_ in}
            for _ in 0..<500{if pipeline.idle{break};try await Task.sleep(nanoseconds:10_000_000)}
            pass(network==1,"successful reconnection restores conditional loading")
        }catch{preconditionFailure("NAS cache checks failed: \(error)")}
        client.setForeground(false);await disk.closeForChecks()
        print("\(checks) NAS local catalog integration checks passed")
    }
}

enum NASSchedulingExperiment {
    @MainActor static func run()async {
        // Real pipeline + image decoding; synthetic per-request delays. This is
        // NOT shared-bandwidth/N100/Wi-Fi modelling and cannot select a winner.
        let sample=ReaderDemo.data("1")
        for delay in [20,80] {
            for (label,limit,burst,rate) in [("baseline",3,6,8),("two",2,6,8),("four",4,6,8),("four-faster-gate",4,8,16)] {
                for round in 0..<3 {
                    let pipeline=SmartCoverPipeline();await pipeline.configureExperiment(limit:limit,burst:burst,rate:rate)
                    var inFlight=0,peak=0,requests=0,delivered=0
                    pipeline.conditionalLoad={_,_ in
                        requests+=1;inFlight+=1;peak=max(peak,inFlight);defer{inFlight-=1}
                        try await Task.sleep(nanoseconds:UInt64(delay)*1_000_000)
                        return .init(data:sample,status:200,etag:nil)
                    }
                    let start=ContinuousClock.now
                    for i in 0..<12{pipeline.subscribe("/v1/books/\(i+1)/cover",id:UUID(),load:{preconditionFailure()}){if case .success=$0{delivered+=1}}}
                    for _ in 0..<1000{if pipeline.idle{break};try? await Task.sleep(nanoseconds:5_000_000)}
                    precondition(delivered==12 && requests==12 && peak<=limit && pipeline.memoryCost<=32*1024*1024)
                    print("EXPERIMENT scheduling \(label) delay=\(delay) round=\(round) elapsed=\(start.duration(to:.now)) peak=\(peak) requests=\(requests) decodedBytes=\(pipeline.memoryCost)")
                }
            }
        }
        // Metadata-only next-page prototype uses the actual cache and parser.
        for prefetch in [false,true] {
            var cache=CatalogPageCache(),calls=0
            func fetch(_ page:Int)async throws->CatalogPageCache.ValidatedPage {
                calls+=1;try await Task.sleep(nanoseconds:30_000_000)
                let data=try JSONEncoder().encode(CachedNASFixture.page(page*100,100))
                return try await MetadataParser.shared.catalog(data,page:page,size:100)
            }
            do {
                cache.store(try await fetch(0),owner:CachedNASFixture.owner)
                if prefetch{cache.store(try await fetch(1),owner:CachedNASFixture.owner)}
                let before=calls,start=ContinuousClock.now
                if cache.value(page:1,size:100)==nil{cache.store(try await fetch(1),owner:CachedNASFixture.owner)}
                precondition(cache.value(page:1,size:100)?.books.first?.id=="101")
                print("EXPERIMENT next-page prefetch=\(prefetch) clickWait=\(start.duration(to:.now)) clickRequests=\(calls-before) totalRequests=\(calls)")
                if prefetch{print("EXPERIMENT next-page if-user-never-turns wastedRequests=1; preview waits for matching snapshot validation")}
            }catch{preconditionFailure("metadata experiment \(error)")}
        }
        // The duplicate NAS page fetch is also a final publication check. A
        // two-request prototype is faster but loses that last check.
        for reuse in [false,true] {
            let start=ContinuousClock.now;var calls=0
            func request()async{calls+=1;try? await Task.sleep(nanoseconds:30_000_000)}
            await request() // position
            await request() // page matching position's revision
            let validated=CachedNASFixture.page(100,100)
            let match=CatalogLocator.Match(book:validated.books[1],offset:101,snapshot:validated)
            if !reuse{await request()}
            precondition(CatalogLocator.sameSnapshot(match.snapshot,validated))
            print("EXPERIMENT locate reuse=\(reuse) elapsed=\(start.duration(to:.now)) requests=\(calls)")
        }
        let a=CachedNASFixture.page(100,100),changed=CachedNASFixture.page(100,100,revision:"e")
        precondition(!CatalogLocator.sameSnapshot(a,changed))
        print("EXPERIMENT locate final-check rejects changed publication; reuse-only prototype cannot observe it; keep production check")

        // Keep the earlier experiment as a regression of status-only updates.
        let defaults=UserDefaults.standard,hidden=defaults.object(forKey:"shelf.hideCovers")
        defer{if let hidden{defaults.set(hidden,forKey:"shelf.hideCovers")}else{defaults.removeObject(forKey:"shelf.hideCovers")}}
        let library=Library(loadPair:{nil},savePair:{_ in},removePair:{},lookup:{_ in []})
        library.setForeground(false);library.coversHidden=true;library.books=CachedNASFixture.page(0,500).books;library.total=600
        let grid=CollectionShelfController();grid.loadViewIfNeeded();grid.view.frame=CGRect(x:0,y:0,width:402,height:874)
        let header=AnyView(Text("Synthetic library"))
        grid.configure(library:library,columns:3,header:header,seek:nil)
        while grid.isUpdating{try? await Task.sleep(for:.milliseconds(5))}
        let initial=grid.experimentReloads
        for value in [true,false]{library.loading=value;grid.configure(library:library,columns:3,header:header,seek:nil)}
        let loadingReloads=grid.experimentReloads-initial
        library.error="Synthetic retry notice";grid.configure(library:library,columns:3,header:header,seek:nil)
        let errorReloads=grid.experimentReloads-initial-loadingReloads
        let before=grid.experimentReloads
        for _ in 0..<30{grid.configure(library:library,columns:3,header:header,seek:nil)}
        precondition(loadingReloads==0 && errorReloads==0 && grid.experimentReloads==before)
        print("EXPERIMENT grid books=500 loadingCycleReloads=\(loadingReloads) errorOnlyReloads=\(errorReloads) unchanged30UpdatesReloads=\(grid.experimentReloads-before); reloadData calls, not 500 realized cells or measured dropped frames")
        grid.dispose();library.setForeground(false)
        print("NAS experiments complete; production remains 3 physical cover tasks and 6-burst/8-per-second gate")
    }
}

struct ColdStartShelfDemo:View {
    @StateObject private var library:Library
    init(){
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.9.45:8089",token:CachedNASFixture.token,deviceId:CachedNASFixture.owner)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CachedNASFixture.self]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cold-shelf-"+UUID().uuidString)
        CachedNASFixture.configure(ready:!ProcessInfo.processInfo.arguments.contains("--cold-start-error"),delay:4,cover:ReaderDemo.data("1"))
        _library=StateObject(wrappedValue:Library(transport:LimitedHTTP(configuration:config),loadPair:{code},savePair:{_ in},removePair:{},lookup:{_ in []},catalogDisk:CatalogDiskStore(root:root.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:root.appendingPathComponent("covers"))))
    }
    var body:some View{ShelfView(library:library)}
}

struct NASCatalogPreviewDemo:View {
    @StateObject private var library:Library
    @State private var prepared=false
    private let code:PairingCode
    init(){
        code=PairingCode(app:"localshelf",version:2,address:"http://192.168.9.45:8089",token:CachedNASFixture.token,deviceId:CachedNASFixture.owner)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CachedNASFixture.self]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("nas-preview-"+UUID().uuidString)
        let pair=code
        _library=StateObject(wrappedValue:Library(transport:LimitedHTTP(configuration:config),loadPair:{pair},savePair:{_ in},removePair:{},lookup:{_ in []},catalogDisk:CatalogDiskStore(root:root.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:root.appendingPathComponent("covers"))))
    }
    var body:some View {
        Group {
            if prepared{ShelfView(library:library)}
            else{ProgressView().task{
                library.setForeground(false)
                do {
                    let ticket=try await library.catalogDisk.begin(owner:CachedNASFixture.owner,first:CachedNASFixture.page(0,500))
                    try await library.catalogDisk.append(CachedNASFixture.page(500,500),offset:500,ticket:ticket)
                    try await library.catalogDisk.commit(ticket,confirmed:CachedNASFixture.page(0,50))
                    let scope=CachedNASFixture.owner+"\n"+CachedNASFixture.library,identity=String(repeating:"b",count:64)
                    for id in 1...6 {for pixels in [320,480,640]{
                        let key=CoverRules.key(scope:scope+"\n"+identity+"\nthumbnail-v2-\(pixels)",path:"/v1/books/\(id)/cover")!
                        let record=CoverRecord(bytes:ReaderDemo.data(String(id)),thumbnail:false,etag:nil,checked:Date(),revision:String(repeating:"a",count:64))
                        try await library.coverDisk.put(record.packed(),key:key,ticket:await library.coverDisk.ticket())
                    }}
                    CachedNASFixture.configure(ready:false);await library.connect(code:code);await library.restoreLocalCatalog()
                    prepared=true
                }catch{preconditionFailure("preview fixture \(error)")}
            }}
        }
    }
}
// Two collections intentionally reuse book ID 1. Never contact a real NAS.
final class ManualLibraryFixture:URLProtocol {
    static let owner=String(repeating:"6",count:32),token=String(repeating:"M",count:32)
    static let ehID=String(repeating:"e",count:64),manualID=String(repeating:"d",count:64)
    static let lock=NSLock()
    static var paths:[String]=[]
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    static func list(manual:Bool,offset:Int,size:Int)->BookList {
        let count=manual ? 160:300
        return BookList(orderVerified:true,total:count,books:(offset..<min(offset+size,count)).map{Book(id:String($0+1),title:(manual ? "手动 · ":"Eh · ")+"示例漫画 \($0+1)",rank:$0,coverIdentity:manualID,pageCount:24)},orderPolicy:manual ? ShelfSource.manualPolicy:"ehviewer-downloads-time-desc",catalogRevision:manual ? manualID:ehID,libraryId:manual ? manualID:ehID)
    }
    override func startLoading(){
        let url=request.url!,path=url.path
        Self.lock.lock();Self.paths.append(path);Self.lock.unlock()
        var body=Data(),headers=[String:String]()
        let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        if path=="/v2/identity" {
            let nonce=query.first{$0.name=="nonce"}!.value!
            let proof=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(Self.owner)\n\(nonce)".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":Self.owner,"proof":proof])
        }else if path=="/v2/health"{
            body=try! JSONSerialization.data(withJSONObject:["app":"localshelf-reader","version":1,"serverKind":"nas","capabilities":["reader-v1","pair-v2","locate-v1","manual-library-v1","page-manifest-v1","conditional-manifest-v1"]])
        }else {
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            let manual=path.hasPrefix("/manual/")
            if path.hasSuffix("/books"){
                let offset=Int(query.first{$0.name=="offset"}!.value!)!,size=Int(query.first{$0.name=="limit"}!.value!)!
                body=try! JSONEncoder().encode(Self.list(manual:manual,offset:offset,size:size))
            }else if path.hasSuffix("/manifest"){
                let id=path.split(separator:"/").dropLast().last!
                let bytes=Data((manual ? "manual-body":"eh-body").utf8),sha=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
                body=try! JSONSerialization.data(withJSONObject:["id":String(id),"libraryId":manual ? Self.manualID:Self.ehID,"contentRevision":sha,"pages":[["number":1,"size":bytes.count,"sha256":sha]]])
                headers["ETag"]="\""+SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()+"\""
            }else if path.contains("/pages/"){
                body=Data((manual ? "manual-body":"eh-body").utf8)
                headers["ETag"]="\""+SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()+"\""
            }else if path.hasSuffix("/cover"){
                let id=path.split(separator:"/").dropLast().last ?? "1"
                body=ReaderDemo.data(String(id))
            }else{preconditionFailure("Unexpected isolated route: \(path)")}
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}

struct ManualLibraryDemo:View {
    @StateObject private var library:Library
    init(){
        UserDefaults.standard.set("nas",forKey:"server.selected")
        UserDefaults.standard.set("eh",forKey:"shelf.source")
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ManualLibraryFixture.self]
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.9.45:8089",token:ManualLibraryFixture.token,deviceId:ManualLibraryFixture.owner)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("manual-ui-fixture")
        _library=StateObject(wrappedValue:Library(transport:LimitedHTTP(configuration:config),loadPair:{code},savePair:{_ in},removePair:{},catalogDisk:CatalogDiskStore(root:root.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:root.appendingPathComponent("covers")),bodyDisk:BodyDiskCache(root:root.appendingPathComponent("body"))))
    }
    var body:some View{ShelfView(library:library)}
}

enum ManualLibraryChecks {
    @MainActor static func run()async {
        var checks=0
        func pass(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS \(label)")}
        let defaults=UserDefaults.standard
        let keys=["server.selected","shelf.source","shelf.hideCovers","reading.serverScope.nas"]
        let old=keys.map{defaults.object(forKey:$0)}
        defaults.set("nas",forKey:"server.selected");defaults.set("eh",forKey:"shelf.source");defaults.set(true,forKey:"shelf.hideCovers")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("manual-library-checks-"+UUID().uuidString)
        defer{for (key,value) in zip(keys,old){if let value{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}};try? FileManager.default.removeItem(at:root)}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ManualLibraryFixture.self]
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.9.45:8089",token:ManualLibraryFixture.token,deviceId:ManualLibraryFixture.owner)
        let disk=CatalogDiskStore(root:root.appendingPathComponent("catalog"))
        let library=Library(transport:LimitedHTTP(configuration:config),loadPair:{code},savePair:{_ in},removePair:{},catalogDisk:disk,coverDisk:CoverDiskCache(root:root.appendingPathComponent("cover")),bodyDisk:BodyDiskCache(root:root.appendingPathComponent("body")))
        do {
            await library.connect(code:code)
            pass(library.base != nil && library.total==300 && library.manualAvailable,"Eh remains initial collection on compatible server")
            let ehScope=library.recentScope!
            pass(String(decoding:try await library.data("/v1/books/1/pages/1"),as:UTF8.self)=="eh-body","Eh page uses Eh manifest and body")
            library.rememberReading(book:library.books[0],pages:[Page(number:1)],index:0,scope:ehScope)
            await library.refreshLocalCatalog();await library.loadPage(2);library.recordVisibleBook("205")
            await library.selectShelf(.manual)
            pass(library.shelfSource == .manual && library.total==160 && library.pageIndex==0,"manual switch loads separate collection")
            pass(library.recentScope != ehScope && library.recentReading==nil,"same numeric IDs do not adopt Eh reading progress")
            pass(String(decoding:try await library.data("/v1/books/1/pages/1"),as:UTF8.self)=="manual-body","same book ID reads manual body rather than Eh disk bytes")
            await library.refreshLocalCatalog()
            pass(try await disk.page(owner:ManualLibraryFixture.owner,page:0,size:50,source:.eh)?.list.total==300,"Eh local snapshot remains after manual cache save")
            pass(try await disk.page(owner:ManualLibraryFixture.owner,page:0,size:50,source:.manual)?.list.total==160,"manual local snapshot is selected by source")
            await library.loadPage(1);library.recordVisibleBook("110")
            await library.selectShelf(.eh)
            pass(library.pageIndex==2 && library.restoredBookID=="205","Eh page and visible book restored after switch")
            pass(library.recentReading?.book.id=="1" && library.recentScope==ehScope,"Eh continue-reading survives manual switch")
            await library.selectShelf(.manual)
            pass(library.pageIndex==1 && library.restoredBookID=="110","manual has independent viewport position")
            pass(library.paired?.token==code.token,"library switching does not re-pair or replace server token")
            library.setForeground(false)
            let manualScope=ManualLibraryFixture.owner+"\n"+ManualLibraryFixture.manualID
            for scope in [ehScope,manualScope]{defaults.removeObject(forKey:ReadingProgress.key(scope:scope,id:"1"))}
            for source in ShelfSource.allCases{for suffix in [".page",".anchor"]{defaults.removeObject(forKey:"shelf.position."+ManualLibraryFixture.owner+"."+source.rawValue+suffix)}}
        }catch{library.setForeground(false);preconditionFailure("Manual source checks failed: \(error)")}
        print("\(checks) manual library integration checks passed")
    }
}
#endif
