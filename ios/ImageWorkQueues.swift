import Foundation
import UIKit

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
