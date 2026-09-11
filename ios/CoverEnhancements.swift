import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// Nuke-inspired token bucket: burst on first display, throttle request churn only.
struct CoverRequestBucket {
    private(set) var tokens:Double=6
    private var last:TimeInterval?
    mutating func take(now:TimeInterval)->Bool {
        tokens=min(6,tokens+max(0,now-(last ?? now))*8);last=now
        guard tokens>=1 else{return false};tokens-=1;return true
    }
}
actor CoverRequestGate {
    private var bucket=CoverRequestBucket()
    func acquire()async throws {
        while true {
            try Task.checkCancellation()
            if bucket.take(now:ProcessInfo.processInfo.systemUptime){return}
            try await Task.sleep(nanoseconds:50_000_000)
        }
    }
}

struct CoverRecord:Codable {
    var schema=2
    var bytes:Data
    var thumbnail:Bool
    var etag:String?
    var checked:Date
    var revision:String
    func fresh(revision:String,now:Date=Date())->Bool {self.revision==revision && now.timeIntervalSince(checked)>=0 && now.timeIntervalSince(checked)<24*3600}
    func packed()throws->Data {let encoder=PropertyListEncoder();encoder.outputFormat = .binary;return try encoder.encode(self)}
    static func unpack(_ data:Data)throws->CoverRecord {
        let value=try PropertyListDecoder().decode(Self.self,from:data)
        guard value.schema==2,!value.bytes.isEmpty,value.bytes.count<=8*1024*1024,
              value.etag==nil || validETag(value.etag!) else{throw LibraryError.malformed}
        return value
    }
    static func validETag(_ value:String)->Bool {value.utf8.count==68 && value.range(of:"^W/\"[a-f0-9]{64}\"$",options:.regularExpression) != nil}
}

// Kingfisher-inspired processed-image cache. Original files are never changed.
actor SmartCoverDecoder {
    private(set) var decodes=0
    func unpack(_ data:Data)throws->CoverRecord {
        try Task.checkCancellation()
        guard data.count<=8*1024*1024 else{throw LibraryError.malformed}
        #if DEBUG && targetEnvironment(simulator)
        precondition(!Thread.isMainThread,"Cover unpacking must not run on main thread")
        #endif
        let record=try autoreleasepool {try CoverRecord.unpack(data)}
        try Task.checkCancellation();return record
    }
    func pack(_ record:CoverRecord)throws->Data{try Task.checkCancellation();return try record.packed()}
    func display(_ record:CoverRecord,pixels:Int)throws->UIImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source=CGImageSourceCreateWithData(record.bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
            decodes+=1;try Task.checkCancellation();return UIImage(cgImage:cg)
        }
    }
    func decode(_ record:CoverRecord,pixels:Int)throws->(UIImage,CoverRecord) {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source=CGImageSourceCreateWithData(record.bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
            decodes+=1
            var result=record
            if !record.thumbnail {
                let data=NSMutableData()
                guard let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else{throw LibraryError.malformed}
                CGImageDestinationAddImage(destination,cg,nil)
                guard CGImageDestinationFinalize(destination) else{throw LibraryError.malformed}
                result.bytes=data as Data;result.thumbnail=true
            }
            try Task.checkCancellation();return (UIImage(cgImage:cg),result)
        }
    }
}

// A distinct executor from display decoding. Never blocks delivery on PNG or plist.
actor CoverEncoder {
    func encode(_ record:CoverRecord,image:UIImage?)throws->Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            var record=record
            if let image,!record.thumbnail {
                let data=NSMutableData()
                guard let cg=image.cgImage,let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else{throw LibraryError.malformed}
                CGImageDestinationAddImage(destination,cg,nil)
                guard CGImageDestinationFinalize(destination) else{throw LibraryError.malformed}
                record.bytes=data as Data;record.thumbnail=true
            }
            try Task.checkCancellation();let packed=try record.packed();try Task.checkCancellation();return packed
        }
    }
}

