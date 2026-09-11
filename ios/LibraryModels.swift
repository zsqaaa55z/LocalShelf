import Foundation
import CryptoKit

struct TransferBuffer {
    let limit:Int
    private(set) var data=Data()
    mutating func append(_ chunk:Data)throws {
        guard limit>=0,data.count<=limit,chunk.count<=limit-data.count else{throw LibraryError.malformed}
        data.append(chunk)
    }
    func acceptsLength(_ length:Int64)->Bool {length<0 || length<=Int64(limit)}
}

enum ReadingBudget {
    static let normal=64*1024*1024
    static let pressure=24*1024*1024
    static let compressed=8*1024*1024
    static func keep(costs:[Int:Int],priority:[Int],available:Int)->Set<Int> {
        var left=max(0,available),kept=Set<Int>()
        for number in priority {if let cost=costs[number],cost>=0,cost<=left,!kept.contains(number){kept.insert(number);left-=cost}}
        return kept
    }
}

struct CostLRU<Key:Hashable,Value> {
    private var entries:[Key:(Value,Int)]=[:]
    private var order:[Key]=[]
    private(set) var cost=0
    let budget:Int
    let countLimit:Int
    init(budget:Int,countLimit:Int){self.budget=max(0,budget);self.countLimit=max(0,countLimit)}
    mutating func value(for key:Key)->Value? {
        guard let entry=entries[key] else{return nil}
        order.removeAll{$0==key};order.append(key);return entry.0
    }
    mutating func insert(_ value:Value,for key:Key,cost newCost:Int){
        if let old=entries.removeValue(forKey:key){cost-=old.1};order.removeAll{$0==key}
        guard newCost>=0,newCost<=budget,countLimit>0 else{return}
        while cost>budget-newCost || order.count>=countLimit {
            let oldest=order.removeFirst();if let old=entries.removeValue(forKey:oldest){cost-=old.1}
        }
        entries[key]=(value,newCost);order.append(key);cost+=newCost
    }
    mutating func removeAll(){entries.removeAll();order.removeAll();cost=0}
    mutating func remove(_ key:Key){if let old=entries.removeValue(forKey:key){cost-=old.1};order.removeAll{$0==key}}
}

enum CoverRules {
    static let diskBudget=2_000_000_000
    static func key(scope:String,path:String)->String? {
        guard path.range(of:"^/v1/books/[0-9]{1,20}/cover$",options:.regularExpression) != nil else{return nil}
        return SHA256.hash(data:Data(("cover-v1\n"+scope+"\n"+path).utf8)).map{String(format:"%02x",$0)}.joined()
    }
    static func prefetch(anchor:Int,count:Int,screen:Int,direction:Int)->[Int]{
        guard count>0,anchor>=0,anchor<count else{return []}
        let size=min(18,max(1,screen))
        if direction<0{return (1...size).map{anchor-$0}.filter{$0>=0}}
        let start=anchor+size;guard start<count else{return []}
        return Array(start..<min(count,anchor+size*2))
    }
}

enum PagingRules {
    static let returnEdgeWidth=48.0
    static func edgeStart(x:Double,width:Double)->Bool{x.isFinite && width.isFinite && width>0 && x>=0 && x<=min(returnEdgeWidth,width/2)}
    // Only pans beginning inside the left hot zone can request a return.
    static func edgeReturns(x:Double,y:Double,velocityX:Double,width:Double)->Bool {
        guard width.isFinite,width>0,x.isFinite,y.isFinite,velocityX.isFinite,x>=18,x>abs(y)*1.2,velocityX > -150 else{return false}
        return x>=44 || x+max(0,min(2000,velocityX))*0.08>=64
    }
    static func sliderIndex(position:Double,length:Double,count:Int)->Int {
        guard position.isFinite,length.isFinite,length>0,count>1 else{return 0}
        return index(Int((min(1,max(0,position/length))*Double(count-1)).rounded()),count:count)
    }
    // Taps only toggle controls. Buttons, swipes and the slider handle navigation.
    static func tapStep(fraction:Double)->Int {0}
    static func detailPixelLimit(width:Double,height:Double)->Int {
        guard width>0,height>0,width.isFinite,height.isFinite else{return 2048}
        return max(1,Int(min(4096,max(width,height)*min(1,sqrt(12_000_000/(width*height))))))
    }
    static func swipeStep(x:Double,y:Double,width:Double,velocityX:Double=0)->Int {
        guard width>0,width.isFinite,x.isFinite,y.isFinite,velocityX.isFinite,abs(x)>abs(y)*1.5 else{return 0}
        // A deliberate short flick counts; a last-moment reversal returns to the
        // current page instead of jumping across it into the opposite neighbor.
        if abs(velocityX)>=650,abs(x)>=12 {
            if x*velocityX<0{return 0}
            return velocityX<0 ? 1 : -1
        }
        guard abs(x)>=min(40,width*0.1) else{return 0}
        return x<0 ? 1 : -1
    }
    static func prefetchIndices(current:Int,count:Int,direction:Int=1)->[Int] {
        guard (0..<max(0,count)).contains(current) else {return []}
        let step=direction<0 ? -1 : 1
        return [0,step,-step,2*step,-2*step].map{current+$0}.filter{(0..<count).contains($0)}
    }
    static func count(total:Int,size:Int)->Int {max(1,(max(0,total)+max(1,size)-1)/max(1,size))}
    static func index(_ target:Int,count:Int)->Int {min(max(0,target),max(0,count-1))}
}

