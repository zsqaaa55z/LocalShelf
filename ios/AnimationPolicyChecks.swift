#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import ImageIO

@MainActor enum AnimationPolicyChecks {
    private static var checks=0
    private static func pass(_ ok:Bool,_ message:String){precondition(ok,message);checks+=1;print("PASS "+message);fflush(stdout)}
    private static func wait(line:UInt=#line,_ predicate:()->Bool)async {
        for _ in 0..<1500{if predicate(){return};try? await Task.sleep(for:.milliseconds(5))}
        preconditionFailure("animation policy timeout at \(line)")
    }
    // Real encoded synthetic colored frames. No personal files or network access.
    private static func gif(width:Int,height:Int,frames:Int)->Data {
        func word(_ n:Int)->[UInt8]{[UInt8(n&255),UInt8(n>>8)]}
        func imageData(_ color:UInt32)->Data {
            // Literal GIF LZW stream: clear + one palette index, repeated. The
            // dictionary never grows, so all codes stay three bits wide.
            let pixels=width*height,pair=UInt32(4)|(color<<3)
            let four=pair|(pair<<6)|(pair<<12)|(pair<<18)
            var packed=Data(count:(pixels*6+3+7)/8)
            packed.withUnsafeMutableBytes{(raw:UnsafeMutableRawBufferPointer) in
                var offset=0
                for _ in 0..<(pixels/4){raw[offset]=UInt8(four&255);raw[offset+1]=UInt8((four>>8)&255);raw[offset+2]=UInt8((four>>16)&255);offset+=3}
                var tail:UInt32=0,bits=0
                for _ in 0..<(pixels%4){tail |= pair<<bits;bits+=6}
                tail |= 5<<bits;bits+=3
                while bits>0{raw[offset]=UInt8(tail&255);offset+=1;tail >>= 8;bits-=8}
            }
            var blocks=Data([2])
            for offset in stride(from:0,to:packed.count,by:255){let end=min(offset+255,packed.count);blocks.append(UInt8(end-offset));blocks.append(packed[offset..<end])}
            blocks.append(0);return blocks
        }
        var output=Data("GIF89a".utf8)
        output.append(contentsOf:word(width)+word(height)+[0x80,0,0,255,0,0,0,255,0])
        output.append(contentsOf:[0x21,0xff,11]);output.append(Data("NETSCAPE2.0".utf8));output.append(contentsOf:[3,1,0,0,0])
        let first=imageData(0),second=imageData(1)
        for index in 0..<frames {
            output.append(contentsOf:[0x21,0xf9,4,4,3,0,0,0,0x2c,0,0,0,0]+word(width)+word(height)+[0])
            output.append(index%2==0 ? first:second)
        }
        output.append(0x3b);return output
    }
    static func run()async {
        checks=0
        let small=ReaderDemo.animationData("1")
        do {
            let ordinary=try AnimationPlan.make(bytes:small.count,width:32,height:32,frames:3)
            pass(!ordinary.extended && ordinary.pixelLimit==1024,"ordinary animations retain the existing output profile")
            let big=try AnimationPlan.make(bytes:20*1024*1024,width:1920,height:1080,frames:2400)
            pass(big.extended && big.pixelLimit==768 && big.reservation<=AnimationLimits.extendedReserve-AnimationLimits.playback,"large input uses current-page profile with composition surfaces charged")
            let near=try AnimationPlan.make(bytes:1_000_000,width:3200,height:2400,frames:3)
            pass(near.extended,"7.68 MP canvas can pass the combined resource budget")
            for (bytes,w,h,frames,expected) in [
                (AnimationLimits.compressed+1,32,32,3,AnimationFailure.fileSize(AnimationLimits.compressed+1)),
                (100,4000,3000,3,.dimensions(4000,3000)),
                (100,32,32,10001,.frameCount(10001)),
                (100,Int.max,Int.max,3,.dimensions(Int.max,Int.max)),
                (32*1024*1024,3200,2400,10000,.workingSet(99_887_104))
            ] {
                do{_ = try AnimationPlan.make(bytes:bytes,width:w,height:h,frames:frames);preconditionFailure("unsafe animation admitted")}
                catch{pass(error as? AnimationFailure==expected,"precise rejection: \(expected)")}
            }
            pass(AnimationFailure.frame(69).message.contains("第 70 帧") && !AnimationFailure.network.message.contains("不支持"),"diagnostics distinguish frame failure and network failure")
            let slots=AnimationFrameSlots();try await slots.acquire();try await slots.acquire()
            do{try await slots.acquire(timeout:.milliseconds(20));preconditionFailure("occupied slots admitted new work")}
            catch{pass(error as? AnimationFailure == .resources,"occupied physical slots time out as resources, not an endless loading state")}
            await slots.release();await slots.release()
            let decoder=AnimationDecoder(),large=gif(width:2560,height:1800,frames:3),ticket=UUID()
            let began=ContinuousClock.now,info=try await decoder.open(large,ticket:ticket)
            let frame=try await decoder.frame(1,ticket:ticket)
            pass(info.plan.extended && max(frame.0.cgImage!.width,frame.0.cgImage!.height)<=768,"real 4.6 MP GIF decodes to a bounded playback frame")
            pass(abs(frame.1-0.03)<0.001,"large animation preserves its original frame timing")
            print("METRIC synthetic_4_6MP_open_and_frame=\(began.duration(to:.now)); output_bytes=\(frame.0.cgImage!.bytesPerRow*frame.0.cgImage!.height)")
            await decoder.close(ticket)
            var webp=ReaderDemo.animationData("3")
            for (offset,value) in [(24,2559),(27,1799)]{for byte in 0..<3{webp[offset+byte]=UInt8((value>>(8*byte))&255)}}
            let webpTicket=UUID(),webpInfo=try await decoder.open(webp,ticket:webpTicket)
            pass(webpInfo.plan.width==2560 && webpInfo.plan.height==1800 && webpInfo.plan.extended,"partial-frame WebP is admitted by full canvas dimensions")
            do {
                let webpFrame=try await decoder.frame(1,ticket:webpTicket)
                pass(max(webpFrame.0.cgImage!.width,webpFrame.0.cgImage!.height)<=768 && abs(webpFrame.1-0.2)<0.001,"large-canvas WebP retains timing with bounded output and the original system decoder")
            }catch {
                let source=CGImageSourceCreateWithData(webp as CFData,nil)!
                let full=CGImageSourceCreateImageAtIndex(source,1,nil)
                print("METRIC expanded_canvas_webp full_frame_available=\(full != nil)");fflush(stdout)
                pass(error as? AnimationFailure == .frame(1),"native codec rejection reports exact frame instead of claiming file-size overflow")
            }
            await decoder.close(webpTicket)
            let long=gif(width:8,height:8,frames:2101),longTicket=UUID()
            let longInfo=try await decoder.open(long,ticket:longTicket)
            _ = try await decoder.frame(2100,ticket:longTicket)
            pass(longInfo.count==2101 && longInfo.plan.extended,"real 2101-frame animation opens and its final frame decodes on demand")
            await decoder.close(longTicket)
            // Size/admission fixture only, not a large-content performance benchmark.
            var padded=small;padded.append(Data(repeating:0,count:20*1024*1024))
            let heater=AnimationPreheater();heater.configure([1,2]);heater.offer(2,data:small)
            let session=try await heater.obtain(1){padded}
            await wait{heater.value(1) != nil}
            pass(session.info.plan.extended && heater.value(2)==nil && heater.extended,"20 MiB input starts on current page and evicts speculative animation")
            pass(heater.used<=heater.reservation-AnimationLimits.playback,"large compressed input plus decoder estimate and prepared frames are charged together")
            heater.configure([2,1]);heater.offer(2,data:small)
            await wait{heater.value(2) != nil}
            pass(!heater.extended && heater.value(1)==nil,"leaving large page restores normal budget without retaining its decoder")
            heater.clear();await wait{heater.used==0}
        }catch{preconditionFailure("animation policy fixture failed: \(error)")}

        let player=AnimatedPagePlayer();var attempts=0,shown=0,failures:[AnimationFailure]=[]
        player.play(key:"network-once",load:{attempts+=1;if attempts==1{throw URLError(.timedOut)};return small},display:{_ in shown+=1},failed:{failures.append($0)})
        await wait{shown>=2};pass(attempts==2 && failures.isEmpty,"one transient load failure gets one bounded automatic retry")
        player.stop();attempts=0
        player.play(key:"network-persistent",load:{attempts+=1;throw URLError(.timedOut)},display:{_ in preconditionFailure("unexpected frame")},failed:{failures.append($0)})
        await wait{failures.count==1};pass(attempts==2 && failures.last == .network,"persistent network failure stops after two attempts with the correct reason")
        player.stop();attempts=0;failures=[]
        player.play(key:"cancelled",load:{attempts+=1;throw CancellationError()},display:{_ in preconditionFailure("cancelled frame")},failed:{failures.append($0)})
        await wait{player.key==nil};pass(attempts==1 && failures.isEmpty,"cancellation is silent, not unsupported format or a retry loop")
        player.stop()

        let library=Library(),cache=ReadingCache(),pages=(1...4).map{Page(number:$0)}
        cache.update(library:library,book:"0",pages:pages,index:0)
        await wait{cache.images[1] != nil}
        cache.animationFailed(.frame(4),number:1)
        pass(cache.animationPaused && cache.animationMessage.contains("第 5 帧"),"current page exposes the exact frame failure")
        cache.toggleAnimation()
        do{_ = try await cache.prepareAnimation(1);pass(!cache.animationPaused && cache.animationMessage.isEmpty,"play button clears page failure and permits fresh decoder preparation")}catch{preconditionFailure("manual retry failed: \(error)")}
        cache.animationFailed(.unsupported,number:1)
        cache.update(library:library,book:"0",pages:pages,index:1)
        pass(!cache.animationPaused && cache.animationMessage.isEmpty,"one failed page does not disable animations on the next page")
        cache.clear();await wait{cache.animationPreheater.used==0}
        ReaderDemo.largeAnimationFixture=true;ReaderDemo.animationPaddingBytes=20*1024*1024
        let largeCache=ReadingCache()
        largeCache.update(library:library,book:"0",pages:pages,index:0)
        await wait{largeCache.preparedAnimation(1) != nil}
        pass(largeCache.animationPreheater.extended && largeCache.retainedBytes<=ReadingBudget.largeAnimation,"real ReadingCache applies the 96 MiB large-page managed budget")
        pass(largeCache.preparedAnimation(2)==nil,"large-page mode keeps neighboring animations unprepared")
        largeCache.update(library:library,book:"0",pages:pages,index:2)
        await wait{largeCache.preparedAnimation(3) != nil && !largeCache.animationPreheater.extended}
        pass(largeCache.retainedBytes<=ReadingBudget.normal,"ReadingCache returns to the normal 64 MiB budget on a small page")
        largeCache.memoryPressure();await wait{largeCache.animationPreheater.used==0}
        pass(largeCache.reducedMemory && largeCache.retainedBytes<=ReadingBudget.pressure,"memory warning drains animation work and preserves the 24 MiB pressure budget")
        largeCache.clear();await wait{largeCache.animationPreheater.used==0}
        ReaderDemo.largeAnimationFixture=false;ReaderDemo.animationPaddingBytes=9*1024*1024
        await neighborHandoff()
        await cancellation()
        print("\(checks) animation policy checks passed")
    }
    private static func neighborHandoff()async {
        let probe=AnimationDecodeProbe.shared,heater=AnimationPreheater()
        var input=ReaderDemo.animationData("1");input.append(Data(repeating:0,count:9*1024*1024))
        probe.start(block:0);heater.configure([1,2]);heater.offer(2,data:input)
        await wait{probe.snapshot().waiting==1}
        heater.offer(1,data:input)
        try? await Task.sleep(for:.milliseconds(100))
        pass(heater.used<=heater.reservation-AnimationLimits.playback,"neighbor-first cancellation stays charged without double-charging shared input")
        probe.release(3)
        await wait{heater.value(1) != nil && heater.value(2) != nil}
        pass(heater.value(2)?.data.count==input.count,"demoted 9 MiB neighbor is restaged after physical cancellation without reloading")
        heater.clear();await wait{heater.used==0 && probe.snapshot().active==0};probe.stop()
    }
    static func cancellation()async {
        let probe=AnimationDecodeProbe.shared,small=ReaderDemo.animationData("1"),heater=AnimationPreheater()
        probe.start(block:0);heater.configure([1]);heater.offer(1,data:small)
        await wait{probe.snapshot().waiting==1}
        let charge=heater.used
        heater.clear()
        pass(heater.used==charge && charge>=small.count+AnimationLimits.playback,"cancelled physical decode stays charged until it actually exits")
        heater.configure([2]);heater.offer(2,data:small);await wait{probe.snapshot().waiting==2}
        for number in 3...8{heater.configure([number]);heater.offer(number,data:small);try? await Task.sleep(for:.milliseconds(10))}
        pass(probe.snapshot().peak==2 && heater.used<=heater.reservation-AnimationLimits.playback,"rapid cancelled requests cannot exceed two physical frame calls or the source pool")
        heater.clear();probe.release(2)
        await wait{probe.snapshot().active==0 && heater.used==0}
        pass((1...8).allSatisfy{heater.value($0)==nil},"cancelled work drains without restoring old pages")
        probe.stop()
    }
    static func cancellationOnly()async{checks=0;await cancellation();print("\(checks) cancellation checks passed")}
}
#endif
