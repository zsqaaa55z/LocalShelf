import Foundation
import CryptoKit

// One delegate queue writes each sink. Never place a complete compressed body
// in the network buffer before writing the optional cache.
final class BodyStreamSink {
    let expected:Int,sha:String
    private var handle:FileHandle?
    private var count=0,digest=SHA256()
    init(url:URL,size:Int,sha:String)throws {
        self.expected=size;self.sha=sha
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.protectionKey:FileProtectionType.complete]) else{throw CocoaError(.fileWriteUnknown)}
        handle=try FileHandle(forWritingTo:url)
    }
    func append(_ data:Data)throws{
        guard data.count<=expected-count,let handle else{throw LibraryError.malformed}
        try handle.write(contentsOf:data);digest.update(data:data);count+=data.count
    }
    func finish(etag:String?)throws{
        try handle?.close();handle=nil
        if let etag,ManifestValidator.valid(etag),etag != "\""+sha+"\""{throw PageReadFailure.changed}
        guard count==expected,etag=="\""+sha+"\"",digest.finalize().map({String(format:"%02x",$0)}).joined()==sha else{throw LibraryError.malformed}
    }
    deinit{try? handle?.close()}
}

#if DEBUG && targetEnvironment(simulator)
enum BodyCacheChecks {
    @MainActor static func run()async {
        var checks=0
        func pass(_ ok:Bool,_ text:String){precondition(ok,text);checks+=1;print("PASS "+text)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("body-checks-"+UUID().uuidString)
        let previous=UserDefaults.standard.object(forKey:"server.selected")
        defer{try? FileManager.default.removeItem(at:root);if let previous{UserDefaults.standard.set(previous,forKey:"server.selected")}else{UserDefaults.standard.removeObject(forKey:"server.selected")}}
        do{
            let disk=BodyDiskCache(root:root.appendingPathComponent("bodies"),budget:16*1024*1024)
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[NASFixture.self]
            UserDefaults.standard.set("nas",forKey:"server.selected")
            NASFixture.bodyMode=true;NASFixture.ready=true;NASFixture.bodyVersion=1;NASFixture.bodyRequests=0;NASFixture.manifestRequests=0
            let library=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in},removePair:{},catalogDisk:CatalogDiskStore(root:root.appendingPathComponent("catalog")),coverDisk:CoverDiskCache(root:root.appendingPathComponent("covers")),bodyDisk:disk)
            library.setForeground(false);library.address="http://192.168.9.2:8089";await library.connect(pin:"001234")
            pass(library.base != nil,"new NAS establishes verified source")
            let pages=try await library.pageList("1");pass(pages.pages[0].sha256 != nil,"manifest includes content hashes")
            let first=try await library.data("/v1/books/1/pages/1")
            pass(first==Data(repeating:1,count:1024*1024) && NASFixture.bodyRequests==1,"first body streams and verifies SHA before caching")
            let second=try await library.data("/v1/books/1/pages/1")
            pass(second==first && NASFixture.bodyRequests==1,"body hit avoids repeated HTTP download")
            _=try await library.pageList("1")
            pass(NASFixture.manifestRequests==2,"reentering book revalidates content manifest")
            NASFixture.bodyVersion=2;_=try await library.pageList("1",force:true)
            let updated=try await library.data("/v1/books/1/pages/1")
            pass(updated==Data(repeating:2,count:first.count) && first.first==1 && NASFixture.bodyRequests==2,"same-size new content does not overwrite old mapped bytes")
            NASFixture.bodyVersion=3;NASFixture.bodyCorrupt=true;_=try await library.pageList("1",force:true)
            do{_=try await library.data("/v1/books/1/pages/1");preconditionFailure("bad hash accepted")}catch{pass(true,"bad network SHA is rejected, not persisted")}
            NASFixture.bodyCorrupt=false
            let corrected=try await library.data("/v1/books/1/pages/1");pass(corrected.first==3,"failed stream releases reservation for retry")
            let sha=SHA256.hash(data:first).map{String(format:"%02x",$0)}.joined()
            let other=try await disk.value(scope:"another-library",sha:sha,size:first.count);pass(other==nil,"same bytes never bypass server/library scope")
            let pending=try await disk.begin(scope:"cancel",sha:sha,size:first.count)
            let sink=try await disk.sink(pending);try sink.append(first);try sink.finish(etag:"\""+sha+"\"")
            try await disk.clear()
            do{_=try await disk.commit(pending);preconditionFailure("old commit survived clear")}catch{pass(true,"clear invalidates in-flight write tickets")}
            pass(first.first==1 && updated.first==2 && corrected.first==3,"clear does not invalidate live mapped player bytes")
            pass(try await disk.usage()<=16*1024*1024,"live retired files remain within charged budget")
            let fileValues=try root.appendingPathComponent("bodies").resourceValues(forKeys:[.isExcludedFromBackupKey]);pass(fileValues.isExcludedFromBackup==true,"body directory excluded from backups")
            for n in 1...3 {
                let sample=ReaderDemo.animationData("/v1/books/1/pages/\(n)")
                let hash=SHA256.hash(data:sample).map{String(format:"%02x",$0)}.joined()
                let cache=BodyDiskCache(root:root.appendingPathComponent("animation\(n)"),budget:16*1024*1024)
                let ticket=try await cache.begin(scope:"animation",sha:hash,size:sample.count),writer=try await cache.sink(ticket)
                try writer.append(sample);try writer.finish(etag:"\""+hash+"\"")
                let mapped=try await cache.commit(ticket),original=try await PreparedAnimation.make(sample),prepared=try await PreparedAnimation.make(mapped)
                pass(original.info.count==prepared.info.count && original.first.1==prepared.first.1 && original.second.1==prepared.second.1,"mapped animation \(n) retains frame count and timing")
                try await cache.clear();_=try await prepared.frame(2)
                pass(true,"mapped animation \(n) continues decoding after cache clear")
            }
            library.setForeground(false);NASFixture.bodyMode=false
        }catch{preconditionFailure("body cache checks failed: \(error)")}
        print("\(checks) body cache checks passed")
    }
}
#endif

