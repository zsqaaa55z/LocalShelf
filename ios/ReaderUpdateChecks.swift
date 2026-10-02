#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit

// Synthetic fault/occupancy probes only. Never compiled into a device build.
final class AnimationDecodeProbe:@unchecked Sendable {
    static let shared=AnimationDecodeProbe()
    struct Ticket{let fail:Bool}
    private let lock=NSLock()
    private var enabled=false,blockedIndex:Int?,failedIndex:Int?,gate:DispatchSemaphore?
    private var active=0,peak=0,entered=0,waiting=0
    func start(block:Int?=nil,fail:Int?=nil){
        lock.lock();defer{lock.unlock()};precondition(active==0)
        enabled=true;blockedIndex=block;failedIndex=fail;gate=block.map{_ in DispatchSemaphore(value:0)}
        peak=0;entered=0;waiting=0
    }
    func enter(_ index:Int)->Ticket?{
        lock.lock();guard enabled else{lock.unlock();return nil}
        active+=1;entered+=1;peak=max(peak,active)
        let gate=blockedIndex==index ? self.gate:nil,fail=failedIndex==index
        if gate != nil{waiting+=1};lock.unlock()
        gate?.wait() // Models a non-interruptible ImageIO call, not a real delay benchmark.
        return Ticket(fail:fail)
    }
    func leave(_ ticket:Ticket?){guard ticket != nil else{return};lock.lock();active-=1;lock.unlock()}
    func release(_ count:Int=1){lock.lock();let gate=self.gate;lock.unlock();for _ in 0..<count{gate?.signal()}}
    func snapshot()->(active:Int,peak:Int,entered:Int,waiting:Int){lock.lock();defer{lock.unlock()};return(active,peak,entered,waiting)}
    func stop(){lock.lock();defer{lock.unlock()};precondition(active==0);enabled=false;gate=nil}
}

