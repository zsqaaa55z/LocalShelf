import SwiftUI
import UIKit
import Foundation
import ImageIO
import VisionKit
import AVFoundation
import Security
import CryptoKit
import UniformTypeIdentifiers

struct ProgressDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.json]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws{guard let data=configuration.file.regularFileContents else{throw LibraryError.malformed};_ = try ProgressBackup.decode(data);self.data=data}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{FileWrapper(regularFileWithContents:data)}
}

enum PairingKeychain {
    private static func query(_ account:String)->[String:Any]{[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.shelf.pairing.v2",kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]}
    static func load(account:String="android")throws->PairingCode? {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))}
        guard let data=result as? Data,let text=String(data:data,encoding:.utf8) else{throw LibraryError.malformed}
        let code=try PairingCode.parse(text);guard code.version==2 else{throw LibraryError.malformed};return code
    }
    static func save(_ code:PairingCode,account:String="android")throws {
        let value=try JSONEncoder().encode(code)
        let attributes:[String:Any]=[kSecValueData as String:value,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status=SecItemUpdate(query(account) as CFDictionary,attributes as CFDictionary)
        if status==errSecItemNotFound {
            let add=query(account).merging(attributes){_,new in new};let result=SecItemAdd(add as CFDictionary,nil)
            guard result==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(result))}
        }else if status != errSecSuccess{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))}
    }
    static func remove(account:String="android")throws {let status=SecItemDelete(query(account) as CFDictionary);guard status==errSecSuccess || status==errSecItemNotFound else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))}}
}

// Bounded, foreground-only DNS-SD. Neither service name nor TXT is trusted identity.
@MainActor final class AndroidDiscovery:NSObject,@preconcurrency NetServiceBrowserDelegate,@preconcurrency NetServiceDelegate {
    private var browser:NetServiceBrowser?
    private var services:[NetService]=[]
    private var results:Set<String>=[]
    private var expected=""
    private var waiter:CheckedContinuation<[String],Never>?
    private var deadline:Task<Void,Never>?
    private var ticket=UUID()
    func addresses(for id:String)async->[String]{
        stop();expected=id;ticket=UUID();let current=ticket
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation{continuation in
                guard !Task.isCancelled else{continuation.resume(returning:[]);return}
                waiter=continuation
                let browser=NetServiceBrowser();self.browser=browser;browser.delegate=self
                browser.searchForServices(ofType:"_localshelf._tcp.",inDomain:"local.")
                deadline=Task{try? await Task.sleep(nanoseconds:5_000_000_000);if !Task.isCancelled{self.stop()}}
            }
        },onCancel:{Task{@MainActor in if self.ticket==current{self.stop()}}})
    }
    func stop(){
        deadline?.cancel();deadline=nil;browser?.stop();browser?.delegate=nil;browser=nil
        for service in services{service.stop();service.delegate=nil};services=[]
        let continuation=waiter;waiter=nil;let found=Array(results).sorted();results=[];continuation?.resume(returning:found)
    }
    func netServiceBrowser(_ browser:NetServiceBrowser,didFind service:NetService,moreComing:Bool){
        guard browser===self.browser,services.count<8,service.name.hasPrefix("LocalShelf-"+expected) else{return}
        services.append(service);service.delegate=self;service.resolve(withTimeout:3)
    }
    func netServiceBrowser(_ browser:NetServiceBrowser,didNotSearch errorDict:[String:NSNumber]){if browser===self.browser{stop()}}
    func netServiceDidResolveAddress(_ sender:NetService){
        guard services.contains(where:{$0===sender}),sender.port==8088 else{return}
        for data in sender.addresses ?? [] {
            // Copy instead of assuming Data's alignment for sockaddr_in.
            guard data.count>=MemoryLayout<sockaddr_in>.size else{continue}
            var address=sockaddr_in();_ = withUnsafeMutableBytes(of:&address){data.copyBytes(to:$0)}
            guard address.sin_family==sa_family_t(AF_INET) else{continue}
            var buffer=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET,&address.sin_addr,&buffer,socklen_t(INET_ADDRSTRLEN)) != nil else{continue}
            let url="http://\(String(cString:buffer)):8088"
            if (try? LibraryRules.address(url)) != nil{results.insert(url)}
        }
    }
}

struct PairingScanner: UIViewControllerRepresentable {
    var complete: (Result<PairingCode, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            guard !context.coordinator.done else { return }
            do { try scanner.startScanning() }
            catch { context.coordinator.finish(.failure(error), scanner) }
        }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { coordinator.done = true; controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var done = false
        let complete: (Result<PairingCode, Error>) -> Void
        init(_ complete: @escaping (Result<PairingCode, Error>) -> Void) { self.complete = complete }
        func finish(_ result: Result<PairingCode, Error>, _ scanner: DataScannerViewController) {
            guard !done else { return }; done = true; scanner.stopScanning(); complete(result)
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                finish(Result { try PairingCode.parse(text) }, scanner); return
            } }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { finish(.failure(error), scanner) }
    }
}

final class LimitedHTTP: NSObject, URLSessionDataDelegate {
    struct Payload {let data:Data;let status:Int;let etag:String?}
    private final class State {
        var buffer:TransferBuffer
        var status=200;var etag:String?
        let allowNotModified:Bool
        let continuation:CheckedContinuation<Payload,Error>
        init(limit:Int,allowNotModified:Bool,continuation:CheckedContinuation<Payload,Error>){buffer=TransferBuffer(limit:limit);self.allowNotModified=allowNotModified;self.continuation=continuation}
    }
    private final class Cancellation:@unchecked Sendable {
        let lock=NSLock();var task:URLSessionTask?;var cancelled=false
        func attach(_ task:URLSessionTask){lock.lock();self.task=task;let cancel=cancelled;lock.unlock();if cancel{task.cancel()}}
        func cancel(){lock.lock();cancelled=true;let task=task;lock.unlock();task?.cancel()}
    }
    private let lock=NSLock()
    private var states:[Int:State]=[:]
    private var tasks:[Int:URLSessionDataTask]=[:]
    private let configuration:URLSessionConfiguration
    init(configuration:URLSessionConfiguration = .ephemeral){self.configuration=configuration;super.init()}
    private lazy var session:URLSession = {
        let config=configuration;config.urlCache=nil;config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=120
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1
        return URLSession(configuration:config,delegate:self,delegateQueue:queue)
    }()
    // Call on the Library's main actor; delegate chunk accumulation stays off it.
    func data(_ request:URLRequest,limit:Int,priority:Float=URLSessionTask.defaultPriority)async throws->Data {
        try await response(request,limit:limit,priority:priority).data
    }
    func response(_ request:URLRequest,limit:Int,priority:Float=URLSessionTask.defaultPriority,allowNotModified:Bool=false)async throws->Payload {
        let cancellation=Cancellation()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation{continuation in
                lock.lock();let task=session.dataTask(with:request)
                task.priority=priority;tasks[task.taskIdentifier]=task
                states[task.taskIdentifier]=State(limit:limit,allowNotModified:allowNotModified,continuation:continuation);lock.unlock()
                cancellation.attach(task);task.resume()
            }
        },onCancel:{cancellation.cancel()})
    }
    private func finish(_ task:URLSessionTask,error:Error?){
        lock.lock();let state=states.removeValue(forKey:task.taskIdentifier);tasks.removeValue(forKey:task.taskIdentifier);lock.unlock()
        guard let state else{return}
        if let error{state.continuation.resume(throwing:error)}else{state.continuation.resume(returning:Payload(data:state.buffer.data,status:state.status,etag:state.etag))}
    }
    func prioritizePage(_ path:String){
        lock.lock();defer{lock.unlock()}
        for task in tasks.values {
            guard let route=task.originalRequest?.url?.path,route.contains("/pages/") else{continue}
            task.priority=route==path ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
        lock.lock();let state=states[dataTask.taskIdentifier];lock.unlock()
        if let http=response as? HTTPURLResponse,http.statusCode != 200 && !(state?.allowNotModified == true && http.statusCode==304){
            completionHandler(.cancel);finish(dataTask,error:ServerFailure.status(http.statusCode));return
        }
        guard let state,let http=response as? HTTPURLResponse,(http.statusCode==200 || (state.allowNotModified && http.statusCode==304)),state.buffer.acceptsLength(response.expectedContentLength) else{
            completionHandler(.cancel);finish(dataTask,error:URLError(.badServerResponse));return
        }
        state.status=http.statusCode;state.etag=http.value(forHTTPHeaderField:"ETag")
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){
        lock.lock();let state=states[dataTask.taskIdentifier];lock.unlock()
        guard let state else{return}
        do{try state.buffer.append(data)}catch{dataTask.cancel();finish(dataTask,error:error)}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){finish(task,error:error)}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func close(){lock.lock();let current=session;lock.unlock();current.invalidateAndCancel()}
}

// Managed cover files only; actor isolation keeps directory I/O off the main actor.
actor CoverDiskCache {
    struct Entry {var cost:Int;var used:Date;let written:Date}
    private let root:URL
    private let budget:Int
    private let ttl:TimeInterval
    private var entries:[String:Entry]=[:]
    private var bytes=0
    private var initialized=false
    private var epoch=UUID()
    private var touches=Set<String>()
    private var touchTask:Task<Void,Never>?
    init(root:URL?=nil,budget:Int=CoverRules.diskBudget,ttl:TimeInterval=30*24*60*60){
        self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("LocalShelfCovers-v1",isDirectory:true)
        self.budget=max(0,budget);self.ttl=ttl
    }
    private func valid(_ key:String)->Bool{key.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
    private func file(_ key:String)->URL{root.appendingPathComponent(key+".cover")}
    private func prepare()throws{
        guard !initialized else{return}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var protected=root;var values=URLResourceValues();values.isExcludedFromBackup=true;try protected.setResourceValues(values)
        let properties:Set<URLResourceKey>=[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.totalFileAllocatedSizeKey,.creationDateKey,.contentModificationDateKey]
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:Array(properties),options:.skipsHiddenFiles)
        let now=Date();entries.removeAll();bytes=0
        for url in files where url.pathExtension=="cover" && valid(url.deletingPathExtension().lastPathComponent){
            let v=try url.resourceValues(forKeys:properties)
            guard v.isRegularFile==true,v.isSymbolicLink != true,let size=v.fileSize,size<=8*1024*1024,
                  let written=v.creationDate,now.timeIntervalSince(written)<ttl else{try FileManager.default.removeItem(at:url);continue}
            let cost=max(size,v.totalFileAllocatedSize ?? size)
            entries[url.deletingPathExtension().lastPathComponent]=Entry(cost:cost,used:v.contentModificationDate ?? written,written:written);bytes+=cost
        }
        initialized=true;try trim(to:budget)
    }
    private func remove(_ key:String)throws{
        touches.remove(key)
        let url=file(key)
        if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
        if let removed=entries.removeValue(forKey:key){bytes-=removed.cost}
    }
    private func trim(to target:Int)throws{
        guard bytes>max(0,target) || entries.count>20000 else{return}
        for oldest in entries.sorted(by:{$0.value.used<$1.value.used}) {
            guard bytes>max(0,target) || entries.count>20000 else{break};try remove(oldest.key)
        }
    }
    func ticket()->UUID{epoch}
    func usage()throws->Int{try prepare();return bytes}
    func value(_ key:String)throws->Data?{
        try Task.checkCancellation();guard valid(key) else{return nil};try prepare()
        guard var entry=entries[key] else{return nil}
        guard Date().timeIntervalSince(entry.written)<ttl else{try remove(key);return nil}
        do{
            let url=file(key),v=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isRegularFile==true,v.isSymbolicLink != true,let size=v.fileSize,size<=8*1024*1024 else{try remove(key);return nil}
            let data=try Data(contentsOf:url);try Task.checkCancellation()
            entry.used=Date();entries[key]=entry
            touches.insert(key);scheduleTouches()
            return data
        }catch{if !(error is CancellationError){try? remove(key)};throw error}
    }
    private func scheduleTouches(){
        guard touchTask==nil else{return}
        touchTask=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:1_000_000_000)}catch{return}
            await self?.flushTouches()
        }
    }
    func flushTouches(){
        touchTask?.cancel();touchTask=nil
        for key in touches{if let entry=entries[key]{try? FileManager.default.setAttributes([.modificationDate:entry.used],ofItemAtPath:file(key).path)}}
        touches.removeAll()
    }
    func put(_ data:Data,key:String,ticket:UUID)throws{
        try Task.checkCancellation();guard ticket==epoch,valid(key),!data.isEmpty,data.count<=min(budget,8*1024*1024) else{return}
        try prepare();guard ticket==epoch else{return}
        // Reserve a filesystem allocation block before atomic write; trim actual size afterwards.
        try remove(key);try trim(to:budget-min(budget,data.count+16384))
        let url=file(key)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        let v=try url.resourceValues(forKeys:[.fileSizeKey,.totalFileAllocatedSizeKey,.creationDateKey])
        let cost=max(data.count,v.totalFileAllocatedSize ?? data.count),now=Date()
        entries[key]=Entry(cost:cost,used:now,written:v.creationDate ?? now);bytes+=cost
        try trim(to:budget)
    }
    func discard(_ key:String){guard valid(key) else{return};try? prepare();try? remove(key)}
    func clear()throws{
        epoch=UUID();touchTask?.cancel();touchTask=nil;touches.removeAll();try prepare()
        for key in Array(entries.keys){try remove(key)}
    }
}

// Display never awaits a cache write. Staged + actively writing bytes are bounded.
@MainActor final class CoverWriteQueue {
    struct Item {let data:Data,key:String,ticket:UUID,disk:CoverDiskCache}
    private struct Work {let cost:Int;let run:()async throws->Void}
    private var queue:[Work]=[]
    private var active:Task<Void,Never>?
    private(set) var bytes=0
    private let persist:(Item)async throws->Void
    private let encoder=CoverEncoder()
    #if DEBUG && targetEnvironment(simulator)
    var beforeEncode:(()async->Void)?
    #endif
    init(persist:((Item)async throws->Void)?=nil){self.persist=persist ?? {try await $0.disk.put($0.data,key:$0.key,ticket:$0.ticket)}}
    var idle:Bool{active==nil && queue.isEmpty}
    func enqueue(_ data:Data,key:String,ticket:UUID,disk:CoverDiskCache){
        let item=Item(data:data,key:key,ticket:ticket,disk:disk),persist=self.persist
        admit(cost:data.count){try await persist(item)}
    }
    func enqueueCover(_ record:CoverRecord,image:UIImage?,key:String,ticket:UUID,disk:CoverDiskCache){
        var record=record
        // Encoding retains the thumbnail, not the downloaded original as well.
        if image != nil{record.bytes=Data()}
        let input=record.bytes.count+(image?.cgImage.map{$0.bytesPerRow*$0.height} ?? 0)
        // Charge input + PNG + packed output, including active work.
        let reserved=input*3+131072,encoder=self.encoder,persist=self.persist
        let payload=record
        #if DEBUG && targetEnvironment(simulator)
        let hook=beforeEncode
        #endif
        admit(cost:reserved){
            #if DEBUG && targetEnvironment(simulator)
            await hook?()
            #endif
            try Task.checkCancellation()
            let data=try await encoder.encode(payload,image:image)
            guard data.count*2+input<=reserved,data.count<=8*1024*1024 else{return}
            try Task.checkCancellation();try await persist(Item(data:data,key:key,ticket:ticket,disk:disk))
        }
    }
    private func admit(cost:Int,run:@escaping()async throws->Void){
        guard cost>=0,cost<=8*1024*1024-bytes,queue.count<16 else{return}
        queue.append(Work(cost:cost,run:run));bytes+=cost;pump()
    }
    func cancel(){
        bytes-=queue.reduce(0){$0+$1.cost};queue.removeAll();active?.cancel()
    }
    private func pump(){
        guard active==nil,!queue.isEmpty else{return}
        let item=queue.removeFirst()
        active=Task{[self] in
            try? await item.run()
            bytes-=item.cost;active=nil;pump()
        }
    }
}

// Shared physical decode limit: cancelling a running ImageIO call does not free
// its slot until it returns. Queued obsolete work is removed without decoding.
@MainActor final class PageDecodeQueue {
    static let shared=PageDecodeQueue()
    typealias Output=(UIImage,Bool)
    private struct Job {
        let id:UUID,key:String,work:@Sendable ()throws->Output,reply:CheckedContinuation<Output,Error>
    }
    private var queue:[Job]=[]
    private var running=Set<UUID>(),cancelled=Set<UUID>()
    private var current=""
    private let limit:Int
    private(set) var peak=0
    init(limit:Int=2){self.limit=max(1,limit)}
    func prioritize(_ key:String){current=key;pump()}
    func decode(key:String,work:@escaping @Sendable ()throws->Output)async throws->Output {
        let id=UUID()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation{reply in
                queue.append(Job(id:id,key:key,work:work,reply:reply));pump()
            }
        },onCancel:{Task{@MainActor in self.cancel(id)}})
    }
    private func cancel(_ id:UUID){
        if let index=queue.firstIndex(where:{$0.id==id}){queue.remove(at:index).reply.resume(throwing:CancellationError())}
        else if running.contains(id){cancelled.insert(id)}
    }
    private func pump(){
        while running.count<limit,!queue.isEmpty {
            let index=queue.firstIndex(where:{$0.key==current}) ?? 0,job=queue.remove(at:index)
            running.insert(job.id);peak=max(peak,running.count)
            Task{[self] in
                let result=await Task.detached(priority:job.key==current ? .userInitiated : .utility){Result{try job.work()}}.value
                running.remove(job.id)
                if cancelled.remove(job.id) != nil{job.reply.resume(throwing:CancellationError())}else{job.reply.resume(with:result)}
                pump()
            }
        }
    }
}

private actor CoverDecoder {
    func decode(_ data:Data)throws->UIImage {
        try Task.checkCancellation()
        guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:600,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
        return UIImage(cgImage:cg)
    }
}

#if DEBUG && targetEnvironment(simulator)
// Historical baseline retained only for regression comparison, not shipped.
@MainActor final class CoverPipeline {
    typealias Completion=(Result<UIImage,Error>)->Void
    private final class Job {
        var listeners:[UUID:Completion]=[:]
        let load:()async throws->Data
        var task:Task<Void,Never>?
        var ticket=UUID()
        init(load:@escaping ()async throws->Data){self.load=load}
    }
    private var cache=CostLRU<String,UIImage>(budget:32*1024*1024,countLimit:96)
    private var jobs:[String:Job]=[:]
    private var queue:[String]=[]
    private var active=0
    private var suspended=false
    private let decoder=CoverDecoder()
    private let disk:CoverDiskCache?
    let writes:CoverWriteQueue
    private var scope:String?
    private var prefetched=Set<String>()
    var changed:(()->Void)?
    init(disk:CoverDiskCache?=nil,writes:CoverWriteQueue?=nil){self.disk=disk;self.writes=writes ?? CoverWriteQueue()}
    func configureScope(_ value:String?){let keep=value != nil && value==scope;reset(keepCache:keep);scope=value}
    func prefetch(_ paths:[String],load:@escaping(String)async throws->Data){
        let wanted=Set(paths.prefix(18))
        for path in prefetched.subtracting(wanted){if let job=jobs[path],job.listeners.isEmpty{remove(path)}}
        prefetched=wanted
        guard !suspended else{return}
        for path in paths.prefix(18) where jobs[path]==nil {
            if cache.value(for:path) != nil{continue}
            jobs[path]=Job(load:{try await load(path)});queue.append(path)
        }
        pump()
    }
    private func remove(_ path:String){
        guard let job=jobs.removeValue(forKey:path) else{return}
        queue.removeAll{$0==path};if job.task != nil{job.task?.cancel();active-=1}
    }
    private func prioritizeDemand(){
        guard active>=3,let path=queue.first(where:{jobs[$0]?.listeners.isEmpty==true && jobs[$0]?.task != nil}),let job=jobs[path] else{return}
        job.ticket=UUID();job.task?.cancel();job.task=nil;active-=1
    }
    func subscribe(_ path:String,id:UUID,load:@escaping ()async throws->Data,complete:@escaping Completion){
        if let image=cache.value(for:path){complete(.success(image));return}
        if let job=jobs[path]{job.listeners[id]=complete;if job.task==nil{prioritizeDemand();pump()};return}
        let job=Job(load:load);job.listeners[id]=complete;jobs[path]=job;queue.append(path);prioritizeDemand();pump()
    }
    func cancel(_ path:String,id:UUID){
        guard let job=jobs[path] else{return};job.listeners.removeValue(forKey:id)
        guard job.listeners.isEmpty else{return}
        if !prefetched.contains(path){remove(path)}
        else if job.task != nil && jobs.contains(where:{$0.key != path && $0.value.task != nil && $0.value.listeners.isEmpty}){
            job.ticket=UUID();job.task?.cancel();job.task=nil;active-=1
        }
        pump()
    }
    func suspend(_ value:Bool){
        suspended=value
        if value {
            for path in prefetched{if jobs[path]?.listeners.isEmpty==true{remove(path)}};prefetched.removeAll()
            for job in jobs.values where job.task != nil {job.ticket=UUID();job.task?.cancel();job.task=nil}
            active=0
        }else{pump()}
    }
    func trim(){cache.removeAll();prefetch([]){_ in throw CancellationError()}}
    func reset(keepCache:Bool=false){
        writes.cancel()
        let old=Array(jobs.values);jobs.removeAll();queue.removeAll();prefetched.removeAll();active=0;if !keepCache{cache.removeAll()}
        for job in old {job.task?.cancel();for complete in job.listeners.values{complete(.failure(CancellationError()))}}
    }
    private func pump(){
        guard !suspended else{return}
        // Display demand precedes speculative work, with only one prefetch in flight.
        let ordered=queue.filter{jobs[$0]?.listeners.isEmpty==false}+queue.filter{jobs[$0]?.listeners.isEmpty==true}
        for path in ordered where active<3 {
            guard let job=jobs[path],job.task==nil else{continue}
            if job.listeners.isEmpty && jobs.values.contains(where:{$0.task != nil && $0.listeners.isEmpty}){continue}
            active+=1;job.ticket=UUID();let ticket=job.ticket,load=job.load,decoder=decoder
            let disk=self.disk,key=scope.flatMap{CoverRules.key(scope:$0,path:path)}
            job.task=Task{[weak self] in
                let result:Result<UIImage,Error>
                var persistence:(Data,String,UUID,CoverDiskCache)?
                do{
                    try Task.checkCancellation()
                    let diskTicket=await disk?.ticket()
                    var decoded:UIImage?
                    if let disk,let key,let data=try? await disk.value(key){
                        do{decoded=try await decoder.decode(data)}catch{try Task.checkCancellation();await disk.discard(key)}
                    }
                    if decoded==nil {
                        try Task.checkCancellation();let data=try await load();try Task.checkCancellation()
                        guard data.count<=8*1024*1024 else{throw LibraryError.malformed}
                        decoded=try await decoder.decode(data);try Task.checkCancellation()
                        if let disk,let key,let diskTicket{persistence=(data,key,diskTicket,disk)}
                    }
                    try Task.checkCancellation();result = .success(decoded!)
                }catch{result = .failure(error)}
                guard let self,let current=self.jobs[path],current.ticket==ticket else{return}
                self.jobs.removeValue(forKey:path);self.queue.removeAll{$0==path};self.active-=1
                if case .success(let image)=result,let cg=image.cgImage {self.cache.insert(image,for:path,cost:cg.bytesPerRow*cg.height)}
                for complete in current.listeners.values{complete(result)}
                if case .success=result,let (data,key,ticket,disk)=persistence{self.writes.enqueue(data,key:key,ticket:ticket,disk:disk)}
                self.changed?()
                self.pump()
            }
        }
    }
}