@MainActor final class SmartCoverPipeline {
    typealias Completion=(Result<UIImage,Error>)->Void
    private struct Memory {let image:UIImage;let checked:Date;let revision:String}
    private final class Job {
        var listeners:[UUID:Completion]=[:]
        let load:()async throws->Data
        var task:Task<Void,Never>?
        var ticket=UUID()
        #if DEBUG && targetEnvironment(simulator)
        var benchmarkParked=false
        #endif
        init(load:@escaping()async throws->Data){self.load=load}
    }
    private var memory=CostLRU<String,Memory>(budget:32*1024*1024,countLimit:96)
    private var jobs:[String:Job]=[:],order:[String]=[]
    private var running=Set<UUID>()
    private var prefetched=Set<String>(),near=Set<String>()
    private var scope:String?,revision="",identities:[String:String]=[:]
    private var suspended=false
    private let decoder=SmartCoverDecoder(),gate=CoverRequestGate()
    private let disk:CoverDiskCache?
    let writes:CoverWriteQueue
    var pixelSize=480
    var nearCount=3
    var changed:(()->Void)?
    var conditionalLoad:((String,String?)async throws->LimitedHTTP.Payload)?
    #if DEBUG && targetEnvironment(simulator)
    var idle:Bool{jobs.isEmpty && running.isEmpty && writes.idle}
    private var benchmarkHold=false
    var benchmarkRunning:Int{running.count}
    func holdBenchmarkNetwork(_ hold:Bool){benchmarkHold=hold;if !hold{for job in jobs.values{job.benchmarkParked=false};pump()}}
    var memoryCost:Int{memory.cost}
    func decodeCount()async->Int{await decoder.decodes}
    #endif
    init(disk:CoverDiskCache?=nil,writes:CoverWriteQueue?=nil){self.disk=disk;self.writes=writes ?? CoverWriteQueue()}
    func configureScope(_ value:String?,revision:String="",identities:[String:String]=[:]){
        if value==scope,self.revision==revision,!identities.contains(where:{self.identities[$0.key] != nil && self.identities[$0.key] != $0.value}){self.identities=identities;return}
        reset(keepCache:value != nil && value==scope)
        self.scope=value;self.revision=revision;self.identities=identities
    }
    private func key(_ path:String)->String? {
        guard let scope else{return nil}
        return CoverRules.key(scope:scope+"\n"+(identities[path] ?? "legacy")+"\nthumbnail-v2-\(pixelSize)",path:path)
    }
    private func memoryKey(_ path:String)->String{key(path) ?? "temporary-\(pixelSize)-"+path}
    func prefetch(_ paths:[String],load:@escaping(String)async throws->Data){
        let values=Array(paths.prefix(18));let wanted=Set(values)
        for path in prefetched.subtracting(wanted) where jobs[path]?.listeners.isEmpty==true{remove(path)}
        prefetched=wanted;near=Set(values.prefix(nearCount))
        guard !suspended else{return}
        for path in values where jobs[path]==nil {
            if let saved=memory.value(for:memoryKey(path)),saved.revision==revision,Date().timeIntervalSince(saved.checked)<24*3600{continue}
            jobs[path]=Job(load:{try await load(path)});order.append(path)
        }
        pump()
    }
    func subscribe(_ path:String,id:UUID,load:@escaping()async throws->Data,complete:@escaping Completion){
        if let value=memory.value(for:memoryKey(path)){
            complete(.success(value.image))
            if value.revision==revision,Date().timeIntervalSince(value.checked)<24*3600{return}
        }
        if let job=jobs[path]{job.listeners[id]=complete}
        else{let job=Job(load:load);job.listeners[id]=complete;jobs[path]=job;order.append(path)}
        // Demand preempts speculative work, but cancelled work keeps its physical
        // slot until it actually finishes. No unlimited cancel/restart fan-out.
        if running.count>=3,let speculative=order.first(where:{$0 != path && jobs[$0]?.task != nil && jobs[$0]?.listeners.isEmpty==true}){remove(speculative)}
        pump()
    }
    private func remove(_ path:String){jobs.removeValue(forKey:path)?.task?.cancel();order.removeAll{$0==path}}
    func cancel(_ path:String,id:UUID){
        guard let job=jobs[path] else{return};job.listeners.removeValue(forKey:id)
        if job.listeners.isEmpty && !prefetched.contains(path){remove(path)}
        else if job.listeners.isEmpty,job.task != nil,jobs.contains(where:{$0.key != path && $0.value.task != nil && $0.value.listeners.isEmpty}){remove(path)}
        pump()
    }
    func suspend(_ value:Bool){
        suspended=value
        if value {
            writes.cancel()
            prefetched.removeAll();near.removeAll()
            for path in Array(jobs.keys){
                if jobs[path]?.listeners.isEmpty==true{remove(path)}
                else{jobs[path]?.task?.cancel();jobs[path]?.task=nil;jobs[path]?.ticket=UUID()}
            }
        }else{pump()}
    }
    func trim(){memory.removeAll();prefetch([]){_ in throw CancellationError()}}
    func reset(keepCache:Bool=false){
        writes.cancel()
        let old=Array(jobs.values);jobs.removeAll();order.removeAll();prefetched.removeAll();near.removeAll()
        if !keepCache{memory.removeAll()}
        for job in old{job.task?.cancel();for reply in job.listeners.values{reply(.failure(CancellationError()))}}
    }
    private func pump(){
        guard !suspended else{return}
        let queue=order.filter{jobs[$0]?.listeners.isEmpty==false}+order.filter{jobs[$0]?.listeners.isEmpty==true}
        for path in queue where running.count<3 {
            guard let job=jobs[path],job.task==nil else{continue}
            #if DEBUG && targetEnvironment(simulator)
            if benchmarkHold && job.benchmarkParked{continue}
            #endif
            if job.listeners.isEmpty && jobs.values.contains(where:{$0.task != nil && $0.listeners.isEmpty}){continue}
            let ticket=UUID();job.ticket=ticket;running.insert(ticket)
            let disk=self.disk,key=key(path),memKey=memoryKey(path),revision=self.revision,pixels=pixelSize,loader=conditionalLoad
            job.task=Task{[weak self] in
                guard let self else{return}
                defer {
                    self.running.remove(ticket)
                    if self.jobs[path]?.ticket==ticket{
                        #if DEBUG && targetEnvironment(simulator)
                        if job.benchmarkParked{job.task=nil}
                        else{self.jobs.removeValue(forKey:path);self.order.removeAll{$0==path}}
                        #else
                        self.jobs.removeValue(forKey:path);self.order.removeAll{$0==path}
                        #endif
                    }
                    self.changed?();self.pump()
                }
                @MainActor func live()->Bool{!Task.isCancelled && self.jobs[path]?.ticket==ticket && !self.suspended}
                @MainActor func wantsImage()->Bool{!job.listeners.isEmpty || self.near.contains(path)}
                @MainActor func deliver(_ image:UIImage,_ record:CoverRecord,notify:Bool=true){
                    guard live(),let cg=image.cgImage else{return}
                    self.memory.insert(Memory(image:image,checked:record.checked,revision:record.revision),for:memKey,cost:cg.bytesPerRow*cg.height)
                    if notify{for reply in job.listeners.values{reply(.success(image))}}
                }
                var displayed=false,replaced=false
                var needsWrite=false
                do {
                    let diskTicket=await disk?.ticket()
                    var saved:CoverRecord?
                    if let disk,let key,let data=try? await disk.value(key){saved=try? await self.decoder.unpack(data)}
                    var image:UIImage?
                    if let record=saved,wantsImage(){
                        do{let decoded=try await self.decoder.display(record,pixels:pixels);image=decoded;needsWrite = !record.thumbnail;deliver(decoded,record);displayed=true}
                        catch{try Task.checkCancellation();saved=nil;if let disk,let key{await disk.discard(key)}}
                    }
                    guard live() else{throw CancellationError()}
                    if saved?.fresh(revision:revision) != true {
                        #if DEBUG && targetEnvironment(simulator)
                        // Test-only network policy: cached reads never wait for
                        // settling, and parked misses release physical slots.
                        if self.benchmarkHold{job.benchmarkParked=true;return}
                        #endif
                        needsWrite=true
                        try await self.gate.acquire();guard live() else{throw CancellationError()}
                        let response:LimitedHTTP.Payload
                        if let loader{response=try await loader(path,saved?.etag)}
                        else{response=LimitedHTTP.Payload(data:try await job.load(),status:200,etag:nil)}
                        guard live() else{throw CancellationError()}
                        if response.status==304 {
                            guard var record=saved,let oldTag=record.etag,response.etag==oldTag else{throw LibraryError.malformed}
                            record.checked=Date();record.revision=revision;saved=record
                        }else{
                            guard response.status==200,!response.data.isEmpty,response.data.count<=8*1024*1024 else{throw LibraryError.malformed}
                            saved=CoverRecord(bytes:response.data,thumbnail:false,etag:response.etag.flatMap{CoverRecord.validETag($0) ? $0:nil},checked:Date(),revision:revision);image=nil;replaced=true
                        }
                    }
                    guard let record=saved,live() else{throw CancellationError()}
                    if wantsImage(){
                        if image==nil{needsWrite = needsWrite || !record.thumbnail;image=try await self.decoder.display(record,pixels:pixels)}
                        if let image{deliver(image,record,notify:!displayed || replaced)}
                    }
                    guard live() else{throw CancellationError()}
                    if needsWrite,let disk,let key,let diskTicket {
                        self.writes.enqueueCover(record,image:record.thumbnail ? nil:image,key:key,ticket:diskTicket,disk:disk)
                    }
                }catch{
                    if live(),!displayed{for reply in job.listeners.values{reply(.failure(error))}}
                }
            }
        }
    }
}