actor BodyDiskCache {
    static let budget=MediaDiskBudget.body
    struct Ticket {let id:String,key:String,url:URL,size:Int,epoch:UUID,sha:String}
    private let root:URL,limit:Int
    private var db:LocalSQL?,epoch=UUID(),prepared=false
    private var pending:[String:Ticket]=[:],leases:[String:Int]=[:],retired:[String:Int]=[:]
    private var verified=Set<String>()
    private var storedBytes=0,storedCount=0,touches:[String:Double]=[:]
    private var touchTask:Task<Void,Never>?
    #if DEBUG && targetEnvironment(simulator)
    private(set) var touchTransactions=0,capacityAudits=0,evictionQueries=0
    func flushForChecks()throws{try prepare();try flushTouches()}
    func accountingForChecks()throws->Bool {
        try prepare();let totals=try db!.rows("SELECT COALESCE(SUM(size+16384),0),COUNT(*) FROM bodies")[0]
        return totals[0].int==storedBytes && totals[1].int==storedCount
    }
    #endif
    init(root:URL?=nil,budget:Int=BodyDiskCache.budget){self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalShelfBodies-v1",isDirectory:true);self.limit=max(0,budget-8*1024*1024)}
    private func validName(_ name:String)->Bool{name.range(of:"^[A-F0-9-]{36}\\.(body|partial)$",options:.regularExpression) != nil}
    private func file(_ name:String)->URL{root.appendingPathComponent(name)}
    private func key(_ scope:String,_ sha:String)throws->String {
        guard !scope.isEmpty,sha.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw LibraryError.malformed}
        return SHA256.hash(data:Data((scope+"\n"+sha).utf8)).map{String(format:"%02x",$0)}.joined()
    }
    private func prepare()throws {
        guard !prepared else{return};try preparePrivateDirectory(root)
        let indexURL=root.appendingPathComponent("index.sqlite")
        do{db=try LocalSQL(indexURL);try db!.execute("CREATE TABLE IF NOT EXISTS bodies(key TEXT PRIMARY KEY,name TEXT UNIQUE,size INTEGER,used REAL)")}
        catch let error as LocalSQLError where error.code==11 || error.code==26 {
            db=nil
            for suffix in ["","-wal","-shm"]{try? FileManager.default.removeItem(at:URL(fileURLWithPath:indexURL.path+suffix))}
            db=try LocalSQL(indexURL);try db!.execute("CREATE TABLE bodies(key TEXT PRIMARY KEY,name TEXT UNIQUE,size INTEGER,used REAL)")
        }
        try db!.execute("PRAGMA max_page_count=1024")
        try db!.execute("PRAGMA wal_autocheckpoint=64")
        try db!.execute("CREATE INDEX IF NOT EXISTS bodies_lru ON bodies(used,key)")
        // <= 2,000 owned entries, off MainActor. Only disposable files with our
        // exact generated names may be removed. Crash partials never become hits.
        let entries=try db!.rows("SELECT name,size FROM bodies")
        var known=Set<String>()
        for entry in entries {
            let name=entry[0].string
            if validName(name),name.hasSuffix(".body"),(1...50*1024*1024).contains(entry[1].int),let v=try? file(name).resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]),v.isRegularFile==true,v.isSymbolicLink != true,v.fileSize==entry[1].int {known.insert(name)}
            else{try db!.execute("DELETE FROM bodies WHERE name=?",[.text(name)])}
        }
        for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where validName(url.lastPathComponent) && !known.contains(url.lastPathComponent){try FileManager.default.removeItem(at:url)}
        let totals=try db!.rows("SELECT COALESCE(SUM(size+16384),0),COUNT(*) FROM bodies")[0]
        storedBytes=totals[0].int;storedCount=totals[1].int
        #if DEBUG && targetEnvironment(simulator)
        capacityAudits+=1
        #endif
        prepared=true;try trim(reserving:0)
    }
    private func charged()->Int{
        storedBytes+retired.values.reduce(0,+)+pending.values.reduce(0){$0+$1.size+16384}
    }
    private func touch(_ key:String,now:Double){
        if touches[key]==nil,touches.count>=128{try? flushTouches();if touches.count>=128{return}}
        touches[key]=now
        if touches.count>=128{try? flushTouches()}
        guard touchTask==nil,!touches.isEmpty else{return}
        touchTask=Task{[weak self] in
            do{try await Task.sleep(for:.seconds(2))}catch{return}
            guard let self else{return};await self.finishTouches()
        }
    }
    private func finishTouches(){touchTask=nil;try? flushTouches()}
    private func flushTouches()throws {
        guard !touches.isEmpty else{return}
        let batch=touches
        try db!.transaction{
            for (key,used) in batch{try db!.execute("UPDATE bodies SET used=MAX(used,?) WHERE key=?",[.real(used),.text(key)])}
        }
        touches.removeAll(keepingCapacity:true)
        #if DEBUG && targetEnvironment(simulator)
        touchTransactions+=1
        #endif
    }
    private func remove(_ key:String,_ name:String)throws{
        guard validName(name) else{throw LibraryError.malformed}
        guard let row=try db!.rows("SELECT size FROM bodies WHERE key=? AND name=?",[.text(key),.text(name)]).first else{return}
        let cost=row[0].int+16384
        if leases[name]==nil{
            do{try FileManager.default.removeItem(at:file(name))}
            catch let e as NSError where e.domain==NSCocoaErrorDomain && e.code==NSFileNoSuchFileError{}
        }
        try db!.execute("DELETE FROM bodies WHERE key=?",[.text(key)])
        storedBytes-=cost;storedCount-=1
        if leases[name] != nil{retired[name]=cost}
        verified.remove(name);touches.removeValue(forKey:key)
    }
    private func trim(reserving:Int)throws{
        guard charged()+reserving>limit || storedCount>=2000 else{return}
        // Pending touches participate in LRU before eviction. An access-time
        // flush failure defers cache writes, never sacrifices the active page.
        try flushTouches()
        var skipped=0
        while charged()+reserving>limit || storedCount>=2000 {
            let rows=try db!.rows("SELECT key,name FROM bodies ORDER BY used,key LIMIT 64 OFFSET ?",[.integer(skipped)])
            #if DEBUG && targetEnvironment(simulator)
            evictionQueries+=1
            #endif
            if rows.isEmpty{break}
            for row in rows {
                if charged()+reserving<=limit && storedCount<2000{return}
                if leases[row[1].string] != nil{skipped+=1;continue}
                try remove(row[0].string,row[1].string)
            }
        }
    }
    func usage()throws->Int{try prepare();return charged()}
    func begin(scope:String,sha:String,size:Int)throws->Ticket{
        try Task.checkCancellation();try prepare()
        guard size>0,size<=50*1024*1024,size<=limit,pending.count<2 else{throw CocoaError(.fileWriteOutOfSpace)}
        let space=try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let space,space<Int64(size)+256*1024*1024{throw CocoaError(.fileWriteOutOfSpace)}
        try trim(reserving:size+16384)
        guard charged()+size+16384<=limit else{throw CocoaError(.fileWriteOutOfSpace)}
        let id=UUID().uuidString,ticket=Ticket(id:id,key:try key(scope,sha),url:file(id+".partial"),size:size,epoch:epoch,sha:sha)
        pending[id]=ticket;return ticket
    }
    func sink(_ ticket:Ticket)throws->BodyStreamSink{
        guard ticket.epoch==epoch,pending[ticket.id] != nil else{throw CancellationError()}
        return try BodyStreamSink(url:ticket.url,size:ticket.size,sha:ticket.sha)
    }
    func abort(_ ticket:Ticket){
        pending.removeValue(forKey:ticket.id);try? FileManager.default.removeItem(at:ticket.url)
    }
    func commit(_ ticket:Ticket)throws->Data{
        try Task.checkCancellation()
        guard pending[ticket.id] != nil,ticket.epoch==epoch else{abort(ticket);throw CancellationError()}
        let name=ticket.id+".body"
        var inserted=false
        do{
            if let old=try db!.rows("SELECT name FROM bodies WHERE key=?",[.text(ticket.key)]).first{try remove(ticket.key,old[0].string)}
            try FileManager.default.moveItem(at:ticket.url,to:file(name))
            try db!.execute("INSERT OR REPLACE INTO bodies VALUES(?,?,?,?)",[.text(ticket.key),.text(name),.integer(ticket.size),.real(Date().timeIntervalSince1970)])
            storedBytes+=ticket.size+16384;storedCount+=1;inserted=true
            pending.removeValue(forKey:ticket.id);verified.insert(name)
            return try mapped(name,size:ticket.size)
        }catch{
            abort(ticket)
            if inserted{try? remove(ticket.key,name)}else if leases[name]==nil{try? FileManager.default.removeItem(at:file(name))}
            throw error
        }
    }
    func value(scope:String,sha:String,size:Int)throws->Data?{
        try Task.checkCancellation();try prepare()
        let key=try key(scope,sha)
        guard let row=try db!.rows("SELECT name,size,used FROM bodies WHERE key=?",[.text(key)]).first else{return nil}
        let name=row[0].string
        guard validName(name),row[1].int==size,size>0,size<=50*1024*1024,Date().timeIntervalSince1970-max(row[2].double,touches[key] ?? 0)<7*24*3600 else{try remove(key,name);return nil}
        do{
            let v=try file(name).resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard v.isRegularFile==true,v.isSymbolicLink != true,v.fileSize==size else{throw LibraryError.malformed}
            if !verified.contains(name){
                let stream=try FileHandle(forReadingFrom:file(name));defer{try? stream.close()};var digest=SHA256()
                while let data=try stream.read(upToCount:256*1024),!data.isEmpty{try Task.checkCancellation();digest.update(data:data)}
                guard digest.finalize().map({String(format:"%02x",$0)}).joined()==sha else{throw LibraryError.malformed};verified.insert(name)
            }
            let data=try mapped(name,size:size)
            touch(key,now:Date().timeIntervalSince1970)
            return data
        }catch{if error is CancellationError{throw error};try remove(key,name);return nil}
    }
    private func mapped(_ name:String,size:Int)throws->Data {
        // Let Foundation decide whether protected storage is safe to map. The
        // backing Data and file lease both survive every ImageIO/CFData reference.
        let backing=try Data(contentsOf:file(name),options:.mappedIfSafe)
        guard backing.count==size else{throw LibraryError.malformed}
        leases[name,default:0]+=1
        return backing.withUnsafeBytes{ bytes in
            Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:bytes.baseAddress!),count:bytes.count,deallocator:.custom{[backing,self] _,_ in
                withExtendedLifetime(backing){};Task{await self.release(name)}
            })
        }
    }
    private func release(_ name:String){
        guard let count=leases[name] else{return}
        if count>1{leases[name]=count-1;return};leases.removeValue(forKey:name)
        if retired[name] != nil{
            do{try FileManager.default.removeItem(at:file(name));retired.removeValue(forKey:name)}
            catch let e as NSError where e.domain==NSCocoaErrorDomain && e.code==NSFileNoSuchFileError{retired.removeValue(forKey:name)}
            catch{} // Still charged if unlink fails, repaired on the next launch.
        }
    }
    func clear()throws{
        try prepare();epoch=UUID()
        touchTask?.cancel();touchTask=nil;touches.removeAll()
        // Active transfers notice the old epoch on commit. Their reserved bytes
        // stay charged until cancellation finishes; do not unlink under a writer.
        for row in try db!.rows("SELECT key,name FROM bodies"){try remove(row[0].string,row[1].string)}
        verified.removeAll()
    }
}
