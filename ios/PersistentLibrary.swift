import Foundation
import SQLite3

// Private, disposable metadata databases. Only the owning actor calls this API.
enum LocalSQLValue {
    case text(String), integer(Int), real(Double), blob(Data), null
    var string:String {if case .text(let v)=self{return v};return ""}
    var int:Int {if case .integer(let v)=self{return v};return 0}
    var double:Double {if case .real(let v)=self{return v};if case .integer(let v)=self{return Double(v)};return 0}
    var data:Data {if case .blob(let v)=self{return v};return Data()}
}
struct LocalSQLError:Error {let code:Int32}
final class LocalSQL {
    private var db:OpaquePointer?
    init(_ url:URL)throws {
        if let v=try? url.resourceValues(forKeys:[.isSymbolicLinkKey]),v.isSymbolicLink==true{throw LibraryError.malformed}
        let code=sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)
        guard code==SQLITE_OK else{sqlite3_close(db);db=nil;throw LocalSQLError(code:code)}
        do {
            sqlite3_busy_timeout(db,2000)
            try execute("PRAGMA journal_mode=WAL");try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON");try execute("PRAGMA max_page_count=32768")
        }catch{sqlite3_close(db);db=nil;throw error}
    }
    deinit{sqlite3_close(db)}
    func rows(_ sql:String,_ args:[LocalSQLValue]=[])throws->[[LocalSQLValue]] {
        var statement:OpaquePointer?
        let code=sqlite3_prepare_v2(db,sql,-1,&statement,nil)
        guard code==SQLITE_OK else{throw LocalSQLError(code:code)}
        defer{sqlite3_finalize(statement)}
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (offset,arg) in args.enumerated(){
            let i=Int32(offset+1);let result:Int32
            switch arg {
            case .text(let value):result=sqlite3_bind_text(statement,i,value,-1,transient)
            case .integer(let value):result=sqlite3_bind_int64(statement,i,Int64(value))
            case .real(let value):result=sqlite3_bind_double(statement,i,value)
            case .blob(let value):result=value.withUnsafeBytes{sqlite3_bind_blob(statement,i,$0.baseAddress,Int32($0.count),transient)}
            case .null:result=sqlite3_bind_null(statement,i)
            }
            guard result==SQLITE_OK else{throw LocalSQLError(code:result)}
        }
        var result:[[LocalSQLValue]]=[]
        while true {
            let status=sqlite3_step(statement)
            if status==SQLITE_DONE{return result}
            guard status==SQLITE_ROW,result.count<20001 else{throw LocalSQLError(code:status)}
            var row:[LocalSQLValue]=[]
            for i in 0..<sqlite3_column_count(statement){
                switch sqlite3_column_type(statement,i){
                case SQLITE_INTEGER:row.append(.integer(Int(sqlite3_column_int64(statement,i))))
                case SQLITE_FLOAT:row.append(.real(sqlite3_column_double(statement,i)))
                case SQLITE_TEXT:row.append(.text(String(cString:sqlite3_column_text(statement,i))))
                case SQLITE_BLOB:row.append(.blob(Data(bytes:sqlite3_column_blob(statement,i),count:Int(sqlite3_column_bytes(statement,i)))))
                default:row.append(.null)
                }
            }
            result.append(row)
        }
    }
    func execute(_ sql:String,_ args:[LocalSQLValue]=[])throws{_ = try rows(sql,args)}
    func transaction<T>(_ operation:()throws->T)throws->T {
        try execute("BEGIN IMMEDIATE")
        do{let result=try operation();try execute("COMMIT");return result}
        catch{try? execute("ROLLBACK");throw error}
    }
}

func preparePrivateDirectory(_ root:URL)throws {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
    guard try root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw LibraryError.malformed}
    var copy=root,values=URLResourceValues();values.isExcludedFromBackup=true;try copy.setResourceValues(values)
}