enum ReadingProgress {
    static func hash(_ scope:String)->String{SHA256.hash(data:Data(scope.utf8)).map{String(format:"%02x",$0)}.joined()}
    static func key(scope:String,id:String)->String{"reading.page."+hash(scope)+"."+id}
    static func register(scope:String,server:ServerTarget,in defaults:UserDefaults = .standard){
        defaults.set(scope,forKey:"reading.scope."+hash(scope))
        defaults.set(scope,forKey:"reading.serverScope."+server.rawValue)
        // Only the first verified Android library may adopt pre-profile records.
        // A NAS or a second Android library never silently claims those records.
        if server == .android,defaults.string(forKey:"reading.legacyOwner")==nil {
            for (name,value) in defaults.dictionaryRepresentation() where name.range(of:"^page\\.[0-9]{1,20}$",options:.regularExpression) != nil {
                let id=String(name.dropFirst(5))
                if let page=value as? Int,page>0,Self.page(scope:scope,id:id,in:defaults)==0{save(page,scope:scope,id:id,in:defaults)}
            }
            defaults.set(scope,forKey:"reading.legacyOwner")
        }
    }
    static func page(scope:String?,id:String,in defaults:UserDefaults = .standard)->Int{
        guard let scope else{return 0};return defaults.integer(forKey:key(scope:scope,id:id))
    }
    static func save(_ page:Int,scope:String?,id:String,in defaults:UserDefaults = .standard){
        guard let scope,page>0,page<=99_999_999,id.range(of:"^[0-9]{1,20}$",options:.regularExpression) != nil else{return}
        defaults.set(scope,forKey:"reading.scope."+hash(scope));defaults.set(page,forKey:key(scope:scope,id:id))
    }
    static func positions(scope:String,in defaults:UserDefaults = .standard)->[String:Int]{
        let prefix="reading.page."+hash(scope)+"."
        return defaults.dictionaryRepresentation().reduce(into:[:]){result,item in
            if item.key.hasPrefix(prefix),let page=item.value as? Int,page>0{result[String(item.key.dropFirst(prefix.count))]=page}
        }
    }
    // Only keys owned by the reader; never clear the defaults domain or pairing.
    static func reset(in defaults:UserDefaults = .standard)->Int {
        let keys=defaults.dictionaryRepresentation().keys.filter{
            $0.range(of:"^(page\\.[0-9]{1,20}|reading\\.page\\.[a-f0-9]{64}\\.[0-9]{1,20})$",options:.regularExpression) != nil
        }
        for key in keys{defaults.removeObject(forKey:key)}
        RecentReading.clear(in:defaults)
        return keys.count
    }
}

