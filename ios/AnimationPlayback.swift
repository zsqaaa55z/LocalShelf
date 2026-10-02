import Foundation
import UIKit
import ImageIO

// Each prepared session owns one serial decoder; frames are never expanded in full.
actor AnimationDecoder {
    struct Info {let count:Int,plays:Int,plan:AnimationPlan}
    private var source:CGImageSource?
    private var pixelLimit=1024
    private var frameDelays:[Double?]=[]
    private var ticket:UUID?
    private var dictionary:CFString=kCGImagePropertyGIFDictionary
    private var delayKey:CFString=kCGImagePropertyGIFDelayTime
    private var unclampedKey:CFString=kCGImagePropertyGIFUnclampedDelayTime
    func open(_ data:Data,ticket:UUID)async throws->Info{
        try await AnimationFrameSlots.shared.acquire()
        do {
            let info=try inspect(data,ticket:ticket)
            await AnimationFrameSlots.shared.release();return info
        }catch{await AnimationFrameSlots.shared.release();throw error}
    }
    private func inspect(_ data:Data,ticket:UUID)throws->Info{
        try Task.checkCancellation();source=nil;self.ticket=nil;frameDelays=[]
        guard data.count<=AnimationLimits.compressed else{throw AnimationFailure.fileSize(data.count)}
        guard let input=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary) else{throw AnimationFailure.unsupported}
        let count=CGImageSourceGetCount(input)
        guard count<=AnimationLimits.maxFrames else{throw AnimationFailure.frameCount(count)}
        let type=CGImageSourceGetType(input) as String? ?? ""
        let loopKey:CFString,canvasWidth:CFString,canvasHeight:CFString,framesKey:CFString
        switch type {
        case "com.compuserve.gif":dictionary=kCGImagePropertyGIFDictionary;delayKey=kCGImagePropertyGIFDelayTime;unclampedKey=kCGImagePropertyGIFUnclampedDelayTime;loopKey=kCGImagePropertyGIFLoopCount;canvasWidth=kCGImagePropertyGIFCanvasPixelWidth;canvasHeight=kCGImagePropertyGIFCanvasPixelHeight;framesKey=kCGImagePropertyGIFFrameInfoArray
        case "public.png":dictionary=kCGImagePropertyPNGDictionary;delayKey=kCGImagePropertyAPNGDelayTime;unclampedKey=kCGImagePropertyAPNGUnclampedDelayTime;loopKey=kCGImagePropertyAPNGLoopCount;canvasWidth=kCGImagePropertyAPNGCanvasPixelWidth;canvasHeight=kCGImagePropertyAPNGCanvasPixelHeight;framesKey=kCGImagePropertyAPNGFrameInfoArray
        case "org.webmproject.webp":dictionary=kCGImagePropertyWebPDictionary;delayKey=kCGImagePropertyWebPDelayTime;unclampedKey=kCGImagePropertyWebPUnclampedDelayTime;loopKey=kCGImagePropertyWebPLoopCount;canvasWidth=kCGImagePropertyWebPCanvasPixelWidth;canvasHeight=kCGImagePropertyWebPCanvasPixelHeight;framesKey=kCGImagePropertyWebPFrameInfoArray
        default:throw AnimationFailure.unsupported
        }
        let global=CGImageSourceCopyProperties(input,nil) as? [CFString:Any]
        let animation=global?[dictionary] as? [CFString:Any]
        let properties=CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any]
        // Animation-wide canvas dimensions are authoritative for partial-frame
        // formats; valid files can expose an empty per-frame property dictionary.
        guard let width=(animation?[canvasWidth] ?? global?[kCGImagePropertyPixelWidth] ?? properties?[kCGImagePropertyPixelWidth]) as? NSNumber,
              let height=(animation?[canvasHeight] ?? global?[kCGImagePropertyPixelHeight] ?? properties?[kCGImagePropertyPixelHeight]) as? NSNumber,
              width.doubleValue.isFinite,height.doubleValue.isFinite,width.doubleValue>0,height.doubleValue>0,
              width.doubleValue<Double(Int.max),height.doubleValue<Double(Int.max) else{throw AnimationFailure.invalidMetadata}
        let plan=try AnimationPlan.make(bytes:data.count,width:width.intValue,height:height.intValue,frames:count)
        if let frames=animation?[framesKey] as? [[CFString:Any]] {
            frameDelays=frames.prefix(count).map{($0[unclampedKey] as? NSNumber)?.doubleValue ?? ($0[delayKey] as? NSNumber)?.doubleValue}
        }
        let loops=(animation?[loopKey] as? NSNumber)?.intValue
        // ImageIO already normalizes GIF repetitions into total plays.
        let plays=loops.map{$0==0 ? 0 : max(1,$0)} ?? 1
        try Task.checkCancellation();source=input;self.ticket=ticket;pixelLimit=plan.pixelLimit
        return Info(count:count,plays:plays,plan:plan)
    }
    func frame(_ index:Int,ticket:UUID)async throws->(UIImage,Double){
        try await AnimationFrameSlots.shared.acquire()
        do {
            let frame=try decodeFrame(index,ticket:ticket)
            await AnimationFrameSlots.shared.release();return frame
        }catch{await AnimationFrameSlots.shared.release();throw error}
    }
    private func decodeFrame(_ index:Int,ticket:UUID)throws->(UIImage,Double){
        try Task.checkCancellation()
        guard self.ticket==ticket,let source,index>=0,index<CGImageSourceGetCount(source) else{throw CancellationError()}
        #if DEBUG && targetEnvironment(simulator)
        let probe=AnimationDecodeProbe.shared.enter(index)
        defer{AnimationDecodeProbe.shared.leave(probe)}
        if probe?.fail==true{throw AnimationFailure.frame(index)}
        #endif
        return try autoreleasepool {
            let properties=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any] ?? [:]
            guard let cg=CGImageSourceCreateThumbnailAtIndex(source,index,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:pixelLimit,kCGImageSourceShouldCache:false,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw AnimationFailure.frame(index)}
            guard cg.bytesPerRow*cg.height<=5*1024*1024 else{throw AnimationFailure.resources}
            let values=properties[dictionary] as? [CFString:Any]
            let sequenceDelay=frameDelays.indices.contains(index) ? frameDelays[index]:nil
            let delay=(values?[unclampedKey] as? NSNumber)?.doubleValue ?? (values?[delayKey] as? NSNumber)?.doubleValue ?? sequenceDelay ?? 0.1
            try Task.checkCancellation();return (UIImage(cgImage:cg),AnimationLimits.delay(delay))
        }
    }
    func close(_ ticket:UUID){if self.ticket==ticket{source=nil;self.ticket=nil;frameDelays=[]}}
}

