#if DEBUG && targetEnvironment(simulator)
import UIKit
import ImageIO
import Foundation

private actor CoverDecoder {
    func decode(_ data:Data)throws->UIImage {
        try Task.checkCancellation()
        guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:600,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
        return UIImage(cgImage:cg)
    }
}

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