// One bounded local resume record, never a second catalog or a source of order.
struct RecentReading:Codable,Equatable {
    static let key="reading.recent.v1"
    let scope:String
    var book:Book
    let pageNumber:Int
    let position:Int
    let pageCount:Int
    var valid:Bool {
        !scope.isEmpty && scope.utf8.count<=256 && book.id.range(of:"^[0-9]{1,20}$",options:.regularExpression) != nil &&
        !book.title.isEmpty && book.title.utf8.count<=16384 && book.rank>=0 && pageNumber>0 &&
        pageCount>0 && position>=0 && position<pageCount
    }
    static func load(scope:String,in defaults:UserDefaults = .standard)->Self? {
        guard let data=defaults.data(forKey:key+"."+ReadingProgress.hash(scope)) ?? defaults.data(forKey:key),data.count<=32768,
              let value=try? JSONDecoder().decode(Self.self,from:data),value.valid,value.scope==scope else{return nil}
        return value
    }
    func save(in defaults:UserDefaults = .standard){
        guard valid,let data=try? JSONEncoder().encode(self),data.count<=32768 else{return}
        defaults.set(data,forKey:Self.key)
        defaults.set(data,forKey:Self.key+"."+ReadingProgress.hash(scope))
        defaults.set(scope,forKey:"reading.scope."+ReadingProgress.hash(scope))
    }
    static func clear(in defaults:UserDefaults = .standard){for name in defaults.dictionaryRepresentation().keys where name==key || name.hasPrefix(key+"."){defaults.removeObject(forKey:name)}}
}

enum ServerTarget:String,CaseIterable,Identifiable {
    case android,nas
    var id:String{rawValue}
    var title:String{self == .android ? "安卓桥接":"NAS 书库"}
    var other:Self{self == .android ? .nas:.android}
    static var selected:Self{Self(rawValue:UserDefaults.standard.string(forKey:"server.selected") ?? "") ?? .android}
}

// Whitelisted reading metadata only. No credentials, server addresses or images.
struct ProgressBackup:Codable {
    struct Library:Codable {let scope:String;let positions:[String:Int];let recent:RecentReading?}
    let version:Int
    let libraries:[Library]
    let legacy:[String:Int]
    static func capture(in defaults:UserDefaults = .standard)->Self {
        var scopes=Set(defaults.dictionaryRepresentation().filter{$0.key.hasPrefix("reading.scope.")}.compactMap{$0.value as? String})
        if let old=defaults.data(forKey:RecentReading.key),old.count<=32768,let recent=try? JSONDecoder().decode(RecentReading.self,from:old),recent.valid{scopes.insert(recent.scope)}
        let libraries=scopes.sorted().map{Library(scope:$0,positions:ReadingProgress.positions(scope:$0,in:defaults),recent:RecentReading.load(scope:$0,in:defaults))}
        let legacy=defaults.dictionaryRepresentation().reduce(into:[String:Int]()){result,item in
            if item.key.range(of:"^page\\.[0-9]{1,20}$",options:.regularExpression) != nil,let page=item.value as? Int{result[String(item.key.dropFirst(5))]=page}
        }
        return Self(version:1,libraries:libraries,legacy:legacy)
    }
    func data()throws->Data{let data=try JSONEncoder().encode(self);_ = try Self.decode(data);return data}
    static func decode(_ data:Data)throws->Self {
        guard data.count<=8*1024*1024 else{throw LibraryError.malformed}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.version==1,value.libraries.count<=32,Set(value.libraries.map(\.scope)).count==value.libraries.count,
              value.libraries.reduce(value.legacy.count,{$0+$1.positions.count})<=40000 else{throw LibraryError.malformed}
        func valid(_ records:[String:Int])->Bool{records.allSatisfy{$0.key.range(of:"^[0-9]{1,20}$",options:.regularExpression) != nil && (1...99_999_999).contains($0.value)}}
        guard valid(value.legacy),value.libraries.allSatisfy({!$0.scope.isEmpty && $0.scope.utf8.count<=256 && valid($0.positions) && ($0.recent==nil || ($0.recent!.valid && $0.recent!.scope==$0.scope))}) else{throw LibraryError.malformed}
        return value
    }
    // Import is additive: existing positions always win; explicit server migration
    // is a separate operation after IDs have been checked against the destination.
    @discardableResult func restore(in defaults:UserDefaults = .standard)->Int {
        var count=0
        for library in libraries {
            defaults.set(library.scope,forKey:"reading.scope."+ReadingProgress.hash(library.scope))
            for (id,page) in library.positions where ReadingProgress.page(scope:library.scope,id:id,in:defaults)==0{ReadingProgress.save(page,scope:library.scope,id:id,in:defaults);count+=1}
            if let recent=library.recent,RecentReading.load(scope:library.scope,in:defaults)==nil{recent.save(in:defaults)}
        }
        for (id,page) in legacy where defaults.object(forKey:"page."+id)==nil{defaults.set(page,forKey:"page."+id);count+=1}
        return count
    }
}

