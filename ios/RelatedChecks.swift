#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import CryptoKit

final class RelatedFixture:URLProtocol {
    static let owner=String(repeating:"6",count:32),libraryID=String(repeating:"7",count:64),revision=String(repeating:"8",count:64),token=String(repeating:"T",count:32)
    static let authorID=String(repeating:"a",count:64),seriesID=String(repeating:"b",count:64)
    static let lock=NSLock()
    static var calls=[String:Int](),mode="",delay=0.0
    static func set(_ mode:String="",delay:Double=0){lock.lock();self.mode=mode;self.delay=delay;calls=[:];lock.unlock()}
    static func count(_ suffix:String)->Int{lock.lock();defer{lock.unlock()};return calls.filter{$0.key.hasSuffix(suffix)}.values.reduce(0,+)}
    static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func picture()->Data{
        UIGraphicsImageRenderer(size:CGSize(width:160,height:240)).pngData{c in
            UIColor(white:0.09,alpha:1).setFill();c.fill(CGRect(x:0,y:0,width:160,height:240))
            UIColor.systemTeal.setFill();c.fill(CGRect(x:18,y:20,width:124,height:160))
            ("DEMO" as NSString).draw(at:CGPoint(x:34,y:194),withAttributes:[.font:UIFont.boldSystemFont(ofSize:22),.foregroundColor:UIColor.white])
        }
    }
    static func book(_ rank:Int)->Book{Book(id:String(rank+1),title:"[合成作者] 夜空 第\(rank+1)卷",rank:rank,available:true,coverIdentity:hash(picture()))}
    static func catalog(offset:Int,size:Int,filtered:Bool=false)->BookList{
        let total=filtered ? 102:10094
        return BookList(orderVerified:true,total:total,books:(offset..<min(total,offset+size)).map{book(filtered ? $0*2:$0)},orderPolicy:"ehviewer-downloads-time-desc",catalogRevision:revision,libraryId:libraryID)
    }
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    private var stopped=false
    override func startLoading(){
        let url=request.url!,path=url.path
        precondition(url.host=="192.168.9.99","Related checks must never reach a real server")
        Self.lock.lock();Self.calls[path,default:0]+=1;let mode=Self.mode,delay=Self.delay;Self.lock.unlock()
        let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        func value(_ name:String,_ fallback:String)->String{query.first{$0.name==name}?.value ?? fallback}
        var body=Data(),status=200
        if path=="/v2/identity"{
            let proof=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(Self.owner)\n\(value("nonce",""))".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":Self.owner,"proof":proof])
        }else if path=="/v2/health"{
            var caps=["reader-v1","pair-v2","locate-v1"]
            if mode != "legacy"{caps += ["author-discovery-v1","series-discovery-v1"]}
            if mode != "legacy" && mode != "v1"{caps.append("author-evidence-v2")}
            if mode.hasPrefix("expanded"){caps.append("related-evidence-v3")}
            if mode == "expandedCredit" || mode == "expandedRelaxed"{caps.append("author-credit-fallback-v1")}
            if mode == "expandedRelaxed"{caps.append("related-relaxed-v1")}
            body=try! JSONSerialization.data(withJSONObject:["app":"localshelf-reader","version":1,"serverKind":"nas","capabilities":caps])
        }else{
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            if path=="/v1/books"{body=try! JSONEncoder().encode(Self.catalog(offset:Int(value("offset","0"))!,size:Int(value("limit","100"))!))}
            else if path.hasSuffix("/cover") || path.contains("/pages/"){body=Self.picture()}
            else if path.hasSuffix("/pages"){body=Data("{\"pages\":[{\"number\":1},{\"number\":2},{\"number\":3}]}".utf8)}
            else {
                let parts=path.split(separator:"/").map(String.init)
                if parts.count>=4,let kind=RelatedKind(rawValue:parts[3]){
                    var choice=RelatedChoice(id:kind == .authors ? Self.authorID:Self.seriesID,name:kind == .authors ? "合成作者 / Demo Artist":"夜空",matchKind:kind == .authors ? "artist":"series",count:102)
                    let expanded=mode.hasPrefix("expanded"),evidence=kind == .authors && mode != "v1"
                    let credit=(mode == "expandedCredit" || mode == "expandedRelaxed") && kind == .authors
                    precondition(value("credit","") == (credit ? "1":""),"credit fallback must be negotiated only for authors")
                    precondition(value("relaxed","") == (mode == "expandedRelaxed" ? "1":""),"relaxed evidence must be negotiated")
                    if expanded{
                        precondition(value("evidence","")=="3" && !query.contains{$0.name=="includePossible"},"v3 must be negotiated")
                        choice.possibleCount=kind == .series ? 102:12;choice.evidenceVersion=3
                    }else if evidence{
                        precondition(value("includePossible","")=="1","v2 candidates must be negotiated")
                        choice.possibleCount=mode=="possible" || mode=="invalidPossible" ? 12:0
                    }else{precondition(!query.contains{$0.name=="includePossible"})}
                    if parts.count==4{
                        var choices=mode=="empty" ? []:[choice]
                        if mode=="multi"{choices.append(RelatedChoice(id:String(repeating:"c",count:64),name:"另一位作者",matchKind:"artist",count:102))}
                        body=try! JSONEncoder().encode(RelatedOptions(bookID:parts[2],kind:kind,libraryId:Self.libraryID,catalogRevision:Self.revision,options:choices))
                    }else{
                        let size=Int(value("limit","100"))!,offset=min(Int(value("offset","0"))!,100/size*size)
                        var result=RelatedResult(bookID:parts[2],kind:kind,option:choice,offset:offset,catalog:Self.catalog(offset:offset,size:size,filtered:true))
                        if expanded{
                            let possible=kind == .series ? result.catalog.books:result.catalog.books.filter{$0.rank>=180}
                            result.possibleBookIDs=possible.map(\.id)
                            result.matchNotes=Dictionary(uniqueKeysWithValues:possible.map{($0.id,kind == .authors ? RelatedMatchNote.circle:($0.rank%4==0 ? .edition:.seriesSubtitle))})
                            if mode == "expandedCredit" && kind == .authors{result.matchNotes=Dictionary(uniqueKeysWithValues:possible.map{($0.id,RelatedMatchNote.creditName)})}
                            if mode == "expandedRelaxed"{result.matchNotes=Dictionary(uniqueKeysWithValues:possible.map{($0.id,kind == .authors ? RelatedMatchNote.workCredit:($0.rank%4==0 ? .authorSeries:.seriesVariant))})}
                            if mode=="expandedInvalid"{result.matchNotes=[:]}
                        }else if evidence{result.possibleBookIDs=choice.possibleCount==12 ? result.catalog.books.filter{$0.rank>=180}.map(\.id):[]}
                        if kind == .series{result.partLabels=Dictionary(uniqueKeysWithValues:result.catalog.books.map{($0.id,"第\($0.rank+1)巻")})}
                        if mode=="invalidPossible"{result.possibleBookIDs=[parts[2]]}
                        body=try! JSONEncoder().encode(result)
                    }
                    if mode=="error"{status=503;body=Data()}
                    if mode=="malformed"{body=Data("{}".utf8)}
                    if parts.count>4 && (mode=="always404" || (mode=="once404" && Self.count(parts[4])==1)){status=404;body=Data()}
                }else{status=404}
            }
        }
        if delay>0 && (path.contains("/authors") || path.contains("/series")){Thread.sleep(forTimeInterval:delay)}
        guard !stopped else{return}
        let headers=["Content-Length":"\(body.count)","ETag":"\""+Self.hash(body)+"\""]
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){stopped=true}
}

