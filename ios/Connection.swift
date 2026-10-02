import Foundation
import SwiftUI
import UIKit
import VisionKit
import Security

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
    struct Payload {let data:Data;let status:Int;let etag:String?;var thumbnailPixels:Int?=nil}
    private final class State {
        var buffer:TransferBuffer
        var status=200;var etag:String?
        let allowNotModified:Bool
        let sink:BodyStreamSink?
        let continuation:CheckedContinuation<Payload,Error>
        init(limit:Int,allowNotModified:Bool,sink:BodyStreamSink?,continuation:CheckedContinuation<Payload,Error>){buffer=TransferBuffer(limit:limit);self.allowNotModified=allowNotModified;self.sink=sink;self.continuation=continuation}
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
    private let resourceTimeout:TimeInterval
    init(configuration:URLSessionConfiguration = .ephemeral,resourceTimeout:TimeInterval=120){self.configuration=configuration;self.resourceTimeout=resourceTimeout;super.init()}
    private lazy var session:URLSession = {
        let config=configuration;config.urlCache=nil;config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=resourceTimeout
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1
        return URLSession(configuration:config,delegate:self,delegateQueue:queue)
    }()
    // Call on the Library's main actor; delegate chunk accumulation stays off it.
    func data(_ request:URLRequest,limit:Int,priority:Float=URLSessionTask.defaultPriority)async throws->Data {
        try await response(request,limit:limit,priority:priority).data
    }
    func response(_ request:URLRequest,limit:Int,priority:Float=URLSessionTask.defaultPriority,allowNotModified:Bool=false,sink:BodyStreamSink?=nil)async throws->Payload {
        let cancellation=Cancellation()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation{continuation in
                lock.lock();let task=session.dataTask(with:request)
                task.priority=priority;tasks[task.taskIdentifier]=task
                states[task.taskIdentifier]=State(limit:limit,allowNotModified:allowNotModified,sink:sink,continuation:continuation);lock.unlock()
                cancellation.attach(task);task.resume()
            }
        },onCancel:{cancellation.cancel()})
    }
    private func finish(_ task:URLSessionTask,error:Error?){
        lock.lock();let state=states.removeValue(forKey:task.taskIdentifier);tasks.removeValue(forKey:task.taskIdentifier);lock.unlock()
        guard let state else{return}
        if let error{state.continuation.resume(throwing:error)}else{
            do{try state.sink?.finish(etag:state.etag);state.continuation.resume(returning:Payload(data:state.buffer.data,status:state.status,etag:state.etag))}
            catch{state.continuation.resume(throwing:error)}
        }
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
            let error:Error=PageReadFailure.header(status:http.statusCode,code:http.value(forHTTPHeaderField:"X-LocalShelf-Error")).map{$0 as Error} ?? ServerFailure.status(http.statusCode)
            completionHandler(.cancel);finish(dataTask,error:error);return
        }
        if let expected=dataTask.originalRequest?.value(forHTTPHeaderField:"If-Match"),let http=response as? HTTPURLResponse,http.statusCode==200,
           let actual=http.value(forHTTPHeaderField:"ETag"),ManifestValidator.valid(expected),ManifestValidator.valid(actual),expected != actual {
            completionHandler(.cancel);finish(dataTask,error:PageReadFailure.changed);return
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
        do{if let sink=state.sink{try sink.append(data)}else{try state.buffer.append(data)}}catch{dataTask.cancel();finish(dataTask,error:error)}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){finish(task,error:error)}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func close(){lock.lock();let current=session;lock.unlock();current.invalidateAndCancel()}
}