struct ReaderService:Decodable {
    let app:String;let version:Int;let serverKind:String;let capabilities:[String]
    var compatible:Bool{app=="localshelf-reader" && version==1 && serverKind=="nas" && ["reader-v1","pair-v2","locate-v1"].allSatisfy{capabilities.contains($0)}}
}
struct LocatedBook:Decodable {let id:String;let offset:Int;let catalogRevision:String;let libraryId:String}
enum ServerFailure:Error,LocalizedError {
    case status(Int), incompatible
    var errorDescription:String? {
        switch self {
        case .incompatible:return "不是兼容的 NAS 阅读服务。备份上传端口 8443 不能用于阅读，请使用阅读服务地址。"
        case .status(401):return "阅读凭据已失效，请重新配对。"
        case .status(403):return "配对码错误或已失效，请重新生成六位码。"
        case .status(404):return "服务接口或文件不存在，请确认阅读服务地址。"
        case .status(409):return "清单或文件正在变化，暂不能安全读取，请稍后重试。"
        case .status(503):return "书库尚未发布，或存储暂不可用。请等待迁移完成并检查服务状态。"
        default:return "阅读服务响应异常，请稍后重试。"
        }
    }
}

enum PairingPIN {
    static func body(_ input:String)throws->Data{
        guard input.utf8.count==6,input.utf8.allSatisfy({$0>=48 && $0<=57}) else{throw LibraryError.malformed}
        return Data(input.utf8)
    }
    static func response(_ data:Data,address:String)throws->PairingCode{
        struct Reply:Decodable{let app:String;let version:Int;let deviceId:String;let token:String}
        guard data.count<=2048 else{throw LibraryError.malformed}
        let reply=try JSONDecoder().decode(Reply.self,from:data)
        guard reply.version==2 else{throw LibraryError.malformed}
        let code=PairingCode(app:reply.app,version:reply.version,address:address,token:reply.token,deviceId:reply.deviceId)
        return try PairingCode.parse(String(decoding:JSONEncoder().encode(code),as:UTF8.self))
    }
}

enum CatalogLocator {
    struct Match {let book:Book;let offset:Int;let snapshot:BookList}
    static func sameSnapshot(_ a:BookList,_ b:BookList)->Bool {
        a.libraryId==b.libraryId && a.catalogRevision==b.catalogRevision && a.total==b.total && a.orderPolicy==b.orderPolicy && a.orderVerified==b.orderVerified
    }
    // Rank is only a hint: exported ranks may have gaps or move after import.
    // Scan metadata only, one bounded batch at a time, never covers or pages.
    @MainActor static func find(id:String,rankHint:Int,fetch:(Int,Int)async throws->BookList)async throws->Match? {
        try Task.checkCancellation()
        let hint=min(39,max(0,rankHint/500))
        let first=try await fetch(hint,500)
        try CatalogPageCache.validate(first,page:hint,size:500)
        if let i=first.books.firstIndex(where:{$0.id==id}){return Match(book:first.books[i],offset:hint*500+i,snapshot:first)}
        for page in 0..<PagingRules.count(total:first.total,size:500) where page != hint {
            try Task.checkCancellation()
            let list=try await fetch(page,500)
            try CatalogPageCache.validate(list,page:page,size:500)
            guard sameSnapshot(first,list) else{throw LibraryError.unverifiedOrder}
            if let i=list.books.firstIndex(where:{$0.id==id}){return Match(book:list.books[i],offset:page*500+i,snapshot:first)}
        }
        return nil
    }
}

struct PairingCode: Codable {
    let app: String
    let version: Int
    let address: String
    let token: String
    var deviceId: String? = nil
    static func parse(_ text: String) throws -> PairingCode {
        guard text.utf8.count <= 2048 else { throw LibraryError.malformed }
        let code = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard code.app == "localshelf", [1,2].contains(code.version),
              code.token.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil else { throw LibraryError.malformed }
        if code.version==2 {guard let id=code.deviceId,id.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil else{throw LibraryError.malformed}}
        _ = try LibraryRules.address(code.address)
        return code
    }
}