// SDWebImage-inspired bounded frame queue. The prepared session's first two frames
// are already charged to its pool. Other displayed + queued + decoding frames share
// the existing 10 MiB playback reserve; no full-animation expansion or extra budget.
actor PlaybackFrameBuffer {
    private let session:PreparedAnimation
    private var queue:[(Int,UIImage,Double)]=[]
    private var nextIndex=1
    private var displayedCost=0,previousCost=0
    private var work:Task<Void,Never>?
    private var failure:Error?
    private var stopped=false
    private let budget=10*1024*1024,worstFrame=5*1024*1024
    private var queuedCost:Int{queue.reduce(0){$0+cost($1.0,$1.1)}}
    var retainedBytes:Int{previousCost+displayedCost+queuedCost+(work==nil ? 0:worstFrame)}
    init(session:PreparedAnimation){self.session=session}
    private func cost(_ index:Int,_ image:UIImage)->Int{index<2 ? 0 : (image.cgImage.map{$0.bytesPerRow*$0.height} ?? worstFrame)}
    func start(){fill()}
    func stop(){stopped=true;work?.cancel();work=nil;queue.removeAll();displayedCost=0;previousCost=0}
    func didDisplay(){previousCost=0;fill()}
    private func fill(){
        let target=min(6,max(2,Int(ceil(0.15/session.first.1))))
        guard !stopped,failure==nil,work==nil,queue.count<target,previousCost+displayedCost+queuedCost+worstFrame<=budget else{return}
        let index=nextIndex
        work=Task{[weak self,session] in
            let result:Result<(UIImage,Double),Error>
            do{result = .success(try await session.frame(index))}catch{result = .failure(error)}
            await self?.completed(index,result)
        }
    }
    private func completed(_ index:Int,_ result:Result<(UIImage,Double),Error>){
        work=nil;guard !stopped else{return}
        switch result {
        case .success(let frame):
            guard previousCost+displayedCost+queuedCost+cost(index,frame.0)<=budget else{failure=LibraryError.malformed;return}
            queue.append((index,frame.0,frame.1));nextIndex=(index+1)%session.info.count
        case .failure(let error):failure=error
        }
        fill()
    }
    func next()async throws->(UIImage,Double){
        while queue.isEmpty {
            try Task.checkCancellation();guard !stopped else{throw CancellationError()}
            if let failure{throw failure}
            fill();guard let task=work else{throw LibraryError.malformed};await task.value
        }
        try Task.checkCancellation();guard !stopped else{throw CancellationError()}
        let frame=queue.removeFirst();previousCost=displayedCost;displayedCost=cost(frame.0,frame.1);fill();return(frame.1,frame.2)
    }
}

