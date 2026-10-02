#if DEBUG && targetEnvironment(simulator)
import Foundation

private final class ManifestParseProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var calls=0,blocking=false,entered=false
    private let gate=DispatchSemaphore(value:0)
    func visit(){lock.lock();calls+=1;let block=blocking;if block{entered=true};lock.unlock();if block{gate.wait()}}
    func count()->Int{lock.lock();defer{lock.unlock()};return calls}
    func block(){lock.lock();blocking=true;entered=false;lock.unlock()}
    func waiting()->Bool{lock.lock();defer{lock.unlock()};return entered}
    func release(){lock.lock();blocking=false;lock.unlock();gate.signal()}
}

@MainActor enum ManifestConditionalChecks {
    static func run()async {
        var checks=0
        func pass(_ ok:Bool,_ text:String){precondition(ok,text);checks+=1;print("PASS "+text)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("manifest-checks-"+UUID().uuidString)
        let defaults=UserDefaults.standard,previous=defaults.object(forKey:"server.selected")
        defer{
            try? FileManager.default.removeItem(at:root);defaults.set(previous,forKey:"server.selected")
            NASFixture.conditionalMode=false;NASFixture.manifestFault="";NASFixture.bodyMode=false
        }
        do {
            let now=Date(),tag="\""+String(repeating:"a",count:64)+"\""
            let prepared=try PageListCache.validated(Pages(pages:[Page(number:1,sha256:String(repeating:"b",count:64),size:1)],id:"1",libraryId:String(repeating:"c",count:64),contentRevision:String(repeating:"d",count:64)))
            var cache=PageListCache();cache.configure("scope");cache.store(prepared,book:"1",now:now,etag:tag)
            pass(cache.value("1",now:now.addingTimeInterval(16))==nil,"expired metadata is not usable as fresh pages")
            pass(cache.candidate("1",now:now.addingTimeInterval(16))?.etag==tag,"expired metadata is retained only for server validation")
            pass(cache.candidate("1",now:now.addingTimeInterval(86400))==nil,"conditional candidates expire within 24 hours")
            cache.store(prepared,book:"1",now:now,etag:tag);cache.configure("another")
            pass(cache.candidate("1",now:now)==nil,"server/library scope change clears validators")
            cache.store(prepared,book:"1",now:now,etag:"W/"+tag)
            pass(cache.candidate("1",now:now)==nil,"weak validators are not retained by strict client")
            let huge=try PageListCache.validated(Pages(pages:(1...20000).map{Page(number:$0,sha256:String(repeating:"b",count:64),size:1)},id:"1",libraryId:String(repeating:"c",count:64),contentRevision:String(repeating:"d",count:64)))
            pass(!cache.store(huge,book:"2") && cache.cost<=1024*1024,"large manifest cannot exceed 1 MiB retained metadata budget")

            defaults.set("nas",forKey:"server.selected")
            NASFixture.bodyMode=true;NASFixture.conditionalMode=true;NASFixture.ready=true;NASFixture.bodyVersion=1
            NASFixture.manifestBodies=0;NASFixture.manifestNotModified=0;NASFixture.manifestConditionals=0
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[NASFixture.self]
            let parser=MetadataParser(),probe=ManifestParseProbe()
            let library=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in},removePair:{},metadata:parser,catalogDisk:CatalogDiskStore(root:root.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:root.appendingPathComponent("covers")),bodyDisk:BodyDiskCache(root:root.appendingPathComponent("bodies")))
            library.setForeground(false);library.address="http://192.168.9.2:8089";await library.connect(pin:"001234")
            pass(library.base != nil,"conditional NAS connects through verified identity")
            await parser.setHook{probe.visit()}
            let first=try await library.pageList("1")
            pass(probe.count()==1 && NASFixture.manifestBodies==1,"first 200 response is validated and parsed once")
            for _ in 0..<10{
                let value=try await library.pageList("1")
                precondition(value.contentRevision==first.contentRevision && value.pages[0].sha256==first.pages[0].sha256)
            }
            pass(NASFixture.manifestNotModified==10 && NASFixture.manifestBodies==1,"ten reentries use authenticated zero-body 304")
            pass(probe.count()==1,"304 reuses validated metadata without ten repeated JSON parses")
            NASFixture.bodyVersion=2
            let updated=try await library.pageList("1")
            pass(updated.contentRevision != first.contentRevision && probe.count()==2,"changed content returns 200 and replaces old page identities")
            let conditionals=NASFixture.manifestConditionals
            _=try await library.pageList("1",force:true)
            pass(NASFixture.manifestConditionals==conditionals && probe.count()==3,"manual refresh bypasses conditional candidate")
            for fault in ["wrongTag","missingTag","401","409","503","badJSON"] {
                NASFixture.manifestFault=fault
                do{_=try await library.pageList("1");preconditionFailure("accepted bad conditional response: "+fault)}catch{pass(true,"rejects conditional response "+fault)}
                NASFixture.manifestFault=""
                let before=NASFixture.manifestConditionals
                _=try await library.pageList("1")
                pass(before==NASFixture.manifestConditionals,"failed response invalidates candidate: "+fault)
            }
            NASFixture.manifestFault="unsolicited304"
            do{_=try await library.pageList("1",force:true);preconditionFailure("unsolicited 304")}catch{pass(true,"304 without a retained representation is rejected")}
            NASFixture.manifestFault="wrongTag"
            do{_=try await library.pageList("1",force:true);preconditionFailure("bad digest")}catch{pass(true,"200 body must match its strong validator")}
            NASFixture.manifestFault=""
            probe.block()
            let pending=Task{try await library.pageList("1",force:true)}
            for _ in 0..<1000{if probe.waiting(){break};try await Task.sleep(for:.milliseconds(5))}
            precondition(probe.waiting());library.invalidatePageList("1");probe.release()
            do{_=try await pending.value;preconditionFailure("stale write after invalidate")}catch{pass(true,"explicit invalidation prevents in-flight response resurrection")}
            _=try await library.pageList("1")
            await parser.setHook(nil)
            NASFixture.conditionalMode=false;await library.reconnect()
            let old=NASFixture.manifestConditionals,bodies=NASFixture.manifestBodies
            _=try await library.pageList("1");_=try await library.pageList("1")
            pass(old==NASFixture.manifestConditionals && NASFixture.manifestBodies==bodies+2,"old NAS without capability keeps full-response compatibility")
            print("\(checks) manifest conditional checks passed")
        }catch{preconditionFailure("manifest conditional checks: \(error)")}
    }
}
#endif