@MainActor enum ReaderUpdateChecks {
    private static var checks=0
    private static func pass(_ value:Bool,_ message:String){precondition(value,message);checks+=1;print("PASS "+message)}
    private static func wait(_ predicate:()->Bool)async {
        for _ in 0..<1000{if predicate(){return};try? await Task.sleep(for:.milliseconds(5))}
        preconditionFailure("reader update timeout")
    }
    private static func centered(_ canvas:ZoomCanvas)->Bool {
        let rect=canvas.picture.convert(canvas.picture.bounds,to:canvas)
        return abs(rect.midX-canvas.bounds.midX)<1 && abs(rect.midY-canvas.bounds.midY)<1
    }
    static func run()async {
        checks=0;let probe=AnimationDecodeProbe.shared
        let gif=ReaderDemo.animationData("1"),player=AnimatedPagePlayer()
        var frames:[UIImage]=[],failures=0
        // First frame must cross the real player path while frame two is blocked.
        probe.start(block:1)
        player.play(key:"early",load:{gif},display:{frames.append($0)},failed:{_ in failures+=1})
        await wait{probe.snapshot().waiting==1}
        pass(frames.count==1 && failures==0,"cold player displays first frame before second-frame work completes")
        player.stop();probe.release();await wait{probe.snapshot().active==0}
        try? await Task.sleep(for:.milliseconds(150))
        pass(frames.count==1 && failures==0 && player.key==nil,"stop during preparation rejects later frames and stale errors")
        probe.stop()

        // The first frame has already been produced by a shared preheater job.
        frames=[];let heater=AnimationPreheater();heater.configure([1])
        probe.start(block:1);heater.offer(1,data:gif);await wait{probe.snapshot().waiting==1}
        let charged=heater.used
        pass(heater.value(1)==nil && charged>=gif.count+10*1024*1024,"early frame does not mark two-frame session ready or release its reservation")
        var loads=0
        player.play(key:"shared",prepare:{first in try await heater.obtain(1,firstReady:first){loads+=1;return gif}},load:{preconditionFailure("duplicate load")},display:{frames.append($0)},failed:{_ in failures+=1})
        await wait{frames.count==1}
        pass(loads==0 && heater.used==charged,"demand joins the existing job and receives its cached first frame")
        probe.release();await wait{heater.value(1) != nil && frames.count>=2}
        let ready=heater.value(1)!
        pass(frames[0] === ready.first.0 && frames[1] === ready.second.0,"first frame is not displayed twice before the second frame")
        player.stop();await wait{probe.snapshot().active==0};heater.clear();probe.stop()

        // A frame-two failure still reports an error instead of false success.
        frames=[];probe.start(fail:1)
        player.play(key:"failure",load:{gif},display:{frames.append($0)},failed:{_ in failures+=1})
        await wait{failures==1};pass(frames.count==1,"second-frame failure preserves early preview and reports failure")
        player.stop();await wait{probe.snapshot().active==0};probe.stop()

        // Gate-controlled comparison: a hold is injected only into frame two.
        // Numbers demonstrate removal of this dependency, not real-device speed.
        var old:[Double]=[],new:[Double]=[]
        for _ in 0..<4 {
            for early in [false,true] {
                probe.start(block:1);let start=ProcessInfo.processInfo.systemUptime
                var delivered:Double?
                let callback:(@MainActor ((UIImage,Double))->Void)?
                if early{callback={_ in delivered=ProcessInfo.processInfo.systemUptime-start}}else{callback=nil}
                let task=Task<PreparedAnimation,Error> {try await PreparedAnimation.make(gif,firstReady:callback)}
                await wait{probe.snapshot().waiting==1}
                if early{pass(delivered != nil,"first-frame callback is independent of blocked second frame")}
                else{pass(delivered==nil,"two-frame baseline cannot deliver while second frame is blocked")}
                try? await Task.sleep(for:.milliseconds(60));probe.release()
                _=try! await task.value
                if !early{delivered=ProcessInfo.processInfo.systemUptime-start}
                if early{new.append(delivered!*1000)}else{old.append(delivered!*1000)}
                await wait{probe.snapshot().active==0};probe.stop()
            }
        }
        print("METRIC synthetic_second_frame_hold_60ms baseline_ms=\(old) early_ms=\(new)")

        // No live connection: a cache with no scheduled loads and synthetic images.
        let cache=ReadingCache(),pager=NativeReadingPager(frame:CGRect(x:0,y:0,width:390,height:844))
        let pages=(1...2000).map{Page(number:$0)},revision=UUID()
        pager.configure(cache:cache,pages:pages,index:100,resetID:0,pageRevision:revision);pager.layoutIfNeeded()
        let before=pager.slots.reduce(0){$0+$1.showUpdates},compared=pager.comparedPageNumbers
        let began=ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000{pager.configure(cache:cache,pages:pages,index:100,resetID:0,pageRevision:revision)}
        print("METRIC 1000_unchanged_configure_ms=\((ProcessInfo.processInfo.systemUptime-began)*1000)")
        pass(pager.comparedPageNumbers==compared,"revisioned updates do not scan 2000 unchanged page numbers")
        pass(pager.slots.reduce(0){$0+$1.showUpdates}==before,"1000 unchanged updates do not reconfigure three unchanged slots")
        var changed=pages;changed[100]=Page(number:9000)
        pager.configure(cache:cache,pages:changed,index:100,resetID:0,pageRevision:UUID())
        pass(pager.slots.reduce(0){$0+$1.showUpdates}>before,"new page revision rebinds page slots")
        pager.configure(cache:cache,pages:pages,index:100,resetID:0)
        let comparedBefore=pager.comparedPageNumbers
        pager.configure(cache:cache,pages:pages,index:100,resetID:0)
        pass(pager.comparedPageNumbers-comparedBefore==2000,"nonrevisioned test/legacy caller keeps content comparison fallback")
        let replacement=ReadingCache(),beforeReplacement=pager.slots.reduce(0){$0+$1.showUpdates}
        pager.configure(cache:replacement,pages:pages,index:100,resetID:0)
        pass(pager.slots.reduce(0){$0+$1.showUpdates}>beforeReplacement,"cache replacement rebinds retry and page callbacks even with identical page numbers")
        pager.dispose()

        let slot=NativePageSlot(frame:CGRect(x:0,y:0,width:390,height:760))
        let portrait=UIImage(data:ReaderDemo.data("1"))!
        slot.show(number:1,image:portrait,failed:false,active:true,reset:false);slot.layoutIfNeeded();slot.canvas.layoutIfNeeded()
        pass(centered(slot.canvas),"portrait stays centered in fit mode")
        let updates=slot.showUpdates
        for _ in 0..<100{slot.show(number:1,image:portrait,failed:false,active:true,reset:false)}
        pass(slot.showUpdates==updates,"identical image and state skip slot configuration")
        slot.frame=CGRect(x:0,y:0,width:844,height:390);slot.setNeedsLayout();slot.layoutIfNeeded();slot.canvas.layoutIfNeeded()
        pass(centered(slot.canvas),"rotation still relayouts and centers an unchanged image")
        slot.show(number:1,image:nil,failed:true,active:true,reset:false)
        pass(!slot.retry.isHidden && slot.canvas.picture.image==nil,"image removal and error state are not suppressed")
        slot.show(number:2,image:portrait,failed:false,active:false,reset:false);slot.layoutIfNeeded();slot.canvas.layoutIfNeeded()
        pass(centered(slot.canvas) && slot.accessibilityElementsHidden,"reused inactive page remains centered and inaccessible")
        slot.show(number:2,image:portrait,failed:false,active:true,reset:false)
        pass(!slot.accessibilityElementsHidden && slot.canvas.isUserInteractionEnabled,"active-state-only change is delivered")
        print("\(checks) reader update checks passed")
    }

}
#endif