#if DEBUG && targetEnvironment(simulator)
enum CoverV2Checks {
    @MainActor static func run()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)")}
        func wait(_ predicate:()->Bool)async{for _ in 0..<1000{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("cover-v2 timeout")}
        var bucket=CoverRequestBucket()
        pass((0..<6).allSatisfy{_ in bucket.take(now:0)} && !bucket.take(now:0),"token bucket allows burst six then throttles")
        pass(!bucket.take(now:0.1) && bucket.take(now:0.125),"token bucket replenishes eight per second")
        pass((0..<6).allSatisfy{_ in bucket.take(now:100)} && !bucket.take(now:100),"idle time never accumulates unbounded tokens")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cover-v2-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let path="/v1/books/1/cover",tag="W/\""+String(repeating:"a",count:64)+"\"",tag2="W/\""+String(repeating:"b",count:64)+"\""
        pass(CoverRecord.validETag(tag) && !CoverRecord.validETag(tag+"\n") && !CoverRecord.validETag(tag+"\r\nInjected: value"),"validator rejects line breaks and header injection")
        let sample=ReaderDemo.data("1"),identity=String(repeating:"c",count:64)
        var calls=0,validators:[String?]=[],serverTag=tag
        let disk=CoverDiskCache(root:root),writes=CoverWriteQueue()
        let pipeline=SmartCoverPipeline(disk:disk,writes:writes)
        func loader(_ path:String,_ validator:String?)async throws->LimitedHTTP.Payload {
            calls+=1;validators.append(validator)
            return .init(data:validator==serverTag ? Data():sample,status:validator==serverTag ? 304:200,etag:serverTag)
        }
        pipeline.conditionalLoad=loader
        func configured(_ pipeline:SmartCoverPipeline,_ revision:String,_ bookIdentity:String=identity){pipeline.configureScope("device/library",revision:revision,identities:[path:bookIdentity])}
        var delivered=0,failures=0,last:UIImage?
        func subscribe(_ pipeline:SmartCoverPipeline,_ path:String){pipeline.subscribe(path,id:UUID(),load:{preconditionFailure("conditional loader not used")}){result in switch result{case .success(let image):last=image;delivered+=1;case .failure:failures+=1}}}
        do {
            configured(pipeline,"v1");subscribe(pipeline,path);await wait{pipeline.idle}
            pass(calls==1 && failures==0 && delivered>0,"cold cover uses one network request")
            pass(max(last!.cgImage!.width,last!.cgImage!.height)<=480,"decoded thumbnail respects display pixel bucket")
            let key=CoverRules.key(scope:"device/library\n\(identity)\nthumbnail-v2-480",path:path)!
            let record=try CoverRecord.unpack(try await disk.value(key)!)
            pass(record.thumbnail && record.etag==tag,"disk stores processed thumbnail and validator")
            pass(record.bytes.prefix(8)==Data([137,80,78,71,13,10,26,10]),"processed thumbnail is lossless PNG")
            let restarted=SmartCoverPipeline(disk:disk);restarted.conditionalLoad=loader;configured(restarted,"v1")
            subscribe(restarted,path);await wait{restarted.idle}
            pass(calls==1,"restart reads processed disk cover without download")
            let oldDelivered=delivered;subscribe(restarted,path)
            pass(delivered==oldDelivered+1 && calls==1,"memory hit returns synchronously without request")
            configured(restarted,"v2");subscribe(restarted,path);await wait{restarted.idle}
            pass(calls==2 && validators.last! == tag,"catalog change revalidates existing book with ETag")
            pass(try CoverRecord.unpack(try await disk.value(key)!).revision=="v2","304 retains image and updates validation metadata")
            serverTag=tag2;configured(restarted,"v3");subscribe(restarted,path);await wait{restarted.idle}
            let replaced=try CoverRecord.unpack(try await disk.value(key)!)
            pass(calls==3 && replaced.etag==tag2,"changed cover replaces processed cache")
            var expired=try CoverRecord.unpack(try await disk.value(key)!);expired.checked=Date(timeIntervalSinceNow:-90_000)
            try await disk.put(expired.packed(),key:key,ticket:await disk.ticket())
            let stale=SmartCoverPipeline(disk:disk);stale.conditionalLoad=loader;configured(stale,"v3")
            var validationGate:CheckedContinuation<LimitedHTTP.Payload,Error>?
            stale.conditionalLoad={_,etag in pass(etag==tag2,"daily revalidation sends previous validator");return try await withCheckedThrowingContinuation{validationGate=$0}}
            let before=delivered;subscribe(stale,path);await wait{validationGate != nil}
            pass(delivered>before,"stale thumbnail displayed before network validation finishes")
            validationGate?.resume(returning:.init(data:Data(),status:304,etag:tag2));await wait{stale.idle}
            let changed=SmartCoverPipeline(disk:disk);changed.conditionalLoad=loader;configured(changed,"v3",String(repeating:"d",count:64));subscribe(changed,path);await wait{changed.idle}
            pass(calls==4 && validators.last! == nil,"changed directory identity does not borrow previous cover")
            try await disk.put(Data([1,2,3]),key:key,ticket:await disk.ticket())
            let corrupt=SmartCoverPipeline(disk:disk);corrupt.conditionalLoad=loader;configured(corrupt,"v3");subscribe(corrupt,path);await wait{corrupt.idle}
            pass(calls==5 && validators.last! == nil,"corrupt disk entry falls back to network")
            let far=SmartCoverPipeline(disk:disk);far.nearCount=0;far.configureScope("far",revision:"v1");far.conditionalLoad=loader
            far.prefetch([path]){_ in preconditionFailure()};await wait{far.idle}
            pass(await far.decodeCount()==0 && far.memoryCost==0,"far prefetch stores bytes without decoding or decoded-memory cost")
            let beforePromotion=calls;subscribe(far,path);await wait{far.idle}
            pass(await far.decodeCount()==1 && calls==beforePromotion,"visible promotion decodes prefetched data without downloading again")
            let bad=SmartCoverPipeline();bad.conditionalLoad={_,_ in .init(data:Data(),status:304,etag:tag)}
            let beforeFailure=failures;subscribe(bad,path);await wait{bad.idle}
            pass(failures==beforeFailure+1,"304 without a cached representation is rejected")
            let clearing=SmartCoverPipeline(disk:disk);clearing.configureScope("clearing")
            var late:CheckedContinuation<LimitedHTTP.Payload,Error>?
            clearing.conditionalLoad={_,_ in try await withCheckedThrowingContinuation{late=$0}}
            subscribe(clearing,path);await wait{late != nil};clearing.reset();try await disk.clear()
            late?.resume(returning:.init(data:sample,status:200,etag:tag));await wait{clearing.idle}
            pass(try await disk.usage()==0,"cancelled response cannot repopulate cleared disk cache")
            pass(CoverRules.diskBudget==2_000_000_000 && pipeline.memoryCost<=32*1024*1024,"disk remains 2 GB and decoded cover memory remains bounded")
        }catch{preconditionFailure("cover-v2 disk checks: \(error)")}
        // A deliberately cancellation-ignoring loader exercises physical slot accounting.
        let queue=SmartCoverPipeline();var gates:[String:CheckedContinuation<Data,Error>]=[:],starts:[String]=[]
        func held(_ path:String)async throws->Data{starts.append(path);return try await withCheckedThrowingContinuation{gates[path]=$0}}
        queue.prefetch(["p","q"],load:held);await wait{starts.count==1}
        for path in ["a","b"]{queue.subscribe(path,id:UUID(),load:{try await held(path)}){_ in}}
        await wait{starts.count==3}
        queue.subscribe("c",id:UUID(),load:{try await held("c")}){_ in}
        try? await Task.sleep(nanoseconds:50_000_000)
        pass(starts.count==3,"cancelled physical request holds its slot until completion")
        gates.removeValue(forKey:"p")?.resume(returning:sample);await wait{starts.contains("c")}
        pass(!starts.contains("q"),"visible demand overtakes queued speculative cover")
        queue.prefetch([],load:held);for gate in gates.values{gate.resume(returning:sample)};gates.removeAll();await wait{queue.idle}
        for format in 1...3 {
            do {
                let session=try await PreparedAnimation.make(ReaderDemo.animationData("\(format)")),buffer=PlaybackFrameBuffer(session:try await PreparedAnimation.make(ReaderDemo.animationData("\(format)")))
                await buffer.start()
                for index in 1...12 {
                    let frame=try await buffer.next(),expected=try await session.frame(index%session.info.count)
                    pass(frame.0.pngData()==expected.0.pngData() && frame.1==expected.1,"format \(format) buffered frame \(index) preserves composition and timing")
                    pass(await buffer.retainedBytes<=10*1024*1024,"format \(format) frame queue stays within playback reserve")
                    await buffer.didDisplay()
                }
                await buffer.stop()
                do{_ = try await buffer.next();preconditionFailure("stopped buffer returned a frame")}catch{}
                pass(await buffer.retainedBytes==0,"format \(format) stop releases buffer accounting")
            }catch{preconditionFailure("frame buffer fixture: \(error)")}
        }
        do {
            let bytes=NSMutableData(),destination=CGImageDestinationCreateWithData(bytes,UTType.gif.identifier as CFString,5,nil)!
            let format=UIGraphicsImageRendererFormat();format.scale=1
            for index in 0..<5 {
                let image=UIGraphicsImageRenderer(size:CGSize(width:1024,height:1024),format:format).image{context in
                    UIColor(hue:CGFloat(index)/5,saturation:1,brightness:1,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:1024,height:1024))
                }
                CGImageDestinationAddImage(destination,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.02]] as CFDictionary)
            }
            precondition(CGImageDestinationFinalize(destination))
            let session=try await PreparedAnimation.make(bytes as Data),buffer=PlaybackFrameBuffer(session:try await PreparedAnimation.make(bytes as Data))
            await buffer.start();var peak=0
            for index in 1...15 {
                let frame=try await buffer.next(),expected=try await session.frame(index%5)
                precondition(frame.0.pngData()==expected.0.pngData(),"large buffered GIF frame mismatch")
                let retained=await buffer.retainedBytes;peak=max(peak,retained);precondition(retained<=10*1024*1024,"large frame reserve overflow")
                await buffer.didDisplay()
            }
            await buffer.stop()
            pass(peak>=4*1024*1024,"large 1024px frames exercise budget backpressure without starving or reordering playback")
        }catch{preconditionFailure("large buffer fixture: \(error)")}
        print("\(checks) enhanced cover and animation buffer checks passed")
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
// These probes use generated bytes only; none are reachable in Release builds.
private final class ParseProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var count=0,main=false
    let gate=DispatchSemaphore(value:0)
    func enter(){lock.lock();count+=1;main = main || Thread.isMainThread;lock.unlock()}
    var snapshot:(Int,Bool){lock.lock();defer{lock.unlock()};return(count,main)}
    func block(){enter();precondition(gate.wait(timeout:.now()+5) == .success,"parse test gate timeout")}
}
enum PageListChecks {
    @MainActor static func run()async {
        var count=0
        func pass(_ value:Bool,_ label:String){precondition(value,label);count+=1;print("PASS \(label)")}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PairingFixture.self]
        let parser=MetadataParser(),library=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in},removePair:{},metadata:parser)
        library.setReading(true)
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.240.124:8088",token:PairingFixture.token,deviceId:PairingFixture.id)
        await library.connect(code:code)
        do {
            var result=try await library.pageList("1")
            pass(result.pages.map(\.number)==[1,3,10] && PairingFixture.hits()==1,"first page-list load fetches and retains numeric gaps")
            _=try await library.pageList("1");pass(PairingFixture.hits()==1,"reopening same book reuses metadata without network")
            PairingFixture.setPages([1,3,10,11]);result=try await library.pageList("1")
            pass(result.pages.count==3 && PairingFixture.hits()==1,"same snapshot remains stable within short TTL")
            result=try await library.pageList("1",force:true)
            pass(result.pages.last?.number==11 && PairingFixture.hits()==2,"manual force reload discovers new pages from server")
            library.invalidatePageList("1");_=try await library.pageList("1");pass(PairingFixture.hits()==3,"page read failure invalidates book metadata")
            library.trimCatalog();_=try await library.pageList("1");pass(PairingFixture.hits()==4,"memory pressure clears cached page numbers")
            PairingFixture.setPages([]);_=try await library.pageList("1",force:true);_=try await library.pageList("1")
            pass(PairingFixture.hits()==6,"empty directory is never cached")
            PairingFixture.setPages([1,1])
            do{_=try await library.pageList("1",force:true);preconditionFailure("duplicate page accepted")}catch{pass(true,"invalid page list cannot replace validated state")}
            PairingFixture.setPages([1,3,10]);_=try await library.pageList("1");pass(PairingFixture.hits()==8,"failed refresh does not resurrect previous cache")
            PairingFixture.changeRevision();await library.more();_=try await library.pageList("1")
            pass(PairingFixture.hits()==9,"catalog refresh invalidates per-book page numbers")
            await library.connect(code:code);_=try await library.pageList("1");pass(PairingFixture.hits()==10,"verified reconnect invalidates page-list cache")
            let probe=ParseProbe();await parser.setHook{if probe.snapshot.0==0{probe.block()}else{probe.enter()}}
            let old=Task{try await library.pageList("2",force:true)}
            for _ in 0..<1000{if probe.snapshot.0==1{break};try? await Task.sleep(nanoseconds:1_000_000)}
            precondition(probe.snapshot.0==1)
            let before=PairingFixture.hits(),new=Task{try await library.pageList("2",force:true)}
            for _ in 0..<1000{if PairingFixture.hits()>before{break};try? await Task.sleep(nanoseconds:1_000_000)}
            precondition(PairingFixture.hits()>before);probe.gate.signal()
            do{_=try await old.value;preconditionFailure("superseded page list returned")}catch is CancellationError{pass(true,"newer refresh supersedes older in-flight page-list response")}
            _=try await new.value;await parser.setHook(nil)
            let hits=PairingFixture.hits();_=try await library.pageList("2");pass(PairingFixture.hits()==hits,"only newest validated refresh is cached")
            library.setForeground(false)
        }catch{preconditionFailure("page cache integration: \(error)")}
        print("\(count) page-list cache checks passed")
    }
}
enum ScrollNetworkBenefits {
    @MainActor static func run()async {
        func now()->Double{ProcessInfo.processInfo.systemUptime}
        func wait(_ test:()->Bool)async{for _ in 0..<2000{if test(){return};try? await Task.sleep(nanoseconds:5_000_000)};preconditionFailure("scroll probe timeout")}
        let sample=ReaderDemo.data("1")
        let scenarios=ProcessInfo.processInfo.arguments.contains("--scroll-short-only") ? ["short-cold","short-low-latency"]:["fast-cold","slow-cold","fast-memory","fast-disk","fast-reverse","fast-low-latency"]
        for scenario in scenarios {
            for repetition in 0..<3 {for candidate in (repetition%2==0 ? [false,true]:[true,false]) {
                let root=FileManager.default.temporaryDirectory.appendingPathComponent("scroll-network-probe-"+UUID().uuidString)
                let disk=CoverDiskCache(root:root),pipeline=SmartCoverPipeline(disk:disk)
                pipeline.configureScope("synthetic",revision:"v1")
                let fast=scenario != "slow-cold",steps=scenario.hasPrefix("short-") ? 2:(fast ? 24:6)
                let period:UInt64=fast ? 50_000_000:350_000_000,chunk:UInt64=scenario.hasSuffix("low-latency") ? 5_000_000:20_000_000
                var starts=0,bytes=0,finished=0,visible:[String:UUID]=[:],shown=Set<String>(),wanted=Set<String>(),peak=0
                pipeline.conditionalLoad={_,_ in
                    starts+=1
                    for part in 0..<4{try await Task.sleep(nanoseconds:chunk);bytes+=sample.count/4+(part==3 ? sample.count%4:0)}
                    finished+=1;return .init(data:sample,status:200,etag:nil)
                }
                func paths(_ step:Int)->[String]{let offset=scenario=="fast-reverse" ? (step<12 ? step:23-step)*3:step*(scenario.hasPrefix("short-") ? 1:3);return (offset+1...offset+6).map{"/v1/books/\($0)/cover"}}
                if scenario=="fast-memory" || scenario=="fast-disk" {
                    // Seed serially: the bounded write queue is allowed to drop
                    // writes under pressure. A disk-warm test must prove all hits.
                    for path in paths(steps-1){
                        pipeline.subscribe(path,id:UUID(),load:{sample}){_ in};await wait{pipeline.idle}
                        let key=CoverRules.key(scope:"synthetic\nlegacy\nthumbnail-v2-480",path:path)!
                        let saved=try? await disk.value(key);precondition(saved != nil,"warm fixture must exist on disk")
                    }
                    await wait{pipeline.idle};try? await Task.sleep(nanoseconds:800_000_000)
                    if scenario=="fast-disk"{pipeline.trim()}
                    starts=0;bytes=0;finished=0
                }
                func show(_ step:Int){
                    wanted=Set(paths(step));shown.formIntersection(wanted)
                    for path in Array(visible.keys) where !wanted.contains(path){pipeline.cancel(path,id:visible.removeValue(forKey:path)!)}
                    for path in paths(step) where visible[path]==nil {
                        let id=UUID();visible[path]=id
                        pipeline.subscribe(path,id:id,load:{sample}){if case .success=$0,wanted.contains(path){shown.insert(path)}}
                    }
                    peak=max(peak,pipeline.memoryCost);precondition(pipeline.benchmarkRunning<=3)
                }
                pipeline.holdBenchmarkNetwork(candidate && fast)
                for step in 0..<steps-1{show(step);try? await Task.sleep(nanoseconds:period)}
                let landed=now();show(steps-1)
                let resume=Task{@MainActor in if candidate && fast{try? await Task.sleep(nanoseconds:150_000_000);pipeline.holdBenchmarkNetwork(false)}}
                await wait{peak=max(peak,pipeline.memoryCost);return wanted.isSubset(of:shown)}
                let elapsed=(now()-landed)*1000
                await resume.value;await wait{pipeline.idle}
                precondition(peak<=32*1024*1024)
                let row:[String:Any]=["scenario":scenario,"candidate":candidate,"repetition":repetition,"landing_ms":elapsed,"requests":starts,"mock_bytes":bytes,"completed":finished,"decodes":await pipeline.decodeCount(),"observed_memory_cost":peak]
                print("SCROLL_NETWORK_RESULT "+String(data:try! JSONSerialization.data(withJSONObject:row,options:.sortedKeys),encoding:.utf8)!)
                pipeline.reset();await disk.flushTouches();try? FileManager.default.removeItem(at:root)
            }}
        }
        print("SCROLL_NETWORK_BENEFITS_COMPLETE (synthetic motion and network; no real FPS or Wi-Fi measurement)")
    }
}
enum ParsingChecks {
    @MainActor static func run()async {
        var count=0
        func pass(_ value:Bool,_ label:String){precondition(value,label);count+=1;print("PASS \(label)")}
        func wait(_ test:()->Bool)async{for _ in 0..<1000{if test(){return};try? await Task.sleep(nanoseconds:1_000_000)};preconditionFailure("parse test timeout")}
        let parser=MetadataParser(),probe=ParseProbe()
        await parser.setHook{probe.enter()}
        let source=BookList(orderVerified:false,total:500,books:(0..<500).map{Book(id:String($0+1),title:"合成标题 \($0)",rank:$0,available:$0 != 2,coverIdentity:String(repeating:"c",count:64))},orderPolicy:"snapshot-query",catalogRevision:String(repeating:"a",count:64),libraryId:String(repeating:"b",count:64))
        let bytes=try! JSONEncoder().encode(source)
        do {
            let page=try await parser.catalog(bytes,page:0,size:500)
            pass(probe.snapshot.0==1 && !probe.snapshot.1,"catalog decode and validation execute off main thread")
            pass(page.list.books.map(\.rank)==Array(0..<500) && page.list.books[2].isMissing,"background catalog keeps source order and missing position")
            var old=CatalogPageCache(),prepared=CatalogPageCache();let now=Date()
            try old.store(source,page:0,size:500,owner:"device",now:now);prepared.store(page,owner:"device",now:now)
            pass(old.cost==prepared.cost && prepared.value(page:0,size:500,now:now)?.books.count==500,"validated handoff preserves cache costs without revalidating on UI actor")
            let result=try await parser.pages(Data("{\"pages\":[{\"number\":1},{\"number\":3},{\"number\":10}]}".utf8))
            pass(result.pages.map(\.number)==[1,3,10] && !probe.snapshot.1,"page-list parsing keeps original numeric gaps off main")
            for data in [Data("bad json".utf8),Data("{\"pages\":[{\"number\":1},{\"number\":1}]}".utf8),Data("{\"pages\":[{\"number\":10},{\"number\":2}]}".utf8)] {
                do{_=try await parser.pages(data);preconditionFailure("malformed pages accepted")}catch{pass(true,"malformed or reordered page list rejected")}
            }
            do{_=try await parser.catalog(bytes,page:0,size:50);preconditionFailure("oversized page accepted")}catch{pass(true,"invalid catalog page length rejected before publication")}
            do{_=try await parser.catalog(Data(repeating:32,count:8*1024*1024+1),page:0,size:500);preconditionFailure("oversized data accepted")}catch{pass(true,"parser preserves 8 MiB input limit")}
            let decoder=SmartCoverDecoder(),record=CoverRecord(bytes:Data([1,2,3]),thumbnail:true,etag:nil,checked:now,revision:"a")
            let unpacked=try await decoder.unpack(record.packed())
            pass(unpacked.bytes==record.bytes && unpacked.checked==record.checked,"cover record unpack preserves bytes and freshness metadata off main")
            do{_=try await decoder.unpack(Data([1]));preconditionFailure("invalid plist accepted")}catch{pass(true,"invalid cover cache record rejected off main")}

            let blocked=MetadataParser(),block=ParseProbe();await blocked.setHook{block.block()}
            let first=Task{try await blocked.catalog(bytes,page:0,size:500)}
            await wait{block.snapshot.0==1}
            pass(!block.snapshot.1,"UI task continues while parser is deliberately blocked")
            let second=Task{try await blocked.catalog(bytes,page:0,size:500)}
            await Task.yield();second.cancel();block.gate.signal();_=try await first.value
            do{_=try await second.value;preconditionFailure("cancelled queued parse returned")}catch is CancellationError{pass(block.snapshot.0==1,"queued cancellation skips parsing and no extra parser starts")}

            let activeParser=MetadataParser(),active=ParseProbe();await activeParser.setHook{active.block()}
            let cancelled=Task{try await activeParser.pages(Data("{\"pages\":[]}".utf8))}
            await wait{active.snapshot.0==1};cancelled.cancel();active.gate.signal()
            do{_=try await cancelled.value;preconditionFailure("cancelled active parse returned")}catch is CancellationError{pass(true,"cancellation during parsing cannot return a result")}

            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PairingFixture.self]
            let connectionParser=MetadataParser(),connectionProbe=ParseProbe()
            await connectionParser.setHook{connectionProbe.block()}
            let library=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in preconditionFailure("obsolete connection saved")},removePair:{},metadata:connectionParser)
            library.setReading(true)
            let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.240.124:8088",token:PairingFixture.token,deviceId:PairingFixture.id)
            let connecting=Task{await library.connect(code:code)}
            await wait{connectionProbe.snapshot.0==1};library.setForeground(false);connectionProbe.gate.signal();await connecting.value
            pass(library.books.isEmpty && library.base==nil && library.paired==nil,"backgrounding during parse rejects obsolete connection and pairing write")
        }catch{preconditionFailure("parsing checks: \(error)")}
        print("\(count) background parsing checks passed")
    }
}