@MainActor enum RelatedChecks {
    static func client(_ root:URL)async->Library{
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RelatedFixture.self]
        let library=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in},removePair:{},
            catalogDisk:CatalogDiskStore(root:root.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:root.appendingPathComponent("covers")),bodyDisk:BodyDiskCache(root:root.appendingPathComponent("body")))
        library.setForeground(false)
        if library.serverTarget != .nas{await library.selectServer(.nas)}
        await library.connect(code:PairingCode(app:"localshelf",version:2,address:"http://192.168.9.99:8089",token:RelatedFixture.token,deviceId:RelatedFixture.owner))
        precondition(library.base != nil);return library
    }
    static func wait(_ condition:@MainActor ()->Bool)async {
        for _ in 0..<200{if condition(){return};try? await Task.sleep(for:.milliseconds(20))}
        preconditionFailure("Related check timed out")
    }
    static func run()async {
        let previous=UserDefaults.standard.object(forKey:"server.selected"),hidden=UserDefaults.standard.object(forKey:"shelf.hideCovers")
        defer{UserDefaults.standard.set(previous,forKey:"server.selected");UserDefaults.standard.set(hidden,forKey:"shelf.hideCovers")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var checks=0
        func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS \(label)")}
        RelatedFixture.set();let library=await client(root)
        let original=library.books,originalTotal=library.total,originalPage=library.pageIndex
        library.setRelatedBrowsing(true)
        let request=RelatedRequest(book:original[0],kind:.authors),model=RelatedShelfModel()
        model.start(library:library,request:request);await wait{model.result != nil}
        check(model.result?.catalog.total==102,"author result has independent filtered count")
        check(model.result?.catalog.books.count==100,"result limited to one page")
        check(library.books==original && library.total==originalTotal && library.pageIndex==originalPage,"main shelf untouched by author query")
        check(model.result!.catalog.books.map(\.rank)==Array(stride(from:0,to:200,by:2)),"original ranks preserved")
        model.select(model.result!.option,library:library,request:request,page:1);await wait{!model.loading}
        check(model.page==1 && model.result?.catalog.books.count==2,"filtered tail page")
        model.start(library:library,request:request)
        check(model.page==1,"reader return does not reset filtered page")
        let grid=RelatedCollectionController();grid.configure(library:library,books:model.result!.catalog.books,columns:3,pageKey:"one",origin:"1")
        grid.view.frame=CGRect(x:0,y:0,width:390,height:640);grid.view.layoutIfNeeded()
        check(grid.collectionView.numberOfItems(inSection:0)==2,"real UIKit result grid count")
        library.coversHidden=true;let count=RelatedFixture.count("/cover")
        let cell=ShelfCoverCell(frame:CGRect(x:0,y:0,width:100,height:200));cell.configure(book:original[0],library:library)
        try? await Task.sleep(for:.milliseconds(80))
        check(RelatedFixture.count("/cover")==count && cell.picture.image==nil,"hidden covers never requested")
        cell.stop();grid.stop();model.cancel()
        RelatedFixture.set("possible");let possible=RelatedShelfModel();possible.start(library:library,request:request);await wait{possible.result != nil}
        check(possible.result?.option.possibleCount==12 && possible.result?.possibleBookIDs?.count==10,"candidate count and current-page evidence decoded")
        let candidate=possible.result!.catalog.books.last!
        cell.configure(book:candidate,library:library,possibleMatch:true)
        check(cell.accessibilityLabel?.contains("可能匹配")==true,"candidate evidence visible to accessibility")
        cell.prepareForReuse();cell.configure(book:original[0],library:library)
        check(cell.accessibilityLabel?.contains("可能匹配")==false,"reused ordinary cell has no stale candidate badge")
        possible.select(possible.result!.option,library:library,request:request,page:1);await wait{!possible.loading}
        check(possible.result?.possibleBookIDs==["201","203"],"candidate evidence follows result pagination")
        possible.cancel();cell.stop()
        RelatedFixture.set("invalidPossible");possible.start(library:library,request:request,force:true);await wait{!possible.loading}
        check(possible.result==nil && !possible.message.isEmpty,"malformed candidate evidence rejected")
        RelatedFixture.set("v1");let older=await client(root.appendingPathComponent("v1")),olderModel=RelatedShelfModel()
        olderModel.start(library:older,request:request);await wait{olderModel.result != nil}
        check(olderModel.result?.option.possibleCount==nil,"v1 server works without new query parameters")
        olderModel.cancel();older.setForeground(false)
        RelatedFixture.set("multi");let multi=RelatedShelfModel();multi.start(library:library,request:request);await wait{!multi.loading}
        check(multi.options.count==2 && multi.result==nil,"multiple authors require selection")
        RelatedFixture.set("empty");multi.start(library:library,request:request,force:true);await wait{!multi.loading}
        check(multi.options.isEmpty && multi.result==nil && !multi.message.isEmpty,"empty authors explained")
        RelatedFixture.set("malformed");multi.start(library:library,request:request,force:true);await wait{!multi.loading}
        check(multi.result==nil && !multi.message.isEmpty,"malformed response never displayed")
        RelatedFixture.set();let series=RelatedShelfModel();series.start(library:library,request:RelatedRequest(book:original[0],kind:.series));await wait{series.result != nil}
        check(series.result?.kind == .series,"series endpoint and response isolation")
        check(series.result?.partLabels?["1"]=="第1巻","series volume labels decoded")
        series.cancel()
        RelatedFixture.set("expanded");let wideLibrary=await client(root.appendingPathComponent("expanded")),wideModel=RelatedShelfModel()
        wideModel.start(library:wideLibrary,request:request);await wait{wideModel.result != nil}
        check(wideModel.result?.option.evidenceVersion==3 && wideModel.result?.matchNotes?.values.allSatisfy{$0 == .circle}==true,"v3 authors negotiate circle evidence")
        let wideBook=wideModel.result!.catalog.books.last!
        cell.configure(book:wideBook,library:wideLibrary,possibleMatch:true,matchNote:.circle)
        check(cell.accessibilityLabel?.contains("同社团，作者待确认")==true,"circle badge does not claim author identity")
        cell.configure(book:wideBook,library:wideLibrary,possibleMatch:true,partLabel:"番外",matchNote:.edition)
        check(cell.accessibilityLabel?.contains("同作不同版本")==true && cell.accessibilityLabel?.contains("番外")==true,"edition and part remain distinguishable")
        cell.configure(book:wideBook,library:wideLibrary)
        check(cell.accessibilityLabel==wideBook.title,"evidence-only reuse clears badge without changing cover identity")
        var countedBook=wideBook;countedBook.pageCount=256
        let beforeCountRestart=cell.imageRestarts
        cell.configure(book:countedBook,library:wideLibrary,possibleMatch:true,partLabel:"番外",matchNote:.edition)
        check(cell.pageCountBadge.text=="256" && cell.imageRestarts==beforeCountRestart,"related card adds a numeric count without reloading its cover")
        check(cell.accessibilityLabel?.contains("同作不同版本")==true && cell.accessibilityLabel?.hasSuffix("256 页")==true,"count and series evidence coexist")
        wideModel.cancel()
        let wideRequest=RelatedRequest(book:original[0],kind:.series)
        wideModel.start(library:wideLibrary,request:wideRequest,force:true);await wait{wideModel.result != nil}
        check(wideModel.result?.option.possibleCount==102 && wideModel.result?.matchNotes?.count==100,"all-candidate series accepted with complete page evidence")
        wideModel.select(wideModel.result!.option,library:wideLibrary,request:wideRequest,page:1);await wait{!wideModel.loading}
        check(wideModel.result?.matchNotes?.count==2 && wideModel.result?.possibleBookIDs==["201","203"],"expanded series tail page remains bounded and ordered")
        RelatedFixture.set("expandedInvalid");wideModel.start(library:wideLibrary,request:wideRequest,force:true);await wait{!wideModel.loading}
        check(wideModel.result==nil && !wideModel.message.isEmpty,"missing v3 reasons rejected")
        wideModel.cancel();cell.stop();wideLibrary.setForeground(false)
        for mode in ["expandedCredit","expandedRelaxed"]{
            RelatedFixture.set(mode);let newLibrary=await client(root.appendingPathComponent(mode)),newModel=RelatedShelfModel()
            newModel.start(library:newLibrary,request:request);await wait{newModel.result != nil}
            let expected:RelatedMatchNote=mode == "expandedCredit" ? .creditName:.workCredit
            check(newModel.result?.matchNotes?.values.allSatisfy{$0 == expected}==true,"new author evidence negotiated: \(mode)")
            cell.configure(book:newModel.result!.catalog.books.last!,library:newLibrary,possibleMatch:true,matchNote:expected)
            check(cell.accessibilityLabel?.contains(expected.explanation)==true,"new author evidence accessible without claiming identity")
            newModel.cancel();newModel.start(library:newLibrary,request:wideRequest,force:true);await wait{newModel.result != nil}
            let allowed:Set<RelatedMatchNote>=mode == "expandedCredit" ? [.edition,.seriesSubtitle]:[.authorSeries,.seriesVariant]
            check(newModel.result?.matchNotes?.values.allSatisfy{allowed.contains($0)}==true,"series negotiates its own evidence without author credit parameter")
            newModel.cancel();newLibrary.setForeground(false);cell.stop()
        }
        RelatedFixture.set("once404");let refreshed=RelatedShelfModel();refreshed.start(library:library,request:request);await wait{refreshed.result != nil}
        check(RelatedFixture.count("/authors")==2 && RelatedFixture.count(RelatedFixture.authorID)==2,"changed selection recovers with one bounded re-resolution")
        refreshed.cancel()
        RelatedFixture.set("always404");refreshed.start(library:library,request:request,force:true);await wait{!refreshed.loading}
        check(refreshed.result==nil && !refreshed.message.isEmpty && RelatedFixture.count(RelatedFixture.authorID)==2,"persistent 404 stops after one retry")
        RelatedFixture.set(delay:0.2);let cancelled=RelatedShelfModel();cancelled.start(library:library,request:request)
        cancelled.cancel();try? await Task.sleep(for:.milliseconds(350))
        check(cancelled.result==nil && !cancelled.loading,"cancelled response never resurrects results")
        RelatedFixture.set("legacy");let legacy=await client(root.appendingPathComponent("legacy")),legacyModel=RelatedShelfModel()
        legacyModel.start(library:legacy,request:request)
        check(!legacyModel.loading && !legacyModel.message.isEmpty && !legacy.supportsRelated(.authors),"old server displays upgrade instruction")
        check(RelatedFixture.count("/authors")==0,"legacy never downloads full catalog for search")
        library.setRelatedBrowsing(false);library.setForeground(false);legacy.setForeground(false)
        check(library.books==original && library.total==originalTotal && library.pageIndex==originalPage,"closing result preserves main shelf")
        print("\(checks) related discovery checks passed")
    }
}

struct RelatedDemoView:View {
    @State private var library:Library?
    var body:some View{Group{if let library{ShelfView(library:library)}else{ProgressView()}}.task{
        let args=ProcessInfo.processInfo.arguments
        RelatedFixture.set(args.contains("--related-relaxed-demo") ? "expandedRelaxed":args.contains("--related-credit-demo") ? "expandedCredit":args.contains("--related-expanded-demo") ? "expanded":args.contains("--related-possible-demo") ? "possible":"")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("related-ui-fixture",isDirectory:true)
        library=await RelatedChecks.client(root)
    }}
}
#endif