#endif
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
    @Published private(set) var cacheMessage="封面上限 2 GB，正文不缓存"
    private var coverScope:String?,coverRevision:String?
    private var catalogPages=CatalogPageCache()
    private var catalogOwner:String?
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
    @Published private(set) var paired:PairingCode?
    @Published private(set) var serverTarget=ServerTarget.selected
    @Published private(set) var migrationMessage=""
    @Published private(set) var recentReading:RecentReading?
    private(set) var recentScope:String?
    private(set) var recentRevision=0
    @Published private(set) var locatingRecent=false
    @Published private(set) var locateMessage=""
    @Published private(set) var locatedBookID:String?
    @Published private(set) var pairingStatus="首次扫码后，将记住这台安卓"
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
    init(transport:LimitedHTTP=LimitedHTTP(),loadPair:(()throws->PairingCode?)?=nil,savePair:((PairingCode)throws->Void)?=nil,removePair:(()throws->Void)?=nil,lookup:((String)async->[String])?=nil,metadata:MetadataParser = .shared){
        let disk=CoverDiskCache();coverDisk=disk;covers=SmartCoverPipeline(disk:disk)
        self.transport=transport;self.metadata=metadata;self.loadPair=loadPair ?? {try PairingKeychain.load(account:ServerTarget.selected.rawValue)}
        self.savePair=savePair ?? {try PairingKeychain.save($0,account:ServerTarget.selected.rawValue)};self.removePair=removePair ?? {try PairingKeychain.remove(account:ServerTarget.selected.rawValue)};self.lookup=lookup
        covers.changed={[weak self] in self?.scheduleCacheStats()}
        covers.conditionalLoad={[weak self] path,etag in guard let self else{throw CancellationError()};return try await self.coverResponse(path,etag:etag)}
    }
    deinit{transport.close()}
    private func scheduleCacheStats(){
        guard coverStatsTask==nil else{return}
        coverStatsTask=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:2_000_000_000)}catch{return}
            guard let self else{return};await refreshCacheUsage();coverStatsTask=nil
        }
    }
    func refreshCacheUsage()async{
        do{let bytes=try await coverDisk.usage();guard !Task.isCancelled else{return};cacheUsage=ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.decimal)+" / 2 GB"}
        catch{if !Task.isCancelled{cacheUsage="磁盘缓存暂不可用，仍可联网加载"}}
    }
    func clearCoverCache()async{
        guard !cacheBusy else{return};cacheBusy=true;coverStatsTask?.cancel();coverStatsTask=nil
        cancelCoverPrefetch();covers.suspend(true);covers.reset()
        do{try await coverDisk.clear();cacheMessage="已清空；可见封面会按需重新缓存"}catch{cacheMessage="部分缓存无法清除，请解锁手机或稍后重试"}
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
        let changed=force || scope != coverScope || revision != coverRevision
        cancelCoverPrefetch();lastCoverAnchor=nil;coverScope=scope;diskEnabled=scope != nil
        coverRevision=revision
        let identities=Dictionary(uniqueKeysWithValues:bookIdentities.compactMap{book in book.coverIdentity.map{("/v1/books/\(book.id)/cover",$0)}})
        covers.configureScope(scope,revision:revision ?? "",identities:identities)
        if changed{coverEpoch+=1;clearPageLists()}
        pageLists.configure(catalogOwner==nil ? nil:scope.flatMap{scope in revision.map{scope+"\n"+$0}})
    }
    private func setRecent(_ recent:RecentReading?){
        guard recent != recentReading else{return};recentRevision+=1;recentReading=recent
    }
    func rememberReading(book:Book,pages:[Page],index:Int,scope:String?){
        guard let scope,scope==recentScope,pages.indices.contains(index) else{return}
        let value=RecentReading(scope:scope,book:book,pageNumber:pages[index].number,position:index,pageCount:pages.count)
        guard value.valid else{return};ReadingProgress.save(value.pageNumber,scope:scope,id:book.id);value.save();locateMessage="";setRecent(value)
    }
    func reloadReading(){setRecent(recentScope.flatMap{RecentReading.load(scope:$0)})}
    func selectServer(_ target:ServerTarget)async {
        guard target != serverTarget,!reading,!loading else{return}
        generation+=1;automatic?.cancel();automatic=nil;discovery.stop();cancelCoverPrefetch()
        // Keep credentials and disk caches for BOTH sources. Never auto-fallback.
        UserDefaults.standard.set(target.rawValue,forKey:"server.selected");serverTarget=target
        base=nil;activeToken="";paired=nil;address="";secret="";books=[];total=0;pageIndex=0
        catalogPages.clear();catalogOwner=nil;configureCoverScope(device:nil,revision:nil,force:true)
        locatedBookID=nil;locateMessage="";migrationMessage="";error=""
        do{paired=try loadPair();address=paired?.address ?? ""}catch{self.error="无法读取保存的配对，请解锁手机后重试。"}
        pairingStatus=paired==nil ? "请配对"+target.title:"正在连接"+target.title
        setForeground(foreground)
    }
    func migrateReading()async {
        guard let destination=recentScope,base != nil,!loading,
              let source=UserDefaults.standard.string(forKey:"reading.serverScope."+serverTarget.other.rawValue),source != destination else{migrationMessage="请先连接过原书库，再连接目标书库。";return}
        loading=true;let ticket=generation;defer{if generation==ticket{loading=false}}
        migrationMessage="正在核对目标清单；不会覆盖已有进度…"
        do {
            // Private, local recovery snapshot, created BEFORE any writes.
            let backup=try ProgressBackup.capture().data()
            let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ReadingBackups",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try backup.write(to:directory.appendingPathComponent("before-migration-"+UUID().uuidString+".json"),options:[.atomic,.completeFileProtection])
            let positions=ReadingProgress.positions(scope:source)
            let recent=RecentReading.load(scope:source)
            var ids=Set(positions.keys);if let recent{ids.insert(recent.book.id)}
            var matched=Set<String>(),snapshot:BookList?,recentBook:Book?
            for page in 0..<40 {
                let value=try await metadata.catalog(data("/v1/books?offset=\(page*500)&limit=500"),page:page,size:500).list
                try Task.checkCancellation();guard generation==ticket,recentScope==destination else{throw CancellationError()}
                if let snapshot{guard CatalogLocator.sameSnapshot(snapshot,value) else{throw LibraryError.unverifiedOrder}}else{snapshot=value}
                for book in value.books where ids.contains(book.id){matched.insert(book.id);if book.id==recent?.book.id{recentBook=book}}
                if (page+1)*500>=value.total{break}
            }
            // Verify the published revision once more before local commit.
            let final=try await metadata.catalog(data("/v1/books?offset=0&limit=50"),page:0,size:50).list
            try Task.checkCancellation();guard generation==ticket,recentScope==destination,let snapshot,CatalogLocator.sameSnapshot(snapshot,final),paired?.deviceId.flatMap({id in final.libraryId.map{id+"\n"+$0}})==destination else{throw LibraryError.unverifiedOrder}
            var copied=0,kept=0
            for (id,page) in positions where matched.contains(id) {
                if ReadingProgress.page(scope:destination,id:id)==0{ReadingProgress.save(page,scope:destination,id:id);copied+=1}else{kept+=1}
            }
            if let recent,let book=recentBook,RecentReading.load(scope:destination)==nil {
                let page=ReadingProgress.page(scope:destination,id:book.id)
                if page==0{ReadingProgress.save(recent.pageNumber,scope:destination,id:book.id)}
                RecentReading(scope:destination,book:book,pageNumber:page>0 ? page:recent.pageNumber,position:recent.position,pageCount:recent.pageCount).save()
            }
            reloadReading();migrationMessage="已迁移 \(copied) 本，保留目标已有 \(kept) 本；\(ids.subtracting(matched).count) 本未匹配，原记录仍保留。打开漫画时核对实际页码。"
        }catch{if generation==ticket{migrationMessage="迁移未完成；原进度未删除。请确认目标清单稳定后重试。"}}
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
        guard !coversHidden,foreground,!reading,!cacheBusy,!books.isEmpty else{return}
        let paths=CoverRules.prefetch(anchor:anchor,count:books.count,screen:coverScreenCount,direction:direction).filter{!books[$0].isMissing}.map{"/v1/books/\(books[$0].id)/cover"}
        let ticket=prefetchGeneration
        prefetchTask=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:150_000_000)}catch{return}
            guard let self,!coversHidden,ticket==prefetchGeneration,foreground,!reading,!cacheBusy else{return}
            covers.prefetch(paths){[weak self] path in guard let self else{throw CancellationError()};return try await data(path)}
        }
    }
    func setReading(_ value:Bool){reading=value;cancelCoverPrefetch();covers.suspend(value || !foreground || cacheBusy)}
    func prioritizePage(_ path:String){transport.prioritizePage(path)}
    func coverResponse(_ path:String,etag:String?)async throws->LimitedHTTP.Payload {
        guard !coversHidden else{throw CancellationError()}
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains(where:{$0.hasSuffix("-checks") || $0.hasSuffix("-demo")}){return LimitedHTTP.Payload(data:try await data(path),status:200,etag:nil)}
        #endif
        guard path.range(of:"^/v1/books/[0-9]{1,20}/cover$",options:.regularExpression) != nil,let base,let url=URL(string:path,relativeTo:base) else{throw LibraryError.unsafeAddress}
        let ticket=generation
        var request=URLRequest(url:url);request.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
        if let etag,CoverRecord.validETag(etag){request.setValue(etag,forHTTPHeaderField:"If-None-Match")}
        do {
            let result=try await transport.response(request,limit:8*1024*1024,allowNotModified:etag != nil)
            try Task.checkCancellation();guard ticket==generation else{throw CancellationError()};return result
        }catch{
            if ticket==generation,paired != nil,let network=error as? URLError,
               [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.timedOut,.cannotFindHost].contains(network.code){
                self.base=nil;pairingStatus="连接中断，正在等待书库服务恢复…"
            }
            throw error
        }
    }
    func data(_ path:String,priority:Float=URLSessionTask.defaultPriority) async throws -> Data {
        if coversHidden,path.hasSuffix("/cover"){throw CancellationError()}
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--scheduling-checks"){ReaderDemo.requests[path,default:0]+=1;return ReaderDemo.data(path)}
        if ProcessInfo.processInfo.arguments.contains("--fail-page-image"),path.contains("/pages/"){throw LibraryError.malformed}
        if ProcessInfo.processInfo.arguments.contains("--animation-checks") || ProcessInfo.processInfo.arguments.contains("--animation-demo"){ReaderDemo.requests[path,default:0]+=1;return ReaderDemo.animationData(path)}
        if ProcessInfo.processInfo.arguments.contains("--shelf-demo") || ProcessInfo.processInfo.arguments.contains("--shelf-jump-checks") {
            if path.hasPrefix("/v1/books?") {
                ReaderDemo.requests["shelf-list",default:0]+=1
                let items=URLComponents(string:"http://fixture"+path)!.queryItems!
                let offset=Int(items.first{$0.name=="offset"}!.value!)!,limit=Int(items.first{$0.name=="limit"}!.value!)!
                let books=(offset..<min(12071,offset+limit)).map{Book(id:String($0+1),title:"合成封面 · 第 \($0+1) 本",rank:$0)}
                return try JSONEncoder().encode(BookList(orderVerified:!ProcessInfo.processInfo.arguments.contains("--order-notice-demo"),total:12071,books:books,orderPolicy:"snapshot-query"))
            }
            return ReaderDemo.data(path)
        }
        if ProcessInfo.processInfo.arguments.contains("--reader-demo") || ProcessInfo.processInfo.arguments.contains("--performance-checks") || ProcessInfo.processInfo.arguments.contains("--native-pager-checks") || ProcessInfo.processInfo.arguments.contains("--rapid-pager-checks") {ReaderDemo.requests[path,default:0]+=1;return ReaderDemo.data(path)}
        #endif
        guard let base else {throw LibraryError.unsafeAddress}
        guard let url=URL(string:path,relativeTo:base) else {throw LibraryError.malformed}
        var r=URLRequest(url:url);r.setValue("Bearer "+activeToken,forHTTPHeaderField:"Authorization")
        let limit=path.hasSuffix("/cover") ? 8*1024*1024 : (path.hasSuffix("/pages") || path.hasPrefix("/v1/books?") ? 8*1024*1024 : 50*1024*1024)
        let ticket=generation
        do{return try await transport.data(r,limit:limit,priority:priority)}catch{
            if ticket==generation,paired != nil,let network=error as? URLError,
               [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.timedOut,.cannotFindHost].contains(network.code){
                self.base=nil;pairingStatus="连接中断，正在等待安卓共享恢复…"
            }
            throw error
        }
    }
    private func verify(_ code:PairingCode,at address:String)async throws->URL {
        let url=try LibraryRules.address(address)
        let nonce=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        var request=URLRequest(url:URL(string:"/v2/identity?nonce="+nonce,relativeTo:url)!);request.timeoutInterval=3
        let proof=try JSONDecoder().decode(IdentityProof.self,from:await transport.data(request,limit:2048))
        guard PairingProof.verify(proof,code:code,nonce:nonce) else{throw LibraryError.malformed};return url
    }
    private func establish(_ code:PairingCode,at address:String,ticket:Int)async throws {
        let url=try await (code.version==2 ? verify(code,at:address) : LibraryRules.address(address))
        try Task.checkCancellation();guard ticket==generation else{throw CancellationError()}
        if serverTarget == .nas {
            let request=URLRequest(url:URL(string:"/v2/health",relativeTo:url)!)
            let service=try JSONDecoder().decode(ReaderService.self,from:await transport.data(request,limit:4096))
            guard service.compatible else{throw ServerFailure.incompatible}
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
        var request=URLRequest(url:URL(string:"/v1/books?offset=0&limit=\(size)",relativeTo:url)!)
        request.setValue("Bearer "+code.token,forHTTPHeaderField:"Authorization");request.timeoutInterval=8
        let validated=try await metadata.catalog(transport.data(request,limit:8*1024*1024),page:0,size:size)
        let list=validated.list
        try Task.checkCancellation();guard ticket==generation else{throw CancellationError()}
        if code.version==2 {
            let saved=PairingCode(app:"localshelf",version:2,address:address,token:code.token,deviceId:code.deviceId)
            try savePair(saved);paired=saved;pairingStatus="已连接"+serverTarget.title+" · 下次自动连接"
        }else {pairingStatus="旧版临时连接：升级安卓并扫码一次，才能自动重连"}
        catalogOwner=code.version==2 ? code.deviceId:nil
        catalogPages.clear() // every verified reconnect establishes a fresh snapshot
        catalogPages.store(validated,owner:catalogOwner)
        configureCoverScope(device:code.version==2 ? code.deviceId : nil,revision:list.catalogRevision,libraryID:list.libraryId,bookIdentities:list.books,force:true);base=url;activeToken=code.token
        self.address=address;secret=code.token;books=list.books;total=list.total;pageIndex=0;error=""
        orderNotice=list.orderVerified ? "" : "列表采用备份查询顺序，同值记录位置待核对；漫画内按数字页码阅读。"
        scheduleCoverPrefetch(anchor:0)
    }
    func connect(code:PairingCode? = nil) async {
        guard !loading else{return};generation+=1;let ticket=generation;loading=true
        defer{if generation==ticket{loading=false}}
        do {
            let candidate=code ?? PairingCode(app:"localshelf",version:1,address:address.trimmingCharacters(in:.whitespacesAndNewlines),token:secret)
            let checked=try PairingCode.parse(String(decoding:JSONEncoder().encode(candidate),as:UTF8.self))
            guard checked.version==2 || paired==nil else{throw LibraryError.malformed}
            guard serverTarget == .android || checked.version==2 else{throw ServerFailure.incompatible}
            try await establish(checked,at:checked.address,ticket:ticket)
        }catch{if ticket==generation{self.error=(error as? ServerFailure)?.errorDescription ?? "连接失败或身份无法验证。请确认书库服务已开启、地址正确且两端处于同一局域网。"}}
    }
    func connect(pin:String)async{
        guard !loading else{return};generation+=1;let ticket=generation;loading=true
        defer{if generation==ticket{loading=false}}
        do{
            let host=address.trimmingCharacters(in:.whitespacesAndNewlines)
            let base=try LibraryRules.address(host)
            if serverTarget == .nas {
                do{
                    let service=try JSONDecoder().decode(ReaderService.self,from:await transport.data(URLRequest(url:URL(string:"/v2/health",relativeTo:base)!),limit:4096))
                    guard service.compatible else{throw ServerFailure.incompatible}
                }catch let error as URLError{throw error}catch{throw ServerFailure.incompatible}
            }
            var request=URLRequest(url:URL(string:"/v2/pair",relativeTo:base)!);request.httpMethod="POST"
            request.httpBody=try PairingPIN.body(pin);request.setValue("text/plain; charset=us-ascii",forHTTPHeaderField:"Content-Type");request.timeoutInterval=8
            let code=try PairingPIN.response(await transport.data(request,limit:2048),address:host)
            try Task.checkCancellation();guard generation==ticket else{return}
            try await establish(code,at:host,ticket:ticket)
        }catch{if generation==ticket{self.error=(error as? ServerFailure)?.errorDescription ?? "配对失败：请确认同一局域网、正确的阅读地址。六位码有效 5 分钟，最多尝试 5 次；失效后请在服务端生成新码。"}}
    }
    func forget(){
        do{try removePair()}catch{self.error="无法移除钥匙串配对，请解锁手机后重试。";return}
        setRecent(nil);recentScope=nil
        locatingRecent=false;locatedBookID=nil;locateMessage=""
        generation+=1;discovery.stop();paired=nil;base=nil;activeToken="";address="";secret=""
        catalogPages.clear();catalogOwner=nil
        configureCoverScope(device:nil,revision:nil,force:true);books=[];total=0;pageIndex=0;loading=false;error="";orderNotice=""
        pairingStatus="已解除当前服务器配对；阅读记录和其他服务器配对保留。撤销凭据需在服务端操作。"
    }
    func setForeground(_ foreground:Bool){
        self.foreground=foreground;cancelCoverPrefetch();covers.suspend(reading || !foreground || cacheBusy)
        if !foreground {
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
            // Check the stored endpoint on each foreground entry; never blindly send its token.
            if let saved=paired,let base {
                let ticket=generation
                do{_=try await verify(saved,at:base.absoluteString)}catch{if !Task.isCancelled,ticket==generation{self.base=nil}}
            }
            while !Task.isCancelled {
                if base==nil{await reconnect()}
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
    private func clearPageLists(){pageLists.clear();pageListEpoch+=1;pageListRequests.removeAll()}
    func trimCatalog(){catalogPages.clear();clearPageLists()}
    func invalidatePageList(_ book:String){pageLists.invalidate(book)}
    func pageList(_ book:String,force:Bool=false)async throws->Pages {
        try Task.checkCancellation()
        guard book.range(of:"^[0-9]{1,20}$",options:.regularExpression) != nil else{throw LibraryError.malformed}
        if force{pageLists.invalidate(book)}
        if !force,base != nil,let cached=pageLists.value(book){return cached}
        let ticket=generation,epoch=pageListEpoch,request=UUID()
        pageListRequests[book]=request
        defer{if pageListRequests[book]==request{pageListRequests.removeValue(forKey:book)}}
        do {
            let result=try await metadata.preparedPages(data("/v1/books/\(book)/pages"))
            try Task.checkCancellation()
            guard ticket==generation,epoch==pageListEpoch,pageListRequests[book]==request else{throw CancellationError()}
            pageLists.store(result,book:book);return result.value
        }catch{if pageListRequests[book]==request{pageLists.invalidate(book)};throw error}
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

enum AnimationLimits {
    static let compressed=16*1024*1024,reserve=40*1024*1024,maxPixels=4_000_000,maxFrames=2000
    static func delay(_ raw:Double)->Double{raw.isFinite && raw>=0.02 ? min(raw,60) : 0.1}
}

// Each prepared session owns one serial decoder; frames are never expanded in full.
actor AnimationDecoder {
    struct Info {let count:Int,plays:Int}
    private var source:CGImageSource?
    private var ticket:UUID?
    private var dictionary:CFString=kCGImagePropertyGIFDictionary
    private var delayKey:CFString=kCGImagePropertyGIFDelayTime
    private var unclampedKey:CFString=kCGImagePropertyGIFUnclampedDelayTime
    func open(_ data:Data,ticket:UUID)throws->Info{
        try Task.checkCancellation();source=nil;self.ticket=nil
        guard data.count<=AnimationLimits.compressed,
              let input=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue>0,height.doubleValue>0,width.doubleValue*height.doubleValue<=Double(AnimationLimits.maxPixels) else{throw LibraryError.malformed}
        let count=CGImageSourceGetCount(input);guard count>1,count<=AnimationLimits.maxFrames else{throw LibraryError.malformed}
        let type=CGImageSourceGetType(input) as String? ?? ""
        let loopKey:CFString
        switch type {
        case "com.compuserve.gif":dictionary=kCGImagePropertyGIFDictionary;delayKey=kCGImagePropertyGIFDelayTime;unclampedKey=kCGImagePropertyGIFUnclampedDelayTime;loopKey=kCGImagePropertyGIFLoopCount
        case "public.png":dictionary=kCGImagePropertyPNGDictionary;delayKey=kCGImagePropertyAPNGDelayTime;unclampedKey=kCGImagePropertyAPNGUnclampedDelayTime;loopKey=kCGImagePropertyAPNGLoopCount
        case "org.webmproject.webp":dictionary=kCGImagePropertyWebPDictionary;delayKey=kCGImagePropertyWebPDelayTime;unclampedKey=kCGImagePropertyWebPUnclampedDelayTime;loopKey=kCGImagePropertyWebPLoopCount
        default:throw LibraryError.malformed
        }
        let global=CGImageSourceCopyProperties(input,nil) as? [CFString:Any]
        let animation=global?[dictionary] as? [CFString:Any]
        let loops=(animation?[loopKey] as? NSNumber)?.intValue
        // ImageIO already normalizes GIF repetitions into total plays.
        let plays=loops.map{$0==0 ? 0 : max(1,$0)} ?? 1
        try Task.checkCancellation();source=input;self.ticket=ticket
        return Info(count:count,plays:plays)
    }
    func frame(_ index:Int,ticket:UUID)throws->(UIImage,Double){
        try Task.checkCancellation()
        guard self.ticket==ticket,let source,index>=0,index<CGImageSourceGetCount(source) else{throw CancellationError()}
        return try autoreleasepool {
            guard let properties=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any],
                  let cg=CGImageSourceCreateThumbnailAtIndex(source,index,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceShouldCache:false,kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
                  cg.bytesPerRow*cg.height<=5*1024*1024 else{throw LibraryError.malformed}
            let values=properties[dictionary] as? [CFString:Any]
            let delay=(values?[unclampedKey] as? NSNumber)?.doubleValue ?? (values?[delayKey] as? NSNumber)?.doubleValue ?? 0.1
            try Task.checkCancellation();return (UIImage(cgImage:cg),AnimationLimits.delay(delay))
        }
    }
    func close(_ ticket:UUID){if self.ticket==ticket{source=nil;self.ticket=nil}}
}

final class PreparedAnimation {
    let data:Data
    let decoder:AnimationDecoder,ticket:UUID,info:AnimationDecoder.Info
    let first:(UIImage,Double),second:(UIImage,Double)
    let cost:Int
    private init(data:Data,decoder:AnimationDecoder,ticket:UUID,info:AnimationDecoder.Info,first:(UIImage,Double),second:(UIImage,Double),cost:Int){self.data=data;self.decoder=decoder;self.ticket=ticket;self.info=info;self.first=first;self.second=second;self.cost=cost}
    static func make(_ data:Data)async throws->PreparedAnimation{
        let decoder=AnimationDecoder(),ticket=UUID()
        let info=try await decoder.open(data,ticket:ticket)
        let first=try await decoder.frame(0,ticket:ticket),second=try await decoder.frame(1,ticket:ticket)
        try Task.checkCancellation()
        let cost=data.count+[first.0,second.0].reduce(0){$0+($1.cgImage.map{$0.bytesPerRow*$0.height} ?? 0)}
        return PreparedAnimation(data:data,decoder:decoder,ticket:ticket,info:info,first:first,second:second,cost:cost)
    }
    func frame(_ index:Int)async throws->(UIImage,Double){
        try Task.checkCancellation()
        if index==0{return first};if index==1{return second}
        return try await decoder.frame(index,ticket:ticket)
    }
}

@MainActor final class AnimationPreheater {
    private struct Job {let id:UUID,reserved:Int,data:Data,task:Task<PreparedAnimation,Error>}
    private var ready:[Int:PreparedAnimation]=[:]
    private var staged:[Int:Data]=[:]
    private var jobs:[Int:Job]=[:]
    private var order:[Int]=[]
    private var failed=Set<Int>()
    private let budget=AnimationLimits.reserve-10*1024*1024 // two live playback frames
    var changed:(()->Void)?
    var used:Int{ready.values.reduce(0){$0+$1.cost}+jobs.values.reduce(0){$0+$1.reserved}+staged.values.reduce(0){$0+$1.count}}
    func value(_ number:Int)->PreparedAnimation?{ready[number]}
    func configure(_ order:[Int]){
        self.order=Array(order.prefix(3))
        failed=failed.intersection(self.order)
        for key in Set(ready.keys).union(jobs.keys).union(staged.keys) where !self.order.contains(key){remove(key)}
    }
    private func remove(_ key:Int){ready.removeValue(forKey:key);staged.removeValue(forKey:key);jobs.removeValue(forKey:key)?.task.cancel()}
    private func makeRoom(_ bytes:Int,for number:Int){
        guard let rank=order.firstIndex(of:number) else{return}
        let lower=order.reversed().filter{order.firstIndex(of:$0)!>rank}
        // Cancel speculative decoding before discarding downloaded bytes. Completion
        // tickets prevent demoted jobs from restoring their old session afterwards.
        for key in lower where used-(staged[number]?.count ?? 0)+bytes>budget {
            if let data=jobs[key]?.data ?? ready[key]?.data{remove(key);staged[key]=data}
        }
        for key in lower where used-(staged[number]?.count ?? 0)+bytes>budget{remove(key)}
    }
    private func stage(_ number:Int,_ data:Data)->Bool{
        makeRoom(data.count,for:number)
        guard used-(staged[number]?.count ?? 0)+data.count<=budget else{return false}
        staged[number]=data;return true
    }
    func clear(){configure([])}
    @discardableResult func offer(_ number:Int,data:Data)->Bool{
        guard order.contains(number),!failed.contains(number),data.count<=AnimationLimits.compressed else{return false}
        if ready[number] != nil || jobs[number] != nil{return true}
        // Only one speculative decode at a time; current-page demand may run alongside it.
        if number != order.first && jobs.keys.contains(where:{$0 != order.first}){return stage(number,data)}
        let reserve=data.count+10*1024*1024
        makeRoom(reserve,for:number)
        guard used-(staged[number]?.count ?? 0)+reserve<=budget else{return stage(number,data)}
        staged.removeValue(forKey:number)
        let id=UUID()
        let task=Task(priority:number==order.first ? .userInitiated : .utility){try await PreparedAnimation.make(data)}
        jobs[number]=Job(id:id,reserved:reserve,data:data,task:task)
        Task{[weak self] in
            let result=await task.result
            guard let self,self.jobs[number]?.id==id else{return}
            self.jobs.removeValue(forKey:number)
            if case .success(let session)=result,self.order.contains(number){self.ready[number]=session}
            if case .failure=result{self.failed.insert(number)}
            for key in self.order{if let data=self.staged[key]{self.offer(key,data:data)}}
            self.changed?()
        }
        return true
    }
    func obtain(_ number:Int,load:()async throws->Data)async throws->PreparedAnimation{
        if let session=ready[number]{return session}
        if let job=jobs[number]{let value=try await job.task.value;try Task.checkCancellation();return value}
        let data:Data
        if let saved=staged[number]{data=saved}else{data=try await load()}
        try Task.checkCancellation()
        guard offer(number,data:data) else{throw CancellationError()}
        if let session=ready[number]{return session}
        guard let job=jobs[number] else{throw CancellationError()}
        let session=try await job.task.value;try Task.checkCancellation();return session
    }
    deinit{for job in jobs.values{job.task.cancel()}}
}

@MainActor final class AnimatedPagePlayer {
    private var task:Task<Void,Never>?
    private var ticket=UUID()
    private(set) var key:String?
    #if DEBUG && targetEnvironment(simulator)
    private(set) var displayedFrames=0
    private(set) var playbackStarts=0
    #endif
    func play(key:String,prepared:PreparedAnimation?=nil,prepare:(()async throws->PreparedAnimation)?=nil,load:@escaping()async throws->Data,display:@escaping(UIImage)->Void,failed:@escaping()->Void){
        guard self.key != key else{return};stop();self.key=key
        #if DEBUG && targetEnvironment(simulator)
        playbackStarts+=1
        #endif
        let ticket=self.ticket
        let shownAt=prepared.map{session in display(session.first.0);return ContinuousClock.now}
        task=Task{[weak self] in
            do{
                let session:PreparedAnimation
                if let prepared{session=prepared}else if let prepare{session=try await prepare()}else{session=try await PreparedAnimation.make(try await load())}
                let info=session.info
                let buffer=PlaybackFrameBuffer(session:session)
                await buffer.start()
                defer{Task{await buffer.stop()}}
                var index=0,plays=0
                var frame=session.first,initial=true
                while !Task.isCancelled {
                    guard self?.ticket==ticket else{throw CancellationError()}
                    if !initial || shownAt==nil{display(frame.0)}
                    await buffer.didDisplay()
                    #if DEBUG && targetEnvironment(simulator)
                    self?.displayedFrames+=1
                    #endif
                    let deadline=(initial ? shownAt ?? .now : .now).advanced(by:.seconds(frame.1));initial=false
                    index+=1
                    if index==info.count{index=0;plays+=1;if info.plays>0 && plays>=info.plays{break}}
                    try await Task.sleep(until:deadline,clock:.continuous)
                    frame=try await buffer.next()
                }
            }catch{if !Task.isCancelled,self?.ticket==ticket{failed()}}
        }
    }
    func stop(){ticket=UUID();task?.cancel();task=nil;key=nil}
    deinit{task?.cancel()}
}

@MainActor final class ReadingCache:ObservableObject {
    let animationPreheater=AnimationPreheater()
    private var warmOrder:[Int]=[]
    private var travelDirection=1
    init(){animationPreheater.changed={[weak self] in self?.warmAnimations()}}
    func warmAnimations(){
        guard canAnimate,detailNumber==nil else{animationPreheater.clear();return}
        animationPreheater.configure(warmOrder)
        for number in warmOrder where animated.contains(number){if let data=raw[number]{animationPreheater.offer(number,data:data)}}
    }
    func preparedAnimation(_ number:Int)->PreparedAnimation?{animationPreheater.value(number)}
    func prepareAnimation(_ number:Int)async throws->PreparedAnimation{
        guard canAnimate,warmOrder.contains(number) else{throw CancellationError()}
        animationPreheater.configure([number]+warmOrder.filter{$0 != number})
        return try await animationPreheater.obtain(number){[weak self] in guard let self else{throw CancellationError()};return try await self.pageData(number,path:"/v1/books/\(self.bookID)/pages/\(number)")}
    }
    @Published private(set) var images:[Int:UIImage]=[:]
    @Published private(set) var failed:Set<Int>=[]
    @Published private(set) var animated:Set<Int>=[]
    @Published private(set) var animationPaused=false
    @Published private(set) var animationMessage=""
    @Published private(set) var animationForeground=true
    var canAnimate:Bool{!reducedMemory && !animationPaused && animationForeground}
    private var animationReserve:Int{canAnimate && detailNumber==nil && warmOrder.contains(where:{animated.contains($0)}) ? AnimationLimits.reserve : 0}
    func setAnimationForeground(_ value:Bool){animationForeground=value;warmAnimations();enforceBudget()}
    func toggleAnimation(){animationPaused.toggle();animationMessage="";warmAnimations();enforceBudget()}
    func animationFailed(){animationPaused=true;animationPreheater.clear();animationMessage="动图暂无法播放（编码不支持或超过 16 MiB / 400 万像素 / 2000 帧限额），已显示静态预览";enforceBudget()}
    func animationData(_ number:Int)async throws->Data{
        guard current==number,canAnimate,animated.contains(number) else{throw CancellationError()}
        let data=try await pageData(number,path:"/v1/books/\(bookID)/pages/\(number)")
        try Task.checkCancellation();guard current==number,canAnimate else{throw CancellationError()};return data
    }
    private var pending:[Int:(UUID,Task<Void,Never>)]=[:]
    private var desired:[Int]=[]
    private var source:Library?
    private var bookID=""
    @Published private(set) var reducedMemory=false
    private var raw:[Int:Data]=[:]
    private var transfers:[Int:(UUID,Task<Data,Error>)]=[:]
    private var omitted=Set<Int>()
    private var current:Int? {desired.first}
    #if DEBUG && targetEnvironment(simulator)
    var retainedBytes:Int {images.values.reduce(0){$0+cost($1)}+cost(detailImage)+raw.values.reduce(0){$0+$1.count}+animationReserve}
    var pendingPages:Set<Int>{Set(pending.keys)}
    #endif
    private func cost(_ image:UIImage?)->Int {guard let cg=image?.cgImage else{return 0};return cg.bytesPerRow*cg.height}
    private func enforceBudget(){
        let limit=(reducedMemory ? ReadingBudget.pressure : ReadingBudget.normal)-animationReserve
        let rawKeep=ReadingBudget.keep(costs:raw.mapValues{$0.count},priority:desired,available:ReadingBudget.compressed)
        raw=raw.filter{rawKeep.contains($0.key)}
        var used=current.flatMap{images[$0]}.map{cost($0)} ?? 0
        if cost(detailImage)+used>limit{detailImage=nil;detailFailed=true}
        used+=cost(detailImage)
        let keepRaw=ReadingBudget.keep(costs:raw.mapValues{$0.count},priority:desired,available:limit-used)
        raw=raw.filter{keepRaw.contains($0.key)};used+=raw.values.reduce(0){$0+$1.count}
        let neighbors=Array(desired.dropFirst())
        let keep=ReadingBudget.keep(costs:images.mapValues{cost($0)},priority:neighbors,available:limit-used)
        for number in images.keys where number != current && !keep.contains(number){omitted.insert(number)}
        images=images.filter{$0.key==current || keep.contains($0.key)}
    }
    private func pageData(_ number:Int,path:String)async throws->Data {
        try Task.checkCancellation()
        if let data=raw[number]{return data}
        if let existing=transfers[number]{return try await existing.1.value}
        guard let source else{throw CancellationError()}
        let priority=number==current ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        let ticket=UUID(),task=Task{try await source.data(path,priority:priority)}
        transfers[number]=(ticket,task)
        do {
            let data=try await task.value
            guard transfers[number]?.0==ticket,desired.contains(number) else{throw CancellationError()}
            transfers.removeValue(forKey:number)
            if data.count<=ReadingBudget.compressed{raw[number]=data;enforceBudget()}
            return data
        }catch{if transfers[number]?.0==ticket{transfers.removeValue(forKey:number)};throw error}
    }
    func memoryPressure(){
        reducedMemory=true;animationPreheater.clear();source?.covers.trim();clearDetail();raw.removeAll();omitted.removeAll()
        for (_,task) in transfers.values{task.cancel()};transfers.removeAll()
        for (_,task) in pending.values{task.cancel()};pending.removeAll()
        desired=Array(desired.prefix(1));images=images.filter{$0.key==current && cost($0.value)<=ReadingBudget.pressure};failed=failed.intersection(Set(desired));pump()
    }
    func restorePrefetch(){reducedMemory=false;omitted.removeAll()}
    @Published private(set) var detailImage:UIImage?
    @Published private(set) var detailNumber:Int?
    @Published private(set) var detailLoading=false
    @Published private(set) var detailFailed=false
    private var detailTask:Task<Void,Never>?
    private var detailTicket=UUID()
    func loadDetail(_ number:Int){
        guard !animated.contains(number) else{return}
        animationPreheater.clear()
        guard source != nil,desired.contains(number) else{return}
        if detailNumber==number && (detailLoading || detailImage != nil){return}
        clearDetail();detailNumber=number;detailLoading=true
        let ticket=detailTicket,path="/v1/books/\(bookID)/pages/\(number)"
        detailTask=Task{[weak self] in
            do {
                guard let self else{throw CancellationError()}
                let data=try await self.pageData(number,path:path);try Task.checkCancellation()
                let detailLimit=self.reducedMemory ? 2048 : 4096
                let decoded=try await PageDecodeQueue.shared.decode(key:path){
                    guard let input=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                          let properties=CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any],
                          let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let h=properties[kCGImagePropertyPixelHeight] as? NSNumber else{throw LibraryError.malformed}
                    let limit=min(detailLimit,PagingRules.detailPixelLimit(width:w.doubleValue,height:h.doubleValue))
                    guard let cg=CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:limit,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
                    return (UIImage(cgImage:cg),false)
                }
                try Task.checkCancellation()
                guard self.detailTicket==ticket else{return}
                self.detailImage=decoded.0;self.enforceBudget()
            }catch{
                guard let self,self.detailTicket==ticket else{return}
                self.detailFailed = !Task.isCancelled
            }
            guard let self,self.detailTicket==ticket else{return}
            self.detailLoading=false;self.detailTask=nil
        }
    }
    func clearDetail(){detailTicket=UUID();detailTask?.cancel();detailTask=nil;detailImage=nil;detailNumber=nil;detailLoading=false;detailFailed=false}
    func update(library:Library,book:String,pages:[Page],index:Int){
        let oldCurrent=current
        if !pages.indices.contains(index) || detailNumber != pages[index].number {clearDetail()}
        source=library;bookID=book
        if let oldCurrent,let oldIndex=pages.firstIndex(where:{$0.number==oldCurrent}),oldIndex != index{travelDirection=index>oldIndex ? 1 : -1}
        desired=PagingRules.prefetchIndices(current:index,count:pages.count,direction:travelDirection).map{pages[$0].number}
        if let current {
            let path="/v1/books/\(book)/pages/\(current)"
            library.prioritizePage(path);PageDecodeQueue.shared.prioritize(path)
        }
        warmOrder=[index,index+travelDirection,index-travelDirection].filter{pages.indices.contains($0)}.map{pages[$0].number}
        if reducedMemory{desired=Array(desired.prefix(1))}
        if current != oldCurrent{omitted.removeAll();animationPaused=false;animationMessage=""}
        let keep=Set(desired)
        for key in Array(transfers.keys) where !keep.contains(key){transfers.removeValue(forKey:key)?.1.cancel()}
        raw=raw.filter{keep.contains($0.key)}
        for key in Array(pending.keys) where !keep.contains(key){pending.removeValue(forKey:key)?.1.cancel()}
        images=images.filter{keep.contains($0.key)};failed=failed.intersection(keep)
        animated=animated.intersection(keep)
        warmAnimations();enforceBudget();pump()
    }
    private func pump(){
        guard source != nil else{return}
        for number in desired where images[number]==nil{if let session=animationPreheater.value(number){images[number]=session.first.0}}
        enforceBudget()
        // A newly demanded page must not wait for both speculative jobs. Keep
        // the closer neighbor and cancel only the lowest-priority occupied slot.
        if let current,images[current]==nil,pending[current]==nil,!failed.contains(current),pending.count>=(reducedMemory ? 1 : 2),
           let victim=desired.reversed().first(where:{$0 != current && pending[$0] != nil}) {
            pending.removeValue(forKey:victim)?.1.cancel()
            transfers.removeValue(forKey:victim)?.1.cancel()
        }
        // Two requests at most; current page gets the first slot, then nearest neighbors.
        for number in desired where pending.count<(reducedMemory ? 1 : 2) && images[number]==nil && pending[number]==nil && !failed.contains(number) && !omitted.contains(number){
            let id=UUID(),path="/v1/books/\(bookID)/pages/\(number)"
            let task=Task{[weak self] in
                do {
                    guard let self else{throw CancellationError()}
                    let data=try await self.pageData(number,path:path);try Task.checkCancellation()
                    let previewLimit=self.reducedMemory ? 1536 : 2048
                    let decoded=try await PageDecodeQueue.shared.decode(key:path){
                        guard let input=CGImageSourceCreateWithData(data as CFData,nil),
                              let cg=CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:previewLimit,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
                        let type=CGImageSourceGetType(input) as String? ?? ""
                        let animated=CGImageSourceGetCount(input)>1 && ["com.compuserve.gif","public.png","org.webmproject.webp"].contains(type)
                        return (UIImage(cgImage:cg),animated)
                    }
                    try Task.checkCancellation()
                    guard self.pending[number]?.0==id else{return}
                    guard self.cost(decoded.0)<=(self.reducedMemory ? ReadingBudget.pressure : ReadingBudget.normal) else{throw LibraryError.malformed}
                    if decoded.1{self.animated.insert(number)}
                    if decoded.1,self.canAnimate,self.warmOrder.contains(number){self.animationPreheater.offer(number,data:data)}
                    self.images[number]=decoded.0;self.enforceBudget()
                }catch{
                    guard let self,self.pending[number]?.0==id else{return}
                    if !Task.isCancelled{self.failed.insert(number);self.source?.invalidatePageList(self.bookID)}
                }
                guard let self,self.pending[number]?.0==id else{return}
                self.pending.removeValue(forKey:number);self.pump()
            }
            pending[number]=(id,task)
        }
    }
    func retry(_ number:Int){failed.remove(number);pump()}
    func clear(){animationPreheater.clear();warmOrder=[];clearDetail();for (_,task) in pending.values{task.cancel()};for (_,task) in transfers.values{task.cancel()};transfers.removeAll();raw.removeAll();omitted.removeAll();pending.removeAll();desired=[];images.removeAll();failed.removeAll();animated.removeAll();animationPaused=false;animationMessage="";source=nil;reducedMemory=false}
}

// Fixed fit-to-screen layout. Single taps toggle controls; no zoom gestures.

final class ZoomCanvas:UIView,UIScrollViewDelegate,UIGestureRecognizerDelegate {
    let scroll=UIScrollView(),picture=UIImageView()
    var zoomChanged:((Bool)->Void)?
    var tapped:((Double)->Void)?
    private var previousSize=CGSize.zero
    private var resetID = -1
    private var active=false
    private var reportedZoom=false
    override init(frame:CGRect){
        super.init(frame:frame)
        isUserInteractionEnabled=false
        backgroundColor = .black;scroll.backgroundColor = .black
        scroll.minimumZoomScale=1;scroll.maximumZoomScale=1;scroll.bouncesZoom=false
        scroll.pinchGestureRecognizer?.isEnabled=false
        scroll.showsHorizontalScrollIndicator=false;scroll.showsVerticalScrollIndicator=false
        scroll.contentInsetAdjustmentBehavior = .never;scroll.delegate=self
        scroll.panGestureRecognizer.isEnabled=false
        scroll.pinchGestureRecognizer?.isEnabled=false
        addSubview(scroll);scroll.addSubview(picture)
        picture.contentMode = .scaleToFill;picture.isAccessibilityElement=true
        picture.accessibilityLabel="漫画页面";picture.accessibilityHint="左右滑动翻页；轻点显示或隐藏工具栏；从左侧边缘向右滑返回书库"
        let singleTap=UITapGestureRecognizer(target:self,action:#selector(singleTapped(_:)))
        scroll.addGestureRecognizer(singleTap)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func configure(image:UIImage,active:Bool,resetID:Int){
        // Replacing the preview with detail must not reset the focal point or scale.
        let imageChanged=picture.image !== image
        if imageChanged{picture.image=image}
        let needsReset=self.resetID != resetID || (self.active && !active)
        if self.active != active{isUserInteractionEnabled=active}
        self.active=active
        if needsReset {
            previousSize = .zero
            self.resetID=resetID;scroll.setZoomScale(1,animated:false);report(false)
        }
        if imageChanged || needsReset{setNeedsLayout()}
    }
    override func layoutSubviews(){
        super.layoutSubviews()
        if scroll.frame != bounds{scroll.frame=bounds}
        guard bounds.width>0,bounds.height>0,let image=picture.image else{return}
        if previousSize != bounds.size || picture.bounds.size == .zero {
            previousSize=bounds.size;scroll.setZoomScale(1,animated:false)
            let factor=min(bounds.width/image.size.width,bounds.height/image.size.height)
            picture.frame=CGRect(origin:.zero,size:CGSize(width:image.size.width*factor,height:image.size.height*factor))
            scroll.contentSize=picture.bounds.size;report(false)
        }
        centerPicture()
    }
    private func centerPicture(){
        let inset=UIEdgeInsets(top:max(0,(scroll.bounds.height-picture.frame.height)/2),left:max(0,(scroll.bounds.width-picture.frame.width)/2),bottom:0,right:0)
        if scroll.contentInset != inset{scroll.contentInset=inset}
        // Insets define the fit-scale origin: zero offset would pin a reused page
        // to the top. Reapply that origin even when the inset has not changed.
        // While zoomed, preserve the user's focal point / pan position instead.
        if scroll.zoomScale<=1.0001 {
            let origin=CGPoint(x:-inset.left,y:-inset.top)
            if scroll.contentOffset != origin{scroll.setContentOffset(origin,animated:false)}
        }
    }
    private func report(_ zoomed:Bool){
        scroll.panGestureRecognizer.isEnabled=zoomed
        guard reportedZoom != zoomed else{return};reportedZoom=zoomed
        // UIKit layout can run inside updateUIView; publish after that update finishes.
        DispatchQueue.main.async{[weak self] in guard let self,self.active,self.reportedZoom==zoomed else{return};self.zoomChanged?(zoomed)}
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView?{picture}
    func scrollViewWillBeginZooming(_ scrollView:UIScrollView,with view:UIView?){report(true)}
    func scrollViewDidZoom(_ scrollView:UIScrollView){centerPicture()}
    func scrollViewDidEndZooming(_ scrollView:UIScrollView,with view:UIView?,atScale scale:CGFloat){report(scale>1.01)}
    func prioritizeEdge(_ edge:UIGestureRecognizer){
        scroll.panGestureRecognizer.require(toFail:edge)
    }
    @objc private func singleTapped(_ gesture:UITapGestureRecognizer){
        guard active else{return}
        let fraction=gesture.location(in:self).x/max(1,bounds.width)
        tapped?(scroll.zoomScale>1.01 ? 0.5 : Double(fraction))
    }
}

// Native slots persist across page changes. Dragging never writes SwiftUI state.
final class NativePageSlot:UIView {
    let canvas=ZoomCanvas()
    let spinner=UIActivityIndicatorView(style:.large)
    let retry=UIButton(type:.system)
    var position:Int?
    private var number:Int?
    private var resetGeneration=0
    var onRetry:(()->Void)?
    override init(frame:CGRect){
        super.init(frame:frame);backgroundColor = .black
        addSubview(canvas);spinner.color = .white;addSubview(spinner)
        var style=UIButton.Configuration.tinted();style.title="本页暂时无法加载";style.subtitle="点击重试 · 请确认安卓共享与 Wi-Fi"
        style.image=UIImage(systemName:"arrow.clockwise");style.imagePadding=10;style.cornerStyle = .large
        style.baseForegroundColor = .white;style.baseBackgroundColor=UIColor(white:0.12,alpha:1);retry.configuration=style
        retry.addTarget(self,action:#selector(retryTapped),for:.touchUpInside);addSubview(retry)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    @objc private func retryTapped(){onRetry?()}
    override func layoutSubviews(){
        super.layoutSubviews();canvas.frame=bounds
        spinner.center=CGPoint(x:bounds.midX,y:bounds.midY)
        let width=min(340,max(0,bounds.width-32));retry.frame=CGRect(x:(bounds.width-width)/2,y:bounds.midY-38,width:width,height:76)
    }
    func show(number:Int,image:UIImage?,failed:Bool,active:Bool,reset:Bool){
        if self.number != number || reset {resetGeneration+=1}
        self.number=number
        canvas.isHidden=image==nil
        retry.isHidden=image != nil || !failed;retry.isEnabled=active
        if let image {
            spinner.stopAnimating()
            canvas.configure(image:image,active:active,resetID:resetGeneration)
        }else{
            // Do not retain an evicted page through an invisible UIImageView.
            canvas.picture.image=nil
            if failed{spinner.stopAnimating()}else{spinner.startAnimating()}
        }
        accessibilityElementsHidden = !active
    }
}

// Stop an in-flight settle at touch-down, before UIKit's pan recognition slop.
// A tap or rejected pan resumes the held settle rather than leaving a stuck page.
final class ReaderPanGestureRecognizer:UIPanGestureRecognizer {
    var contact:((CGPoint)->Void)?
    var released:(()->Void)?
    private var origin:CGPoint?
    var initialLocation:CGPoint?{origin}
    private(set) var contactTranslation=CGPoint.zero
    private var contactRevision=0
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent){
        contactRevision+=1
        if touches.count==1,numberOfTouches==0,let touch=touches.first,let view{
            let point=touch.location(in:view);origin=point;contactTranslation = .zero;contact?(point)
        }
        super.touchesBegan(touches,with:event)
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent){updateContact(touches);super.touchesMoved(touches,with:event)}
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent){updateContact(touches);super.touchesEnded(touches,with:event);finishContact()}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent){super.touchesCancelled(touches,with:event);finishContact()}
    override func reset(){super.reset();finishContact()}
    private func updateContact(_ touches:Set<UITouch>){
        guard let origin,let touch=touches.first,let view else{return}
        let point=touch.location(in:view);contactTranslation=CGPoint(x:point.x-origin.x,y:point.y-origin.y)
    }
    private func finishContact(){
        let ticket=contactRevision
        DispatchQueue.main.async{[weak self] in guard let self,self.contactRevision==ticket else{return};self.released?()}
    }
}

// Shared edge-return policy for app-owned modal pages. Attach to that page's
// controller, never UIWindow: a sheet must not also dismiss its presenting page.
// The reader keeps its existing recognizer and animation; system file pickers
// and confirmation dialogs keep their own navigation/cancel behavior.
struct PageEdgeReturn:UIViewControllerRepresentable {
    var enabled:Bool=true
    let perform:()->Void
    func makeUIViewController(context:Context)->Controller{Controller()}
    func updateUIViewController(_ controller:Controller,context:Context){controller.enabled=enabled;controller.perform=perform;controller.attach()}
    static func dismantleUIViewController(_ controller:Controller,coordinator:()){controller.detach();controller.perform=nil}
    final class Controller:UIViewController,UIGestureRecognizerDelegate {
        var enabled=true
        var perform:(()->Void)?
        private weak var host:UIViewController?
        private let pan=ReaderPanGestureRecognizer()
        private var fired=false
        override func loadView(){view=UIView();view.backgroundColor = .clear;view.isUserInteractionEnabled=false}
        override func viewDidLoad(){
            super.viewDidLoad();pan.maximumNumberOfTouches=1;pan.delegate=self
            pan.addTarget(self,action:#selector(dragged(_:)))
        }
        override func didMove(toParent parent:UIViewController?){super.didMove(toParent:parent);if parent==nil{detach()}else{attach()}}
        override func viewDidAppear(_ animated:Bool){super.viewDidAppear(animated);attach()}
        override func viewDidLayoutSubviews(){super.viewDidLayoutSubviews();attach()}
        override func viewDidDisappear(_ animated:Bool){super.viewDidDisappear(animated);detach()}
        func attach(){
            guard isViewLoaded,view.window != nil,var owner=parent else{return}
            while let parent=owner.parent,!(owner is UINavigationController){owner=parent}
            if host !== owner{detach();host=owner;owner.view.addGestureRecognizer(pan)}
            if pan.isEnabled != enabled{pan.isEnabled=enabled}
        }
        func detach(){pan.view?.removeGestureRecognizer(pan);host=nil}
        private var canReturn:Bool{enabled && viewIfLoaded?.window != nil && host != nil && host?.presentedViewController==nil && host?.isBeingDismissed==false}
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
            guard canReturn,let surface=pan.view,PagingRules.edgeStart(x:Double(touch.location(in:surface).x),width:Double(surface.bounds.width)) else{return false}
            var target=touch.view
            while let node=target,node !== surface {
                if node is UIControl || node is UITextView{return false}
                target=node.superview
            }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool {
            guard canReturn,let surface=pan.view else{return false}
            let velocity=pan.velocity(in:surface)
            return PagingRules.edgeStart(x:Double(pan.initialLocation?.x ?? -1),width:Double(surface.bounds.width)) && velocity.x>0 && velocity.x>abs(velocity.y)*1.2
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer)->Bool {
            // No failure dependency on vertical scrolling: ordinary Form scrolling
            // begins immediately, and a horizontal return doesn't move its content.
            other.view is UIScrollView
        }
        @objc private func dragged(_ gesture:UIPanGestureRecognizer){
            if gesture.state == .began{fired=false}
            guard gesture.state == .ended,!fired,canReturn,let surface=pan.view else{return}
            let translation=pan.contactTranslation,velocity=pan.velocity(in:surface)
            guard PagingRules.edgeReturns(x:Double(translation.x),y:Double(translation.y),velocityX:Double(velocity.x),width:Double(surface.bounds.width)) else{return}
            fired=true;surface.endEditing(true);perform?()
        }
    }
}

extension View {
    func pageEdgeReturn(enabled:Bool=true,perform:@escaping()->Void)->some View {
        background(PageEdgeReturn(enabled:enabled,perform:perform).allowsHitTesting(false))
    }
}

final class NativeReadingPager:UIView,UIGestureRecognizerDelegate {
    let animationPlayer=AnimatedPagePlayer()
    let content=UIView()
    let slots=(0..<3).map{_ in NativePageSlot()}
    private(set) var index=0
    private var pages:[Page]=[]
    private weak var cache:ReadingCache?
    private var lastReset = -1
    private var previousSize=CGSize.zero
    private var offset:CGFloat=0
    private var zoomed=false
    private var animator:UIViewPropertyAnimator?
    private var settlingTarget:Int?
    private var heldTarget:Int?
    private var dragging=false
    private var dragOrigin:CGFloat=0
    let pagePan=ReaderPanGestureRecognizer()
    // A committed incoming page may play during settling, never during a tentative drag.
    private var playbackTarget:Int?
    private var playbackPosition:Int{playbackTarget ?? index}
    let edgeReturn=ReaderPanGestureRecognizer()
    #if DEBUG && targetEnvironment(simulator)
    var motionActive:Bool {animator != nil}
    private var lastPanDistance:CGFloat=0,lastPanVelocity:CGFloat=0
    override var accessibilityValue:String? {
        get {let canvas=slots.first{$0.position==index}?.canvas;return "page=\(index);zoom=\(Int((canvas?.scroll.zoomScale ?? 1)*100));native=\(!edgeReturn.isEnabled);image=\(canvas?.picture.image != nil);anim=\(animationPlayer.key ?? "none");frames=\(animationPlayer.displayedFrames);pan=\(Int(lastPanDistance)),\(Int(lastPanVelocity))"}
        set {}
    }
    #endif
    private var revision=0
    var select:((Int)->Void)?
    var zoomChanged:((Bool)->Void)?
    var toggleControls:(()->Void)?
    var returnToLibrary:(()->Void)?
    private var stride:CGFloat {bounds.width+12}
    override init(frame:CGRect){
        super.init(frame:frame);backgroundColor = .black;clipsToBounds=true
        #if DEBUG && targetEnvironment(simulator)
        isAccessibilityElement=true;accessibilityIdentifier="native-reader"
        #endif
        addSubview(content)
        edgeReturn.maximumNumberOfTouches=1;edgeReturn.delegate=self;edgeReturn.addTarget(self,action:#selector(edgeDragged(_:)));addGestureRecognizer(edgeReturn)
        pagePan.maximumNumberOfTouches=1;pagePan.delegate=self
        pagePan.addTarget(self,action:#selector(pageDragged(_:)));addGestureRecognizer(pagePan)
        pagePan.require(toFail:edgeReturn)
        pagePan.contact={[weak self] point in self?.beginContact(at:point)}
        pagePan.released={[weak self] in self?.finishContact()}
        for slot in slots{content.addSubview(slot);slot.canvas.prioritizeEdge(edgeReturn)}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool {
        if gestureRecognizer===pagePan {
            let v=pagePan.velocity(in:self)
            return canDrag && abs(v.x)>abs(v.y)*1.5
        }
        guard gestureRecognizer===edgeReturn else{return true}
        let v=edgeReturn.velocity(in:self)
        return PagingRules.edgeStart(x:Double(edgeReturn.initialLocation?.x ?? -1),width:Double(bounds.width)) && v.x>0 && v.x>abs(v.y)*1.2
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
        guard gestureRecognizer===pagePan || gestureRecognizer===edgeReturn else{return true}
        if gestureRecognizer===edgeReturn,!PagingRules.edgeStart(x:Double(touch.location(in:self).x),width:Double(bounds.width)){return false}
        var view=touch.view
        while let current=view,current !== self{if current is UIControl{return false};view=current.superview}
        return true
    }
    private var canDrag:Bool {
        guard !zoomed,!pages.isEmpty,bounds.width>0 else{return false}
        let scroll=slots.first{$0.position==index}?.canvas.scroll
        return (scroll?.zoomScale ?? 1)<=1.01 && scroll?.isZooming != true
    }
    @objc private func pageDragged(_ gesture:UIPanGestureRecognizer){
        // Include UIKit's recognition slop in the actual finger travel. Otherwise
        // a real 34pt flick may be reported as just 8pt and incorrectly rejected.
        let p=pagePan.contactTranslation,v=gesture.velocity(in:self)
        switch gesture.state {
        case .began:beginDrag();if dragging{drag(CGSize(width:p.x,height:p.y),ended:false)}
        case .changed:if dragging{drag(CGSize(width:p.x,height:p.y),ended:false)}
        case .ended:if dragging{drag(CGSize(width:p.x,height:p.y),ended:true,velocityX:v.x)}
        case .cancelled,.failed:if dragging{dragging=false;settle(target:index)}else{finishContact()}
        default:break
        }
    }
    func beginContact(at point:CGPoint){
        guard canDrag,!PagingRules.edgeStart(x:Double(point.x),width:Double(bounds.width)),animator != nil else{return}
        captureMotion()
    }
    func finishContact(){
        guard !dragging,animator==nil,let target=heldTarget else{return}
        guard canDrag else{cancelMotion();return}
        heldTarget=nil;settle(target:target)
    }
    private func captureMotion(){
        guard let motion=animator else{return}
        let visible=content.layer.presentation()?.affineTransform().tx ?? offset
        let target=settlingTarget
        revision+=1;motion.stopAnimation(true);animator=nil;settlingTarget=nil
        offset=visible;heldTarget=target
        UIView.performWithoutAnimation{content.transform=CGAffineTransform(translationX:visible,y:0)}
    }
    func beginDrag(){
        guard canDrag else{return}
        captureMotion();heldTarget=nil;dragging=true
        // Rebase to the page nearest the viewport while preserving every visible
        // pixel's screen position. The next gesture can now continue another page.
        let nearest=PagingRules.index(index+Int((-offset/stride).rounded()),count:pages.count)
        let old=index
        index=nearest;offset+=CGFloat(nearest-old)*stride;playbackTarget=nil
        UIView.performWithoutAnimation{
            content.transform=CGAffineTransform(translationX:offset,y:0);render(reset:false);layoutIfNeeded()
        }
        let edge=(index==0 && offset>0)||(index==pages.count-1 && offset<0)
        dragOrigin=edge ? offset/0.18 : offset
        if nearest != old{select?(nearest)}
    }
    @objc private func edgeDragged(_ gesture:UIPanGestureRecognizer){
        if gesture.state == .began{cancelMotion()}
        finishEdgeReturn(translation:edgeReturn.contactTranslation,velocity:gesture.velocity(in:self),ended:gesture.state == .ended)
    }
    func finishEdgeReturn(translation:CGPoint,velocity:CGPoint,ended:Bool){
        guard ended,PagingRules.edgeReturns(x:Double(translation.x),y:Double(translation.y),velocityX:Double(velocity.x),width:Double(bounds.width)) else{return}
        cancelMotion();returnToLibrary?()
    }
    func configure(cache:ReadingCache,pages:[Page],index:Int,resetID:Int){
        if self.cache !== cache{cancelMotion(restorePlayback:false);stopAnimationPlayback()}
        self.cache=cache
        let changed=self.index != index || !self.pages.elementsEqual(pages,by:{$0.number==$1.number})
        let reset=lastReset != resetID || changed
        if reset {cancelMotion(restorePlayback:false);zoomed=false}
        self.index=index;self.pages=pages;lastReset=resetID
        render(reset:reset)
    }
    override func layoutSubviews(){
        super.layoutSubviews()
        if previousSize != bounds.size {
            previousSize=bounds.size;cancelMotion()
            content.bounds=CGRect(origin:.zero,size:bounds.size);content.center=CGPoint(x:bounds.midX,y:bounds.midY)
            render(reset:true)
        }
    }
    private func render(reset:Bool){
        guard let cache,!pages.isEmpty,pages.indices.contains(index) else{return}
        let wanted=Set(max(0,index-1)..<min(pages.count,index+2))
        for slot in slots where !wanted.contains(slot.position ?? -1){slot.position=nil;slot.isHidden=true;slot.canvas.picture.image=nil}
        for position in wanted.sorted(){
            guard let slot=slots.first(where:{$0.position==position}) ?? slots.first(where:{$0.position==nil}) else{continue}
            slot.position=position;slot.isHidden=false
            slot.frame=CGRect(x:CGFloat(position-index)*stride,y:0,width:bounds.width,height:bounds.height)
            let number=pages[position].number
            let playing=position==playbackPosition && animationPlayer.key=="\(number)" && cache.canAnimate
            let image=(playing ? slot.canvas.picture.image : nil) ?? (cache.detailNumber==number ? cache.detailImage : nil) ?? cache.images[number] ?? cache.preparedAnimation(number)?.first.0
            slot.show(number:number,image:image,failed:cache.failed.contains(number),active:position==index,reset:reset)
            slot.onRetry={[weak cache] in cache?.retry(number)}
            slot.canvas.tapped={[weak self] fraction in
                guard let self,self.index==position,self.animator==nil else{return}
                self.toggleControls?()
            }
            slot.canvas.zoomChanged={[weak self] value in
                guard let self,self.index==position else{return}
                self.zoomed=value;if value{self.cancelMotion()};self.zoomChanged?(value)
            }
        }
        updateAnimationPlayback()
    }
    func updateAnimationPlayback(){
        let position=playbackPosition
        guard let cache,pages.indices.contains(position),cache.canAnimate,
              cache.animated.contains(pages[position].number),let slot=slots.first(where:{$0.position==position}),
              slot.canvas.picture.image != nil else{animationPlayer.stop();return}
        let number=pages[position].number
        animationPlayer.play(key:"\(number)",prepared:cache.preparedAnimation(number),prepare:{[weak cache] in guard let cache else{throw CancellationError()};return try await cache.prepareAnimation(number)},load:{[weak cache] in guard let cache else{throw CancellationError()};return try await cache.animationData(number)},display:{[weak self,weak slot] image in
            guard let self,let slot,self.playbackPosition==position,slot.position==position,
                  self.pages.indices.contains(position),self.pages[position].number==number else{return}
            // Replace pixels directly; no SwiftUI state, layout or zoom reset per frame.
            slot.canvas.picture.image=image
        },failed:{[weak cache] in if cache?.canAnimate==true{cache?.animationFailed()}})
    }
    func stopAnimationPlayback(){animationPlayer.stop()}
    func endPresentation(){cancelMotion(restorePlayback:false);stopAnimationPlayback()}
    func drag(_ translation:CGSize,ended:Bool,velocityX:CGFloat=0){
        guard canDrag else{return}
        if !dragging{beginDrag()}
        let x=dragOrigin+translation.width
        let edge=(index==0 && x>0)||(index==pages.count-1 && x<0)
        offset=edge ? x*0.18 : min(stride,max(-stride,x))
        content.transform=CGAffineTransform(translationX:offset,y:0)
        if ended{
            dragging=false
            #if DEBUG && targetEnvironment(simulator)
            lastPanDistance=translation.width;lastPanVelocity=velocityX
            #endif
            let step=PagingRules.swipeStep(x:Double(translation.width),y:0,width:Double(bounds.width),velocityX:Double(velocityX))
            settle(target:PagingRules.index(index+step,count:pages.count),velocityX:velocityX)
        }
    }
    func settle(target:Int,animated:Bool=true,velocityX:CGFloat=0){
        guard !pages.isEmpty else{return}
        captureMotion();heldTarget=nil;dragging=false
        let target=PagingRules.index(target,count:pages.count)
        let destination = -CGFloat(target-index)*stride
        if destination==offset && target==index{playbackTarget=nil;updateAnimationPlayback();return}
        let ticket=revision
        let complete:()->Void = {[weak self] in
            guard let self,self.revision==ticket else{return}
            self.animator=nil;self.settlingTarget=nil
            let changed=self.index != target;self.index=target;self.playbackTarget=nil;self.offset=0
            UIView.performWithoutAnimation{
                self.content.transform = .identity;self.render(reset:changed);self.layoutIfNeeded()
            }
            if changed{self.zoomed=false;self.zoomChanged?(false);self.select?(target)}
        }
        if !animated || UIAccessibility.isReduceMotionEnabled{complete();return}
        var duration=min(0.26,max(0.16,Double(abs(destination-offset)/max(1,stride))*0.26))
        if velocityX.isFinite,(destination-offset)*velocityX>0,abs(velocityX)>650{duration=min(duration,max(0.10,Double(abs(destination-offset)/min(4000,abs(velocityX)))))}
        let motion=UIViewPropertyAnimator(duration:duration,controlPoint1:CGPoint(x:0.22,y:1),controlPoint2:CGPoint(x:0.36,y:1))
        animator=motion;settlingTarget=target
        playbackTarget=target != index ? target : nil;updateAnimationPlayback()
        motion.addAnimations{[weak self] in self?.content.transform=CGAffineTransform(translationX:destination,y:0)}
        motion.addCompletion{_ in complete()}
        motion.startAnimation()
    }
    func cancelMotion(restorePlayback:Bool=true){
        revision+=1;animator?.stopAnimation(true);animator=nil;offset=0;content.transform = .identity
        settlingTarget=nil;heldTarget=nil;dragging=false;dragOrigin=0
        if playbackTarget != nil{playbackTarget=nil;stopAnimationPlayback();if restorePlayback{updateAnimationPlayback()}}
    }
    func dispose(){
        stopAnimationPlayback()
        cancelMotion(restorePlayback:false);cache=nil;select=nil;zoomChanged=nil;toggleControls=nil;returnToLibrary=nil
        for slot in slots {
            slot.canvas.zoomChanged=nil;slot.canvas.tapped=nil
            slot.canvas.picture.image=nil;slot.onRetry=nil
        }
    }
}

// Keep the previous threshold-based edge return. Disable competing system pops
// only while reading; restore their original state when leaving the reader.
final class NativeReaderController:UIViewController {
    let pager=NativeReadingPager()
    private weak var edge:UIGestureRecognizer?
    private var savedEnabled=false
    private weak var contentPop:UIGestureRecognizer?
    private var contentEnabled=false
    var readingChanged:((Bool)->Void)?
    var releaseCache:(()->Void)?
    override func loadView(){view=pager}
    override func viewDidAppear(_ animated:Bool){
        super.viewDidAppear(animated);installEdge();readingChanged?(true)
    }
    override func viewWillDisappear(_ animated:Bool){
        super.viewWillDisappear(animated)
        pager.endPresentation()
    }
    override func viewDidDisappear(_ animated:Bool){
        super.viewDidDisappear(animated)
        if transitionCoordinator?.isCancelled != true{restoreEdge()}
    }
    func installEdge(){
        guard let nav=navigationController,let top=nav.topViewController,
              nav.viewControllers.count>1,let gesture=nav.interactivePopGestureRecognizer else{return}
        var ancestor:UIViewController?=self
        while let current=ancestor,current !== top{ancestor=current.parent}
        guard ancestor === top else{return}
        if edge !== gesture {
            restoreEdge();edge=gesture;savedEnabled=gesture.isEnabled
            if #available(iOS 26.0,*) {
                contentPop=nav.interactiveContentPopGestureRecognizer
                contentEnabled=contentPop?.isEnabled ?? false
            }
        }
        gesture.isEnabled=false;contentPop?.isEnabled=false
        pager.edgeReturn.isEnabled=true
    }
    func restoreEdge(){
        if let edge {
            edge.isEnabled=savedEnabled
        }
        contentPop?.isEnabled=contentEnabled
        edge=nil;contentPop=nil
        pager.edgeReturn.isEnabled=true
    }
    func dispose(){restoreEdge();pager.dispose();releaseCache?();releaseCache=nil;readingChanged=nil}
}

struct ReadingPager:UIViewControllerRepresentable {
    @ObservedObject var cache:ReadingCache
    let pages:[Page]
    @Binding var index:Int
    @Binding var zoomed:Bool
    let resetID:Int
    let toggleControls:()->Void
    let returnToLibrary:()->Void
    let readingChanged:(Bool)->Void
    func makeUIViewController(context:Context)->NativeReaderController{let controller=NativeReaderController();updateUIViewController(controller,context:context);return controller}
    func updateUIViewController(_ controller:NativeReaderController,context:Context){
        let view=controller.pager
        controller.readingChanged=readingChanged;controller.releaseCache={[weak cache] in cache?.clear()}
        view.select={index=$0};view.zoomChanged={zoomed=$0}
        view.toggleControls=toggleControls;view.returnToLibrary=returnToLibrary
        view.configure(cache:cache,pages:pages,index:index,resetID:resetID)
    }
    static func dismantleUIViewController(_ controller:NativeReaderController,coordinator:()){controller.dispose()}
}

// A 44pt hit area: touching anywhere previews the position; release commits once.
// Keep UIKit tracking local, so scrubbing does not initiate network requests.
final class PositionControl:UIControl {
    var vertical=false
    var edgeOverlay=false
    var count=1
    private(set) var value=0
    private(set) var scrubbing=false
    private var initial=0
    var preview:((Int)->Void)?
    var commit:((Int)->Void)?
    var editing:((Bool)->Void)?
    private let rail=CALayer(),fill=CALayer(),thumb=CALayer()
    override init(frame:CGRect){
        super.init(frame:frame);isExclusiveTouch=true;isAccessibilityElement=true;accessibilityTraits=[.adjustable]
        rail.backgroundColor=UIColor(white:0.25,alpha:1).cgColor;fill.backgroundColor=UIColor(red:0.4,green:0.8,blue:0.73,alpha:1).cgColor
        thumb.backgroundColor=UIColor.white.cgColor
        for part in [rail,fill,thumb]{layer.addSublayer(part)}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func setValue(_ value:Int){guard !scrubbing else{return};self.value=PagingRules.index(value,count:count);setNeedsLayout()}
    override func layoutSubviews(){
        super.layoutSubviews()
        let length=max(0,(vertical ? bounds.height : bounds.width)-36)
        let fraction=count>1 ? CGFloat(value)/CGFloat(count-1) : 0
        let point=18+length*fraction
        CATransaction.begin();CATransaction.setDisableActions(true)
        rail.cornerRadius=2;fill.cornerRadius=2;thumb.cornerRadius=9
        if vertical {
            let center=edgeOverlay ? bounds.maxX-7:bounds.midX
            rail.frame=CGRect(x:center-1,y:18,width:2,height:length)
            fill.frame=CGRect(x:center-1,y:18,width:2,height:length*fraction)
            let width:CGFloat=scrubbing ? 8:4
            thumb.frame=CGRect(x:center-width/2,y:point-14,width:width,height:28);thumb.cornerRadius=width/2
        }else{
            rail.frame=CGRect(x:18,y:bounds.midY-2,width:length,height:4)
            fill.frame=CGRect(x:18,y:bounds.midY-2,width:length*fraction,height:4)
            thumb.frame=CGRect(x:point-9,y:bounds.midY-9,width:18,height:18)
        }
        layer.opacity=isEnabled ? 1 : 0.35
        CATransaction.commit()
        accessibilityValue="\(value+1) / \(count)"
    }
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool{
        guard super.point(inside:point,with:event) else{return false}
        // A 44pt-wide thumb target, but unused space passes cover taps through.
        guard edgeOverlay else{return true}
        return scrubbing || point.x>=bounds.maxX-16 || abs(point.y-thumb.frame.midY)<=22
    }
    func begin(at point:CGPoint){
        guard isEnabled,count>1 else{return};initial=value;scrubbing=true;editing?(true);update(at:point)
    }
    func update(at point:CGPoint){
        guard scrubbing else{return}
        value=PagingRules.sliderIndex(position:Double((vertical ? point.y : point.x)-18),length:Double((vertical ? bounds.height : bounds.width)-36),count:count)
        preview?(value);setNeedsLayout()
    }
    func finish(cancelled:Bool){
        guard scrubbing else{return};scrubbing=false
        if cancelled{value=initial;preview?(initial)}else{commit?(value)}
        editing?(false);setNeedsLayout()
    }
    override func beginTracking(_ touch:UITouch,with event:UIEvent?)->Bool{begin(at:touch.location(in:self));return scrubbing}
    override func continueTracking(_ touch:UITouch,with event:UIEvent?)->Bool{update(at:touch.location(in:self));return scrubbing}
    override func endTracking(_ touch:UITouch?,with event:UIEvent?){if let touch{update(at:touch.location(in:self))};finish(cancelled:false)}
    override func cancelTracking(with event:UIEvent?){finish(cancelled:true)}
    private func adjust(_ step:Int){guard isEnabled,count>1 else{return};value=PagingRules.index(value+step,count:count);preview?(value);commit?(value);setNeedsLayout()}
    override func accessibilityIncrement(){adjust(1)}
    override func accessibilityDecrement(){adjust(-1)}
}

struct PositionSlider:UIViewRepresentable {
    @Binding var value:Double
    let count:Int
    var vertical=false
    var edgeOverlay=false
    let label:String
    var editing:(Bool)->Void={_ in}
    let commit:(Int)->Void
    func makeUIView(context:Context)->PositionControl{let view=PositionControl();updateUIView(view,context:context);return view}
    func updateUIView(_ view:PositionControl,context:Context){
        view.vertical=vertical;view.edgeOverlay=edgeOverlay;view.count=max(1,count);view.isEnabled=count>1 && context.environment.isEnabled;view.accessibilityLabel=label
        view.accessibilityIdentifier=edgeOverlay ? "shelfPositionRail":"readerPositionSlider"
        view.preview={value=Double($0)};view.commit=commit;view.editing=editing;view.setValue(Int(value));view.setNeedsLayout()
    }
    static func dismantleUIView(_ view:PositionControl,coordinator:()){view.preview=nil;view.commit=nil;view.editing=nil}
}

// Isolate drag previews from the 50–500-card shelf view's state updates.
struct ShelfPositionRail:View {
    let position:Int,total:Int,enabled:Bool
    let commit:(Int)->Void
    @State private var preview=0.0
    @State private var dragging=false
    var body:some View {
        GeometryReader{geometry in
            PositionSlider(value:$preview,count:total,vertical:true,edgeOverlay:true,label:"本页漫画定位",editing:{dragging=$0},commit:commit)
                .frame(height:max(44,min(300,geometry.size.height-32))).disabled(!enabled)
                .overlay(alignment:.trailing){if dragging{Text("本页 \(Int(preview)+1) / \(total) 本").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(ShelfTheme.accent).padding(12).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:12)).fixedSize().offset(x:-44).allowsHitTesting(false)}}
                .frame(maxHeight:.infinity)
        }.frame(width:44)
        .onAppear{preview=Double(position)}
        .onChange(of:position){_,value in if !dragging{preview=Double(value)}}
        .onChange(of:total){_,_ in if !dragging{preview=Double(PagingRules.index(position,count:total))}}
    }
}

struct Reader:View {
    @ObservedObject var library:Library
    let book:Book
    var resumePage:Int?=nil
    @State private var readingScope:String?
    @State private var pages:[Page]=[]
    @State private var index=0
    @State private var error=""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var zoomed=false
    @State private var resetID=0
    @State private var immersive=false
    @State private var scrub=0.0
    @StateObject private var cache=ReadingCache()
    @State private var pageLoadID=0
    @State private var pageLoadTicket=UUID()
    @State private var pageLoading=false
    @State private var automaticPageRefresh=false
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ReadingPager(cache:cache,pages:pages,index:$index,zoomed:$zoomed,resetID:resetID,toggleControls:{immersive.toggle()},returnToLibrary:{dismiss()},readingChanged:{library.setReading($0)})
                .ignoresSafeArea()
                .accessibilityAction(named:"显示或隐藏阅读控制"){immersive.toggle()}
                .accessibilityAction(named:"返回书库"){dismiss()}
            if pages.isEmpty && error.isEmpty{VStack(spacing:12){ProgressView();Text("正在读取页码…").font(.footnote).foregroundStyle(ShelfTheme.secondary)}.padding(20).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:16))}
            if !immersive || !error.isEmpty || (pages.indices.contains(index) && cache.failed.contains(pages[index].number)) {
                VStack(spacing:0){
                    HStack(spacing:4) {
                        Button{dismiss()}label:{Image(systemName:"chevron.left").font(.headline).frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel("返回书库")
                        Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                        Menu{
                            Button("刷新页码",systemImage:"arrow.clockwise"){automaticPageRefresh=true;pageLoadID+=1}.accessibilityIdentifier("refreshPageList").disabled(pageLoading)
                            Button("沉浸阅读",systemImage:"arrow.up.left.and.arrow.down.right"){immersive=true}
                        }label:{Image(systemName:"ellipsis").font(.headline).frame(width:44,height:44).contentShape(Rectangle())}
                            .accessibilityLabel("阅读选项").accessibilityIdentifier("readerOptions").accessibilityValue(pageLoading ? "读取中":"已刷新\(pageLoadID)次")
                    }.padding(4).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:16)).padding(.horizontal,12).padding(.top,4)
                    Spacer()
                    VStack(spacing:8){
                        if !error.isEmpty{ShelfNotice(title:"页码暂时不可用",message:error,icon:"exclamationmark.circle",actionTitle:"重试",action:{automaticPageRefresh=true;pageLoadID+=1}).disabled(pageLoading)}
                        if !pages.isEmpty {
                            if pages.count>1 {PositionSlider(value:$scrub,count:pages.count,label:"阅读页码，点击或拖动跳页",commit:jump).frame(height:44)}
                            HStack(spacing:8) {
                                Button{move(-1)}label:{Label("上一页",systemImage:"chevron.left").font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}.disabled(index==0)
                                Spacer(minLength:0)
                                VStack(spacing:3){Text("\(Int(scrub)+1) / \(pages.count)").font(.subheadline.weight(.semibold));Text("原页码 \(pages[PagingRules.index(Int(scrub),count:pages.count)].number)").font(.caption2).foregroundStyle(ShelfTheme.secondary)}.monospacedDigit()
                                Spacer(minLength:0)
                                Button{move(1)}label:{HStack{Text("下一页");Image(systemName:"chevron.right")}.font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}.disabled(index==pages.count-1)
                            }
                            if pages.indices.contains(index),cache.animated.contains(pages[index].number){
                                Button(cache.animationPaused ? "播放动图" : "暂停动图",systemImage:cache.animationPaused ? "play.fill":"pause.fill"){cache.toggleAnimation()}.font(.caption).frame(minHeight:44).disabled(cache.reducedMemory)
                                if !cache.animationMessage.isEmpty{Text(cache.animationMessage).font(.caption).foregroundStyle(.orange)}
                            }
                            if cache.reducedMemory {Button("内存保护中 · 点此恢复邻页预加载"){cache.restorePrefetch();cache.update(library:library,book:book.id,pages:pages,index:index)}.font(.caption)}
                        }
                    }.padding(.horizontal,14).padding(.vertical,8).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12).padding(.bottom,4)
                }
            }
        }.foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
        .onAppear{readingScope=library.recentScope;library.setReading(true);cache.setAnimationForeground(scenePhase == .active)}
        .onDisappear{rememberReading()}
        .onChange(of:scenePhase){_,phase in cache.setAnimationForeground(phase == .active);if phase != .active{rememberReading()}}
        .toolbar(.hidden,for:.navigationBar).navigationBarBackButtonHidden(true).statusBarHidden(immersive)
        .task(id:pageLoadID){await readPageList(force:pageLoadID>0)}
        .onChange(of:cache.failed){_,failed in
            if !automaticPageRefresh,!pageLoading,pages.indices.contains(index),failed.contains(pages[index].number){automaticPageRefresh=true;pageLoadID+=1}
        }
        .onChange(of:index){_,value in scrub=Double(value);if pages.indices.contains(value){ReadingProgress.save(pages[value].number,scope:readingScope ?? library.recentScope,id:book.id);cache.update(library:library,book:book.id,pages:pages,index:value)}}
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)){_ in resetID+=1;zoomed=false;cache.memoryPressure();library.trimCatalog()}
    }
    private func readPageList(force:Bool)async {
        let ticket=UUID();pageLoadTicket=ticket;pageLoading=true
        defer{if pageLoadTicket==ticket{pageLoading=false}}
        let saved=pages.indices.contains(index) ? pages[index].number:(resumePage ?? ReadingProgress.page(scope:readingScope ?? library.recentScope,id:book.id))
        do {
            let result=try await library.pageList(book.id,force:force)
            try Task.checkCancellation();guard pageLoadTicket==ticket else{return}
            if force{cache.clear();resetID+=1}
            pages=result.pages
            index=pages.firstIndex(where:{$0.number==saved}) ?? pages.firstIndex(where:{$0.number>=saved}) ?? max(0,pages.count-1)
            scrub=Double(index);error=pages.isEmpty ? "未找到可读取的已下载页面。可稍后刷新页码。":""
            cache.update(library:library,book:book.id,pages:pages,index:index)
        }catch{if !Task.isCancelled,pageLoadTicket==ticket{self.error = error is CancellationError ? "连接或缓存状态已变化，请刷新页码。":"无法刷新页序；保留现有页序，不会按时间重排。"}}
    }
    func jump(_ target:Int){guard !pages.isEmpty else{return};resetID+=1;zoomed=false;index=PagingRules.index(target,count:pages.count);scrub=Double(index);ReadingProgress.save(pages[index].number,scope:readingScope ?? library.recentScope,id:book.id)}
    func move(_ step:Int){jump(index+step)}
    private func rememberReading(){library.rememberReading(book:book,pages:pages,index:index,scope:readingScope)}
}

