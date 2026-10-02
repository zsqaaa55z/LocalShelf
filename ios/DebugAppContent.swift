import SwiftUI

#if DEBUG && targetEnvironment(simulator)
/// Launch-only synthetic checks and demos; never included in device Release builds.
struct DebugAppContent: View {
    var body: some View { Group {
        if ProcessInfo.processInfo.arguments.contains("--diagnostic-checks"){Text("只读连接诊断检查").task{await DiagnosticChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--manual-library-checks"){Text("双书库隔离检查").task{await ManualLibraryChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--manual-library-demo"){ManualLibraryDemo()}
        else if ProcessInfo.processInfo.arguments.contains("--cold-start-demo"){ColdStartShelfDemo()}
        else if ProcessInfo.processInfo.arguments.contains("--cache-efficiency-checks"){Text("缓存效率检查").task{await CacheEfficiencyChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--related-checks"){Text("作者与系列检查").task{await RelatedChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--related-demo"){RelatedDemoView()}
        else if ProcessInfo.processInfo.arguments.contains("--local-update-checks"){Text("单页恢复与局部更新检查").task{await LocalUpdateChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--connection-recovery-test"){Text("连接恢复检查").task{await ConnectionRecoveryChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--shelf-update-checks"){Text("书库局部刷新检查").task{await ShelfUpdateChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--reader-update-checks"){Text("阅读增量与首帧检查").task{await ReaderUpdateChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--decode-cancellation-checks"){Text("解码取消专项验证").task{await AnimationPolicyChecks.cancellationOnly();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--manifest-conditional-checks"){Text("清单条件缓存检查").task{await ManifestConditionalChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--body-cache-checks"){Text("正文缓存检查").task{await BodyCacheChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--nas-thumbnail-contract-checks"){Text("NAS 缩略图协议检查").task{await NASThumbnailChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--nas-library-cache-checks"){Text("NAS 本地目录检查").task{await NASLibraryCacheChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--nas-scheduling-experiment"){Text("NAS 调度对照").task{await NASSchedulingExperiment.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--nas-cache-demo"){NASCatalogPreviewDemo()}
        else if ProcessInfo.processInfo.arguments.contains("--nas-password-checks"){Text("NAS 密码检查").task{await NASPasswordChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--nas-checks"){Text("NAS 迁移检查").task{await NASChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--page-cache-checks"){Text("页码缓存检查").task{await PageListChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--scroll-network-benefits"){Text("快滑网络对照").task{await ScrollNetworkBenefits.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--parsing-checks"){Text("后台解析检查").task{await ParsingChecks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--cache-read-benefits"){Text("缓存读取对照").task{await CacheReadBenefits.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--p34-checks"){Text("分页与编码队列测试").task{await P34Checks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--cover-v2-checks"){Text("增强封面与动图缓冲测试").task{await CoverV2Checks.run();exit(0)}}
        else if ProcessInfo.processInfo.arguments.contains("--animation-policy-checks"){Text("大动图与错误恢复测试").task{await AnimationPolicyChecks.run();exit(0)}}
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
    } }
}
#endif