final class PreparedAnimation {
    let data:Data
    let decoder:AnimationDecoder,ticket:UUID,info:AnimationDecoder.Info
    let first:(UIImage,Double),second:(UIImage,Double)
    let cost:Int
    private init(data:Data,decoder:AnimationDecoder,ticket:UUID,info:AnimationDecoder.Info,first:(UIImage,Double),second:(UIImage,Double),cost:Int){self.data=data;self.decoder=decoder;self.ticket=ticket;self.info=info;self.first=first;self.second=second;self.cost=cost}
    static func make(_ data:Data,firstReady:(@MainActor ((UIImage,Double))->Void)?=nil,admit:(@MainActor (AnimationPlan)async throws->Void)?=nil)async throws->PreparedAnimation{
        let decoder=AnimationDecoder(),ticket=UUID()
        let info=try await decoder.open(data,ticket:ticket)
        if let admit{try await admit(info.plan)}
        let first=try await decoder.frame(0,ticket:ticket)
        try Task.checkCancellation()
        // Cold playback can present now. Preheat still completes both frames and
        // retains the same reservation; second-frame timing is anchored to display.
        if let firstReady{await firstReady(first)}
        let second=try await decoder.frame(1,ticket:ticket)
        try Task.checkCancellation()
        let cost=info.plan.sourceCost+[first.0,second.0].reduce(0){$0+($1.cgImage.map{$0.bytesPerRow*$0.height} ?? 0)}
        return PreparedAnimation(data:data,decoder:decoder,ticket:ticket,info:info,first:first,second:second,cost:cost)
    }
    func frame(_ index:Int)async throws->(UIImage,Double){
        try Task.checkCancellation()
        if index==0{return first};if index==1{return second}
        return try await decoder.frame(index,ticket:ticket)
    }
}