// Restrained, opaque surfaces: no full-screen blur or cover-dependent brightness.
enum ShelfTheme {
    static let background=Color.black
    static let surface=Color(white:0.075)
    static let primary=Color(white:0.94)
    static let secondary=Color(white:0.68)
    static let accent=Color(red:0.40,green:0.80,blue:0.73)
}

struct ShelfNotice:View {
    let title:String,message:String,icon:String
    var actionTitle:String?=nil
    var action:(()->Void)?=nil
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            HStack(spacing:8){
                Label(title,systemImage:icon).font(.subheadline.weight(.medium))
                Spacer(minLength:4)
                if let actionTitle,let action{Button(actionTitle,action:action).font(.subheadline.weight(.medium)).frame(minHeight:44).foregroundStyle(ShelfTheme.accent)}
            }
            DisclosureGroup("详细说明"){Text(message).font(.footnote).foregroundStyle(ShelfTheme.secondary).frame(maxWidth:.infinity,alignment:.leading)}.font(.caption).tint(ShelfTheme.secondary)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:14))
    }
}

struct ShelfView:View {
    @StateObject var library:Library
    @MainActor init(library:Library?=nil){_library=StateObject(wrappedValue:library ?? Library())}
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingForget=false
    @State private var confirmingCacheClear=false
    @State private var confirmingProgressReset=false
    @State private var progressMessage=""
    @State private var exportingProgress=false
    @State private var importingProgress=false
    @State private var confirmingMigration=false
    @State private var progressDocument=ProgressDocument(data:Data())
    @State private var scanning=false
    @State private var requestingCamera=false
    @State private var shelfScrub=0.0
    @State private var atShelfBottom=false
    @State private var shelfSeek:ShelfSeek?
    @State private var selectedBook:Book?
    @State private var selectedResumePage:Int?
    @State private var locateTask:Task<Void,Never>?
    @ObservedObject private var meter=InteractionMeter.shared
    @State private var showingSettings=false
    @State private var pairingDigits=""
    @State private var fullTitle:String?
    @AppStorage("shelf.columns") private var storedColumns=2
    @State private var viewport=CGSize.zero
    private var columns:Int{storedColumns==3 ? 3:2}
    var body:some View {
        NavigationStack {
            CollectionShelf(library:library,columns:columns,header:AnyView(collectionHeader),seek:shelfSeek,select:{selectedResumePage=nil;selectedBook=$0},fullTitle:{fullTitle=$0},position:{value,bottom in shelfScrub=Double(value);atShelfBottom=bottom})
            .background(ShelfTheme.background).navigationTitle("LocalShelf")
            .navigationBarTitleDisplayMode(.inline).toolbarColorScheme(.dark,for:.navigationBar)
            .toolbarBackground(.black,for:.navigationBar).toolbarBackground(.visible,for:.navigationBar)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing){
                    Button("设置",systemImage:"gearshape"){showingSettings=true}
                        .frame(minWidth:44,minHeight:44).accessibilityIdentifier("shelfSettings")
                }
            }
            .overlay(alignment:.trailing){
                if library.books.count>1 {
                    ShelfPositionRail(position:atShelfBottom ? library.books.count-1:Int(shelfScrub),total:library.books.count,enabled:!library.loading,commit:{offset in
                        guard !library.loading,!library.books.isEmpty else{return}
                        let local=PagingRules.index(offset,count:library.books.count)
                        shelfScrub=Double(local)
                        shelfSeek=ShelfSeek(index:local)
                    }).id(library.pageIndex)
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0){pageControls}
            .background{GeometryReader{geometry in Color.clear.onAppear{viewport=geometry.size;library.updateCoverViewport(viewport,columns:columns)}.onChange(of:geometry.size){_,size in viewport=size;library.updateCoverViewport(size,columns:columns)}}}
            .onChange(of:columns){_,_ in library.updateCoverViewport(viewport,columns:columns)}
            .onChange(of:library.total){_,_ in library.updateCoverViewport(viewport,columns:columns)}
            .onChange(of:library.pageSize){_,_ in if library.base != nil {Task{await library.loadPage(0)}}}
            .onAppear{library.setReading(false);library.scheduleCoverPrefetch(anchor:PagingRules.index(Int(shelfScrub),count:library.books.count))}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)){_ in library.cancelCoverPrefetch();library.covers.trim();library.trimCatalog()}
            .onChange(of:library.pageIndex){_,_ in resetShelfPosition()}
            .onChange(of:library.books.count){_,_ in resetShelfPosition()}
            .sheet(isPresented:$showingSettings){settingsView}
            .navigationDestination(isPresented:Binding(get:{selectedBook != nil},set:{if !$0{selectedBook=nil;selectedResumePage=nil}})){if let book=selectedBook{Reader(library:library,book:book,resumePage:selectedResumePage)}}
        }
        .tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.primary).preferredColorScheme(.dark)
        .task{library.setForeground(scenePhase == .active);await library.refreshCacheUsage()}
        .onChange(of:scenePhase){_,phase in library.setForeground(phase == .active);if phase != .active{meter.stop();locateTask?.cancel()}}
        .onDisappear{locateTask?.cancel()}
        .alert("漫画名称",isPresented:Binding(get:{fullTitle != nil},set:{if !$0{fullTitle=nil}})){
            Button("完成",role:.cancel){fullTitle=nil}
        } message:{Text(fullTitle ?? "")}
    }
    private var collectionHeader:some View {
        VStack(alignment:.leading,spacing:16){
            shelfHeader
            if library.recentScope != nil{continueReadingCard}
            if library.base==nil && !library.loading{Button("连接与配对"){showingSettings=true}.buttonStyle(.borderedProminent)}
            if !library.error.isEmpty{ShelfNotice(title:"书库暂时无法更新",message:library.error,icon:"wifi.exclamationmark",actionTitle:"连接设置",action:{showingSettings=true})}
            if library.books.isEmpty && !library.loading && library.base != nil && library.error.isEmpty{Text("书库暂时没有漫画，请在安卓导入最新清单。")}
            if library.loading{Text("正在更新书库…").font(.footnote).foregroundStyle(ShelfTheme.secondary)}
        }.padding(16).foregroundStyle(ShelfTheme.primary).tint(ShelfTheme.accent).preferredColorScheme(.dark)
    }
    private var continueReadingCard:some View {
        let recent=library.recentReading
        let available=recent != nil && recent?.book.isMissing==false && library.base != nil && !library.loading
        return HStack(spacing:8){
        Button {
            guard available,let recent else{return}
            selectedResumePage=recent.pageNumber;selectedBook=recent.book
        }label:{
            HStack(spacing:12){
                Group {
                    if let recent,!library.coversHidden,!recent.book.isMissing,library.base != nil {
                        RecentReadingCover(library:library,book:recent.book).accessibilityHidden(true)
                    }else{Image(systemName:library.coversHidden ? "eye.slash":"book.closed").foregroundStyle(ShelfTheme.secondary)}
                }.frame(width:40,height:60).background(ShelfTheme.background,in:RoundedRectangle(cornerRadius:6)).clipShape(RoundedRectangle(cornerRadius:6))
                VStack(alignment:.leading,spacing:3){
                    Text("继续阅读").font(.caption).foregroundStyle(ShelfTheme.accent)
                    Text(recent?.book.title ?? "从下一次阅读开始记录").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(!library.locateMessage.isEmpty ? library.locateMessage:(recent.map{$0.book.isMissing ? "本地文件缺失":(library.base==nil ? "连接书库后继续":"上次读到 \($0.position+1) / \($0.pageCount) · 原页码 \($0.pageNumber)")} ?? "只记住最近一本，不改变书库顺序"))
                        .font(.caption2).monospacedDigit().foregroundStyle(ShelfTheme.secondary).lineLimit(1)
                }.frame(maxWidth:.infinity,alignment:.leading)
                Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ShelfTheme.secondary)
            }.frame(height:60).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!available)
        .accessibilityIdentifier("continueReading")
        .accessibilityLabel(recent.map{"继续阅读，\($0.book.title)"} ?? "继续阅读，暂无记录")
        .accessibilityValue(recent.map{"第 \($0.position+1) 页，共 \($0.pageCount) 页"+(library.coversHidden ? "，封面已隐藏":"")} ?? "暂无记录")
        Divider().frame(height:40)
        Button {
            if library.locatingRecent{locateTask?.cancel();return}
            locateTask=Task{if let index=await library.locateRecentBook(),!Task.isCancelled{shelfSeek=ShelfSeek(index:index,centered:true);shelfScrub=Double(index);atShelfBottom=false}}
        }label:{VStack(spacing:4){Image(systemName:library.locatingRecent ? "xmark":"scope");Text(library.locatingRecent ? "取消":"定位").font(.caption2)}.frame(width:44,height:60)}
        .buttonStyle(.plain).foregroundStyle(ShelfTheme.accent)
        .disabled(!library.locatingRecent && (recent==nil || library.base==nil || library.loading))
        .accessibilityIdentifier("locateRecentReading").accessibilityLabel(library.locatingRecent ? "取消定位":"在书库中定位")
        .accessibilityValue(library.locateMessage)
        }.padding(10).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:12))
    }
    private func resetShelfPosition(){
        let index=library.locatedBookID.flatMap{id in library.books.firstIndex{$0.id==id}}
        shelfSeek=ShelfSeek(index:index,centered:index != nil);shelfScrub=Double(index ?? 0);atShelfBottom=false
    }
    private var shelfHeader:some View {
        VStack(alignment:.leading,spacing:12){
            HStack(alignment:.firstTextBaseline){
                Text("书库").font(.largeTitle.bold())
                Text("\(library.total.formatted()) 本").font(.subheadline).monospacedDigit().foregroundStyle(ShelfTheme.secondary)
                Spacer()
                Button{showingSettings=true}label:{
                    Label(library.loading ? "连接 / 加载中":(!library.error.isEmpty ? "需检查连接":(library.base==nil ? "未连接":"已连接")),systemImage:library.base==nil ? "wifi.slash":"wifi")
                        .font(.caption.weight(.medium)).padding(.horizontal,10).padding(.vertical,7)
                        .background(ShelfTheme.surface,in:Capsule())
                }.buttonStyle(.plain).foregroundStyle(ShelfTheme.accent).accessibilityIdentifier("connectionStatus")
            }
            HStack{
                Menu {
                    Picker("封面布局",selection:$storedColumns){Text("舒适两列").tag(2);Text("紧凑三列").tag(3)}
                    Picker("每页数量",selection:$library.pageSize){ForEach(Array(stride(from:50,through:500,by:50)),id:\.self){Text("\($0) 本 / 页").tag($0)}}.disabled(library.loading)
                }label:{Label("\(columns) 列 · \(library.pageSize) 本 / 页",systemImage:"square.grid.2x2").font(.subheadline)}
                .frame(minHeight:44).accessibilityIdentifier("shelfLayout")
                Spacer()
                Button("刷新书库",systemImage:"arrow.clockwise"){Task{await library.more()}}
                    .labelStyle(.iconOnly).frame(width:44,height:44).disabled(library.loading || library.base==nil).accessibilityIdentifier("refreshCatalog")
            }
        }
    }
    private var settingsView:some View {
        NavigationStack {
            Form {
                Section {
                    Button(library.coversHidden ? "显示所有封面":"隐藏所有封面",systemImage:library.coversHidden ? "eye":"eye.slash"){
                        library.coversHidden.toggle()
                    }.accessibilityIdentifier("hideAllCovers").accessibilityValue(library.coversHidden ? "1":"0")
                } header:{Text("隐私显示")} footer:{Text("仅隐藏书库封面并暂停封面加载；保留标题、顺序和缓存，不影响正文阅读。此选择会自动保存。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    Button(meter.recording ? "停止记录":"记录 15 秒交互耗时"){
                        if meter.recording{meter.stop()}else{meter.start();showingSettings=false}
                    }.accessibilityIdentifier("recordInteraction")
                    Text(meter.report).font(.footnote).monospacedDigit().foregroundStyle(ShelfTheme.secondary)
                } header:{Text("交互诊断")} footer:{Text("书库已内置 UIKit 网格，阅读沿用原翻页手感，无需切换。耗时记录仅存在内存，不包含漫画内容，也不是实际屏幕帧率。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    Picker("书库服务器",selection:Binding(get:{library.serverTarget},set:{target in Task{await library.selectServer(target)}})){
                        ForEach(ServerTarget.allCases){Text($0.title).tag($0)}
                    }.pickerStyle(.segmented).disabled(library.loading).accessibilityIdentifier("serverTarget")
                    Text(library.pairingStatus).foregroundStyle(ShelfTheme.secondary)
                    if !library.error.isEmpty{Text(library.error).foregroundStyle(.orange)}
                    if library.paired != nil {
                        Button("重新连接"){Task{await library.reconnect()}}.disabled(library.loading)
                        Button("解除配对",role:.destructive){confirmingForget=true}.foregroundStyle(.red)
                    }
                    if library.serverTarget == .android{Button("扫码连接安卓",systemImage:"qrcode.viewfinder"){Task{await scan()}}.disabled(library.loading || requestingCamera)}
                    if library.paired==nil || library.serverTarget == .nas {
                        TextField(library.serverTarget == .nas ? "NAS 阅读地址：http://192.168.…:8089":"安卓地址：http://192.168.…:8088",text:$library.address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(library.loading).accessibilityIdentifier("serverAddress")
                        SecureField("6 位数字配对码",text:$pairingDigits).keyboardType(.numberPad).textContentType(.oneTimeCode).disabled(library.loading)
                            .onChange(of:pairingDigits){_,value in pairingDigits=String(value.filter{"0123456789".contains($0)}.prefix(6))}
                        Button("使用六位码配对"){Task{await library.connect(pin:pairingDigits);pairingDigits="";if library.base != nil && library.error.isEmpty{showingSettings=false}}}
                            .disabled(library.loading || pairingDigits.count != 6)
                        if library.serverTarget == .android{DisclosureGroup("旧版安卓临时连接"){
                            SecureField("旧版完整访问口令",text:$library.secret).disabled(library.loading)
                            Button("手动临时连接"){Task{await library.connect()}}.disabled(library.loading)
                        }}
                    }
                } header:{Text("连接与配对")} footer:{Text("扫码或六位码配对一次，之后自动连接。数字码 5 分钟有效，最多尝试 5 次，成功后失效。后台随机凭据仅存本机钥匙串。仅可信私人 Wi-Fi · HTTP 未加密。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    LabeledContent("磁盘缓存上限",value:"2 GB")
                    Text(library.cacheUsage).monospacedDigit()
                    if !library.cacheMessage.isEmpty{Text(library.cacheMessage).font(.footnote).foregroundStyle(ShelfTheme.secondary)}
                    Button(library.cacheBusy ? "清理中…":"清空封面缓存",role:.destructive){confirmingCacheClear=true}.foregroundStyle(.red).disabled(library.cacheBusy)
                } header:{Text("封面缓存与预加载")} footer:{Text(library.diskEnabled ? "分层预取与缩略图缓存已开启。缓存不备份，不保存正文，不修改原始文件。":"分层预加载可用；连接支持稳定书库身份的服务器后启用持久缓存。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    Button("导出阅读记录备份"){
                        do{progressDocument=ProgressDocument(data:try ProgressBackup.capture().data());exportingProgress=true}catch{progressMessage="无法生成有效备份，原记录未改动。"}
                    }.accessibilityIdentifier("exportReadingProgress")
                    Button("从备份恢复（不覆盖已有进度）"){importingProgress=true}.disabled(library.loading)
                    Button("从"+library.serverTarget.other.title+"迁移阅读记录"){confirmingMigration=true}.disabled(library.base==nil || library.loading).accessibilityIdentifier("migrateReadingProgress")
                    if !library.migrationMessage.isEmpty{Text(library.migrationMessage).font(.footnote).foregroundStyle(ShelfTheme.secondary)}
                    Button("重置所有漫画阅读进度",role:.destructive){confirmingProgressReset=true}.foregroundStyle(.red).accessibilityIdentifier("resetReadingProgress")
                    if !progressMessage.isEmpty{Text(progressMessage).font(.footnote).foregroundStyle(ShelfTheme.secondary)}
                } header:{Text("阅读进度")} footer:{Text("安卓和 NAS 进度独立保存。迁移按漫画 ID 核对，不覆盖目标已有进度，不改变原顺序。备份包含漫画标题和页码，不含配对口令或图片，请妥善保管。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    Text("按导入的清单顺序展示漫画；漫画内部按数字页码阅读。").font(.subheadline).foregroundStyle(ShelfTheme.secondary)
                    if !library.orderNotice.isEmpty {
                        Text(library.orderNotice).font(.footnote).foregroundStyle(ShelfTheme.secondary).accessibilityIdentifier("libraryOrderNotice")
                    }
                } header:{Text("书库说明")}
                .listRowBackground(ShelfTheme.surface)
            }.scrollContentBackground(.hidden).background(ShelfTheme.background)
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){showingSettings=false}.accessibilityIdentifier("closeShelfSettings")}}
        }.tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.primary).preferredColorScheme(.dark)
        .pageEdgeReturn(enabled:!scanning && !exportingProgress && !importingProgress && !confirmingForget && !confirmingCacheClear && !confirmingProgressReset && !confirmingMigration){showingSettings=false}
        .task{await library.refreshCacheUsage()}
        .fileExporter(isPresented:$exportingProgress,document:progressDocument,contentType:.json,defaultFilename:"LocalShelf-reading-backup"){result in
            switch result{case .success:progressMessage="阅读记录已导出。";case .failure:progressMessage="导出未完成，原记录未改动。"}
        }
        .fileImporter(isPresented:$importingProgress,allowedContentTypes:[.json]){result in
            do{
                let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
                guard size<=8*1024*1024 else{throw LibraryError.malformed}
                let backup=try ProgressBackup.decode(Data(contentsOf:url))
                let count=backup.restore();library.reloadReading();progressMessage="已补充 \(count) 条阅读位置，已有进度未覆盖。"
            }catch{progressMessage="恢复未完成：文件无效、过大或未获授权。"}
        }
        .alert("迁移到当前书库？",isPresented:$confirmingMigration){
            Button("核对并迁移"){Task{await library.migrateReading()}}
            Button("取消",role:.cancel){}
        }message:{Text("仅适用于同一套 EhViewer 书库。按漫画 ID 核对并复制原页码；目标已有进度优先，未匹配记录保留在来源。迁移前自动保存本机备份，建议同时导出一份。")}
        .sheet(isPresented:$scanning){
            NavigationStack {
                scannerContent.navigationTitle("扫描安卓配对码").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){scanning=false}}}
            }.preferredColorScheme(.dark).tint(ShelfTheme.accent)
            .pageEdgeReturn{scanning=false}
        }
        .alert("解除这台 iPhone 的配对？",isPresented:$confirmingForget){
            Button("解除本机配对",role:.destructive){library.forget()}
            Button("取消",role:.cancel){}
        } message:{Text("只解除当前服务器的本机配对；另一服务器、阅读记录和漫画保留。撤销旧凭据需要在对应服务端操作。")}
        .alert("清空本机封面缓存？",isPresented:$confirmingCacheClear){
            Button("清空缓存",role:.destructive){Task{await library.clearCoverCache()}}
            Button("取消",role:.cancel){}
        } message:{Text("不会删除安卓文件。当前可见封面会按需重新缓存。")}
        .alert("重置所有漫画阅读进度？",isPresented:$confirmingProgressReset){
            Button("确认重置所有进度",role:.destructive){let count=library.resetReadingProgress();progressMessage="已重置 \(count) 条本机阅读位置"}
            Button("取消",role:.cancel){}
        } message:{Text("此操作不可撤销。下次打开漫画将从第一页开始；漫画、封面缓存、书库顺序和配对信息均保留。")}
    }
    @ViewBuilder private var scannerContent:some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--edge-return-demo"){
            Color.black.overlay(Text("扫码页返回测试 · 无相机")).accessibilityIdentifier("scannerFixture")
        }else{liveScanner}
        #else
        liveScanner
        #endif
    }
    private var liveScanner:some View {
        PairingScanner {result in
            scanning=false
            switch result{
            case .success(let code):Task{await library.connect(code:code);if library.base != nil && library.error.isEmpty{showingSettings=false}}
            case .failure:library.error="扫码失败或不是有效的 LocalShelf 局域网配对码，请重新扫描。"
            }
        }
    }
    @MainActor private func scan()async{
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--edge-return-demo"){scanning=true;return}
        #endif
        requestingCamera=true;defer{requestingCamera=false}
        guard DataScannerViewController.isSupported else{library.error="此设备不支持扫码，请使用手动输入。";return}
        guard await AVCaptureDevice.requestAccess(for:.video) else{library.error="相机未授权，可在系统设置中允许相机，或手动输入。";return}
        guard DataScannerViewController.isAvailable else{library.error="相机暂不可用，请稍后再试或手动输入。";return}
        scanning=true
    }
    private func browsePage(_ page:Int){Task{await library.loadPage(page)}}
    var pageControls:some View {
        HStack(spacing:12) {
            Button{browsePage(library.pageIndex-1)}label:{Label("上一页",systemImage:"chevron.left").font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}
                .disabled(library.pageIndex==0||library.loading||library.base==nil).accessibilityIdentifier("shelfPreviousPage")
            Spacer()
            Menu{
                ForEach(0..<library.pageCount,id:\.self){page in Button("第 \(page+1) 页"){browsePage(page)}}
            }label:{HStack(spacing:6){Text("\(library.pageIndex+1) / \(library.pageCount) 页").monospacedDigit();Image(systemName:"chevron.down").font(.caption2)}.font(.subheadline.weight(.medium)).frame(minHeight:44).contentShape(Rectangle())}
                .disabled(library.loading||library.base==nil).accessibilityIdentifier("shelfPageMenu")
            Spacer()
            Button{browsePage(library.pageIndex+1)}label:{HStack{Text("下一页");Image(systemName:"chevron.right")}.font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}
                .disabled(library.pageIndex+1>=library.pageCount||library.loading||library.base==nil).accessibilityIdentifier("shelfNextPage")
        }.buttonStyle(.plain).padding(.horizontal,20).padding(.vertical,4).background(ShelfTheme.surface)
    }
}
#if DEBUG && targetEnvironment(simulator)
final class NASFixture:URLProtocol {
    static let lock=NSLock()
    static var ready=false,pinCalls=0
    static let token=String(repeating:"N",count:32)
    static func publish(){lock.lock();ready=true;lock.unlock()}
    static func unpublish(){lock.lock();ready=false;lock.unlock()}
    override class func canInit(with request:URLRequest)->Bool{request.url?.host?.hasPrefix("192.168.241.")==true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let url=request.url!,nas=url.host=="192.168.241.2",wrong=url.host=="192.168.241.3"
        let id=String(repeating:nas ? "b":"a",count:32),library=String(repeating:nas ? "d":"c",count:64)
        var status=200,body:Data
        if url.path=="/v2/health" {
            body=try! JSONSerialization.data(withJSONObject:["app":wrong ? "localshelf-sync":"localshelf-reader","version":1,"serverKind":"nas","capabilities":["reader-v1","pair-v2","locate-v1"]])
        }else if url.path=="/v2/pair" {
            Self.lock.lock();Self.pinCalls+=1;Self.lock.unlock()
            body=try! JSONEncoder().encode(PairingCode(app:"localshelf",version:2,address:url.absoluteString,token:Self.token,deviceId:id))
        }else if url.path=="/v2/identity" {
            precondition(request.value(forHTTPHeaderField:"Authorization")==nil)
            let nonce=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first!.value!
            let proof=HMAC<SHA256>.authenticationCode(for:Data("localshelf-server-v2\n\(id)\n\(nonce)".utf8),using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":id,"proof":proof])
        }else{
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            Self.lock.lock();let ready=Self.ready;Self.lock.unlock()
            if nas && !ready{status=503;body=Data()}
            else if url.path.hasSuffix("/position"){
                body=try! JSONSerialization.data(withJSONObject:["id":"2","offset":1,"catalogRevision":String(repeating:"e",count:64),"libraryId":library])
            }else if url.path=="/v1/books" {
                let offset=Int(URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="offset"}!.value!)!
                let books=offset==0 ? [Book(id:"1",title:"Synthetic One",rank:0),Book(id:"2",title:"Synthetic Two",rank:1)]:[]
                body=try! JSONEncoder().encode(BookList(orderVerified:true,total:2,books:books,catalogRevision:String(repeating:"e",count:64),libraryId:library))
            }else{status=404;body=Data()}
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
enum NASChecks {
    @MainActor static func run()async {
        let defaults=UserDefaults.standard
        func owned(_ key:String)->Bool{key.hasPrefix("reading.") || key.hasPrefix("page.") || key=="server.selected"}
        let before=defaults.dictionaryRepresentation().filter{owned($0.key)}
        defer{
            for key in defaults.dictionaryRepresentation().keys where owned(key){defaults.removeObject(forKey:key)}
            for (key,value) in before{defaults.set(value,forKey:key)}
        }
        defaults.set("android",forKey:"server.selected")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("reading."){defaults.removeObject(forKey:key)}
        var credentials:[ServerTarget:PairingCode]=[:]
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[NASFixture.self]
        let client=Library(transport:LimitedHTTP(configuration:config),loadPair:{credentials[ServerTarget.selected]},savePair:{credentials[ServerTarget.selected]=$0},removePair:{credentials[ServerTarget.selected]=nil},lookup:{_ in preconditionFailure("NAS must not use Android discovery")})
        client.setForeground(false)
        client.address="http://192.168.241.1:8088";await client.connect(pin:"001234")
        precondition(client.base != nil && credentials[.android] != nil);print("PASS Android profile retained")
        let android=client.recentScope!
        ReadingProgress.save(9,scope:android,id:"1");ReadingProgress.save(13,scope:android,id:"2");ReadingProgress.save(11,scope:android,id:"999")
        client.rememberReading(book:Book(id:"2",title:"Synthetic Two",rank:1),pages:[Page(number:13)],index:0,scope:android)
        await client.selectServer(.nas);client.address="http://192.168.241.3:8443"
        let attempts=NASFixture.pinCalls;await client.connect(pin:"001234")
        precondition(NASFixture.pinCalls==attempts && credentials[.nas]==nil && client.error.contains("阅读服务"));print("PASS upload endpoint rejected before PIN exchange")
        client.address="http://192.168.241.2:8089";await client.connect(pin:"001234")
        precondition(credentials[.nas] != nil && credentials[.android] != nil && client.base==nil && client.error.contains("尚未发布"));print("PASS pairing survives unpublished library and preserves Android credential")
        NASFixture.publish();await client.reconnect()
        precondition(client.base != nil && client.total==2);print("PASS published NAS reconnects without another PIN")
        let nas=client.recentScope!;ReadingProgress.save(5,scope:nas,id:"1")
        NASFixture.unpublish();await client.migrateReading()
        precondition(ReadingProgress.page(scope:nas,id:"2")==0 && ReadingProgress.page(scope:android,id:"2")==13);print("PASS failed migration does not write target or remove source")
        NASFixture.publish()
        let cancelled=Task{await client.migrateReading()};cancelled.cancel();await cancelled.value
        precondition(ReadingProgress.page(scope:nas,id:"2")==0);print("PASS cancelled migration does not commit target progress")
        await client.migrateReading()
        precondition(ReadingProgress.page(scope:nas,id:"1")==5 && ReadingProgress.page(scope:nas,id:"2")==13 && ReadingProgress.page(scope:nas,id:"999")==0)
        precondition(ReadingProgress.page(scope:android,id:"999")==11 && client.migrationMessage.contains("1 本未匹配"));print("PASS migration merges matching IDs, preserves target progress and unmatched source")
        precondition(client.recentReading?.book.id=="2" && client.recentReading?.pageNumber==13);print("PASS recent reading transfers to NAS scope")
        let position=await client.locateRecentBook();precondition(position==1);print("PASS NAS position endpoint locates recent book")
        await client.migrateReading();precondition(ReadingProgress.page(scope:nas,id:"1")==5);print("PASS repeated migration is additive")
        await client.selectServer(.android);await client.reconnect()
        precondition(client.recentScope==android && client.recentReading?.pageNumber==13);print("PASS manual Android fallback restores source recent reading")
        client.forget();precondition(credentials[.nas] != nil && ReadingProgress.page(scope:android,id:"2")==13);print("PASS unpair only removes selected credential, not reading records")
        client.setForeground(false)
        print("12 NAS client lifecycle checks passed")
    }
}
final class PairingFixture:URLProtocol {
    static let id="0123456789abcdef0123456789abcdef",token="abcdefghijklmnopqrstuvwxyzABCDEF"
    static let lock=NSLock()
    static var bookHosts:[String]=[]
    static var revision="a"
    static var pageNumbers=[1,3,10],pageHits=0
    static func setPages(_ numbers:[Int]){lock.lock();pageNumbers=numbers;lock.unlock()}
    static func hits()->Int{lock.lock();defer{lock.unlock()};return pageHits}
    static func changeRevision(){lock.lock();revision="b";lock.unlock()}
    static func hosts()->[String]{lock.lock();defer{lock.unlock()};return bookHosts}
    override class func canInit(with request:URLRequest)->Bool{request.url?.host?.hasPrefix("192.168.240.")==true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let url=request.url!,host=url.host!,body:Data
        if url.path=="/v2/pair" {
            precondition(request.httpMethod=="POST" && request.value(forHTTPHeaderField:"Authorization")==nil)
            var data=request.httpBody ?? Data()
            if let stream=request.httpBodyStream{stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:32);let size=stream.read(&buffer,maxLength:32);if size>0{data=Data(buffer.prefix(size))}}
            if data != Data("001234".utf8){
                client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:401,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
                client?.urlProtocolDidFinishLoading(self);return
            }
            body=try! JSONSerialization.data(withJSONObject:["app":"localshelf","version":2,"deviceId":Self.id,"token":Self.token])
        }else if url.path=="/v2/identity" {
            precondition(request.value(forHTTPHeaderField:"Authorization")==nil)
            let nonce=URLComponents(url:url,resolvingAgainstBaseURL:true)!.queryItems!.first{$0.name=="nonce"}!.value!
            let message=Data("localshelf-server-v2\n\(Self.id)\n\(nonce)".utf8)
            let proof=HMAC<SHA256>.authenticationCode(for:message,using:SymmetricKey(data:Data(Self.token.utf8))).map{String(format:"%02x",$0)}.joined()
            body=try! JSONSerialization.data(withJSONObject:["deviceId":Self.id,"proof":host=="192.168.240.124" ? proof : String(repeating:"0",count:64)])
        }else{
            Self.lock.lock();Self.bookHosts.append(host);Self.lock.unlock()
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+Self.token)
            if ProcessInfo.processInfo.arguments.contains("--page-cache-checks"),url.path.hasSuffix("/pages") {
                Self.lock.lock();Self.pageHits+=1;let numbers=Self.pageNumbers;Self.lock.unlock()
                body=try! JSONEncoder().encode(Pages(pages:numbers.map{Page(number:$0)}))
            }else if ProcessInfo.processInfo.arguments.contains("--p34-checks") || ProcessInfo.processInfo.arguments.contains("--page-cache-checks") {
                let query=URLComponents(url:url,resolvingAgainstBaseURL:true)!.queryItems!
                let offset=Int(query.first{$0.name=="offset"}!.value!)!,limit=Int(query.first{$0.name=="limit"}!.value!)!
                Self.lock.lock();let revision=Self.revision;Self.lock.unlock()
                let books=(offset..<min(300,offset+limit)).map{Book(id:String($0+1),title:"Fixture-"+revision,rank:$0)}
                body=try! JSONEncoder().encode(BookList(orderVerified:true,total:300,books:books,catalogRevision:String(repeating:revision,count:64),libraryId:String(repeating:"c",count:64)))
            }else{body=Data("{\"orderVerified\":true,\"total\":1,\"books\":[{\"id\":\"1\",\"title\":\"Synthetic fixture\",\"rank\":0}]}".utf8)}
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
final class TransferFixture:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool{request.url?.host=="192.168.240.123"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let path=request.url!.path
        if path=="/wait" {return}
        if path=="/not-modified" {
            let response=HTTPURLResponse(url:request.url!,statusCode:304,httpVersion:"HTTP/1.1",headerFields:["ETag":"W/\""+String(repeating:"a",count:64)+"\""])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocolDidFinishLoading(self);return
        }
        let header=path=="/header" ? ["Content-Length":"99"] : [:]
        let response=HTTPURLResponse(url:request.url!,statusCode:path=="/status" ? 401 : 200,httpVersion:"HTTP/1.1",headerFields:header)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data([1,2,3]))
        client?.urlProtocol(self,didLoad:path=="/large" ? Data([4,5,6]) : Data([4,5]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
// Neutral, generated pages for gesture/layout QA; never accesses a real library.
enum ReaderDemo {
    @MainActor static var requests:[String:Int]=[:]
    @MainActor static func schedulingChecks()async {
        var count=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);count+=1;print("PASS \(message)")}
        func wait(_ test:()->Bool)async{for _ in 0..<500{if test(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("scheduling timeout")}
        let image=UIImage(systemName:"photo")!,queue=PageDecodeQueue(limit:1),gate=DispatchSemaphore(value:0)
        var completed:[String]=[],cancelled=0
        let first=Task{do{_ = try await queue.decode(key:"first"){gate.wait();return (image,false)}}catch{cancelled+=1}}
        await wait{queue.peak==1}
        let stale=Task{do{_ = try await queue.decode(key:"stale"){preconditionFailure("cancelled queued decode ran")}}catch{cancelled+=1}}
        await Task.yield();stale.cancel();first.cancel()
        let background=Task{_ = try? await queue.decode(key:"background"){(image,false)};completed.append("background")}
        await Task.yield()
        queue.prioritize("current")
        let current=Task{_ = try? await queue.decode(key:"current"){(image,false)};completed.append("current")}
        try? await Task.sleep(nanoseconds:50_000_000)
        pass(completed.isEmpty,"cancelled active ImageIO work retains physical decode slot")
        gate.signal();await first.value;await stale.value;await current.value;await background.value
        pass(cancelled==2,"queued and running cancellation resume their callers")
        pass(completed==["current","background"],"current page overtakes queued background decode")
        pass(queue.peak==1,"decode concurrency never exceeds configured limit")
        do{_ = try await queue.decode(key:"failure"){throw LibraryError.malformed};preconditionFailure("expected failure")}catch{}
        pass((try? await queue.decode(key:"after-failure"){(image,false)}) != nil,"decode failure releases slot")

        // Hold both physical slots to deterministically inspect logical request scheduling.
        let hold=DispatchSemaphore(value:0)
        let a=Task{try? await PageDecodeQueue.shared.decode(key:"hold-a"){hold.wait();return (image,false)}}
        let b=Task{try? await PageDecodeQueue.shared.decode(key:"hold-b"){hold.wait();return (image,false)}}
        await wait{PageDecodeQueue.shared.peak==2}
        let cache=ReadingCache(),library=Library(),pages=(1...9).map{Page(number:$0)}
        cache.update(library:library,book:"fixture",pages:pages,index:2)
        pass(cache.pendingPages==Set([3,4]),"initial logical requests are current and next page")
        await Task.yield()
        cache.update(library:library,book:"fixture",pages:pages,index:4)
        pass(cache.pendingPages==Set([4,5]),"new current page replaces lowest-priority speculative request")
        cache.clear();hold.signal();hold.signal();_ = await a.value;_ = await b.value

        let root=FileManager.default.temporaryDirectory.appendingPathComponent("write-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let disk=CoverDiskCache(root:root),key=String(repeating:"a",count:64),ticket=await disk.ticket()
        var writeGate:CheckedContinuation<Void,Never>?,starts=0,delivered=false
        let writer=CoverWriteQueue{_ in starts+=1;await withCheckedContinuation{writeGate=$0}}
        let pipeline=CoverPipeline(disk:disk,writes:writer);pipeline.configureScope("fixture")
        pipeline.subscribe("/v1/books/1/cover",id:UUID(),load:{data("1")}){if case .success=$0{delivered=true}}
        await wait{delivered && writeGate != nil}
        pass(!writer.idle,"cover delivered while persistence is still blocked")
        writer.enqueue(Data(repeating:0,count:8*1024*1024),key:key,ticket:ticket,disk:disk)
        pass(writer.bytes<8*1024*1024,"staging budget includes the active write and rejects overflow")
        writer.enqueue(Data([1]),key:key,ticket:ticket,disk:disk)
        writer.cancel();writeGate?.resume();writeGate=nil;await wait{writer.idle}
        pass(starts==1 && writer.bytes==0,"reset drops staged writes and releases accounting")
        print("\(count) scheduling and staged-write checks passed")
    }
    @MainActor static func diskCoverChecks()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)")}
        func waitUntil(_ predicate:()->Bool)async{for _ in 0..<500{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("disk/prefetch check timed out")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cover-check-"+UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        do {
            let folder=root.appendingPathComponent("lru"),disk=CoverDiskCache(root:folder,budget:360000)
            let keys=["a","b","c","d"].map{String(repeating:$0,count:64)},payload=Data(repeating:7,count:100000)
            let ticket=await disk.ticket()
            for key in keys.prefix(3){try await disk.put(payload,key:key,ticket:ticket)}
            pass(try await disk.value(keys[0])==payload,"disk cache reads stored bytes")
            try await disk.put(payload,key:keys[3],ticket:ticket)
            let oldest=try await disk.value(keys[1]),recent=try await disk.value(keys[0]),usage=try await disk.usage()
            pass(oldest==nil && recent==payload && usage<=360000,"allocated-size budget evicts least recently used cover")
            let restarted=CoverDiskCache(root:folder,budget:360000)
            pass(try await restarted.value(keys[0])==payload,"new cache instance restores persisted covers")
            pass(try folder.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup==true,"cover directory is excluded from backup")
            let old=await disk.ticket();try await disk.clear();try await disk.put(payload,key:keys[0],ticket:old)
            pass(try await disk.usage()==0,"clear generation rejects late writes")
            try await disk.put(Data(repeating:1,count:400000),key:keys[0],ticket:await disk.ticket())
            pass(try await disk.usage()==0,"oversized cover does not enter cache")
            let expired=CoverDiskCache(root:root.appendingPathComponent("expired"),budget:360000,ttl:0)
            try await expired.put(payload,key:keys[0],ticket:await expired.ticket())
            pass(try await expired.value(keys[0])==nil,"expired covers are removed")
            let pipelineDisk=CoverDiskCache(root:root.appendingPathComponent("pipeline"),budget:4_000_000),sample=data("1"),path="/v1/books/1/cover"
            let first=CoverPipeline(disk:pipelineDisk);first.configureScope("device/catalog")
            var loads=0,delivered=0
            func subscribe(_ pipeline:CoverPipeline,_ path:String){pipeline.subscribe(path,id:UUID(),load:{loads+=1;return sample}){if case .success=$0{delivered+=1}}}
            subscribe(first,path);await waitUntil{delivered==1}
            await waitUntil{first.writes.idle}
            let warm=CoverPipeline(disk:pipelineDisk);warm.configureScope("device/catalog");subscribe(warm,path);await waitUntil{delivered==2}
            pass(loads==1,"cold pipeline reuses disk cover without network fetch")
            warm.configureScope("device/changed");subscribe(warm,path);await waitUntil{delivered==3}
            pass(loads==2,"changed library cannot reuse previous library cover")
            let badKey=CoverRules.key(scope:"corrupt",path:path)!
            try await pipelineDisk.put(Data([1,2,3]),key:badKey,ticket:await pipelineDisk.ticket())
            warm.configureScope("corrupt");subscribe(warm,path);await waitUntil{delivered==4}
            pass(loads==3,"corrupt cached image falls back to validated network image")
            var late:CheckedContinuation<Data,Error>?
            warm.subscribe("/v1/books/2/cover",id:UUID(),load:{try await withCheckedThrowingContinuation{late=$0}}){_ in}
            await waitUntil{late != nil};warm.reset();try await pipelineDisk.clear();late?.resume(returning:sample)
            try? await Task.sleep(nanoseconds:100_000_000)
            pass(try await pipelineDisk.usage()==0,"in-flight fetch cannot repopulate a cleared cache")
        }catch{preconditionFailure("disk fixture failed: \(error)")}
        let queue=CoverPipeline(),sample=data("1")
        var starts:[String]=[],gates:[String:CheckedContinuation<Data,Error>]=[:],delivered=0
        func load(_ path:String)async throws->Data{starts.append(path);return try await withCheckedThrowingContinuation{gates[path]=$0}}
        queue.prefetch(["p","q"],load:load);await waitUntil{starts.count==1}
        pass(starts==["p"],"only one speculative cover starts at once")
        for path in ["a","b"]{queue.subscribe(path,id:UUID(),load:{try await load(path)}){if case .success=$0{delivered+=1}}}
        await waitUntil{starts.count==3}
        queue.subscribe("c",id:UUID(),load:{try await load("c")}){if case .success=$0{delivered+=1}}
        await waitUntil{starts.contains("c")}
        pass(!starts.contains("q"),"visible demand preempts speculative work and takes priority")
        gates.removeValue(forKey:"p")?.resume(returning:sample);queue.prefetch([],load:load)
        for path in ["a","b","c"]{gates.removeValue(forKey:path)?.resume(returning:sample)}
        await waitUntil{delivered==3}
        pass(!starts.contains("q"),"obsolete next-screen requests are removed")
        let promoted=CoverPipeline();var promotedStarts=0,promotedDone=false,promotedGate:CheckedContinuation<Data,Error>?
        promoted.prefetch(["same"]){_ in promotedStarts+=1;return try await withCheckedThrowingContinuation{promotedGate=$0}}
        await waitUntil{promotedGate != nil}
        promoted.subscribe("same",id:UUID(),load:{preconditionFailure("duplicate request")}){if case .success=$0{promotedDone=true}}
        promotedGate?.resume(returning:sample);await waitUntil{promotedDone}
        pass(promotedStarts==1,"prefetched cover promotes to visible without duplicate fetch")
        var stopGate:CheckedContinuation<Data,Error>?,stopStarts=0
        promoted.prefetch(["stop"]){_ in stopStarts+=1;return try await withCheckedThrowingContinuation{stopGate=$0}}
        await waitUntil{stopGate != nil};promoted.suspend(true);stopGate?.resume(returning:sample);promoted.suspend(false)
        try? await Task.sleep(nanoseconds:100_000_000)
        pass(stopStarts==1,"reader/background suspension removes speculative work")
        let demoted=CoverPipeline();let subscriber=UUID();var demotionGates:[String:CheckedContinuation<Data,Error>]=[:],cancelled=false
        func demotionLoad(_ path:String)async throws->Data{
            let result:Data=try await withCheckedThrowingContinuation{demotionGates[path]=$0}
            if path=="visible"{cancelled=Task.isCancelled};return result
        }
        demoted.subscribe("visible",id:subscriber,load:{try await demotionLoad("visible")}){_ in}
        demoted.prefetch(["visible","ahead"],load:demotionLoad)
        await waitUntil{demotionGates.count==2}
        demoted.cancel("visible",id:subscriber)
        demotionGates.removeValue(forKey:"visible")?.resume(returning:sample)
        await waitUntil{cancelled}
        demoted.prefetch([],load:demotionLoad);demotionGates.removeValue(forKey:"ahead")?.resume(returning:sample)
        pass(cancelled,"offscreen demand cannot become a second active prefetch")
        print("\(checks) disk and prefetch checks passed")
    }
    @MainActor static func sliderChecks(){
        let control=PositionControl(frame:CGRect(x:0,y:0,width:400,height:44));control.count=101
        var previews:[Int]=[],commits:[Int]=[],edits:[Bool]=[]
        control.preview={previews.append($0)};control.commit={commits.append($0)};control.editing={edits.append($0)}
        control.begin(at:CGPoint(x:200,y:22));precondition(control.value==50 && commits.isEmpty)
        control.finish(cancelled:false);precondition(commits==[50] && edits==[true,false]);print("PASS tap anywhere commits the tapped page exactly once")
        control.begin(at:CGPoint(x:18,y:22));for x in 20...380{control.update(at:CGPoint(x:x,y:22))}
        precondition(commits.count==1);control.update(at:CGPoint(x:500,y:22));control.finish(cancelled:false)
        precondition(commits==[50,100]);print("PASS drag previews without page requests until release, clamps last page")
        control.begin(at:CGPoint(x:18,y:22));control.finish(cancelled:true)
        precondition(control.value==100 && commits.count==2);print("PASS cancelled slider restores position without navigation")
        control.vertical=true;control.frame=CGRect(x:0,y:0,width:44,height:400)
        control.begin(at:CGPoint(x:22,y:-20));control.finish(cancelled:false);precondition(commits.last==0)
        control.begin(at:CGPoint(x:22,y:400));control.finish(cancelled:false);precondition(commits.last==100)
        print("PASS vertical shelf slider maps top to first and bottom to last")
        control.accessibilityDecrement();precondition(commits.last==99);control.accessibilityIncrement();precondition(commits.last==100)
        print("PASS VoiceOver adjustable actions navigate")
        let before=commits.count;control.isEnabled=false;control.begin(at:.zero);control.finish(cancelled:false);control.accessibilityDecrement()
        precondition(commits.count==before);control.isEnabled=true;control.count=1;control.begin(at:.zero);precondition(!control.scrubbing)
        print("PASS disabled and single-item sliders do not navigate")
        print("6 slider interaction checks passed")
    }
    @MainActor static func pairingChecks()async {
        func waitUntil(_ test:()->Bool)async{for _ in 0..<500{if test(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("pairing test timeout")}
        var stored:PairingCode?
        func make(_ lookup:@escaping(String)async->[String]={_ in ["http://192.168.240.124:8088"]})->Library{
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PairingFixture.self]
            return Library(transport:LimitedHTTP(configuration:config),loadPair:{stored},savePair:{stored=$0},removePair:{stored=nil},lookup:lookup)
        }
        let code=PairingCode(app:"localshelf",version:2,address:"http://192.168.240.124:8088",token:PairingFixture.token,deviceId:PairingFixture.id)
        let account="test-"+UUID().uuidString
        do {
            try PairingKeychain.save(code,account:account)
            let restored=try PairingKeychain.load(account:account)
            precondition(restored?.deviceId==code.deviceId && restored?.token==code.token)
            try PairingKeychain.save(PairingCode(app:"localshelf",version:2,address:"http://192.168.240.125:8088",token:code.token,deviceId:code.deviceId),account:account)
            let updated=try PairingKeychain.load(account:account);precondition(updated?.address=="http://192.168.240.125:8088")
            try PairingKeychain.remove(account:account);let deleted=try PairingKeychain.load(account:account);precondition(deleted==nil)
            print("PASS isolated system Keychain save read update and delete")
        }catch{try? PairingKeychain.remove(account:account);preconditionFailure("Keychain fixture failed: \((error as NSError).code)")}
        let first=make();await first.connect(code:code)
        precondition(stored?.deviceId==code.deviceId && first.total==1);print("PASS first pairing saved only after identity and library validation")
        let digits=make();digits.address=code.address;await digits.connect(pin:"001234")
        precondition(digits.base != nil && stored?.token==code.token && stored?.version==2);print("PASS six-digit POST exchanges for verified persistent identity")
        let wrongPIN=make();wrongPIN.address=code.address;await wrongPIN.connect(pin:"999999")
        precondition(wrongPIN.base==nil && !wrongPIN.error.isEmpty && stored?.token==code.token);print("PASS rejected PIN preserves existing pairing")
        let restarted=make();restarted.setForeground(true);await waitUntil{restarted.base != nil};restarted.setForeground(false)
        precondition(restarted.total==1);print("PASS app relaunch restores pairing and reconnects without QR")
        stored=PairingCode(app:"localshelf",version:2,address:"http://192.168.240.123:8088",token:code.token,deviceId:code.deviceId)
        let changedIP=make();changedIP.setForeground(true);await waitUntil{changedIP.base != nil};changedIP.setForeground(false)
        precondition(stored?.address==code.address);print("PASS discovery resolves changed IP and saves validated endpoint")
        precondition(PairingFixture.hosts().allSatisfy{$0=="192.168.240.124"});print("PASS fake old IP receives no bearer token")
        let invalid=PairingCode(app:"localshelf",version:2,address:"http://192.168.240.123:8088",token:code.token,deviceId:code.deviceId)
        let failed=make();await failed.connect(code:invalid)
        precondition(failed.base==nil && stored?.address==code.address);print("PASS failed new pairing does not overwrite saved pairing")
        let revoked=PairingCode(app:"localshelf",version:2,address:code.address,token:String(repeating:"X",count:32),deviceId:code.deviceId)
        let revokedLibrary=make();let before=PairingFixture.hosts().count;await revokedLibrary.connect(code:revoked)
        precondition(revokedLibrary.base==nil && PairingFixture.hosts().count==before);print("PASS revoked credentials rejected before authenticated requests")
        stored=invalid
        var looking=false
        let forgetting=make{_ in looking=true;try? await Task.sleep(nanoseconds:200_000_000);return [code.address]}
        forgetting.setForeground(true);await waitUntil{looking};forgetting.forget()
        try? await Task.sleep(nanoseconds:300_000_000);forgetting.setForeground(false)
        precondition(stored==nil && forgetting.paired==nil && forgetting.base==nil);print("PASS forgetting invalidates in-flight discovery and prevents restoring credentials")
        stored=invalid;looking=false
        let background=make{_ in looking=true;try? await Task.sleep(nanoseconds:200_000_000);return [code.address]}
        background.setForeground(true);await waitUntil{looking};background.setForeground(false)
        try? await Task.sleep(nanoseconds:300_000_000)
        precondition(background.base==nil && !background.loading);print("PASS backgrounding cancels reconnect and rejects late commits")
        first.forget();precondition(first.books.isEmpty && first.secret.isEmpty && stored==nil);print("PASS unpair clears visible data and in-memory credentials")
        print("12 pairing lifecycle checks passed")
    }
    @MainActor static func pagerChecks()async {
        func waitUntil(_ predicate:()->Bool)async {
            for _ in 0..<500{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
            preconditionFailure("native pager test timed out")
        }
        let library=Library(),cache=ReadingCache(),pages=(1...3).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:1);await waitUntil{cache.images.count==3}
        let pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844))
        var selections:[Int]=[];pager.select={selections.append($0)}
        pager.configure(cache:cache,pages:pages,index:1,resetID:0);pager.layoutIfNeeded()
        let identities=Set(pager.slots.map{ObjectIdentifier($0)})
        precondition(pager.slots.count==3);print("PASS three persistent native page slots")
        func requireCentered(_ canvas:ZoomCanvas,_ context:String){
            canvas.layoutIfNeeded()
            let visible=canvas.picture.convert(canvas.picture.bounds,to:canvas)
            precondition(abs(visible.midX-canvas.bounds.midX)<0.5 && abs(visible.midY-canvas.bounds.midY)<0.5,"Image not centered: \(context), image=\(visible), viewport=\(canvas.bounds), offset=\(canvas.scroll.contentOffset)")
        }
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"initial page")
        for distance in stride(from:0,through:150,by:5){pager.drag(CGSize(width:-distance,height:0),ended:false)}
        precondition(selections.isEmpty && pager.index==1 && pager.content.transform.tx == -150)
        print("PASS drag changes compositor transform without selection binding updates")
        pager.settle(target:2,animated:false)
        precondition(selections==[2] && pager.index==2 && pager.content.transform == .identity)
        print("PASS settle commits page once and recenters")
        requireCentered(pager.slots.first{$0.position==2}!.canvas,"after page turn")
        print("PASS displayed image remains centered after page turn")
        precondition(identities==Set(pager.slots.map{ObjectIdentifier($0)}));print("PASS page slots reused after navigation")
        pager.configure(cache:cache,pages:pages,index:0,resetID:1);pager.drag(CGSize(width:100,height:0),ended:false)
        precondition(abs(pager.content.transform.tx-18)<0.001 && selections==[2]);pager.cancelMotion()
        print("PASS first-page resistance and external jump without duplicate selection")
        pager.settle(target:1);pager.configure(cache:cache,pages:pages,index:2,resetID:2)
        try? await Task.sleep(nanoseconds:350_000_000)
        precondition(pager.index==2 && selections==[2] && !pager.motionActive)
        print("PASS slider jump invalidates obsolete animation completion")
        pager.configure(cache:cache,pages:pages,index:0,resetID:3);pager.settle(target:1)
        await waitUntil{!pager.motionActive};precondition(pager.index==1 && selections==[2,1])
        print("PASS native animation completes with one page notification")
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"animated page turn")
        print("PASS animated page turn preserves image center")
        for index in [2,1,0,1,2,1] {
            pager.settle(target:index,animated:false)
            requireCentered(pager.slots.first{$0.position==index}!.canvas,"repeated forward/backward turn")
        }
        print("PASS repeated forward/backward slot reuse stays centered")
        pager.frame.size=CGSize(width:844,height:390);pager.layoutIfNeeded()
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"landscape viewport")
        pager.frame.size=CGSize(width:390,height:844);pager.layoutIfNeeded()
        requireCentered(pager.slots.first{$0.position==1}!.canvas,"portrait viewport")
        print("PASS viewport rotation centers both axes")
        let slot=pager.slots.first{$0.position==1}!
        var returns=0;pager.returnToLibrary={returns+=1}
        precondition(pager.edgeReturn.maximumNumberOfTouches==1 && PagingRules.returnEdgeWidth==48)
        slot.canvas.zoomChanged?(true)
        pager.finishEdgeReturn(translation:CGPoint(x:0,y:150),velocity:CGPoint(x:0,y:1000),ended:true);precondition(returns==0)
        pager.finishEdgeReturn(translation:CGPoint(x:100,y:0),velocity:.zero,ended:false);precondition(returns==0)
        pager.finishEdgeReturn(translation:CGPoint(x:100,y:0),velocity:.zero,ended:true);precondition(returns==1)
        slot.canvas.zoomChanged?(false)
        print("PASS only completed left-edge right swipe returns, including while zoomed")
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let landscape=UIGraphicsImageRenderer(size:CGSize(width:900,height:600),format:format).image{UIColor.white.setFill();$0.fill(CGRect(x:0,y:0,width:900,height:600))}
        slot.show(number:99,image:landscape,failed:false,active:true,reset:true);slot.layoutIfNeeded();slot.canvas.layoutIfNeeded()
        precondition(abs(slot.canvas.picture.bounds.width/slot.canvas.picture.bounds.height-1.5)<0.01)
        print("PASS reused canvas refits a different image aspect ratio")
        requireCentered(slot.canvas,"different image aspect ratio")
        for _ in 0..<3 {
            slot.show(number:99,image:landscape,failed:false,active:true,reset:true)
            requireCentered(slot.canvas,"unchanged centering inset after reset")
        }
        print("PASS same-inset resets and different image aspect ratios stay centered")
        let canvas=slot.canvas
        // Exercise retained layout math with a synthetic programmatic scale only.
        // Production has max=min=1 and no zoom gesture or UI entry point.
        precondition(canvas.scroll.maximumZoomScale==1 && canvas.scroll.pinchGestureRecognizer?.isEnabled != true)
        canvas.scroll.maximumZoomScale=5
        canvas.scroll.setZoomScale(2.5,animated:false)
        canvas.scroll.setContentOffset(CGPoint(x:80,y:-50),animated:false)
        let focalOffset=canvas.scroll.contentOffset,scale=canvas.scroll.zoomScale
        let detail=UIGraphicsImageRenderer(size:CGSize(width:1800,height:1200),format:format).image{UIColor.gray.setFill();$0.fill(CGRect(x:0,y:0,width:1800,height:1200))}
        slot.show(number:99,image:detail,failed:false,active:true,reset:false);canvas.layoutIfNeeded()
        precondition(canvas.scroll.contentOffset==focalOffset && canvas.scroll.zoomScale==scale)
        print("PASS zoomed detail replacement preserves focal offset and scale")
        canvas.scroll.setZoomScale(1,animated:false);canvas.layoutIfNeeded()
        requireCentered(canvas,"zoom back to fit")
        print("PASS zoom reset restores image center")
        canvas.scroll.setZoomScale(2.5,animated:false)
        slot.show(number:100,image:landscape,failed:false,active:true,reset:true)
        requireCentered(canvas,"recycle a zoomed page")
        print("PASS recycling a zoomed page restores image center")
        slot.show(number:99,image:nil,failed:true,active:true,reset:false)
        precondition(slot.canvas.picture.image==nil && !slot.retry.isHidden);print("PASS missing page releases image and exposes retry")
        pager.dispose();cache.clear();precondition(pager.slots.allSatisfy{$0.canvas.picture.image==nil})
        print("PASS leaving reader clears native image references")
        print("19 native pager checks passed")
    }
    @MainActor static func rapidPagerChecks()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)")}
        func waitUntil(line:UInt=#line,_ value:()->Bool)async{for _ in 0..<500{if value(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("rapid pager timeout at \(line)")}
        let library=Library(),cache=ReadingCache(),pages=(1...8).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:2);await waitUntil{cache.images.count==5}
        let pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844))
        pager.configure(cache:cache,pages:pages,index:2,resetID:0)
        let scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
        let window=UIWindow(windowScene:scene),host=UIViewController();host.view=pager;window.rootViewController=host;window.isHidden=false
        defer{window.isHidden=true;window.rootViewController=nil;pager.dispose();cache.clear()}
        pager.layoutIfNeeded();try? await Task.sleep(nanoseconds:50_000_000)
        var selections:[Int]=[]
        pager.select={target in selections.append(target);cache.update(library:library,book:"0",pages:pages,index:target);pager.configure(cache:cache,pages:pages,index:target,resetID:0)}
        let identities=Set(pager.slots.map{ObjectIdentifier($0)}),span=pager.bounds.width+12
        pass(pager.pagePan.view === pager && pager.pagePan.maximumNumberOfTouches==1,"single container pan owns all visible pages")
        pager.settle(target:3);try? await Task.sleep(nanoseconds:60_000_000)
        let visible=pager.content.layer.presentation()!.affineTransform().tx
        pager.beginContact(at:CGPoint(x:100,y:300))
        let held=pager.content.transform.tx
        pass(!pager.motionActive && abs(held-visible)<2,"touch-down freezes the presentation position without snapping")
        try? await Task.sleep(nanoseconds:80_000_000)
        pass(abs(pager.content.transform.tx-held)<0.01,"held animation remains stationary before pan recognition")
        let incoming=pager.slots.first{$0.position==3}!,before=incoming.convert(.zero,to:pager).x
        let nearest=PagingRules.index(2+Int((-held/span).rounded()),count:pages.count)
        pager.beginDrag()
        pass(pager.index==nearest && abs(incoming.convert(.zero,to:pager).x-before)<0.5,"nearest-page rebase keeps visible pixels stationary")
        let origin=pager.content.transform.tx
        pager.drag(CGSize(width:-25,height:0),ended:false)
        pass(abs(pager.content.transform.tx-(origin-25))<0.01,"interrupted page follows the next finger delta one-to-one")
        pager.drag(CGSize(width:-25,height:0),ended:true,velocityX:-1400)
        await waitUntil{!pager.motionActive}
        pass(pager.index==nearest+1,"short fast continuation advances beyond the caught page")
        pass(selections==Array(Set(selections)).sorted(),"interrupted completion cannot duplicate or reverse committed page order")
        pass(Set(pager.slots.map{ObjectIdentifier($0)})==identities,"rapid handoff retains three reusable page slots")
        pager.settle(target:pager.index+1);try? await Task.sleep(nanoseconds:60_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));pager.beginDrag();let caught=pager.index
        pager.drag(CGSize(width:25,height:0),ended:true,velocityX:1400)
        await waitUntil{!pager.motionActive}
        pass(pager.index==caught-1,"fast reversal takes over the moving page instead of being ignored")
        for direction in [1,1,-1,1,-1,-1] {
            pager.settle(target:PagingRules.index(pager.index+direction,count:pages.count))
            try? await Task.sleep(nanoseconds:35_000_000)
            pager.beginContact(at:CGPoint(x:100,y:300));pager.beginDrag()
            let base=pager.index,target=PagingRules.index(base+direction,count:pages.count)
            pager.drag(CGSize(width:CGFloat(-direction*24),height:0),ended:true,velocityX:CGFloat(-direction*1500))
            await waitUntil{!pager.motionActive}
            precondition(pager.index==target && pager.content.transform == .identity)
        }
        pass(true,"six alternating in-flight handoffs keep page state and transforms consistent")
        let current=pager.index,next=PagingRules.index(current+1,count:pages.count)
        pager.settle(target:next);try? await Task.sleep(nanoseconds:30_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));pager.finishContact()
        await waitUntil{!pager.motionActive}
        pass(pager.index==next,"tap or rejected pan resumes the held settle")
        pager.configure(cache:cache,pages:pages,index:0,resetID:1)
        pager.drag(CGSize(width:120,height:0),ended:false);pager.settle(target:0)
        try? await Task.sleep(nanoseconds:30_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));let bounce=pager.content.transform.tx
        pager.beginDrag();pager.drag(.zero,ended:false)
        pass(abs(pager.content.transform.tx-bounce)<0.5,"catching boundary bounce does not apply resistance twice")
        pager.cancelMotion();let startIndex=pager.index
        let canvas=pager.slots.first{$0.position==startIndex}!.canvas
        pass(canvas.scroll.maximumZoomScale==1 && canvas.scroll.pinchGestureRecognizer?.isEnabled != true,"reader has no enabled pinch zoom")
        pass(!(canvas.scroll.gestureRecognizers ?? []).contains{($0 as? UITapGestureRecognizer)?.numberOfTapsRequired==2},"reader has no double-tap zoom recognizer")
        canvas.scroll.setZoomScale(1,animated:false);pager.configure(cache:cache,pages:pages,index:0,resetID:2)
        pager.settle(target:1);try? await Task.sleep(nanoseconds:25_000_000)
        pager.beginContact(at:CGPoint(x:100,y:300));pager.beginDrag();pager.drag(CGSize(width:-50,height:0),ended:false)
        pager.configure(cache:cache,pages:pages,index:6,resetID:3)
        try? await Task.sleep(nanoseconds:300_000_000)
        pass(pager.index==6 && !pager.motionActive && pager.content.transform == .identity,"external jump invalidates interrupted motion and drag origin")
        pager.settle(target:7);pager.beginContact(at:CGPoint(x:100,y:300));pager.endPresentation();pager.finishContact()
        try? await Task.sleep(nanoseconds:300_000_000)
        pass(!pager.motionActive && pager.animationPlayer.key==nil,"exit while a settle is held cannot resume it later")
        print("\(checks) rapid pager checks passed")
    }
    @MainActor static func performanceChecks()async {
        func waitUntil(_ predicate:()->Bool)async {
            for _ in 0..<500{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
            preconditionFailure("performance test timed out")
        }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[TransferFixture.self]
        let transport=LimitedHTTP(configuration:config)
        func request(_ path:String)->URLRequest {URLRequest(url:URL(string:"http://192.168.240.123/"+path)!)}
        do{
            let parallelRequest=request("ok")
            let bytes=try await withThrowingTaskGroup(of:Int.self){group in
                for _ in 0..<6{group.addTask{try await transport.data(parallelRequest,limit:5).count}}
                var sum=0;for try await count in group{sum+=count};return sum
            }
            precondition(bytes==30);print("PASS concurrent transport initialization and request isolation")
            let data=try await transport.data(request("ok"),limit:5);precondition(data.count==5);print("PASS chunked exact limit")
            let validated=try await transport.response(request("not-modified"),limit:5,allowNotModified:true)
            precondition(validated.status==304 && validated.data.isEmpty && validated.etag != nil);print("PASS explicit conditional transport accepts zero-body 304 and preserves ETag")
            for path in ["large","header","status","not-modified"] {
                do{_=try await transport.data(request(path),limit:5);preconditionFailure("response should fail")}
                catch{print("PASS transport rejects \(path)")}
            }
            let waiting=Task{try await transport.data(request("wait"),limit:5)}
            await Task.yield();waiting.cancel()
            do{_=try await waiting.value;preconditionFailure("cancellation ignored")}catch{print("PASS transport cancellation")}
        }catch{preconditionFailure("transport fixture failed: \(error)")}
        transport.close()
        let library=Library(),cache=ReadingCache(),pages=(1...5).map{Page(number:$0)}
        requests.removeAll();cache.update(library:library,book:"0",pages:pages,index:2)
        await waitUntil{cache.images.count==5}
        precondition(cache.retainedBytes<=ReadingBudget.normal);print("PASS reading retained budget")
        let path="/v1/books/0/pages/3",before=requests[path]
        cache.loadDetail(3);await waitUntil{cache.detailImage != nil || cache.detailFailed}
        precondition(cache.detailImage != nil && requests[path]==before && cache.retainedBytes<=ReadingBudget.normal);print("PASS zoom reuses compressed page without network fetch")
        cache.memoryPressure();let requestCount=requests.values.reduce(0,+)
        await Task.yield()
        precondition(cache.reducedMemory && Set(cache.images.keys)==Set([3]) && cache.detailImage==nil && cache.retainedBytes<=ReadingBudget.pressure && requests.values.reduce(0,+)==requestCount)
        print("PASS memory warning keeps current page without rewarming neighbors")
        cache.update(library:library,book:"0",pages:pages,index:3);await waitUntil{cache.images[4] != nil}
        precondition(cache.images.count==1);print("PASS pressure mode only requests current page after navigation")
        cache.restorePrefetch();cache.update(library:library,book:"0",pages:pages,index:3)
        await waitUntil{cache.images.count==4};precondition(cache.retainedBytes<=ReadingBudget.normal);print("PASS explicit prefetch recovery")
        cache.clear();precondition(cache.images.isEmpty && cache.retainedBytes==0);print("PASS reader exit releases retained data")
        print("12 runtime performance checks passed")
    }
    @MainActor static func coverChecks()async {
        let pipeline=CoverPipeline(),sample=data("1")
        var started=0,delivered=0,cancelledDelivery=0
        var gates:[String:CheckedContinuation<Data,Error>]=[:]
        func waitUntil(_ predicate:()->Bool)async {
            for _ in 0..<500 {if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
            preconditionFailure("cover check timed out")
        }
        pipeline.suspend(true)
        let first=UUID(),second=UUID(),queued=UUID()
        for (path,id) in [("a",first),("a",second),("b",UUID()),("c",UUID()),("d",queued)] {
            pipeline.subscribe(path,id:id,load:{started+=1;return try await withCheckedThrowingContinuation{gates[path]=$0}}){result in
                if id==first {cancelledDelivery+=1};if case .success=result{delivered+=1}
            }
        }
        precondition(started==0);print("PASS suspended cover queue")
        pipeline.suspend(false);await waitUntil{started==3}
        precondition(gates.count==3 && gates["d"]==nil);print("PASS concurrency limit and same-path merge")
        pipeline.cancel("a",id:first);pipeline.cancel("d",id:queued)
        for key in ["a","b","c"]{gates.removeValue(forKey:key)?.resume(returning:sample)}
        await waitUntil{delivered==3}
        precondition(started==3 && cancelledDelivery==0);print("PASS one subscriber cancellation preserves other, queued work removed")
        var hit=false
        pipeline.subscribe("a",id:UUID(),load:{preconditionFailure("cache missed")}){if case .success=$0{hit=true}}
        precondition(hit);print("PASS decoded cover cache hit")
        pipeline.trim();var reloaded=false
        pipeline.subscribe("a",id:UUID(),load:{started+=1;return sample}){if case .success=$0{reloaded=true}}
        await waitUntil{reloaded};precondition(started==4);print("PASS memory trim reload")
        var oldGate:CheckedContinuation<Data,Error>?,oldCancelled=false,newDelivered=false
        pipeline.subscribe("stale",id:UUID(),load:{try await withCheckedThrowingContinuation{oldGate=$0}}){if case .failure(let e)=$0{oldCancelled=e is CancellationError}}
        await waitUntil{oldGate != nil};pipeline.reset();precondition(oldCancelled)
        pipeline.subscribe("stale",id:UUID(),load:{sample}){if case .success=$0{newDelivered=true}}
        oldGate?.resume(returning:sample);await waitUntil{newDelivered}
        print("PASS source reset rejects stale in-flight result")
        print("6 cover pipeline checks passed")
    }
    static var largeAnimationFixture=false
    static func animationData(_ path:String)->Data {
        if path.hasSuffix("/pages"){return Data("{\"pages\":[{\"number\":1},{\"number\":2},{\"number\":3},{\"number\":4}]}".utf8)}
        // Synthetic optimized partial-frame GIF, APNG and lossless WebP.
        let samples=[
            "R0lGODlhIAAgAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAIAAgAAAINQABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJUmRAACH5BAEUAAIALAgACAAQABAAgf8AAAD/AAAAAAAAAAgdAAMIHEiwoMGDCBMqXMiwocOHECNKnEixosWBAQEAIfkEAR4AAgAsAAAAABgAGACB/wAAAAD/AAAAAAAACF4AAwgcKFCAwYMIEwogSFChw4MMBz58GLHgRIUVA1zEWHFjwoweEYIMeRGAyZMoUwJ4qLLlSZYuW8KMmXImzZcOb9bMqROnwp4+EwI1aVNn0ZtHaSaNudRlU5k8gQYEADs=",
            "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACGFjVEwAAAADAAAAAM7tusAAAAAaZmNUTAAAAAAAAAAgAAAAIAAAAAAAAAAAAAEACgAAmicj6gAAACxJREFUeNrtzjEBAAAIA6Bp/84zhg8kYJo0jzbPBAQEBAQEBAQEBAQEBAQEDjDjAj6yKjtjAAAAGmZjVEwAAAABAAAAEAAAABAAAAAIAAAACAABAAUAAHpFze4AAAAhZmRBVAAAAAJ42mNk+M/wn4ECwMRAIRg1YNSAUQMGiwEAV24CHhEdCFMAAAAaZmNUTAAAAAMAAAAYAAAAGAAAAAAAAAAAAAMACgAAqUt0egAAADRmZEFUAAAABHja7dDBDQAgDMNAh/13DhvwqfrCXuAkB1oelTDpsJyAwLwU6iIBAQGB74EL/EsFKwePTzgAAAAASUVORK5CYII=",
            "UklGRswAAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAB8AAB8AAGQAAAJWUDhMDwAAAC8fwAcABxD9j/4HIqL/AQBBTk1GKAAAAAQAAAQAAA8AAA8AAMgAAABWUDhMDwAAAC8PwAMAB9D/iP4HIqL/AQBBTk1GQAAAAAAAAAAAABcAABcAACwBAABWUDhMJwAAAC8XwAUQFxDzLyAo8n+0+Q/4gEzapiZnsjb3jQmI6P8YJAA7jeoxAQA="
        ]
        if let number=Int(path.split(separator:"/").last ?? ""),(1...3).contains(number){var data=Data(base64Encoded:samples[number-1])!;if largeAnimationFixture && number<=2{data.append(Data(repeating:0,count:9*1024*1024))};return data}
        return data("1")
    }
    @MainActor static func animationChecks()async {
        var checks=0
        func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS \(message)")}
        func waitUntil(line:UInt=#line,_ value:()->Bool)async{for _ in 0..<500{if value(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("animation check timed out at \(line)")}
        func pixel(_ image:UIImage)->[UInt8]{
            var bytes=[UInt8](repeating:0,count:32*32*4)
            bytes.withUnsafeMutableBytes{raw in let c=CGContext(data:raw.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image.cgImage!,in:CGRect(x:0,y:0,width:32,height:32))}
            let i=(16*32+16)*4;return Array(bytes[i..<i+3])
        }
        do{
            let decoder=AnimationDecoder()
            for (i,name) in ["GIF","APNG","WebP"].enumerated(){
                let ticket=UUID(),info=try await decoder.open(animationData("\(i+1)"),ticket:ticket)
                pass(info.count==3 && info.plays==0,"\(name) detects three frames and infinite loop")
                let a=try await decoder.frame(0,ticket:ticket),b=try await decoder.frame(1,ticket:ticket),c=try await decoder.frame(2,ticket:ticket)
                pass(a.0.cgImage!.width==32 && b.0.cgImage!.width==32 && c.0.cgImage!.width==32,"\(name) full canvas for partial frames")
                pass(pixel(a.0)==[255,0,0] && pixel(b.0)==[0,255,0] && pixel(c.0)==[255,0,0],"\(name) frame sequence and composition")
                pass(abs(a.1-0.1)<0.001 && abs(b.1-0.2)<0.001 && abs(c.1-0.3)<0.001,"\(name) individual frame durations")
                await decoder.close(ticket)
            }
            pass(AnimationLimits.delay(0)==0.1 && AnimationLimits.delay(.nan)==0.1,"invalid frame duration bounded")
            var finite=animationData("1")
            let loop=finite.range(of:Data("NETSCAPE2.0".utf8))!.upperBound+2;finite[loop]=1
            let finiteInfo=try await decoder.open(finite,ticket:UUID())
            pass(finiteInfo.plays==2,"GIF finite loop means first play plus one repetition")
            var webp=animationData("3");let webpLoop=webp.range(of:Data("ANIM".utf8))!.lowerBound+12;webp[webpLoop]=1
            let webpInfo=try await decoder.open(webp,ticket:UUID());pass(webpInfo.plays==1,"WebP finite loop means total plays")
            var large=animationData("1")
            for start in [6,large.range(of:Data([0x2c,0,0,0,0,32,0,32,0]))!.lowerBound+5]{large[start]=0x88;large[start+1]=0x13;large[start+2]=0x88;large[start+3]=0x13}
            do{_ = try await decoder.open(large,ticket:UUID());preconditionFailure("oversized canvas accepted")}catch{}
            pass(true,"oversized canvas is rejected before frame decoding")
            do{_ = try await decoder.open(Data(repeating:0,count:AnimationLimits.compressed+1),ticket:UUID());preconditionFailure("oversized animation accepted")}catch{}
            pass(true,"oversized input rejected before frame decoding")
        }catch{preconditionFailure("animation fixture failed: \(error)")}
        let player=AnimatedPagePlayer();var frames=0,failures=0
        player.play(key:"gif",load:{animationData("1")},display:{_ in frames+=1},failed:{failures+=1})
        await waitUntil{frames>=4};pass(failures==0,"player advances through loop")
        player.stop();let stopped=frames;try? await Task.sleep(nanoseconds:400_000_000)
        pass(frames==stopped && player.key==nil,"stop prevents late frame display")
        var finite=animationData("1");finite[finite.range(of:Data("NETSCAPE2.0".utf8))!.upperBound+2]=1
        var finiteFrames=0
        player.play(key:"finite",load:{finite},display:{_ in finiteFrames+=1},failed:{preconditionFailure("finite playback failed")})
        await waitUntil{finiteFrames==6};try? await Task.sleep(nanoseconds:500_000_000)
        pass(finiteFrames==6,"finite animation stops on its final frame");player.stop()
        let library=Library(),cache=ReadingCache(),pages=(1...4).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:0);await waitUntil{cache.images.count>=3}
        pass(cache.animated==Set([1,2,3]),"cache detects animation without playing neighbors")
        pass(cache.retainedBytes<=ReadingBudget.normal,"animation reservation fits reading budget")
        await waitUntil{cache.preparedAnimation(1) != nil && cache.preparedAnimation(2) != nil}
        let firstPrepared=cache.preparedAnimation(1)!,nextPrepared=cache.preparedAnimation(2)!
        pass(cache.animationPreheater.used<=AnimationLimits.reserve-10*1024*1024,"prepared data and first two frames obey shared budget")
        let pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844));pager.configure(cache:cache,pages:pages,index:0,resetID:0);pager.layoutIfNeeded()
        await waitUntil{pager.animationPlayer.displayedFrames>=3}
        pass(pager.animationPlayer.key=="1","only current native page plays")
        let requestCount=requests["/v1/books/0/pages/2"]
        cache.update(library:library,book:"0",pages:pages,index:1);pager.configure(cache:cache,pages:pages,index:1,resetID:1)
        pass(pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.first.0,"warm page displays its prepared first frame synchronously")
        pass(cache.preparedAnimation(2) === nextPrepared && requests["/v1/books/0/pages/2"]==requestCount,"handoff reuses decoder and compressed bytes without network")
        await waitUntil{cache.preparedAnimation(3) != nil}
        pass(cache.preparedAnimation(1) === firstPrepared,"previous animation stays prepared within budget")
        cache.update(library:library,book:"0",pages:pages,index:0);pager.configure(cache:cache,pages:pages,index:0,resetID:2)
        pass(pager.slots.first{$0.position==0}?.canvas.picture.image === firstPrepared.first.0,"reverse navigation directly reuses prepared previous page")
        // UIKit completes off-window animations early; use a visible synthetic host
        // when checking overlap between actual settling and frame presentation.
        let scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
        let window=UIWindow(windowScene:scene),host=UIViewController()
        host.view=pager;window.rootViewController=host;window.isHidden=false
        defer{window.isHidden=true;window.rootViewController=nil}
        pager.setNeedsLayout();pager.layoutIfNeeded()
        try? await Task.sleep(nanoseconds:50_000_000)
        var committed:[Int]=[]
        pager.select={target in committed.append(target);cache.update(library:library,book:"0",pages:pages,index:target);pager.configure(cache:cache,pages:pages,index:target,resetID:2)}
        pager.drag(CGSize(width:-80,height:0),ended:false)
        pass(pager.animationPlayer.key=="1" && committed.isEmpty,"tentative drag does not play the neighbor or commit its page")
        pager.cancelMotion()
        let began=ContinuousClock.now,starts=pager.animationPlayer.playbackStarts,frameCount=pager.animationPlayer.displayedFrames
        pager.settle(target:1)
        let elapsed=began.duration(to:.now)
        pass(elapsed < .milliseconds(100) && pager.animationPlayer.key=="2" && pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.first.0,"warm committed turn attaches incoming first frame within 100 ms")
        print("METRIC warm handoff main-thread attachment: \(elapsed)")
        pass(pager.motionActive && pager.index==0 && committed.isEmpty,"incoming playback starts before settle without early page selection")
        await waitUntil{pager.animationPlayer.displayedFrames>=frameCount+2}
        print("METRIC incoming second frame: \(began.duration(to:.now)); motion=\(pager.motionActive); key=\(pager.animationPlayer.key ?? "none"); starts=\(pager.animationPlayer.playbackStarts-starts); second=\(pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.second.0)")
        pass(pager.motionActive && pager.slots.first{$0.position==1}?.canvas.picture.image === nextPrepared.second.0,"incoming second frame plays while the page is still settling")
        await waitUntil{!pager.motionActive}
        pass(pager.index==1 && committed==[1] && pager.animationPlayer.playbackStarts==starts+1,"settle completion keeps playback timeline without restarting")
        let centered=pager.slots.first{$0.position==1}!.canvas
        let imageFrame=centered.picture.convert(centered.picture.bounds,to:centered)
        pass(abs(imageFrame.midY-centered.bounds.midY)<1 && abs(imageFrame.midX-centered.bounds.midX)<1,"early playback preserves centered image after settling")
        pager.settle(target:0);pager.cancelMotion()
        pass(pager.index==1 && pager.animationPlayer.key=="2","cancelled incoming transition resumes the original page")
        pager.settle(target:0);cache.setAnimationForeground(false);pager.configure(cache:cache,pages:pages,index:1,resetID:2)
        await waitUntil{!pager.motionActive}
        pass(pager.animationPlayer.key==nil,"background during settling cannot restart incoming playback")
        cache.setAnimationForeground(true);pager.configure(cache:cache,pages:pages,index:0,resetID:2)
        pager.settle(target:1)
        cache.update(library:library,book:"0",pages:pages,index:3);pager.configure(cache:cache,pages:pages,index:3,resetID:3)
        try? await Task.sleep(nanoseconds:350_000_000)
        pass(pager.index==3 && pager.animationPlayer.key==nil && !pager.motionActive,"external static-page jump rejects incoming frames and stale settle completion")
        cache.update(library:library,book:"0",pages:pages,index:0);pager.configure(cache:cache,pages:pages,index:0,resetID:4)
        pager.select=nil
        cache.setAnimationForeground(false);pager.configure(cache:cache,pages:pages,index:0,resetID:0)
        pass(pager.animationPlayer.key==nil,"background stops animation")
        cache.setAnimationForeground(true);pager.configure(cache:cache,pages:pages,index:0,resetID:0)
        cache.toggleAnimation();pager.configure(cache:cache,pages:pages,index:0,resetID:0)
        pass(pager.animationPlayer.key==nil,"manual pause stops animation")
        cache.update(library:library,book:"0",pages:pages,index:3);await waitUntil{cache.images[4] != nil};pager.configure(cache:cache,pages:pages,index:3,resetID:1)
        pass(pager.animationPlayer.key==nil && !cache.animationPaused,"static next page stops playback")
        cache.update(library:library,book:"0",pages:pages,index:1);await waitUntil{cache.images[2] != nil};pager.configure(cache:cache,pages:pages,index:1,resetID:2)
        pager.settle(target:0);pager.endPresentation()
        try? await Task.sleep(nanoseconds:350_000_000)
        pass(pager.animationPlayer.key==nil && !pager.motionActive,"leaving a settling reader cannot restart playback after view disappearance")
        cache.memoryPressure();pager.configure(cache:cache,pages:pages,index:1,resetID:2)
        pass(pager.animationPlayer.key==nil && cache.retainedBytes<=ReadingBudget.pressure,"memory pressure stops playback")
        pager.dispose();cache.clear();pass(cache.retainedBytes==0 && cache.animated.isEmpty,"exit releases playback and cache")
        pass(cache.animationPreheater.used==0,"exit clears prepared source pool")
        largeAnimationFixture=true
        let bigLibrary=Library(),big=ReadingCache();let bigPath="/v1/books/0/pages/1",before=requests["/v1/books/0/pages/1",default:0]
        big.update(library:bigLibrary,book:"0",pages:pages,index:0)
        await waitUntil{big.preparedAnimation(1) != nil}
        await waitUntil{big.preparedAnimation(2) != nil}
        pass(big.preparedAnimation(2) != nil,"large neighboring input is staged until decoder budget is available")
        do{let prepared=try await big.prepareAnimation(1);pass(prepared === big.preparedAnimation(1) && requests[bigPath,default:0]==before+1,"file larger than old 8 MiB cache is not downloaded twice")}catch{preconditionFailure("large warm handoff failed")}
        pass(big.retainedBytes<=ReadingBudget.normal && big.animationPreheater.used<=AnimationLimits.reserve-10*1024*1024,"large prepared source remains bounded")
        big.clear();largeAnimationFixture=false
        let reordered=AnimationPreheater();reordered.configure([1,2])
        var padded=animationData("1");padded.append(Data(repeating:0,count:9*1024*1024))
        reordered.offer(2,data:padded);reordered.offer(1,data:padded)
        await waitUntil{reordered.value(1) != nil && reordered.value(2) != nil}
        pass(reordered.used<=AnimationLimits.reserve-10*1024*1024,"neighbor arriving first retains bytes when current page takes priority")
        reordered.clear()
        let isolated=AnimationPreheater();isolated.configure([1]);isolated.offer(1,data:animationData("1"));isolated.clear()
        try? await Task.sleep(nanoseconds:100_000_000)
        pass(isolated.value(1)==nil && isolated.used==0,"cleared preheat jobs cannot resurrect stale sources")
        print("\(checks) animation checks passed")
    }
    static func data(_ path:String)->Data {
        if path.hasSuffix("/pages"){return Data("{\"pages\":[{\"number\":1},{\"number\":2},{\"number\":3}]}".utf8)}
        let number=Int(path.split(separator:"/").last ?? "1") ?? 1
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:1200,height:1800),format:format).jpegData(withCompressionQuality:0.9){context in
            UIColor(white:0.94,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:1200,height:1800))
            let colors:[UIColor]=[.systemTeal,.systemIndigo,.systemOrange]
            for row in 0..<6 {for col in 0..<4 {
                colors[(number-1)%3].withAlphaComponent(CGFloat(row+col+2)/12).setFill()
                context.fill(CGRect(x:CGFloat(col*300+8),y:CGFloat(row*300+8),width:284,height:284))
                "\(row+1)-\(col+1)".draw(at:CGPoint(x:CGFloat(col*300+30),y:CGFloat(row*300+35)),withAttributes:[.font:UIFont.systemFont(ofSize:40),.foregroundColor:UIColor.black])
            }}
            "PAGE \(number)".draw(at:CGPoint(x:280,y:830),withAttributes:[.font:UIFont.boldSystemFont(ofSize:130),.foregroundColor:UIColor.black])
        }
    }
}
struct ReaderDemoView:View {
    @StateObject private var library=Library()
    var body:some View {NavigationStack{Reader(library:library,book:Book(id:"0",title:"阅读测试 · 合成网格",rank:0))}}
}
struct ShelfDemoView:View {
    @StateObject private var library=Library(loadPair:{nil},savePair:{_ in},removePair:{})
    var body:some View {ShelfView(library:library).task{
        library.base=URL(string:"http://192.168.240.123:8088");library.pageSize=500
        await library.loadPage(0)
        if ProcessInfo.processInfo.arguments.contains("--shelf-jump-checks"){
            @MainActor func allViews(_ view:UIView)->[UIView]{[view]+view.subviews.flatMap{allViews($0)}}
            @MainActor func views()->[UIView]{UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap{$0.windows}.flatMap{allViews($0)}}
            @MainActor func settled() async{try? await Task.sleep(nanoseconds:600_000_000)}
            @MainActor func slider(count:Int) async->PositionControl{
                for _ in 0..<500{
                    if !library.loading,library.books.count==count,let control=views().compactMap({$0 as? PositionControl}).first(where:{$0.vertical && $0.count==count && $0.isEnabled}){await settled();return control}
                    try? await Task.sleep(nanoseconds:10_000_000)
                };preconditionFailure("local shelf slider missing: \(count), \(library.error)")
            }
            @MainActor func checkPage(count:Int) async{
                let control=await slider(count:count)
                guard let scroll=views().compactMap({$0 as? UIScrollView}).first(where:{$0.contentSize.height>$0.bounds.height+100}) else{preconditionFailure("shelf scroll missing")}
                let page=library.pageIndex,ids=library.books.map(\.id),requests=ReaderDemo.requests["shelf-list"]
                let start=scroll.contentOffset.y
                control.begin(at:CGPoint(x:37,y:control.bounds.height))
                precondition(scroll.contentOffset.y==start,"preview must not scroll or load")
                control.finish(cancelled:false);await settled()
                precondition(scroll.contentOffset.y+scroll.bounds.height>=scroll.contentSize.height-80,"bottom target not visible")
                precondition(control.value==count-1,"bottom rail must reach current-page endpoint: \(control.value) / \(count)")
                let bottom=scroll.contentOffset.y
                control.begin(at:CGPoint(x:37,y:control.bounds.height/2));control.finish(cancelled:false);await settled()
                precondition(scroll.contentOffset.y<bottom-100 && control.value>0 && control.value<count-1,"middle seek")
                control.begin(at:CGPoint(x:37,y:0));control.finish(cancelled:false);await settled()
                precondition(control.value<3 && scroll.contentOffset.y<600,"return to local first row")
                precondition(library.pageIndex==page && library.books.map(\.id)==ids && ReaderDemo.requests["shelf-list"]==requests,"rail must not cross page, reorder, or request catalog")
                control.layoutIfNeeded()
                precondition(!control.point(inside:CGPoint(x:1,y:control.bounds.height-20),with:nil),"empty overlay must pass cover taps through")
                precondition(control.point(inside:CGPoint(x:37,y:control.bounds.height-20),with:nil),"edge track remains tappable")
                print("PASS local \(count)-book rail: endpoints, middle, no catalog requests/order changes, hit testing")
            }
            await checkPage(count:500)
            await library.loadPage(24);await checkPage(count:71)
            library.pageSize=50
            _=await slider(count:50);await checkPage(count:50)
            await library.loadPage(241);await checkPage(count:21)
            print("4 current-page shelf integration scenarios passed");exit(0)
        }
    }}
}
#endif
@main struct LocalShelfApp:App {
    var body:some Scene {WindowGroup{Group{
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--nas-checks"){Text("NAS 迁移检查").task{await NASChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--page-cache-checks"){Text("页码缓存检查").task{await PageListChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--scroll-network-benefits"){Text("快滑网络对照").task{await ScrollNetworkBenefits.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--parsing-checks"){Text("后台解析检查").task{await ParsingChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--cache-read-benefits"){Text("缓存读取对照").task{await CacheReadBenefits.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--p34-checks"){Text("分页与编码队列测试").task{await P34Checks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--cover-v2-checks"){Text("增强封面与动图缓冲测试").task{await CoverV2Checks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--animation-checks"){Text("动图测试").task{await ReaderDemo.animationChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--animation-demo"){ReaderDemoView()}
        else if ProcessInfo.processInfo.arguments.contains("--scheduling-checks"){Text("调度与后台写入测试").task{await ReaderDemo.schedulingChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--disk-cover-checks"){Text("封面磁盘与预取测试").task{await ReaderDemo.diskCoverChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--slider-checks"){Text("滑块测试").task{ReaderDemo.sliderChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--pairing-checks"){Text("配对测试").task{await ReaderDemo.pairingChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--native-pager-checks"){Text("原生翻页测试").task{await ReaderDemo.pagerChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--rapid-pager-checks"){Text("连续翻页测试").task{await ReaderDemo.rapidPagerChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--performance-checks"){Text("内存与传输测试").task{await ReaderDemo.performanceChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--cover-checks") {Text("封面队列测试").task{await ReaderDemo.coverChecks();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--reader-demo"){ReaderDemoView()}
        else if ProcessInfo.processInfo.arguments.contains("--shelf-demo") || ProcessInfo.processInfo.arguments.contains("--shelf-jump-checks"){ShelfDemoView()}else{ShelfView()}
        #else
        ShelfView()
        #endif
    }.preferredColorScheme(.dark)}}
}
