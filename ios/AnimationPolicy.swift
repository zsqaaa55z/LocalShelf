import Foundation

enum AnimationLimits {
    static let compressed=32*1024*1024, maxPixels=8_000_000, maxFrames=10_000
    static let reserve=40*1024*1024, extendedReserve=88*1024*1024
    static let playback=10*1024*1024
    static func delay(_ raw:Double)->Double{raw.isFinite && raw>=0.02 ? min(raw,60) : 0.1}
}

// No paths, titles, tokens or raw server error strings are put into UI diagnostics.
enum AnimationFailure:Error,Equatable {
    case fileSize(Int), dimensions(Int,Int), frameCount(Int), unsupported, invalidMetadata
    case frame(Int), workingSet(Int), resources, network, unavailable, deferred
    static func cancelled(_ error:Error)->Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    static func classify(_ error:Error)->Self {
        if let failure=error as? Self{return failure}
        if error is URLError{return .network}
        return .unavailable
    }
    var transient:Bool{self == .resources || self == .network || self == .deferred}
    var message:String {
        let preview="；保留静态预览，可点播放重试。"
        switch self {
        case .fileSize(let bytes):return String(format:"动图文件 %.1f MiB，超过 32 MiB 安全上限",Double(bytes)/1048576)+preview
        case .dimensions(let w,let h):return "动图尺寸 \(w) × \(h)，超过 800 万像素安全上限"+preview
        case .frameCount(let count):return "动图共 \(count) 帧，超过 10000 帧安全上限"+preview
        case .unsupported:return "系统解码器无法识别此动画格式"+preview
        case .invalidMetadata:return "无法读取完整的动图信息"+preview
        case .frame(let index):return "动图第 \(index+1) 帧解码失败"+preview
        case .workingSet(let bytes):return String(format:"动图预计解码开销 %.1f MiB，超过单页安全预算",Double(bytes)/1048576)+preview
        case .resources:return "播放资源暂不足，已暂停邻页动图预热"+preview
        case .network:return "动图读取遇到网络问题"+preview
        case .unavailable:return "动图读取失败"+preview
        case .deferred:return "大动图仅在当前页准备播放"+preview
        }
    }
}

struct AnimationPlan {
    let width:Int,height:Int,frames:Int,bytes:Int
    let pixelLimit:Int,sourceCost:Int,reservation:Int,extended:Bool
    static func make(bytes:Int,width:Int,height:Int,frames:Int)throws->Self {
        guard bytes<=AnimationLimits.compressed else{throw AnimationFailure.fileSize(bytes)}
        guard bytes>=0,width>0,height>0,frames>1 else{throw AnimationFailure.invalidMetadata}
        guard width<=AnimationLimits.maxPixels,height<=AnimationLimits.maxPixels,
              width<=AnimationLimits.maxPixels/height else{throw AnimationFailure.dimensions(width,height)}
        guard frames<=AnimationLimits.maxFrames else{throw AnimationFailure.frameCount(frames)}
        let large=bytes>16*1024*1024 || width*height>4_000_000 || frames>2000
        let pixelLimit=large ? 768:1024
        // Charge two source-sized composition surfaces and bounded frame metadata,
        // not just the thumbnail. This is an admission estimate, not an RSS promise.
        let source=bytes+width*height*8+frames*128
        let scale=min(1,Double(pixelLimit)/Double(max(width,height)))
        let frameBytes=(Int(ceil(Double(width)*scale))*4+64)*Int(ceil(Double(height)*scale))
        let reservation=max(bytes+AnimationLimits.playback,source+2*frameBytes)
        guard reservation<=AnimationLimits.extendedReserve-AnimationLimits.playback else{throw AnimationFailure.workingSet(reservation)}
        return Self(width:width,height:height,frames:frames,bytes:bytes,pixelLimit:pixelLimit,sourceCost:source,reservation:reservation,
                    extended:large || reservation>AnimationLimits.reserve-AnimationLimits.playback)
    }
}

// A cancelled ImageIO call is not interruptible. Metadata/frame work keeps its
// physical slot until it returns; queued demand has a bounded wait, not a hang.
actor AnimationFrameSlots {
    static let shared=AnimationFrameSlots()
    private var active=0
    func acquire(timeout:Duration = .seconds(2))async throws {
        let deadline=ContinuousClock.now.advanced(by:timeout)
        while active>=2{
            try Task.checkCancellation()
            guard ContinuousClock.now<deadline else{throw AnimationFailure.resources}
            try await Task.sleep(for:.milliseconds(5))
        }
        try Task.checkCancellation();active+=1
    }
    func release(){active-=1}
}