// Read-only candidate for optimization 2. Deliberately no put/clear API: this
// measures removing full-directory enumeration from a read, NOT a safe complete
// replacement for the production cache's 2 GB accounting and lifecycle.
private final class DirectCacheReadProbe:@unchecked Sendable {
    let root:URL
    let queue=DispatchQueue(label:"localshelf.benchmark.read",qos:.userInitiated)
    init(root:URL){self.root=root}
    func value(_ key:String)async throws->Data? {
        try await withCheckedThrowingContinuation{continuation in queue.async{[root] in
            do {
                guard key.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{continuation.resume(returning:nil);return}
                let file=root.appendingPathComponent(key+".cover")
                let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.creationDateKey])
                guard v.isRegularFile==true,v.isSymbolicLink != true,let size=v.fileSize,size<=8*1024*1024,let written=v.creationDate,Date().timeIntervalSince(written)<30*24*3600 else{continuation.resume(returning:nil);return}
                continuation.resume(returning:try Data(contentsOf:file))
            }catch{continuation.resume(throwing:error)}
        }}
    }
}
enum CacheReadBenefits {
    @MainActor static func run()async {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cache-read-benefit-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let sample=Data(repeating:67,count:4096)
        func median(_ values:[Double])->Double{values.sorted()[values.count/2]}
        do {
            for total in [6,1000,10000] {
                let folder=root.appendingPathComponent(String(total))
                try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in DispatchQueue.global(qos:.utility).async{
                    do {
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
                        for i in 0..<total{try sample.write(to:folder.appendingPathComponent(String(format:"%064x.cover",i)),options:.completeFileProtection)}
                        continuation.resume()
                    }catch{continuation.resume(throwing:error)}
                }}
                var coldOld:[Double]=[],coldNew:[Double]=[],warmOld:[Double]=[],warmNew:[Double]=[]
                let keys=(0..<6).map{String(format:"%064x",$0)}
                for round in 0..<5 {
                    let old=CoverDiskCache(root:folder),candidate=DirectCacheReadProbe(root:folder)
                    for warm in [false,true] {
                        for variant in (round%2==0 ? [0,1]:[1,0]) {
                            let begin=ProcessInfo.processInfo.systemUptime
                            for key in keys {
                                let bytes=try await (variant==0 ? old.value(key):candidate.value(key))
                                precondition(bytes==sample,"read-only candidate changed cache payload")
                            }
                            let elapsed=(ProcessInfo.processInfo.systemUptime-begin)*1000
                            if warm{if variant==0{warmOld.append(elapsed)}else{warmNew.append(elapsed)}}
                            else{if variant==0{coldOld.append(elapsed)}else{coldNew.append(elapsed)}}
                        }
                    }
                    await old.flushTouches()
                }
                print(String(format:"CACHE_READ_BENEFIT files=%d payload=4096 samples=5 first6_existing_ms=%.3f first6_readonly_ms=%.3f warm6_existing_ms=%.3f warm6_readonly_ms=%.3f",total,median(coldOld),median(coldNew),median(warmOld),median(warmNew)))
                print("CACHE_READ_RAW files=\(total) coldExisting=\(coldOld) coldReadOnly=\(coldNew) warmExisting=\(warmOld) warmReadOnly=\(warmNew)")
            }
            print("CACHE_READ_BENEFITS_COMPLETE (read-only prototype; not production capacity/lifecycle validation)")
        }catch{preconditionFailure("cache benchmark: \(error)")}
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
enum P34Checks {
    @MainActor static func run()async {
        var count=0
        func pass(_ value:Bool,_ name:String){precondition(value,name);count+=1;print("PASS \(name)")}
        func wait(_ condition:()->Bool)async{for _ in 0..<1000{if condition(){return};try? await Task.sleep(nanoseconds:5_000_000)};preconditionFailure("P3/P4 timeout")}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PairingFixture.self]
        let library=Library(transport:LimitedHTTP(configuration:config),loadPair:{nil},savePair:{_ in},removePair:{})
        library.setReading(true)
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.240.124:8088",token:PairingFixture.token,deviceId:PairingFixture.id)
        await library.connect(code:code)
        pass(library.books.first?.id=="1" && PairingFixture.hosts().count==1,"verified connection seeds first page cache from network")
        await library.loadPage(1)
        pass(library.books.first?.id=="101" && PairingFixture.hosts().count==2,"new page fetches once with original order")
        await library.loadPage(0);await library.loadPage(1)
        pass(PairingFixture.hosts().count==2 && library.books.first?.id=="101","back-and-forth pages reuse validated metadata")
        await library.more()
        pass(PairingFixture.hosts().count==3 && library.pageIndex==0,"explicit refresh always bypasses cache")
        await library.loadPage(1);pass(PairingFixture.hosts().count==4,"refresh invalidates other cached pages")
        PairingFixture.changeRevision();await library.more();await library.loadPage(1)
        pass(PairingFixture.hosts().count==6 && library.books.first?.title=="Fixture-b","changed catalog cannot mix old-page titles or ranks")
        library.pageSize=50;await library.loadPage(1)
        pass(library.books.first?.id=="51" && library.books.count==50 && PairingFixture.hosts().count==7,"page size switch has independent offset and cache key")
        library.trimCatalog();await library.loadPage(1)
        pass(PairingFixture.hosts().count==8,"memory pressure discards metadata cache")
        await library.connect(code:code);await library.loadPage(1)
        pass(PairingFixture.hosts().count==10,"reconnect revalidates first page and discards old page cache")
        library.setForeground(false)