// An enumeration error is not an empty cache: budget accounting must fail closed.
private final class CoverDirectoryWalk {
    private var iterator:FileManager.DirectoryEnumerator?
    private var failure:Error?
    init(_ root:URL)throws {
        iterator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles,.skipsSubdirectoryDescendants],errorHandler:{[weak self] _,error in self?.failure=error;return false})
        guard iterator != nil else{throw CocoaError(.fileReadUnknown)}
    }
    func next()throws->URL? {
        let value=iterator?.nextObject() as? URL
        if let failure{throw failure};return value
    }
}

// Existing .cover files stay in place. Warm startup opens the index, not every
// cover; first upgrade/corruption rebuild yields between small directory batches.
actor CoverDiskCache {
    private let root:URL,budget:Int,ttl:TimeInterval
    private var index:LocalSQL?
    private var bytes=0,count=0
    private var complete=false,clearing=false
    private var epoch=UUID(),touches:[String:Date]=[:]
    private var touchTask:Task<Void,Never>?,repairTask:Task<Void,Never>?
    private var enumerator:CoverDirectoryWalk?
    private(set) var examinedFiles=0
    private(set) var repairPasses=0
    init(root:URL?=nil,budget:Int=CoverRules.diskBudget,ttl:TimeInterval=30*24*60*60){
        self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalShelfCovers-v1",isDirectory:true)
        self.budget=max(0,budget);self.ttl=ttl
    }
    private func valid(_ key:String)->Bool{key.utf8.count==64 && key.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    private func file(_ key:String)->URL{root.appendingPathComponent(key+".cover")}
    private func prepare()throws {
        guard index==nil else{return}
        try preparePrivateDirectory(root)
        let path=root.appendingPathComponent(".cover-index-v1.sqlite")
        do {index=try LocalSQL(path);try initialize()}
        catch let error as LocalSQLError where error.code==SQLITE_CORRUPT || error.code==SQLITE_NOTADB {
            index=nil
            // Only derived index files, never original cover files or a source DB.
            for suffix in ["","-wal","-shm"]{let url=URL(fileURLWithPath:path.path+suffix);if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}}
            index=try LocalSQL(path);try initialize()
        }catch{index=nil;throw error}
    }
    private func initialize()throws {
        guard let index else{return}
        try index.execute("CREATE TABLE IF NOT EXISTS entries(key TEXT PRIMARY KEY,cost INTEGER NOT NULL,written REAL NOT NULL,used REAL NOT NULL)")
        try index.execute("CREATE INDEX IF NOT EXISTS entries_lru ON entries(used)")
        try index.execute("CREATE TABLE IF NOT EXISTS pending(key TEXT PRIMARY KEY)")
        try index.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value REAL)")
        complete=try index.rows("SELECT value FROM meta WHERE key='complete'").first?.first?.double==1
        let totals=try index.rows("SELECT COALESCE(SUM(cost),0),COUNT(*) FROM entries")[0]
        bytes=totals[0].int;count=totals[1].int
        // A durable intent precedes file replacement; repair only these files
        // after an interrupted write, not the entire cache directory.
        for row in try index.rows("SELECT key FROM pending LIMIT 32"){
            let key=row[0].string
            if valid(key){try reconcile(key)}
            try index.execute("DELETE FROM pending WHERE key=?",[.text(key)])
        }
        if !complete {
            try index.execute("DELETE FROM entries");bytes=0;count=0
            let files=try CoverDirectoryWalk(root)
            if try files.next()==nil {
                try index.execute("INSERT OR REPLACE INTO meta VALUES('complete',1)")
                try index.execute("INSERT OR REPLACE INTO meta VALUES('audit',?)",[.real(Date().timeIntervalSince1970)])
                complete=true
            }else{startRepair()}
        }else{
            try trim(to:budget)
            let audit=try index.rows("SELECT value FROM meta WHERE key='audit'").first?.first?.double ?? 0
            if Date().timeIntervalSince1970-audit>24*3600{startRepair()}
        }
    }
    private func entry(_ key:String)throws->[LocalSQLValue]?{try index?.rows("SELECT cost,written,used FROM entries WHERE key=?",[.text(key)]).first}
    private func insert(_ key:String,cost:Int,written:Double,used:Double)throws {
        let previous=try entry(key)
        try index?.execute("INSERT OR REPLACE INTO entries VALUES(?,?,?,?)",[.text(key),.integer(cost),.real(written),.real(used)])
        bytes+=cost-(previous?[0].int ?? 0);if previous==nil{count+=1}
    }
    private func remove(_ key:String)throws {
        touches.removeValue(forKey:key)
        // Delete file first: a crash can only overestimate usage, never omit a
        // surviving file from budget accounting.
        do{try FileManager.default.removeItem(at:file(key))}catch let e as NSError where e.domain==NSCocoaErrorDomain && e.code==NSFileNoSuchFileError{}
        let previous=try entry(key)
        try index?.execute("DELETE FROM entries WHERE key=?",[.text(key)])
        if let previous{bytes-=previous[0].int;count-=1}
    }
    private func reconcile(_ key:String)throws {
        let url=file(key)
        guard FileManager.default.fileExists(atPath:url.path) else{
            let previous=try entry(key);try index?.execute("DELETE FROM entries WHERE key=?",[.text(key)])
            if let previous{bytes-=previous[0].int;count-=1};return
        }
        let value=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.totalFileAllocatedSizeKey,.creationDateKey,.contentModificationDateKey])
        examinedFiles+=1
        guard value.isRegularFile==true,value.isSymbolicLink != true,let size=value.fileSize,size>0,size<=8*1024*1024,
              let written=value.creationDate,Date().timeIntervalSince(written)<ttl else{try remove(key);return}
        try insert(key,cost:max(size,value.totalFileAllocatedSize ?? size),written:written.timeIntervalSince1970,used:(value.contentModificationDate ?? written).timeIntervalSince1970)
    }
    private func trim(to target:Int)throws {
        if bytes>max(0,target) || count>20000{flushTouches()}
        while bytes>max(0,target) || count>20000 {
            guard let rows=try index?.rows("SELECT key FROM entries ORDER BY used LIMIT 32"),!rows.isEmpty else{break}
            for row in rows {
                if bytes<=max(0,target) && count<=20000{break}
                try remove(row[0].string)
            }
        }
    }
    private func startRepair(){
        guard repairTask==nil,!clearing else{return}
        repairPasses+=1
        do{enumerator=try CoverDirectoryWalk(root)}catch{return}
        let ticket=epoch
        repairTask=Task{[weak self] in
            do {
                try await Task.sleep(nanoseconds:25_000_000)
                while let self,!Task.isCancelled {
                    if try await self.repairBatch(ticket){break}
                    try await Task.sleep(nanoseconds:2_000_000)
                }
            }catch{await self?.endRepair(ticket)}
        }
    }
    private func endRepair(_ ticket:UUID){
        if ticket==epoch {
            repairTask=nil;enumerator=nil
            if let totals=try? index?.rows("SELECT COALESCE(SUM(cost),0),COUNT(*) FROM entries").first{bytes=totals[0].int;count=totals[1].int}
        }
    }
    private func repairBatch(_ ticket:UUID)throws->Bool {
        guard ticket==epoch,!clearing,let index else{return true}
        guard let enumerator else{throw CocoaError(.fileReadUnknown)}
        var finished=false
        try index.transaction {
        for _ in 0..<64 {
            guard let url=try enumerator.next() else{
                finished=true;break
            }
            let key=url.deletingPathExtension().lastPathComponent
            if url.pathExtension=="cover",valid(key){try reconcile(key)}
        }
        }
        // Bound upgrade memory/disk growth; all files already belong to the cache.
        try trim(to:budget)
        if finished {
            try index.execute("INSERT OR REPLACE INTO meta VALUES('complete',1)")
            try index.execute("INSERT OR REPLACE INTO meta VALUES('audit',?)",[.real(Date().timeIntervalSince1970)])
            complete=true;endRepair(ticket)
        }
        return finished
    }
    func ticket()->UUID{epoch}
    func usage()throws->Int{try prepare();if !complete,repairTask==nil,!clearing{startRepair()};return bytes}
    func isIndexing()->Bool{!complete || repairTask != nil}
    func value(_ key:String)throws->Data? {
        try Task.checkCancellation();guard valid(key),!clearing else{return nil};try prepare()
        if try entry(key)==nil,!complete{try reconcile(key)}
        guard let saved=try entry(key) else{return nil}
        guard Date().timeIntervalSince1970-saved[1].double<ttl else{try remove(key);return nil}
        do {
            let url=file(key),v=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isRegularFile==true,v.isSymbolicLink != true,let size=v.fileSize,size<=8*1024*1024 else{try remove(key);return nil}
            let data=try Data(contentsOf:url);try Task.checkCancellation()
            touches[key]=Date();scheduleTouches();return data
        }catch{if !(error is CancellationError){try? remove(key)};throw error}
    }
    private func scheduleTouches(){
        guard touchTask==nil else{return}
        touchTask=Task{[weak self] in do{try await Task.sleep(nanoseconds:1_000_000_000)}catch{return};await self?.flushTouches()}
    }
    func flushTouches(){
        touchTask?.cancel();touchTask=nil
        try? index?.transaction {
            for (key,date) in touches {
                try index?.execute("UPDATE entries SET used=? WHERE key=?",[.real(date.timeIntervalSince1970),.text(key)])
                try? FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file(key).path)
            }
        }
        touches.removeAll()
    }
    func put(_ data:Data,key:String,ticket:UUID)throws {
        try Task.checkCancellation();guard ticket==epoch,valid(key),!clearing,!data.isEmpty,data.count<=min(budget,8*1024*1024) else{return}
        try prepare()
        // Until legacy usage is known, do not add bytes beyond the old budget.
        // The display has already received its image; only this optional write is skipped.
        guard complete,ticket==epoch else{return}
        try index?.execute("INSERT OR REPLACE INTO pending VALUES(?)",[.text(key)])
        do {
            try remove(key);try trim(to:budget-min(budget,data.count+16384))
            try data.write(to:file(key),options:[.atomic,.completeFileProtection])
            try reconcile(key);try trim(to:budget)
            try index?.execute("DELETE FROM pending WHERE key=?",[.text(key)])
        }catch{try? reconcile(key);throw error}
    }
    func discard(_ key:String){guard valid(key),!clearing else{return};try? prepare();try? remove(key)}
    func clear()async throws {
        epoch=UUID();repairTask?.cancel();repairTask=nil;enumerator=nil
        touchTask?.cancel();touchTask=nil;touches.removeAll();try prepare()
        // prepare may schedule an initial migration. Invalidate it as well.
        epoch=UUID();repairTask?.cancel();repairTask=nil;enumerator=nil;clearing=true;complete=false
        defer{clearing=false}
        try index?.execute("INSERT OR REPLACE INTO meta VALUES('complete',0)")
        let items=try CoverDirectoryWalk(root)
        var processed=0
        while let url=try items.next() {
            let key=url.deletingPathExtension().lastPathComponent
            if url.pathExtension=="cover",valid(key){try remove(key)}
            processed+=1;if processed%64==0{await Task.yield()}
        }
        try index?.execute("DELETE FROM entries");try index?.execute("DELETE FROM pending")
        try index?.execute("INSERT OR REPLACE INTO meta VALUES('complete',1)")
        try index?.execute("INSERT OR REPLACE INTO meta VALUES('audit',?)",[.real(Date().timeIntervalSince1970)])
        bytes=0;count=0;complete=true
    }
    #if DEBUG
    func closeForChecks(){repairTask?.cancel();repairTask=nil;enumerator=nil;flushTouches();index=nil}
    #endif
}

