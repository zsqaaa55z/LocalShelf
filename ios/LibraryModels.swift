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

enum PageJumpRules {
    static func index(_ text:String,count:Int)->Int? {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard count>0,!value.isEmpty,value.count<=7,value.allSatisfy({"0123456789".contains($0)}),let number=Int(value),(1...count).contains(number) else{return nil}
        return number-1
    }
    static func nearby(current:Int,count:Int)->[Int] {
        guard count>0 else{return []}
        let page=PagingRules.index(current,count:count)
        return Array(Set([0,page-1,page,page+1,count-1].filter{(0..<count).contains($0)})).sorted()
    }
}

enum ReadingBudget {
    static let normal=64*1024*1024
    static let largeAnimation=96*1024*1024 // current large animation only; normal reading unchanged
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

enum MediaDiskBudget {static let total=2_000_000_000,body=512_000_000;static let covers=total-body}
enum CoverRules {
    static let diskBudget=MediaDiskBudget.covers
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
        // A bounded projection avoids the old 649/650 pt/s all-or-nothing gate.
        // Minimum travel still rejects taps/jitter; a clear reversal cancels.
        guard abs(x)>=12 else{return 0}
        if x*velocityX<0,abs(velocityX)>=150{return 0}
        let projected=abs(x)+(x*velocityX>0 ? min(2000,abs(velocityX))*0.08 : 0)
        guard projected>=min(40,width*0.1) else{return 0}
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

// Touch timestamps, not display frames: bounded to 32 samples / about 100 ms.
// Keep this independent of UIKit so slow lift-off, pauses and reversals can be
// tested using the same release estimator that the actual recognizer uses.
struct ReaderSwipeMotion {
    struct Release {
        let velocityX:Double
        let reversed:Bool
        let paused:Bool
    }
    private var samples:[(x:Double,time:Double)]=[]
    private var lastMovement:Double=0
    var sampleCount:Int{samples.count}
    mutating func reset(time:Double){
        samples.removeAll(keepingCapacity:true);lastMovement=time
        record(x:0,time:time)
    }
    mutating func record(x:Double,time:Double){
        guard x.isFinite,time.isFinite else{return}
        if let last=samples.last {
            guard time>last.time else{return}
            if abs(x-last.x)>=0.25{lastMovement=time}
        }else{lastMovement=time}
        samples.append((x,time))
        while samples.count>2,samples[1].time<time-0.1{samples.removeFirst()}
        if samples.count>32{samples.removeFirst(samples.count-32)}
    }
    func release(fallbackVelocity:Double)->Release {
        let fallback=fallbackVelocity.isFinite ? max(-2000,min(2000,fallbackVelocity)) : 0
        guard let first=samples.first,let last=samples.last,samples.count>=2 else{
            return Release(velocityX:fallback,reversed:false,paused:false)
        }
        let paused=last.time-lastMovement>=0.08
        // Interpolate the window boundary instead of including an old point
        // from a long initial hold. A pause must not retain a stale fast flick.
        let start=max(first.time,last.time-0.1)
        var startX=first.x
        if samples.count>1,first.time<start {
            let next=samples[1]
            startX=first.x+(next.x-first.x)*min(1,max(0,(start-first.time)/(next.time-first.time)))
        }
        let elapsed=last.time-start
        let recent=elapsed>=0.004 ? (last.x-startX)/elapsed : fallback
        let minimum=samples.map(\.x).min() ?? last.x,maximum=samples.map(\.x).max() ?? last.x
        let reversed=(last.x<0 && last.x-minimum>=6) || (last.x>0 && maximum-last.x>=6)
        // Do not use the peak speed: it would turn an intentional stop into a
        // page advance. Tiny opposite lift-off noise doesn't cancel a flick.
        let terminalReversal=last.x*fallback<0 && abs(fallback)>=150
        return Release(velocityX:paused ? 0 : max(-2000,min(2000,recent)),reversed:reversed || (!paused && terminalReversal),paused:paused)
    }
}

// Scheduling only: never changes gesture thresholds, page selection or animation.
struct ReadingPrefetchPolicy {
    private(set) var lastIndex:Int?
    private var lastMove:TimeInterval?
    private var streak=0
    private(set) var rapidUntil:TimeInterval=0
    static let settleDelay:TimeInterval=0.45
    mutating func moved(to index:Int,now:TimeInterval){
        defer{lastIndex=index}
        guard let previous=lastIndex,previous != index else{return}
        let fast=lastMove.map{now >= $0 && now-$0<0.28} ?? false
        streak=fast ? streak+1:1
        if streak>=2 || abs(index-previous)>1{rapidUntil=now+Self.settleDelay}
        lastMove=now
    }
    func rapid(now:TimeInterval)->Bool{now<rapidUntil}
    func indices(current:Int,count:Int,direction:Int,thermal:Int,pressure:Bool,now:TimeInterval)->[Int]{
        guard (0..<max(0,count)).contains(current) else{return []}
        let all=PagingRules.prefetchIndices(current:current,count:count,direction:direction)
        if pressure || thermal>=3{return Array(all.prefix(1))}
        if thermal>=2{return Array(all.prefix(2))}
        if rapid(now:now){let step=direction<0 ? -1:1;return [current,current+step,current+step*2].filter{(0..<count).contains($0)}}
        return all
    }
    func animationIndices(current:Int,count:Int,direction:Int,thermal:Int,pressure:Bool,now:TimeInterval)->[Int]{
        guard (0..<max(0,count)).contains(current) else{return []}
        let all=PagingRules.prefetchIndices(current:current,count:count,direction:direction)
        return Array(all.prefix(pressure || thermal>=2 ? 1:(rapid(now:now) ? 2:3)))
    }
}

enum CoverRequest {
    static func path(_ path:String,pixels:Int,thumbnails:Bool)->String? {
        guard path.range(of:"^/v1/books/[0-9]{1,20}/cover$",options:.regularExpression) != nil else{return nil}
        guard thumbnails else{return path}
        let width=pixels<=320 ? 320:(pixels<=480 ? 480:640)
        return path+"?width=\(width)"
    }
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

enum ShelfSource:String,CaseIterable,Identifiable {
    case eh,manual
    var id:String{rawValue}
    var title:String{self == .eh ? "Eh 同步":"手动上传"}
    static let manualPolicy="manual-import-newest-first-v1"
    static var selected:Self{Self(rawValue:UserDefaults.standard.string(forKey:"shelf.source") ?? "") ?? .eh}
    func path(_ logical:String,target:ServerTarget)->String {
        target == .nas && self == .manual && logical.hasPrefix("/v1/") ? "/manual"+logical:logical
    }
    func accepts(_ list:BookList)->Bool{self == .manual ? list.orderPolicy==Self.manualPolicy:list.orderPolicy != Self.manualPolicy}
}

enum ServerTarget:String,CaseIterable,Identifiable {
    case android,nas
    var id:String{rawValue}
    var title:String{self == .android ? "安卓桥接":"NAS 书库"}
    static var selected:Self{Self(rawValue:UserDefaults.standard.string(forKey:"server.selected") ?? "") ?? .android}
}

struct ReaderService:Decodable {
    let app:String;let version:Int;let serverKind:String;let capabilities:[String]
    var compatible:Bool{app=="localshelf-reader" && version==1 && serverKind=="nas" && ["reader-v1","pair-v2","locate-v1"].allSatisfy{capabilities.contains($0)}}
    var passwordPairing:Bool{compatible && capabilities.contains("password-pair-v1")}
    var thumbnails:Bool{compatible && capabilities.contains("cover-thumbnail-v1")}
    var pageManifests:Bool{compatible && capabilities.contains("page-manifest-v1")}
    var conditionalManifests:Bool{pageManifests && capabilities.contains("conditional-manifest-v1")}
    var catalogWindows:Bool{compatible && capabilities.contains("catalog-window-v1")}
    func related(_ kind:RelatedKind)->Bool{compatible && capabilities.contains(kind == .authors ? "author-discovery-v1":"series-discovery-v1")}
}
// Only fixed, recognized response codes are shown. Never display a server's
// arbitrary error text or infer content changes from a generic network failure.
enum PageReadFailure:Error,Equatable {
    case network,busy,changed,missing,invalid,authorization,other
    static func header(status:Int,code:String?)->Self? {
        switch (status,code ?? "") {
        case (412,"page_content_changed"):return .changed
        case (404,"image_missing"),(404,"file_unavailable"),(404,"book_not_in_published_catalog"):return .missing
        case (409,"image_updating"),(409,"image_updating_or_too_large"):return .invalid
        case (503,"reader_busy"),(503,"verification_busy"),(503,"verification_timeout"):return .busy
        default:return nil
        }
    }
    static func classify(_ error:Error)->Self {
        if let known=error as? Self{return known}
        if let url=error as? URLError {
            return [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.timedOut,.cannotFindHost].contains(url.code) ? .network:.other
        }
        if case ServerFailure.status(let status)=error {
            switch status{case 401,403:return .authorization;case 404:return .missing;case 502,503,504:return .busy;default:return .other}
        }
        if case LibraryError.unsafeAddress=error{return .network}
        if error is LibraryError{return .invalid}
        return .other
    }
    var automaticRetry:Bool{self == .network || self == .busy}
    var title:String {
        switch self{case .changed:return "本页内容已更新";case .missing:return "本页文件缺失";case .invalid:return "本页文件尚不可安全读取";case .authorization:return "阅读授权已失效";default:return "本页暂时无法加载"}
    }
    var message:String {
        switch self {
        case .network:return "检查 Wi-Fi 和书库连接 · 点击重试本页"
        case .busy:return "服务暂忙 · 稍后点此重试本页"
        case .changed:return "正在核对页码；仍失败时可在阅读选项刷新"
        case .missing:return "请检查同步是否完成；文件补齐后点此重试"
        case .invalid:return "文件可能在更新、损坏或格式不支持；不会循环重试"
        case .authorization:return "请返回设置重新连接书库"
        case .other:return "点此重试本页 · 不会清空已加载的邻页"
        }
    }
}
struct LocatedBook:Decodable {let id:String;let offset:Int;let catalogRevision:String;let libraryId:String}
enum ServerFailure:Error,LocalizedError {
    case status(Int), incompatible, passwordRequired, passwordUnsupported, manualUnsupported
    var errorDescription:String? {
        switch self {
        case .incompatible:return "不是兼容的 NAS 阅读服务。备份上传端口 8443 不能用于阅读，请使用阅读服务地址。"
        case .manualUnsupported:return "NAS 尚未开启手动书库。请先更新并启用服务；Eh 同步书库仍可从首页顶部切回。"
        case .passwordRequired:return "此 NAS 已使用固定密码，请在密码输入框连接，不再使用六位码。"
        case .passwordUnsupported:return "此 NAS 尚未开启固定密码，请先更新阅读服务并设置密码，或使用旧版六位码入口。"
        case .status(401):return "阅读凭据已失效，请重新配对。"
        case .status(403):return "配对码错误或已失效，请重新生成六位码。"
        case .status(404):return "服务接口或文件不存在，请确认阅读服务地址。"
        case .status(409):return "清单或文件正在变化，暂不能安全读取，请稍后重试。"
        case .status(429):return "密码连续输错次数过多，请等待 15 分钟后再试；已连接设备不受影响。"
        case .status(503):return "书库尚未发布，或存储暂不可用。请等待迁移完成并检查服务状态。"
        default:return "阅读服务响应异常，请稍后重试。"
        }
    }
}

enum NASPassword {
    static func body(_ input:String)throws->Data {
        guard (8...128).contains(input.utf8.count),!input.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw LibraryError.malformed}
        return Data(input.utf8)
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

struct Book: Codable, Identifiable, Equatable {
    let id:String;let title:String;let rank:Int
    var available:Bool?=nil;var coverIdentity:String?=nil;var pageCount:Int?=nil
    var isMissing:Bool{available == false}
    // Old Android/NAS lists and saved library snapshots may omit pageCount.
    // A count is the number of indexed pages, not the largest filename or GIF frames.
    var pageCountLabel:String?{guard !isMissing,let pageCount,(1...20000).contains(pageCount) else{return nil};return String(pageCount)}
}
struct BookList: Codable { let orderVerified: Bool; let total: Int; let books: [Book]; var orderPolicy: String? = nil; var catalogRevision:String? = nil; var libraryId:String? = nil }
enum RelatedKind:String,Codable,CaseIterable {
    case authors,series
    var title:String{self == .authors ? "同作者漫画":"同系列作品"}
    var action:String{"查看"+title}
    var empty:String{self == .authors ? "暂未识别作者":"暂未找到同系列作品"}
    var explanation:String{self == .authors ? "按署名、明确别名及同本日英文对应关联；写法变体、署名线索和同社团作品为可能匹配，不代表作者身份已确认。":"优先按同一创作者的作品名、卷篇和番外关联；标题变体、作者线索和目录补充会标记为可能匹配。同作不同版本不代表续篇，不按共同原作/IP 合并。"}
}
enum RelatedMatchNote:String,Codable {
    case nameVariant,circle,creditName,workCredit,seriesTitle,seriesSubtitle,seriesVariant,authorSeries,directory,edition
    var label:String {
        switch self {
        case .nameVariant:return "写法相近"
        case .circle:return "同社团待确认"
        case .creditName:return "署名待确认"
        case .workCredit:return "同作署名线索"
        case .seriesVariant:return "标题写法相近"
        case .authorSeries:return "作者与系列线索"
        case .seriesTitle:return "同名待确认"
        case .seriesSubtitle:return "副标题关联"
        case .directory:return "目录名关联"
        case .edition:return "同作不同版本"
        }
    }
    var explanation:String{
        switch self {
        case .creditName:return "署名区域出现已知作者完整名字，格式或角色待确认"
        case .workCredit:return "同作品不同语言版本出现不同署名，作者对应待确认"
        case .authorSeries:return "作者写法或署名线索相符，主标题与卷篇线索支持关联，仍待确认"
        case .seriesVariant:return "主标题格式或少量文字相近，系列关系待确认"
        case .circle:return "同社团，作者待确认"
        default:return label
        }
    }
    func valid(for kind:RelatedKind)->Bool{let author=self == .nameVariant || self == .circle || self == .creditName || self == .workCredit;return kind == .authors ? author:!author}
}
struct RelatedChoice:Codable,Identifiable,Equatable {
    let id:String,name:String,matchKind:String,count:Int
    var aliases:[String]?=nil
    var possibleCount:Int?=nil
    var evidenceVersion:Int?=nil
    func validate(kind:RelatedKind)throws {
        guard id.range(of:"\\A[a-f0-9]{64}\\z",options:.regularExpression) != nil,
              !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=768,
              name.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}),
              (1...20000).contains(count),
              (kind == .authors ? ["artist","name"]:["series"]).contains(matchKind),
              evidenceVersion == nil || evidenceVersion == 3,
              evidenceVersion == 3 ? (possibleCount != nil && (0...count).contains(possibleCount!)) : (possibleCount == nil || (kind == .authors && (0..<count).contains(possibleCount!))),
              (aliases?.count ?? 0)<=8,aliases?.allSatisfy({!$0.isEmpty && $0.utf8.count<=768 && $0.unicodeScalars.allSatisfy{!CharacterSet.controlCharacters.contains($0)}}) != false else{throw LibraryError.malformed}
    }
}
struct RelatedOptions:Codable {
    let bookID:String,kind:RelatedKind,libraryId:String,catalogRevision:String,options:[RelatedChoice]
    func validate(book:String,kind:RelatedKind,library:String)throws {
        guard bookID==book,self.kind==kind,libraryId==library,
              catalogRevision.range(of:"\\A[a-f0-9]{64}\\z",options:.regularExpression) != nil,
              options.count<=8,Set(options.map(\.id)).count==options.count else{throw LibraryError.malformed}
        for option in options{try option.validate(kind:kind)}
    }
}
struct RelatedResult:Codable {
    let bookID:String,kind:RelatedKind,option:RelatedChoice,offset:Int,catalog:BookList
    var possibleBookIDs:[String]?=nil
    var partLabels:[String:String]?=nil
    var matchNotes:[String:RelatedMatchNote]?=nil
    func validate(book:String,kind:RelatedKind,choice:String,size:Int,requestedOffset:Int,library:String)throws {
        try option.validate(kind:kind)
        guard bookID==book,self.kind==kind,option.id==choice,catalog.libraryId==library,
              catalog.catalogRevision != nil,catalog.orderVerified,catalog.total==option.count,
              (50...500).contains(size),size%50==0,requestedOffset>=0,requestedOffset%size==0,
              offset==min(requestedOffset,(max(1,catalog.total)-1)/size*size) else{throw LibraryError.malformed}
        try CatalogPageCache.validate(catalog,page:offset/size,size:size)
        if let possibleCount=option.possibleCount {
            guard (kind == .authors || option.evidenceVersion == 3),let ids=possibleBookIDs,ids.count<=size,Set(ids).count==ids.count,
                  (option.evidenceVersion == 3 || !ids.contains(bookID)),Set(ids).isSubset(of:Set(catalog.books.map(\.id))),
                  ids.count<=possibleCount,catalog.books.count-ids.count<=catalog.total-possibleCount else{throw LibraryError.malformed}
        }else if possibleBookIDs != nil{throw LibraryError.malformed}
        if option.evidenceVersion == 3 {
            guard let notes=matchNotes,let ids=possibleBookIDs,notes.count<=size,
                  Set(notes.keys)==Set(ids),notes.values.allSatisfy({$0.valid(for:kind)}),
                  kind != .authors || !ids.contains(bookID) || notes[bookID] == .circle || notes[bookID] == .creditName else{throw LibraryError.malformed}
        }else if matchNotes != nil{throw LibraryError.malformed}
        if let parts=partLabels {
            guard kind == .series,parts.count<=size,Set(parts.keys).isSubset(of:Set(catalog.books.map(\.id))),
                  parts.values.allSatisfy({!$0.isEmpty && $0.utf8.count<=384 && $0.unicodeScalars.allSatisfy{!CharacterSet.controlCharacters.contains($0)}}) else{throw LibraryError.malformed}
        }
    }
}
struct CatalogWindow:Decodable {
    let offset:Int,anchor:String?,catalog:BookList
    func validated(size:Int,requestedAnchor:String,library:String?)throws->CatalogPageCache.ValidatedPage {
        guard (50...500).contains(size),size%50==0,offset>=0,offset%size==0,offset<max(1,catalog.total),catalog.libraryId==library,
              anchor==nil || (anchor==requestedAnchor && catalog.books.contains(where:{$0.id==anchor})) else{throw LibraryError.malformed}
        return try CatalogPageCache.validated(catalog,page:offset/size,size:size)
    }
}
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
struct Page: Codable, Identifiable {
    let number:Int;let sha256:String?;let size:Int?
    init(number:Int,sha256:String?=nil,size:Int?=nil){self.number=number;self.sha256=sha256;self.size=size}
    var id:Int{number}
}
struct Pages: Codable {
    let pages:[Page];let id:String?;let libraryId:String?;let contentRevision:String?
    init(pages:[Page],id:String?=nil,libraryId:String?=nil,contentRevision:String?=nil){self.pages=pages;self.id=id;self.libraryId=libraryId;self.contentRevision=contentRevision}
}
// Page numbers only; no image data. Scope is established by a verified library.
struct PageListCache {
    struct Validated {
        let value:Pages
        fileprivate init(_ value:Pages){self.value=value}
    }
    struct Candidate {let value:Validated,etag:String}
    private struct Entry {let validated:Validated,date:Date,etag:String?;var value:Pages{validated.value}}
    private var values=CostLRU<String,Entry>(budget:1024*1024,countLimit:16)
    private var scope:String?
    var cost:Int{values.cost}
    mutating func configure(_ scope:String?){if scope != self.scope{clear();self.scope=scope}}
    mutating func clear(){values.removeAll()}
    mutating func invalidate(_ book:String){values.remove(book)}
    static func validated(_ value:Pages)throws->Validated{try LibraryRules.validate(value);return Validated(value)}
    @discardableResult mutating func store(_ value:Validated,book:String,now:Date=Date(),etag:String?=nil)->Bool {
        invalidate(book)
        guard scope != nil,!value.value.pages.isEmpty,value.value.pages.count<=20000 else{return false}
        let cost=256+value.value.pages.count*(value.value.contentRevision == nil ? 16:240)
        guard cost<=1024*1024 else{return false}
        values.insert(Entry(validated:value,date:now,etag:etag),for:book,cost:cost);return true
    }
    mutating func value(_ book:String,now:Date=Date())->Pages? {
        guard scope != nil,let entry=values.value(for:book) else{return nil}
        let age=now.timeIntervalSince(entry.date)
        guard age>=0 else{invalidate(book);return nil}
        guard age<15 else{return nil};return entry.value
    }
    mutating func candidate(_ book:String,now:Date=Date())->Candidate? {
        guard scope != nil,let entry=values.value(for:book) else{return nil}
        let age=now.timeIntervalSince(entry.date)
        guard age>=0,age<24*3600 else{invalidate(book);return nil}
        guard let etag=entry.etag,ManifestValidator.valid(etag),entry.value.contentRevision != nil else{return nil}
        // A stale representation is ONLY usable after a fresh authenticated 304.
        return Candidate(value:entry.validated,etag:etag)
    }
}
enum ManifestValidator {
    static func valid(_ etag:String)->Bool{etag.range(of:"\\A\"[a-f0-9]{64}\"\\z",options:.regularExpression) != nil}
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
    func window(_ data:Data,size:Int,anchor:String,library:String?)throws->(CatalogWindow,CatalogPageCache.ValidatedPage) {
        try begin(data)
        let window=try JSONDecoder().decode(CatalogWindow.self,from:data)
        let validated=try window.validated(size:size,requestedAnchor:anchor,library:library)
        try Task.checkCancellation();return (window,validated)
    }
    func relatedOptions(_ data:Data,book:String,kind:RelatedKind,library:String)throws->RelatedOptions {
        try begin(data);let value=try JSONDecoder().decode(RelatedOptions.self,from:data)
        try value.validate(book:book,kind:kind,library:library);try Task.checkCancellation();return value
    }
    func relatedResult(_ data:Data,book:String,kind:RelatedKind,choice:String,size:Int,offset:Int,library:String)throws->RelatedResult {
        try begin(data);let value=try JSONDecoder().decode(RelatedResult.self,from:data)
        try value.validate(book:book,kind:kind,choice:choice,size:size,requestedOffset:offset,library:library)
        try Task.checkCancellation();return value
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
    func preparedManifest(_ data:Data,etag:String?)throws->PageListCache.Validated {
        try Task.checkCancellation()
        guard data.count<=8*1024*1024 else{throw LibraryError.malformed}
        if let etag {
            guard ManifestValidator.valid(etag),etag=="\""+SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()+"\"" else{throw LibraryError.malformed}
        }
        return try preparedPages(data)
    }
}
enum LibraryError: Error { case unverifiedOrder, malformed, unsafeAddress }
enum LibraryRules {
    static func validate(_ list: BookList) throws {
        if let library=list.libraryId,library.utf8.count != 64 || library.range(of:"^[a-f0-9]{64}$",options:.regularExpression)==nil{throw LibraryError.malformed}
        for book in list.books {if let identity=book.coverIdentity,identity.utf8.count != 64 || identity.range(of:"^[a-f0-9]{64}$",options:.regularExpression)==nil{throw LibraryError.malformed}}
        for book in list.books {if let count=book.pageCount,!(0...20000).contains(count){throw LibraryError.malformed}}
        if let revision=list.catalogRevision,revision.range(of:"^[a-f0-9]{64}$",options:.regularExpression)==nil{throw LibraryError.malformed}
        guard list.orderVerified || list.orderPolicy == "snapshot-query" else { throw LibraryError.unverifiedOrder }
        guard list.total >= list.books.count, Set(list.books.map(\.id)).count == list.books.count,
              Set(list.books.map(\.rank)).count == list.books.count,
              list.books.allSatisfy({ !$0.title.isEmpty && $0.rank >= 0 && $0.id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil }),
              zip(list.books,list.books.dropFirst()).allSatisfy({ $0.rank < $1.rank }) else { throw LibraryError.malformed }
    }
    static func validate(_ pages: Pages) throws {
        guard pages.pages.allSatisfy({$0.number > 0}), zip(pages.pages,pages.pages.dropFirst()).allSatisfy({$0.number < $1.number}) else { throw LibraryError.malformed }
        let manifest=pages.contentRevision != nil || pages.libraryId != nil || pages.id != nil || pages.pages.contains{$0.sha256 != nil || $0.size != nil}
        if manifest {
            func hash(_ value:String?)->Bool{value?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
            guard pages.pages.count<=20000,hash(pages.contentRevision),hash(pages.libraryId),pages.id?.range(of:"^[1-9][0-9]{0,18}$",options:.regularExpression) != nil,
                  pages.pages.allSatisfy({hash($0.sha256) && ($0.size ?? -1)>=0}) else{throw LibraryError.malformed}
        }
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