        let root=FileManager.default.temporaryDirectory.appendingPathComponent("p34-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let disk=CoverDiskCache(root:root),writer=CoverWriteQueue(),pipeline=SmartCoverPipeline(disk:disk,writes:writer),sample=ReaderDemo.data("1")
        var gate:CheckedContinuation<Void,Never>?,entered=0,shown=0,loads=0
        writer.beforeEncode={entered+=1;if entered==1{await withCheckedContinuation{gate=$0}}}
        pipeline.configureScope("p34",revision:"a")
        func subscribe(_ path:String){pipeline.subscribe(path,id:UUID(),load:{loads+=1;return sample}){if case .success=$0{shown+=1}}}
        subscribe("/v1/books/1/cover");await wait{shown==1 && gate != nil}
        pass(shown==1 && !writer.idle,"cover displayed while PNG encoding is explicitly blocked")
        let firstCost=writer.bytes;subscribe("/v1/books/2/cover");await wait{shown==2}
        pass(shown==2 && entered==1,"another visible cover decodes despite blocked encoder")
        await wait{writer.bytes>firstCost}
        pass(writer.bytes<=8*1024*1024,"pending thumbnails and active encoding share 8 MiB staging budget")
        let before=writer.bytes
        writer.enqueueCover(CoverRecord(bytes:Data(repeating:1,count:3*1024*1024),thumbnail:false,etag:nil,checked:Date(),revision:"a"),image:nil,key:String(repeating:"a",count:64),ticket:await disk.ticket(),disk:disk)
        pass(writer.bytes==before,"oversized persistence job is skipped without blocking display")
        do {
            pipeline.reset();try await disk.clear()
            pass(writer.bytes==firstCost,"cancelling encoder keeps physical active reservation until it exits")
            gate?.resume();gate=nil;await wait{pipeline.idle}
            let usage=try await disk.usage()
            pass(writer.bytes==0 && usage==0,"cancelled encoding cannot resurrect cleared disk cache")
            writer.beforeEncode=nil;subscribe("/v1/books/3/cover");await wait{pipeline.idle}
            let key=CoverRules.key(scope:"p34\nlegacy\nthumbnail-v2-480",path:"/v1/books/3/cover")!
            let record=try CoverRecord.unpack(try await disk.value(key)!)
            pass(record.thumbnail && record.bytes.prefix(8)==Data([137,80,78,71,13,10,26,10]),"background writer stores processed PNG with original cache metadata")
            let restarted=SmartCoverPipeline(disk:disk);restarted.configureScope("p34",revision:"a")
            var delivered=false;let previousLoads=loads
            restarted.subscribe("/v1/books/3/cover",id:UUID(),load:{loads+=1;return sample}){if case .success=$0{delivered=true}}
            await wait{delivered && restarted.idle}
            pass(loads==previousLoads,"restart reuses asynchronously encoded cover without a new download")
            pass(sample==ReaderDemo.data("1"),"persistence never modifies source image bytes")
        }catch{preconditionFailure("P4 fixture: \(error)")}
        var writes=0
        let recovering=CoverWriteQueue{_ in writes+=1;if writes==1{throw LibraryError.malformed}}
        recovering.enqueue(Data([1]),key:String(repeating:"b",count:64),ticket:await disk.ticket(),disk:disk)
        recovering.enqueue(Data([2]),key:String(repeating:"c",count:64),ticket:await disk.ticket(),disk:disk)
        await wait{recovering.idle};pass(writes==2 && recovering.bytes==0,"persistence failure releases capacity and next job proceeds")
        print("\(count) P3/P4 integration checks passed")
    }
}
#endif