@MainActor final class AnimationFirstFrame {
    private var frame:(UIImage,Double)?
    private var observers:[UUID:((UIImage,Double))->Void]=[:]
    func publish(_ frame:(UIImage,Double)){
        guard self.frame==nil else{return};self.frame=frame
        for observer in Array(observers.values){observer(frame)}
    }
    func subscribe(_ observer:@escaping ((UIImage,Double))->Void)->UUID{
        let id=UUID();observers[id]=observer;if let frame{observer(frame)};return id
    }
    func remove(_ id:UUID){observers.removeValue(forKey:id)}
}

@MainActor final class AnimationPreheater {
    private struct Job {let id:UUID,data:Data,first:AnimationFirstFrame,task:Task<PreparedAnimation,Error>;var reserved:Int;var plan:AnimationPlan?}
    private var ready:[Int:PreparedAnimation]=[:]
    private var staged:[Int:Data]=[:]
    private var jobs:[Int:Job]=[:]
    // Cancelled work remains charged until its real completion, including ImageIO.
    private var retiring:[UUID:Job]=[:]
    private var restage:[UUID:Int]=[:]
    private var order:[Int]=[]
    private var failures:[Int:AnimationFailure]=[:]
    private var deferred=Set<Int>()
    private var epoch=UUID()
    private var extendedDemand:Int?
    var extended:Bool {
        if let current=order.first {
            if extendedDemand==current{return true}
            if ready[current]?.info.plan.extended==true || jobs[current]?.plan?.extended==true{return true}
            if (jobs[current]?.data.count ?? staged[current]?.count ?? 0)>16*1024*1024{return true}
        }
        return retiring.values.contains{$0.plan?.extended==true || $0.data.count>16*1024*1024}
    }
    var reservation:Int{extended ? AnimationLimits.extendedReserve:AnimationLimits.reserve}
    private var budget:Int{reservation-AnimationLimits.playback}
    var changed:(()->Void)?
    var budgetChanged:(()->Void)?
    #if DEBUG && targetEnvironment(simulator)
    var debugState:String{"ready=\(ready.keys.sorted()) jobs=\(jobs.mapValues{($0.reserved,$0.plan?.extended)}) staged=\(staged.keys.sorted()) failed=\(failures) deferred=\(deferred) retiring=\(retiring.count) used=\(used)"}
    #endif
    var used:Int{ready.values.reduce(0){$0+$1.cost}+jobs.values.reduce(0){$0+$1.reserved}+staged.values.reduce(0){$0+$1.count}+retiring.values.reduce(0){$0+$1.reserved}}
    func value(_ number:Int)->PreparedAnimation?{ready[number]}
    func configure(_ order:[Int],retaining:[Int]=[]){
        if self.order.first != order.first{extendedDemand=nil}
        if self.order.first != order.first,let current=order.first{deferred.remove(current)}
        self.order=Array(order.prefix(3))
        failures=failures.filter{self.order.contains($0.key)};deferred=deferred.intersection(self.order)
        // Do not throw away an already-warm adjacent decoder just because the
        // user briefly reversed direction. Only speculative work is cancelled.
        let keep=Set(self.order+retaining.prefix(3))
        for key in Array(ready.keys) where !keep.contains(key) || (ready[key]?.info.plan.extended==true && key != self.order.first){ready.removeValue(forKey:key)}
        for key in Set(jobs.keys).union(staged.keys) where !self.order.contains(key){
            remove(key)
        }
    }
    private func remove(_ key:Int){
        ready.removeValue(forKey:key);staged.removeValue(forKey:key)
        if let job=jobs.removeValue(forKey:key){retiring[job.id]=job;job.task.cancel()}
    }
    private func makeRoom(_ bytes:Int,for number:Int){
        guard let rank=order.firstIndex(of:number) else{return}
        for key in ready.keys.sorted() where !order.contains(key) && used-(staged[number]?.count ?? 0)+bytes>budget{ready.removeValue(forKey:key)}
        let lower=order.reversed().filter{order.firstIndex(of:$0)!>rank}
        // Cancel speculative decoding before discarding downloaded bytes. Completion
        // tickets prevent demoted jobs from restoring their old session afterwards.
        for key in lower where used-(staged[number]?.count ?? 0)+bytes>budget {
            if let job=jobs[key]{
                // The retiring job already owns/charges these bytes. Transfer
                // them to staging after completion instead of charging twice
                // and accidentally dropping a >8 MiB uncached neighbor.
                restage[job.id]=key;remove(key)
            }else if let data=ready[key]?.data{remove(key);staged[key]=data}
        }
        for key in lower where used-(staged[number]?.count ?? 0)+bytes>budget{remove(key)}
    }
    private func stage(_ number:Int,_ data:Data)->Bool{
        makeRoom(data.count,for:number)
        guard used-(staged[number]?.count ?? 0)+data.count<=budget else{return false}
        staged[number]=data;return true
    }
    func clear(){epoch=UUID();restage.removeAll();configure([])}
    func invalidate(_ number:Int){restage=restage.filter{$0.value != number};remove(number);failures.removeValue(forKey:number);deferred.remove(number)}
    private func admit(_ plan:AnimationPlan,number:Int,id:UUID)async throws {
        guard jobs[number]?.id==id,order.contains(number) else{throw CancellationError()}
        if plan.extended,number != order.first{throw AnimationFailure.deferred}
        jobs[number]?.plan=plan
        if plan.extended {
            // Current large page gets the pool; neighbors keep their static preview.
            for key in Set(ready.keys).union(jobs.keys).union(staged.keys) where key != number{remove(key)}
        }
        budgetChanged?()
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        while true {
            try Task.checkCancellation()
            guard let job=jobs[number],job.id==id,order.contains(number) else{throw CancellationError()}
            if plan.extended,number != order.first{throw CancellationError()}
            makeRoom(max(0,plan.reservation-job.reserved),for:number)
            if used-job.reserved+plan.reservation<=budget{jobs[number]?.reserved=plan.reservation;return}
            guard ContinuousClock.now<deadline else{throw AnimationFailure.resources}
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    @discardableResult func offer(_ number:Int,data:Data)->Bool{
        guard order.contains(number),failures[number]==nil else{return false}
        guard data.count<=AnimationLimits.compressed else{failures[number] = .fileSize(data.count);return false}
        if ready[number] != nil || jobs[number] != nil{return true}
        if number != order.first,(extended || deferred.contains(number) || data.count>16*1024*1024){
            deferred.insert(number)
            if !extended{return stage(number,data)}
            return false
        }
        // Only one speculative decode at a time; current-page demand may run alongside it.
        if number != order.first && jobs.keys.contains(where:{$0 != order.first}){return stage(number,data)}
        // Metadata inspection is asynchronous. Initial charge covers input; decoded
        // surfaces are admitted separately before the first frame is requested.
        let reserve=data.count
        if number==order.first,data.count>16*1024*1024{extendedDemand=number}
        makeRoom(reserve,for:number)
        guard used-(staged[number]?.count ?? 0)+reserve<=budget else{return stage(number,data)}
        staged.removeValue(forKey:number)
        let id=UUID(),first=AnimationFirstFrame()
        let task=Task(priority:number==order.first ? .userInitiated : .utility){[weak self] in
            try await PreparedAnimation.make(data,firstReady:{first.publish($0)},admit:{[weak self] plan in
                guard let self else{throw CancellationError()};try await self.admit(plan,number:number,id:id)
            })
        }
        jobs[number]=Job(id:id,data:data,first:first,task:task,reserved:reserve)
        Task{[weak self] in
            let result=await task.result
            guard let self else{return}
            self.retiring.removeValue(forKey:id)
            guard self.jobs[number]?.id==id else{
                if self.restage.removeValue(forKey:id) != nil,self.order.contains(number),self.ready[number]==nil,self.jobs[number]==nil,
                   self.failures[number]==nil,(!self.extended || number==self.order.first){_ = self.stage(number,data)}
                for key in self.order{if let data=self.staged[key]{self.offer(key,data:data)}}
                self.changed?();return
            }
            self.jobs.removeValue(forKey:number)
            if case .success(let session)=result,self.order.contains(number){self.ready[number]=session}
            if case .failure(let error)=result,!AnimationFailure.cancelled(error) {
                let failure=AnimationFailure.classify(error)
                if failure == .deferred{self.deferred.insert(number);_ = self.stage(number,data)}
                else{self.failures[number]=failure}
            }
            for key in self.order{if let data=self.staged[key]{self.offer(key,data:data)}}
            self.changed?()
        }
        return true
    }
    func obtain(_ number:Int,firstReady:@escaping ((UIImage,Double))->Void={_ in},load:()async throws->Data)async throws->PreparedAnimation{
        if let failure=failures[number] {
            if failure.transient{failures.removeValue(forKey:number)}else{throw failure}
        }
        if let session=ready[number]{return session}
        if let job=jobs[number]{return try await obtain(job,firstReady:firstReady)}
        let epoch=self.epoch
        let data:Data
        if let saved=staged[number]{data=saved}else{data=try await load()}
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        while true {
            try Task.checkCancellation()
            guard self.epoch==epoch,order.contains(number) else{throw CancellationError()}
            _ = offer(number,data:data)
            if let failure=failures[number]{throw failure}
            if let session=ready[number]{return session}
            if let job=jobs[number]{return try await obtain(job,firstReady:firstReady)}
            guard ContinuousClock.now<deadline else{throw AnimationFailure.resources}
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    private func obtain(_ job:Job,firstReady:@escaping ((UIImage,Double))->Void)async throws->PreparedAnimation{
        try Task.checkCancellation()
        let observer=job.first.subscribe(firstReady);defer{job.first.remove(observer)}
        let value=try await job.task.value;try Task.checkCancellation();return value
    }
    deinit{for job in Array(jobs.values)+Array(retiring.values){job.task.cancel()}}
}

@MainActor final class AnimatedPagePlayer {
    private var task:Task<Void,Never>?
    private var ticket=UUID()
    private(set) var key:String?
    #if DEBUG && targetEnvironment(simulator)
    private(set) var displayedFrames=0
    private(set) var playbackStarts=0
    #endif
    func play(key:String,prepared:PreparedAnimation?=nil,prepare:((@escaping ((UIImage,Double))->Void)async throws->PreparedAnimation)?=nil,load:@escaping()async throws->Data,display:@escaping(UIImage)->Void,failed:@escaping(AnimationFailure)->Void){
        guard self.key != key else{return};stop();self.key=key
        #if DEBUG && targetEnvironment(simulator)
        playbackStarts+=1
        #endif
        let ticket=self.ticket
        var shownAt=prepared.map{session in display(session.first.0);return ContinuousClock.now}
        let firstReady:((UIImage,Double))->Void={[weak self] frame in
            guard self?.ticket==ticket,shownAt==nil else{return}
            display(frame.0);shownAt=ContinuousClock.now
        }
        task=Task{[weak self] in
            do{
                var obtained:PreparedAnimation?
                for attempt in 0...1 {
                    do {
                        if let prepared{obtained=prepared}else if let prepare{obtained=try await prepare(firstReady)}else{obtained=try await PreparedAnimation.make(try await load(),firstReady:firstReady)}
                        break
                    }catch {
                        if Task.isCancelled || AnimationFailure.cancelled(error){throw CancellationError()}
                        guard attempt==0,AnimationFailure.classify(error).transient else{throw error}
                        try await Task.sleep(for:.milliseconds(150))
                    }
                }
                guard let session=obtained else{throw AnimationFailure.unavailable}
                try Task.checkCancellation();guard self?.ticket==ticket else{throw CancellationError()}
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
            }catch{
                guard !Task.isCancelled,self?.ticket==ticket else{return}
                if AnimationFailure.cancelled(error){self?.key=nil;return}
                failed(AnimationFailure.classify(error))
            }
        }
    }
    func stop(){ticket=UUID();task?.cancel();task=nil;key=nil}
    deinit{task?.cancel()}
}
