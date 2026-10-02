import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

#if DEBUG && targetEnvironment(simulator)
enum CacheEfficiencyChecks {
    @MainActor static func run()async {
        var checks=0
        func pass(_ ok:Bool,_ text:String){precondition(ok,text);checks+=1;print("PASS "+text)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cache-efficiency-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        do{
            // Deterministic RGB noise; synthetic only, no library or network.
            var seed:UInt64=431,bytes=Data(count:320*480*4)
            bytes.withUnsafeMutableBytes{(raw:UnsafeMutableRawBufferPointer) in
                for i in 0..<raw.count{seed=seed &* 6364136223846793005 &+ 1;raw[i]=i%4==3 ? 255:UInt8(truncatingIfNeeded:seed>>32)}
            }
            let cg=CGImage(width:320,height:480,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1280,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
                provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let image=UIImage(cgImage:cg),jpeg=image.jpegData(compressionQuality:0.82)!
            let decoder=SmartCoverDecoder(),encoder=CoverEncoder()
            pass(try await decoder.reusableThumbnail(jpeg,width:320),"bounded NAS JPEG is reusable without re-encoding")
            pass(try await !decoder.reusableThumbnail(jpeg,width:nil),"old Android/original-cover response is not implicitly trusted")
            pass(try await !decoder.reusableThumbnail(jpeg,width:100),"unnegotiated derivative width is rejected")
            pass(try await !decoder.reusableThumbnail(image.pngData()!,width:320),"PNG/original fallback retains old processing path")
            pass(try await !decoder.reusableThumbnail(Data([1,2,3]),width:320),"malformed header rejected")
            pass(try await !decoder.reusableThumbnail(Data(repeating:1,count:1024*1024+1),width:320),"oversized derivative rejected before decode")
            let rotated=NSMutableData(),destination=CGImageDestinationCreateWithData(rotated,UTType.jpeg.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,cg,[kCGImagePropertyOrientation:6] as CFDictionary);precondition(CGImageDestinationFinalize(destination))
            pass(try await !decoder.reusableThumbnail(rotated as Data,width:320),"EXIF rotation uses normalized fallback")
            pass(try await !decoder.reusableThumbnail(ReaderDemo.animationData("/v1/books/1/pages/1"),width:640),"animated fallback cannot become a static derivative")
            let record=CoverRecord(bytes:jpeg,thumbnail:true,etag:"\""+String(repeating:"a",count:64)+"\"",checked:Date(),revision:"synthetic")
            let packed=try await encoder.encode(record,image:nil),decoded=try await decoder.display(record,pixels:320)
            pass(try CoverRecord.unpack(packed).bytes==jpeg,"cached bytes preserve exact NAS JPEG")
            let legacy=CoverRecord(bytes:jpeg,thumbnail:false,etag:record.etag,checked:record.checked,revision:record.revision)
            let old=try await encoder.encode(legacy,image:decoded)
            let oldDisplay=try await decoder.display(CoverRecord.unpack(old),pixels:320)
            pass(decoded.size==oldDisplay.size,"warm JPEG and previous processed cache retain display dimensions")
            var oldTimes:[Double]=[],newTimes:[Double]=[]
            for n in 0..<20 {
                // Alternate order. Display/decode happens in both paths; only
                // persistent encoding is compared here, not first-screen time.
                if n%2==0 {
                    let t=ProcessInfo.processInfo.systemUptime;_=try await encoder.encode(legacy,image:decoded);oldTimes.append((ProcessInfo.processInfo.systemUptime-t)*1000)
                    let u=ProcessInfo.processInfo.systemUptime;_=try await encoder.encode(record,image:nil);newTimes.append((ProcessInfo.processInfo.systemUptime-u)*1000)
                }else{
                    let u=ProcessInfo.processInfo.systemUptime;_=try await encoder.encode(record,image:nil);newTimes.append((ProcessInfo.processInfo.systemUptime-u)*1000)
                    let t=ProcessInfo.processInfo.systemUptime;_=try await encoder.encode(legacy,image:decoded);oldTimes.append((ProcessInfo.processInfo.systemUptime-t)*1000)
                }
            }
            print("BENCH cover_cache old_bytes=\(old.count) new_bytes=\(packed.count) old_encode_p50_ms=\(oldTimes.sorted()[10]) new_pack_p50_ms=\(newTimes.sorted()[10])")
            var jpegReads:[Double]=[],pngReads:[Double]=[]
            let previous=try CoverRecord.unpack(old)
            for _ in 0..<20{
                let t=ProcessInfo.processInfo.systemUptime;_=try await decoder.display(record,pixels:320);jpegReads.append((ProcessInfo.processInfo.systemUptime-t)*1000)
                let u=ProcessInfo.processInfo.systemUptime;_=try await decoder.display(previous,pixels:320);pngReads.append((ProcessInfo.processInfo.systemUptime-u)*1000)
            }
            print("BENCH cover_warm_decode old_png_p50_ms=\(pngReads.sorted()[10]) new_jpeg_p50_ms=\(jpegReads.sorted()[10])")
            // Exercise the complete pipeline rather than just its encoder.
            let covers=CoverDiskCache(root:root.appendingPathComponent("covers")),pipeline=SmartCoverPipeline(disk:covers)
            let path="/v1/books/1/cover",scope="synthetic-cache-efficiency",identity=String(repeating:"b",count:64)
            pipeline.configureScope(scope,revision:"v1",identities:[path:identity]);var requests=0,shown=0
            pipeline.variantLoad={_,_,_ in requests+=1;return .init(data:jpeg,status:200,etag:record.etag,thumbnailPixels:320)}
            pipeline.subscribe(path,id:UUID(),load:{preconditionFailure()}){if case .success=$0{shown+=1}}
            for _ in 0..<500{if pipeline.idle{break};try await Task.sleep(for:.milliseconds(10))}
            pass(pipeline.idle && shown==1 && requests==1,"NAS derivative pipeline displays and finishes asynchronous disk write")
            let coverKey=CoverRules.key(scope:scope+"\n"+identity+"\nthumbnail-v2-\(pipeline.pixelSize)",path:path)!
            let saved=try CoverRecord.unpack(try await covers.value(coverKey)!)
            pass(saved.thumbnail && saved.bytes==jpeg,"pipeline keeps negotiated JPEG instead of PNG")

            let disk=BodyDiskCache(root:root.appendingPathComponent("bodies"),budget:12*1024*1024)
            let data=Data(repeating:43,count:512*1024),sha=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            func put(_ scope:String)async throws->Data{
                let ticket=try await disk.begin(scope:scope,sha:sha,size:data.count),sink=try await disk.sink(ticket)
                try sink.append(data);try sink.finish(etag:"\""+sha+"\"");return try await disk.commit(ticket)
            }
            var held:Data?=try await put("pinned")
            var hitsOK=true
            for _ in 0..<100{let hit=try await disk.value(scope:"pinned",sha:sha,size:data.count);hitsOK = hitsOK && hit?.count==data.count}
            pass(hitsOK,"100 body hits preserve validated bytes")
            pass(await disk.touchTransactions<100,"body access bookkeeping batches transactions")
            try await disk.flushForChecks()
            print("BENCH body_hits=100 touch_transactions=\(await disk.touchTransactions) capacity_audits=\(await disk.capacityAudits) eviction_queries=\(await disk.evictionQueries)")
            pass(await disk.capacityAudits==1,"capacity is audited once rather than summed on each hit")
            pass(await disk.evictionQueries==0,"under-budget cache performs no eviction scan")
            for n in 0..<12{_=try await put("other-\(n)");try await Task.sleep(for:.milliseconds(1))}
            pass(held?.first==43,"eviction never unlinks an active mapping")
            pass(try await disk.usage()<=12*1024*1024-8*1024*1024,"eviction respects charged file/reservation budget")
            pass(try await disk.accountingForChecks(),"counter agrees with authoritative SQLite totals after eviction")
            try await disk.clear();pass(held?.first==43,"clear preserves leased bytes")
            pass(try await disk.accountingForChecks(),"clear leaves counters consistent")
            held=nil
            for _ in 0..<100{if try await disk.usage()==0{break};try await Task.sleep(for:.milliseconds(10))}
            pass(try await disk.usage()==0,"retired bytes released only after final player lease ends")
            _=try await put("restart");try await disk.flushForChecks()
            let reopened=BodyDiskCache(root:root.appendingPathComponent("bodies"),budget:12*1024*1024)
            pass(try await reopened.value(scope:"restart",sha:sha,size:data.count)==data,"restart audits and SHA-verifies existing cache")
            pass(try await reopened.accountingForChecks(),"reopened counters match stored bytes")
        }catch{preconditionFailure("cache efficiency checks failed: \(error)")}
        print("\(checks) cache efficiency checks passed")
    }
}
#endif
