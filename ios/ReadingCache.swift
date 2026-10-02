import Foundation
import SwiftUI
import UIKit
import ImageIO

@MainActor final class ReadingCache:ObservableObject {
    let animationPreheater=AnimationPreheater()
    private var warmOrder:[Int]=[]
    private var travelDirection=1
    private var policy=ReadingPrefetchPolicy()
    private var policyPages:[Page]=[],policyIndex=0,thermalLevel=0
    private var settling:Task<Void,Never>?
    private var settleTicket=UUID()
    private var retainedAnimationOrder:[Int]{
        guard thermalLevel<2,!reducedMemory else{return []}
        return PagingRules.prefetchIndices(current:policyIndex,count:policyPages.count,direction:travelDirection).prefix(3).map{policyPages[$0].number}
    }
    init(){
        animationPreheater.changed={[weak self] in self?.warmAnimations();self?.enforceBudget()}
        animationPreheater.budgetChanged={[weak self] in self?.enforceBudget()}
    }
    func warmAnimations(){
        guard canAnimate,detailNumber==nil else{animationPreheater.clear();return}
        animationPreheater.configure(warmOrder,retaining:retainedAnimationOrder)
        for number in warmOrder where animated.contains(number){if let data=raw[number]{animationPreheater.offer(number,data:data)}}
    }
    func preparedAnimation(_ number:Int)->PreparedAnimation?{animationPreheater.value(number)}
    func prepareAnimation(_ number:Int,firstReady:@escaping ((UIImage,Double))->Void={_ in})async throws->PreparedAnimation{
        guard canAnimate,warmOrder.contains(number) else{throw CancellationError()}
        animationPreheater.configure([number]+warmOrder.filter{$0 != number},retaining:retainedAnimationOrder)
        return try await animationPreheater.obtain(number,firstReady:firstReady){[weak self] in guard let self else{throw CancellationError()};return try await self.pageData(number,path:"/v1/books/\(self.bookID)/pages/\(number)")}
    }
    @Published private(set) var images:[Int:UIImage]=[:]
    @Published private(set) var failed:Set<Int>=[]
    private(set) var failures:[Int:PageReadFailure]=[:]
    @Published private(set) var animated:Set<Int>=[]
    @Published private(set) var animationPaused=false
    @Published private(set) var animationMessage=""
    private var animationFailures:[Int:AnimationFailure]=[:]
    @Published private(set) var animationForeground=true
    var canAnimate:Bool{!reducedMemory && !animationPaused && animationForeground}
    private var animationReserve:Int{
        if animationPreheater.used>0{return animationPreheater.reservation}
        return canAnimate && detailNumber==nil && warmOrder.contains(where:{animated.contains($0)}) ? AnimationLimits.reserve:0
    }
    private var retainedLimit:Int{animationPreheater.extended ? ReadingBudget.largeAnimation:ReadingBudget.normal}
    func setAnimationForeground(_ value:Bool){
        animationForeground=value
        if !value{settling?.cancel();settling=nil;settleTicket=UUID()}
        else{applyPrefetchPolicy()}
        warmAnimations();enforceBudget()
    }
    func setThermalState(_ state:ProcessInfo.ThermalState){thermalLevel=state.rawValue;applyPrefetchPolicy()}
    func toggleAnimation(){
        if animationPaused,let current{animationFailures.removeValue(forKey:current);animationPreheater.invalidate(current)}
        animationPaused.toggle();animationMessage="";warmAnimations();enforceBudget()
    }
    func animationFailed(_ failure:AnimationFailure,number:Int){
        guard policyPages.contains(where:{$0.number==number}) else{return}
        animationFailures[number]=failure
        if current==number{animationPaused=true;animationPreheater.clear();animationMessage="第 \(number) 页 · "+failure.message}
        else{animationPreheater.invalidate(number)}
        enforceBudget()
    }
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
    var prefetchPages:[Int]{desired}
    var animationWarmPages:[Int]{warmOrder}
    #endif
    private func cost(_ image:UIImage?)->Int {guard let cg=image?.cgImage else{return 0};return cg.bytesPerRow*cg.height}
    private func enforceBudget(){
        let limit=max(0,(reducedMemory ? ReadingBudget.pressure : retainedLimit)-animationReserve)
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
        let ticket=UUID(),task=Task{try await source.data(path,priority:priority,retryPage:true)}
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
        settling?.cancel();settling=nil;settleTicket=UUID()
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
    // Keep unchanged pages by numeric page + hash, including their warmed player.
    func reconcilePages(_ pages:[Page]) {
        let next=Dictionary(uniqueKeysWithValues:pages.map{($0.number,$0)})
        for old in policyPages {
            let page=next[old.number]
            if page == nil || old.sha256==nil || old.sha256 != page?.sha256 || old.size != page?.size {
                let n=old.number
                pending.removeValue(forKey:n)?.1.cancel();transfers.removeValue(forKey:n)?.1.cancel()
                images.removeValue(forKey:n);raw.removeValue(forKey:n);animated.remove(n)
                animationPreheater.invalidate(n);animationFailures.removeValue(forKey:n);omitted.remove(n);failures.removeValue(forKey:n);failed.remove(n)
                if detailNumber==n{clearDetail()}
            }
        }
        for number in Array(failed) where failures[number] == .changed{failures.removeValue(forKey:number);failed.remove(number)}
    }
    func update(library:Library,book:String,pages:[Page],index:Int){
        if source !== library || bookID != book{clear();travelDirection=1}
        let oldCurrent=current
        if !pages.indices.contains(index) || detailNumber != pages[index].number {clearDetail()}
        if bookID != book{policy=ReadingPrefetchPolicy()}
        source=library;bookID=book;policyPages=pages;policyIndex=index
        if let oldCurrent,let oldIndex=pages.firstIndex(where:{$0.number==oldCurrent}),oldIndex != index{travelDirection=index>oldIndex ? 1 : -1}
        let now=ProcessInfo.processInfo.systemUptime
        policy.moved(to:index,now:now)
        applyPrefetchPolicy()
        settling?.cancel();settling=nil;settleTicket=UUID()
        if policy.rapid(now:now),animationForeground,!reducedMemory {
            let ticket=settleTicket
            let delay=max(0.01,policy.rapidUntil-now+0.01)
            settling=Task{[weak self] in
                do{try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}catch{return}
                guard let self,self.settleTicket==ticket,self.animationForeground,!self.reducedMemory else{return}
                self.settling=nil;self.applyPrefetchPolicy()
            }
        }
        if current != oldCurrent{
            omitted.removeAll()
            let failure=current.flatMap{animationFailures[$0]}
            animationPaused=failure != nil
            animationMessage=failure.map{"第 \(current!) 页 · "+$0.message} ?? ""
            warmAnimations();pump()
        }
    }
    private func applyPrefetchPolicy(){
        guard let library=source else{return}
        let pages=policyPages,index=policyIndex,now=ProcessInfo.processInfo.systemUptime
        desired=policy.indices(current:index,count:pages.count,direction:travelDirection,thermal:thermalLevel,pressure:reducedMemory,now:now).map{pages[$0].number}
        if let current {
            let path="/v1/books/\(bookID)/pages/\(current)"
            library.prioritizePage(path);PageDecodeQueue.shared.prioritize(path)
        }
        warmOrder=policy.animationIndices(current:index,count:pages.count,direction:travelDirection,thermal:thermalLevel,pressure:reducedMemory,now:now).map{pages[$0].number}
        if reducedMemory{desired=Array(desired.prefix(1))}
        let keep=Set(desired)
        // Scheduling window may shrink, but already-ready nearby previews and
        // format flags must survive: the pager can reverse before page commit.
        let retained=thermalLevel>=2 || reducedMemory ? keep:Set(PagingRules.prefetchIndices(current:index,count:pages.count,direction:travelDirection).map{pages[$0].number})
        for key in Array(transfers.keys) where !keep.contains(key){transfers.removeValue(forKey:key)?.1.cancel()}
        raw=raw.filter{keep.contains($0.key)}
        for key in Array(pending.keys) where !keep.contains(key){pending.removeValue(forKey:key)?.1.cancel()}
        images=images.filter{retained.contains($0.key)};failures=failures.filter{retained.contains($0.key)};failed=failed.intersection(retained)
        animated=animated.intersection(retained)
        animationFailures=animationFailures.filter{retained.contains($0.key)}
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
                        guard let input=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary) else{throw LibraryError.malformed}
                        let type=CGImageSourceGetType(input) as String? ?? ""
                        let animated=CGImageSourceGetCount(input)>1 && ["com.compuserve.gif","public.png","org.webmproject.webp"].contains(type)
                        let limit=animated ? min(previewLimit,1024):previewLimit
                        guard let cg=CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:limit,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw LibraryError.malformed}
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
                    if !Task.isCancelled,!(error is CancellationError),(error as? URLError)?.code != .cancelled {
                        self.failures[number]=PageReadFailure.classify(error);self.failed.insert(number)
                    }
                }
                guard let self,self.pending[number]?.0==id else{return}
                self.pending.removeValue(forKey:number);self.pump()
            }
            pending[number]=(id,task)
        }
    }
    func retry(_ number:Int){raw.removeValue(forKey:number);failures.removeValue(forKey:number);failed.remove(number);pump()}
    func clear(){settling?.cancel();settling=nil;settleTicket=UUID();policy=ReadingPrefetchPolicy();policyPages=[];animationPreheater.clear();warmOrder=[];clearDetail();for (_,task) in pending.values{task.cancel()};for (_,task) in transfers.values{task.cancel()};transfers.removeAll();raw.removeAll();omitted.removeAll();pending.removeAll();desired=[];images.removeAll();failures.removeAll();failed.removeAll();animated.removeAll();animationFailures.removeAll();animationPaused=false;animationMessage="";source=nil;reducedMemory=false}
}

// Fixed fit-to-screen layout. Single taps toggle controls; no zoom gestures.