// Only complete, verified metadata snapshots are visible. No URLs, credentials,
// page-image bytes, or Android database files are stored here.
actor CatalogDiskStore {
    struct Ticket {let id:String,owner:String;let header:BookList}
    struct Saved {let list:BookList;let received:Date}
    private let root:URL
    private var db:LocalSQL?
    private var active:Ticket?
    private var nextOffset=0,lastRank = -1,stagedBytes=0
    static let budget=32*1024*1024
    init(root:URL?=nil){self.root=root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalShelfCatalog-v1",isDirectory:true)}
    private func prepare()throws->LocalSQL {
        if let db{return db};try preparePrivateDirectory(root)
        let path=root.appendingPathComponent("catalog.sqlite")
        do{return try initialize(path)}
        catch let error as LocalSQLError where error.code==SQLITE_CORRUPT || error.code==SQLITE_NOTADB {
            // This is our disposable directory preview, never the source catalog.
            db=nil;active=nil
            for suffix in ["","-wal","-shm"]{let url=URL(fileURLWithPath:path.path+suffix);if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}}
            return try initialize(path)
        }
    }
    private func initialize(_ path:URL)throws->LocalSQL {
        let db=try LocalSQL(path)
        try db.execute("CREATE TABLE IF NOT EXISTS snapshots(id TEXT PRIMARY KEY,owner TEXT,library TEXT,revision TEXT,total INTEGER,policy TEXT,verified INTEGER,received REAL,complete INTEGER,bytes INTEGER)")
        try db.execute("CREATE TABLE IF NOT EXISTS books(snapshot TEXT REFERENCES snapshots(id) ON DELETE CASCADE,offset INTEGER,gid TEXT,rank INTEGER,body BLOB,PRIMARY KEY(snapshot,offset),UNIQUE(snapshot,gid))")
        try db.execute("CREATE INDEX IF NOT EXISTS snapshots_owner ON snapshots(owner,complete,received)")
        try db.execute("DELETE FROM snapshots WHERE complete=0")
        self.db=db;return db
    }
    private func ownerValid(_ owner:String)->Bool{owner.utf8.count==32 && owner.range(of:"\\A[a-f0-9]{32}\\z",options:.regularExpression) != nil}
    func begin(owner:String,first:BookList)throws->Ticket {
        guard ownerValid(owner),first.orderVerified,first.libraryId != nil,first.catalogRevision != nil else{throw LibraryError.malformed}
        try CatalogPageCache.validate(first,page:0,size:500)
        let db=try prepare()
        if let active{try db.execute("DELETE FROM snapshots WHERE id=? AND complete=0",[.text(active.id)])}
        let ticket=Ticket(id:UUID().uuidString,owner:owner,header:first)
        try db.execute("INSERT INTO snapshots VALUES(?,?,?,?,?,?,?,?,0,0)",[.text(ticket.id),.text(owner),.text(first.libraryId!),.text(first.catalogRevision!),.integer(first.total),.text(first.orderPolicy ?? ""),.integer(1),.real(Date().timeIntervalSince1970)])
        active=ticket;nextOffset=0;lastRank = -1;stagedBytes=0
        try append(first,offset:0,ticket:ticket);return ticket
    }
    func append(_ list:BookList,offset:Int,ticket:Ticket)throws {
        try Task.checkCancellation()
        guard active?.id==ticket.id,offset==nextOffset,offset%500==0,CatalogLocator.sameSnapshot(ticket.header,list) else{throw LibraryError.unverifiedOrder}
        try CatalogPageCache.validate(list,page:offset/500,size:500)
        let db=try prepare(),encoder=JSONEncoder()
        var nextRank=lastRank,nextBytes=stagedBytes
        try db.transaction {
            for (index,book) in list.books.enumerated(){
                guard book.rank>nextRank,book.title.utf8.count<=16384 else{throw LibraryError.malformed}
                let body=try encoder.encode(book);nextBytes+=body.count+128
                guard nextBytes<=Self.budget else{throw LibraryError.malformed}
                try db.execute("INSERT INTO books VALUES(?,?,?,?,?)",[.text(ticket.id),.integer(offset+index),.text(book.id),.integer(book.rank),.blob(body)])
                nextRank=book.rank
            }
            try db.execute("UPDATE snapshots SET bytes=? WHERE id=?",[.integer(nextBytes),.text(ticket.id)])
        }
        nextOffset+=list.books.count;lastRank=nextRank;stagedBytes=nextBytes
    }
    func commit(_ ticket:Ticket,confirmed:BookList)throws {
        try Task.checkCancellation()
        guard active?.id==ticket.id,nextOffset==ticket.header.total,CatalogLocator.sameSnapshot(ticket.header,confirmed) else{throw LibraryError.unverifiedOrder}
        try CatalogPageCache.validate(confirmed,page:0,size:50)
        let db=try prepare()
        try db.transaction {
            try db.execute("DELETE FROM snapshots WHERE owner=? AND library=? AND id<>?",[.text(ticket.owner),.text(ticket.header.libraryId!),.text(ticket.id)])
            try db.execute("UPDATE snapshots SET complete=1,received=? WHERE id=?",[.real(Date().timeIntervalSince1970),.text(ticket.id)])
            let saved=try db.rows("SELECT id,bytes FROM snapshots WHERE complete=1 ORDER BY received DESC")
            var sum=0
            for (offset,row) in saved.enumerated(){sum+=row[1].int;if offset>=4 || sum>Self.budget{try db.execute("DELETE FROM snapshots WHERE id=?",[.text(row[0].string)])}}
        }
        active=nil
    }
    func abort(_ ticket:Ticket)throws{guard active?.id==ticket.id else{return};try prepare().execute("DELETE FROM snapshots WHERE id=? AND complete=0",[.text(ticket.id)]);active=nil}
    func page(owner:String,library:String?=nil,page:Int,size:Int,source:ShelfSource?=nil)throws->Saved? {
        guard ownerValid(owner),(0...400).contains(page),(50...500).contains(size),size%50==0 else{throw LibraryError.malformed}
        let db=try prepare()
        let sourceValue:LocalSQLValue=source.map{.integer($0 == .manual ? 1:0)} ?? .null
        let values=try db.rows("SELECT id,library,revision,total,policy,received FROM snapshots WHERE owner=? AND complete=1 AND (? IS NULL OR library=?) AND (? IS NULL OR (COALESCE(policy,'')=?)=?) ORDER BY received DESC LIMIT 1",[.text(owner),library.map(LocalSQLValue.text) ?? .null,library.map(LocalSQLValue.text) ?? .null,sourceValue,.text(ShelfSource.manualPolicy),sourceValue])
        guard let row=values.first else{return nil}
        let received=Date(timeIntervalSince1970:row[5].double)
        guard Date().timeIntervalSince(received)>=0,Date().timeIntervalSince(received)<30*24*3600 else{return nil}
        let books=try db.rows("SELECT body FROM books WHERE snapshot=? AND offset>=? AND offset<? ORDER BY offset",[.text(row[0].string),.integer(page*size),.integer((page+1)*size)]).map{try JSONDecoder().decode(Book.self,from:$0[0].data)}
        let list=BookList(orderVerified:true,total:row[3].int,books:books,orderPolicy:row[4].string.isEmpty ? nil:row[4].string,catalogRevision:row[2].string,libraryId:row[1].string)
        try CatalogPageCache.validate(list,page:page,size:size)
        return Saved(list:list,received:received)
    }
}
