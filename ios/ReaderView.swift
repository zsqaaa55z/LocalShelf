import SwiftUI
import UIKit

struct Reader:View {
    @ObservedObject var library:Library
    let book:Book
    var resumePage:Int?=nil
    var returnLabel:String="返回书库"
    @State private var readingScope:String?
    @State private var pages:[Page]=[]
    @State private var pageRevision=UUID()
    @State private var index=0
    @State private var error=""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var zoomed=false
    @State private var resetID=0
    @State private var immersive=false
    @State private var scrub=0.0
    @StateObject private var cache=ReadingCache()
    @State private var pageLoadID=0
    @State private var pageLoadTicket=UUID()
    @State private var pageLoading=false
    @State private var automaticPageRefresh=Set<Int>()
    @State private var showingPageJump=false
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ReadingPager(cache:cache,pages:pages,pageRevision:pageRevision,index:$index,zoomed:$zoomed,resetID:resetID,toggleControls:{immersive.toggle()},returnToLibrary:{dismiss()},readingChanged:{library.setReading($0)})
                .ignoresSafeArea()
                .accessibilityAction(named:"显示或隐藏阅读控制"){immersive.toggle()}
                .accessibilityAction(named:Text(returnLabel)){dismiss()}
            if pages.isEmpty && error.isEmpty{VStack(spacing:12){ProgressView();Text("正在读取页码…").font(.footnote).foregroundStyle(ShelfTheme.secondary)}.padding(20).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:16))}
            if !immersive || !error.isEmpty || (pages.indices.contains(index) && cache.failed.contains(pages[index].number)) {
                VStack(spacing:0){
                    HStack(spacing:4) {
                        Button{dismiss()}label:{Image(systemName:"chevron.left").font(.headline).frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(returnLabel)
                        Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                        Menu{
                            Button("刷新页码",systemImage:"arrow.clockwise"){pageLoadID+=1}.accessibilityIdentifier("refreshPageList").disabled(pageLoading)
                            Button("沉浸阅读",systemImage:"arrow.up.left.and.arrow.down.right"){immersive=true}
                        }label:{Image(systemName:"ellipsis").font(.headline).frame(width:44,height:44).contentShape(Rectangle())}
                            .accessibilityLabel("阅读选项").accessibilityIdentifier("readerOptions").accessibilityValue(pageLoading ? "读取中":"已刷新\(pageLoadID)次")
                    }.padding(.horizontal,4).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:ShelfTheme.corner)).padding(.horizontal,12).padding(.top,4)
                    Spacer()
                    VStack(spacing:0){
                        if !error.isEmpty{ShelfNotice(title:"页码暂时不可用",message:error,icon:"exclamationmark.circle",actionTitle:"重试",action:{pageLoadID+=1}).disabled(pageLoading)}
                        if !pages.isEmpty {
                            if pages.count>1 {PositionSlider(value:$scrub,count:pages.count,label:"阅读页码，点击或拖动跳页",commit:jump).frame(height:44)}
                            HStack(spacing:8) {
                                Button{move(-1)}label:{Label("上一页",systemImage:"chevron.left").font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}.disabled(index==0)
                                Spacer(minLength:0)
                                Button{showingPageJump=true}label:{
                                    VStack(spacing:2){
                                        HStack(spacing:4){Text("\(Int(scrub)+1) / \(pages.count)");Image(systemName:"chevron.up").font(.caption2)}.font(.subheadline.weight(.semibold))
                                        let number=pages[PagingRules.index(Int(scrub),count:pages.count)].number
                                        if number != Int(scrub)+1{Text("原页码 \(number)").font(.caption2).foregroundStyle(ShelfTheme.secondary).accessibilityIdentifier("readerOriginalPage")}
                                    }.monospacedDigit().frame(minWidth:64,minHeight:44)
                                }.accessibilityLabel("输入阅读页码").accessibilityIdentifier("readerPageJump")
                                if pages.indices.contains(index),cache.animated.contains(pages[index].number){
                                    Button(cache.animationPaused ? "播放动图":"暂停动图",systemImage:cache.animationPaused ? "play.fill":"pause.fill"){cache.toggleAnimation()}
                                        .labelStyle(.iconOnly).frame(width:44,height:44).disabled(cache.reducedMemory)
                                }
                                Spacer(minLength:0)
                                Button{move(1)}label:{HStack{Text("下一页");Image(systemName:"chevron.right")}.font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}.disabled(index==pages.count-1)
                            }
                            if pages.indices.contains(index),cache.animated.contains(pages[index].number){
                                if !cache.animationMessage.isEmpty{Text(cache.animationMessage).font(.caption).foregroundStyle(.orange)}
                            }
                            if cache.reducedMemory {Button("内存保护中 · 点此恢复邻页预加载"){cache.restorePrefetch();cache.update(library:library,book:book.id,pages:pages,index:index)}.font(.caption)}
                        }
                    }.padding(.horizontal,12).padding(.vertical,4).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:ShelfTheme.corner)).padding(.horizontal,12).padding(.bottom,4)
                }
            }
        }.foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
        .sheet(isPresented:$showingPageJump){PageJumpSheet(title:"跳到漫画页",current:index,count:pages.count){jump($0)}}
        .onAppear{readingScope=library.recentScope;library.setReading(true);cache.setThermalState(ProcessInfo.processInfo.thermalState);cache.setAnimationForeground(scenePhase == .active)}
        .onDisappear{rememberReading()}
        .onChange(of:scenePhase){_,phase in cache.setAnimationForeground(phase == .active);if phase != .active{rememberReading()}}
        .toolbar(.hidden,for:.navigationBar).navigationBarBackButtonHidden(true).statusBarHidden(immersive)
        .task(id:pageLoadID){await readPageList(force:pageLoadID>0)}
        .onChange(of:cache.failed){_,failed in
            refreshChangedPage()
        }
        .onChange(of:index){_,_ in refreshChangedPage()}
        .onChange(of:index){_,value in scrub=Double(value);if pages.indices.contains(value){ReadingProgress.save(pages[value].number,scope:readingScope ?? library.recentScope,id:book.id);cache.update(library:library,book:book.id,pages:pages,index:value)}}
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)){_ in resetID+=1;zoomed=false;cache.memoryPressure();library.trimCatalog()}
        .onReceive(NotificationCenter.default.publisher(for:ProcessInfo.thermalStateDidChangeNotification)){_ in cache.setThermalState(ProcessInfo.processInfo.thermalState)}
    }
    private func readPageList(force:Bool)async {
        let ticket=UUID();pageLoadTicket=ticket;pageLoading=true
        defer{if pageLoadTicket==ticket{pageLoading=false}}
        let saved=pages.indices.contains(index) ? pages[index].number:(resumePage ?? ReadingProgress.page(scope:readingScope ?? library.recentScope,id:book.id))
        do {
            let result=try await library.pageList(book.id,force:force)
            try Task.checkCancellation();guard pageLoadTicket==ticket else{return}
            if force{cache.reconcilePages(result.pages);resetID+=1}
            pages=result.pages;pageRevision=UUID()
            index=pages.firstIndex(where:{$0.number==saved}) ?? pages.firstIndex(where:{$0.number>=saved}) ?? max(0,pages.count-1)
            scrub=Double(index);error=pages.isEmpty ? "未找到可读取的已下载页面。可稍后刷新页码。":""
            cache.update(library:library,book:book.id,pages:pages,index:index)
        }catch{if !Task.isCancelled,pageLoadTicket==ticket{self.error = error is CancellationError ? "连接或缓存状态已变化，请刷新页码。":"无法刷新页序；保留现有页序，不会按时间重排。"}}
    }
    private func refreshChangedPage(){
        guard !pageLoading,pages.indices.contains(index) else{return}
        let number=pages[index].number
        if cache.failed.contains(number),cache.failures[number] == .changed,automaticPageRefresh.insert(number).inserted{pageLoadID+=1}
    }
    func jump(_ target:Int){guard !pages.isEmpty else{return};resetID+=1;zoomed=false;index=PagingRules.index(target,count:pages.count);scrub=Double(index);ReadingProgress.save(pages[index].number,scope:readingScope ?? library.recentScope,id:book.id)}
    func move(_ step:Int){jump(index+step)}
    private func rememberReading(){library.rememberReading(book:book,pages:pages,index:index,scope:readingScope)}
}

// Restrained, opaque surfaces: no full-screen blur or cover-dependent brightness.