struct IdentityProof:Decodable {let deviceId:String;let proof:String}
enum PairingProof {
    static func verify(_ response:IdentityProof,code:PairingCode,nonce:String)->Bool {
        guard code.version==2,let id=code.deviceId,response.deviceId==id,
              nonce.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              response.proof.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{return false}
        let bytes=stride(from:0,to:64,by:2).map{i->UInt8 in
            let start=response.proof.index(response.proof.startIndex,offsetBy:i)
            return UInt8(response.proof[start..<response.proof.index(start,offsetBy:2)],radix:16)!
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes,authenticating:Data("localshelf-server-v2\n\(id)\n\(nonce)".utf8),using:SymmetricKey(data:Data(code.token.utf8)))
    }
}

struct Book: Codable, Identifiable, Equatable { let id: String; let title: String; let rank: Int; var available: Bool? = nil; var coverIdentity:String? = nil; var isMissing: Bool { available == false } }
struct BookList: Codable { let orderVerified: Bool; let total: Int; let books: [Book]; var orderPolicy: String? = nil; var catalogRevision:String? = nil; var libraryId:String? = nil }
// Disposable, session-only metadata. TTL is measured from network receipt, not hits.
struct CatalogPageCache {
    // Only the validating factory can construct this value. Production callers
    // validate and calculate string costs off the main actor, once per response.
    struct ValidatedPage {
        let list:BookList
        fileprivate let page:Int,size:Int,cost:Int
        fileprivate init(list:BookList,page:Int,size:Int,cost:Int){self.list=list;self.page=page;self.size=size;self.cost=cost}
    }
    private struct Entry {let list:BookList;let received:Date}
    private var pages=CostLRU<String,Entry>(budget:4*1024*1024,countLimit:24)
    private var scope:String?
    var cost:Int{pages.cost}
    mutating func clear(){pages.removeAll();scope=nil}
    static func validate(_ list:BookList,page:Int,size:Int)throws {
        try LibraryRules.validate(list)
        guard (50...500).contains(size),size%50==0,(0...400).contains(page),list.total<=20000,
              list.books.count==min(size,max(0,list.total-page*size)) else{throw LibraryError.malformed}
    }
    @discardableResult mutating func store(_ list:BookList,page:Int,size:Int,owner:String?,now:Date=Date())throws->Bool {
        store(try Self.validated(list,page:page,size:size),owner:owner,now:now)
    }
    static func validated(_ list:BookList,page:Int,size:Int)throws->ValidatedPage {
        try validate(list,page:page,size:size)
        let cost=1024+list.books.reduce(0){$0+256+2*($1.title.utf8.count+$1.id.utf8.count+($1.coverIdentity?.utf8.count ?? 0))}
        return ValidatedPage(list:list,page:page,size:size,cost:cost)
    }
    @discardableResult mutating func store(_ validated:ValidatedPage,owner:String?,now:Date=Date())->Bool {
        let list=validated.list
        guard let owner,let revision=list.catalogRevision,revision.utf8.count==64 else{clear();return false}
        let next=owner+"\n"+(list.libraryId ?? "legacy")+"\n"+revision+"\n\(list.total)\n\(list.orderVerified)\n"+(list.orderPolicy ?? "")
        if next != scope{pages.removeAll();scope=next}
        pages.insert(Entry(list:list,received:now),for:"\(validated.page)/\(validated.size)",cost:validated.cost);return true
    }
    mutating func value(page:Int,size:Int,now:Date=Date())->BookList? {
        guard scope != nil,let entry=pages.value(for:"\(page)/\(size)") else{return nil}
        let age=now.timeIntervalSince(entry.received);return age>=0 && age<60 ? entry.list:nil
    }
}
struct Page: Codable, Identifiable { let number: Int; var id: Int { number } }
struct Pages: Codable { let pages: [Page] }
// Page numbers only; no image data. Scope is established by a verified library.
struct PageListCache {
    struct Validated {
        let value:Pages
        fileprivate init(_ value:Pages){self.value=value}
    }
    private struct Entry {let value:Pages,date:Date}
    private var values=CostLRU<String,Entry>(budget:1024*1024,countLimit:16)
    private var scope:String?
    var cost:Int{values.cost}
    mutating func configure(_ scope:String?){if scope != self.scope{clear();self.scope=scope}}
    mutating func clear(){values.removeAll()}
    mutating func invalidate(_ book:String){values.remove(book)}
    static func validated(_ value:Pages)throws->Validated{try LibraryRules.validate(value);return Validated(value)}
    @discardableResult mutating func store(_ value:Validated,book:String,now:Date=Date())->Bool {
        invalidate(book)
        guard scope != nil,!value.value.pages.isEmpty,value.value.pages.count<=20000 else{return false}
        values.insert(Entry(value:value.value,date:now),for:book,cost:256+value.value.pages.count*16);return true
    }
    mutating func value(_ book:String,now:Date=Date())->Pages? {
        guard scope != nil,let entry=values.value(for:book) else{return nil}
        let age=now.timeIntervalSince(entry.date)
        guard age>=0,age<15 else{invalidate(book);return nil};return entry.value
    }
}
// Serial CPU parsing, distinct from MainActor and image decoding. No detached
// per-request tasks: queued work inherits cancellation and checks it before use.
actor MetadataParser {
    static let shared=MetadataParser()
    #if DEBUG && targetEnvironment(simulator)
    private var beforeParse:(@Sendable ()->Void)?
    func setHook(_ hook:(@Sendable ()->Void)?){beforeParse=hook}
    #endif
    private func begin(_ data:Data)throws {
        try Task.checkCancellation()
        guard data.count<=8*1024*1024 else{throw LibraryError.malformed}
        #if DEBUG && targetEnvironment(simulator)
        precondition(!Thread.isMainThread,"Metadata parsing must not run on main thread")
        beforeParse?()
        #endif
        try Task.checkCancellation()
    }
    func catalog(_ data:Data,page:Int,size:Int)throws->CatalogPageCache.ValidatedPage {
        try begin(data)
        let value=try JSONDecoder().decode(BookList.self,from:data)
        try Task.checkCancellation()
        let validated=try CatalogPageCache.validated(value,page:page,size:size)
        try Task.checkCancellation();return validated
    }
    func pages(_ data:Data)throws->Pages {
        try preparedPages(data).value
    }
    func preparedPages(_ data:Data)throws->PageListCache.Validated {
        try begin(data)
        let value=try JSONDecoder().decode(Pages.self,from:data)
        try Task.checkCancellation();let validated=try PageListCache.validated(value)
        try Task.checkCancellation();return validated
    }
}
enum LibraryError: Error { case unverifiedOrder, malformed, unsafeAddress }
enum LibraryRules {
    static func validate(_ list: BookList) throws {
        if let library=list.libraryId,library.utf8.count != 64 || library.range(of:"^[a-f0-9]{64}$",options:.regularExpression)==nil{throw LibraryError.malformed}
        for book in list.books {if let identity=book.coverIdentity,identity.utf8.count != 64 || identity.range(of:"^[a-f0-9]{64}$",options:.regularExpression)==nil{throw LibraryError.malformed}}
        if let revision=list.catalogRevision,revision.range(of:"^[a-f0-9]{64}$",options:.regularExpression)==nil{throw LibraryError.malformed}
        guard list.orderVerified || list.orderPolicy == "snapshot-query" else { throw LibraryError.unverifiedOrder }
        guard list.total >= list.books.count, Set(list.books.map(\.id)).count == list.books.count,
              Set(list.books.map(\.rank)).count == list.books.count,
              list.books.allSatisfy({ !$0.title.isEmpty && $0.rank >= 0 && $0.id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil }),
              zip(list.books,list.books.dropFirst()).allSatisfy({ $0.rank < $1.rank }) else { throw LibraryError.malformed }
    }
    static func validate(_ pages: Pages) throws {
        guard pages.pages.allSatisfy({$0.number > 0}), zip(pages.pages,pages.pages.dropFirst()).allSatisfy({$0.number < $1.number}) else { throw LibraryError.malformed }
    }
    static func address(_ text: String) throws -> URL {
        guard let url=URL(string:text), url.scheme=="http",url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,
              url.path.isEmpty || url.path=="/", let host=url.host else {throw LibraryError.unsafeAddress}
        let parts=host.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==4,parts.allSatisfy({!$0.isEmpty && $0.allSatisfy({$0.isASCII && $0.isNumber})}) else {throw LibraryError.unsafeAddress}
        let p=parts.compactMap{Int($0)}
        guard p.count==4,p.allSatisfy({(0...255).contains($0)}),p[0]==10 || (p[0]==192 && p[1]==168) || (p[0]==172 && (16...31).contains(p[1])) else {throw LibraryError.unsafeAddress}
        return url
    }
}
