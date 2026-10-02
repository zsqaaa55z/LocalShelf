import SwiftUI
import UIKit
import VisionKit
import AVFoundation

enum ShelfTheme {
    static let background=Color.black
    static let surface=Color(white:0.075)
    static let primary=Color(white:0.94)
    static let secondary=Color(white:0.68)
    static let accent=Color(red:0.40,green:0.80,blue:0.73)
    static let corner:CGFloat=14
}

// Static placeholders provide a stable dark first frame without a blocking
// splash delay, fake catalog rows, network prefetch or per-cell shimmer.
struct ShelfStartupView:View {
    let columns:Int
    var body:some View {
        GeometryReader{geometry in
            let width=max(1,(geometry.size.width-32-CGFloat(columns-1)*12)/CGFloat(columns))
            ScrollView {
                VStack(alignment:.leading,spacing:16){
                    HStack(spacing:10){ProgressView();Text("正在恢复书库…").font(.subheadline).foregroundStyle(ShelfTheme.secondary)}.frame(height:44)
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:columns),spacing:18){
                        ForEach(0..<columns*3,id:\.self){_ in
                            VStack(alignment:.leading,spacing:8){
                                RoundedRectangle(cornerRadius:12).fill(ShelfTheme.surface).frame(height:width*1.5)
                                RoundedRectangle(cornerRadius:3).fill(ShelfTheme.surface).frame(height:12).padding(.trailing,20)
                                RoundedRectangle(cornerRadius:3).fill(ShelfTheme.surface).frame(height:12).padding(.trailing,46)
                            }.accessibilityHidden(true)
                        }
                    }
                }.padding(16)
            }.scrollDisabled(true).background(ShelfTheme.background)
        }.allowsHitTesting(false).accessibilityElement(children:.contain).accessibilityIdentifier("shelfStartupPlaceholder")
    }
}

struct BookTitleSheet:View {
    let title:String
    @Environment(\.dismiss) private var dismiss
    @State private var copied=false
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20){
                    Label("完整名称",systemImage:"text.alignleft").font(.caption.weight(.medium)).foregroundStyle(ShelfTheme.accent)
                    Text(title).font(.title3.weight(.medium)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("fullBookTitle")
                    Button(copied ? "已复制名称":"复制完整名称",systemImage:copied ? "checkmark":"doc.on.doc"){
                        UIPasteboard.general.string=title;copied=true
                    }.frame(minHeight:44).accessibilityIdentifier("copyBookTitle")
                }.padding(20)
            }.background(ShelfTheme.background).navigationTitle("漫画名称").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}.accessibilityIdentifier("closeBookTitle")}}
        }.tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.primary).preferredColorScheme(.dark)
            .presentationDetents([.medium,.large]).presentationDragIndicator(.visible).pageEdgeReturn{dismiss()}
    }
}

struct ShelfNotice:View {
    let title:String,message:String,icon:String
    var actionTitle:String?=nil
    var action:(()->Void)?=nil
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            HStack(spacing:8){
                Label(title,systemImage:icon).font(.subheadline.weight(.medium))
                Spacer(minLength:4)
                if let actionTitle,let action{Button(actionTitle,action:action).font(.subheadline.weight(.medium)).frame(minHeight:44).foregroundStyle(ShelfTheme.accent)}
            }
            DisclosureGroup("详细说明"){Text(message).font(.footnote).foregroundStyle(ShelfTheme.secondary).frame(maxWidth:.infinity,alignment:.leading)}.font(.caption).tint(ShelfTheme.secondary)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:14))
    }
}

struct ShelfView:View {
    @StateObject var library:Library
    @MainActor init(library:Library?=nil){_library=StateObject(wrappedValue:library ?? Library())}
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingForget=false
    @State private var confirmingCacheClear=false
    @State private var confirmingProgressReset=false
    @State private var progressResetMessage=""
    @State private var scanning=false
    @State private var requestingCamera=false
    @State private var shelfScrub=0.0
    @State private var atShelfBottom=false
    @State private var shelfSeek:ShelfSeek?
    @State private var selectedBook:Book?
    @State private var selectedRelated:RelatedRequest?
    @State private var selectedResumePage:Int?
    @State private var locateTask:Task<Void,Never>?
    @ObservedObject private var meter=InteractionMeter.shared
    @State private var showingSettings=false
    @State private var showingDiagnostics=false
    @State private var showingAdvanced=false
    @State private var pairingDigits=""
    @State private var nasPassword=""
    @State private var fullTitle:String?
    @AppStorage("shelf.columns") private var storedColumns=2
    @State private var viewport=CGSize.zero
    private var columns:Int{storedColumns==3 ? 3:2}
    var body:some View {
        NavigationStack {
            CollectionShelf(library:library,columns:columns,header:AnyView(collectionHeader),seek:shelfSeek,select:{book in
                guard !library.browsingCachedCatalog else{library.error="当前是本地目录预览，连接 NAS 后才能读取正文。";return}
                selectedResumePage=nil;selectedBook=book
            },fullTitle:{fullTitle=$0},position:{value,bottom in shelfScrub=Double(value);atShelfBottom=bottom},related:{book,kind in
                library.setRelatedBrowsing(true);selectedRelated=RelatedRequest(book:book,kind:kind)
            })
            .overlay{if library.showStartupPlaceholder{ShelfStartupView(columns:columns)}}
            .background(ShelfTheme.background).navigationTitle(library.total>0 ? "书库 · \(library.total.formatted()) 本":"书库")
            .navigationBarTitleDisplayMode(.inline).toolbarColorScheme(.dark,for:.navigationBar)
            .toolbarBackground(.black,for:.navigationBar).toolbarBackground(.visible,for:.navigationBar)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing){
                    Button("设置",systemImage:"gearshape"){showingSettings=true}
                        .frame(minWidth:44,minHeight:44).accessibilityIdentifier("shelfSettings")
                }
            }
            .overlay(alignment:.trailing){
                if library.books.count>1 {
                    ShelfPositionRail(position:atShelfBottom ? library.books.count-1:Int(shelfScrub),total:library.books.count,enabled:!library.loading,commit:{offset in
                        guard !library.loading,!library.books.isEmpty else{return}
                        let local=PagingRules.index(offset,count:library.books.count)
                        shelfScrub=Double(local)
                        shelfSeek=ShelfSeek(index:local)
                    }).id(library.pageIndex)
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0){pageControls}
            .safeAreaInset(edge:.top,spacing:0){
                if library.serverTarget == .nas {
                    Picker("书库来源",selection:Binding(get:{library.shelfSource},set:{source in Task{await library.selectShelf(source)}})){
                        ForEach(ShelfSource.allCases){source in Text(source.title).tag(source)}
                    }.pickerStyle(.segmented).disabled(library.loading || library.switchingShelf)
                        .padding(.horizontal,16).padding(.vertical,8).background(ShelfTheme.background)
                        .accessibilityIdentifier("shelfSourceSwitcher")
                }
            }
            .background{GeometryReader{geometry in Color.clear.onAppear{viewport=geometry.size;library.updateCoverViewport(viewport,columns:columns)}.onChange(of:geometry.size){_,size in viewport=size;library.updateCoverViewport(size,columns:columns)}}}
            .onChange(of:columns){_,_ in library.updateCoverViewport(viewport,columns:columns)}
            .onChange(of:library.total){_,_ in library.updateCoverViewport(viewport,columns:columns)}
            .onChange(of:library.pageSize){_,_ in if library.canBrowseCatalog {Task{await library.loadPage(0)}}}
            .onAppear{library.setReading(false);library.scheduleCoverPrefetch(anchor:PagingRules.index(Int(shelfScrub),count:library.books.count))}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)){_ in library.cancelCoverPrefetch();library.covers.trim();library.trimCatalog()}
            .sheet(isPresented:$showingSettings){settingsView}
            .sheet(isPresented:Binding(get:{fullTitle != nil},set:{if !$0{fullTitle=nil}})){if let fullTitle{BookTitleSheet(title:fullTitle)}}
            .onChange(of:showingSettings){_,visible in if !visible{nasPassword="";pairingDigits="";showingAdvanced=false}}
            .onChange(of:library.serverTarget){_,_ in nasPassword="";pairingDigits=""}
            .onChange(of:library.shelfSource){_,_ in shelfScrub=0;atShelfBottom=false;shelfSeek=nil}
            .onChange(of:library.restoredBookID){_,id in
                if let id,let index=library.books.firstIndex(where:{$0.id==id}){shelfScrub=Double(index);shelfSeek=ShelfSeek(index:index)}
            }
            .navigationDestination(isPresented:Binding(get:{selectedBook != nil},set:{if !$0{selectedBook=nil;selectedResumePage=nil}})){if let book=selectedBook{Reader(library:library,book:book,resumePage:selectedResumePage)}}
            .navigationDestination(isPresented:Binding(get:{selectedRelated != nil},set:{if !$0{selectedRelated=nil;library.setRelatedBrowsing(false)}})){if let request=selectedRelated{RelatedShelfView(library:library,request:request)}}
        }
        .tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.primary).preferredColorScheme(.dark)
        .task{library.setForeground(scenePhase == .active);await library.refreshCacheUsage()}
        .onChange(of:scenePhase){_,phase in library.setForeground(phase == .active);if phase != .active{meter.stop();locateTask?.cancel()}}
        .onDisappear{locateTask?.cancel()}
    }
    private var collectionHeader:some View {
        VStack(alignment:.leading,spacing:10){
            shelfHeader
            if library.recentReading != nil{continueReadingCard}
            if library.base==nil && !library.loading && !library.startupPending && library.books.isEmpty{Button("连接与配对"){showingSettings=true}.buttonStyle(.borderedProminent)}
            if !library.error.isEmpty{ShelfNotice(title:"书库暂时无法更新",message:library.error,icon:"wifi.exclamationmark",actionTitle:"连接设置",action:{showingSettings=true})}
            if library.books.isEmpty && !library.loading && library.base != nil && library.error.isEmpty{Text(library.serverTarget == .nas ? (library.shelfSource == .manual ? "手动书库还没有漫画。用 Windows 上传工具选择漫画文件夹，上传完成后在这里刷新。":"书库暂时没有漫画，请检查 NAS 已发布目录。") : "书库暂时没有漫画，请在安卓导入最新清单。").font(.subheadline).foregroundStyle(ShelfTheme.secondary)}
        }.padding(.horizontal,16).padding(.vertical,8).foregroundStyle(ShelfTheme.primary).tint(ShelfTheme.accent).preferredColorScheme(.dark)
    }
    private var continueReadingCard:some View {
        let recent=library.recentReading
        let available=recent != nil && recent?.book.isMissing==false && library.base != nil && !library.loading
        return HStack(spacing:8){
        Button {
            guard available,let recent else{return}
            selectedResumePage=recent.pageNumber;selectedBook=recent.book
        }label:{
            HStack(spacing:12){
                Group {
                    if let recent,!library.coversHidden,!recent.book.isMissing,library.base != nil {
                        RecentReadingCover(library:library,book:recent.book).accessibilityHidden(true)
                    }else{Image(systemName:library.coversHidden ? "eye.slash":"book.closed").foregroundStyle(ShelfTheme.secondary)}
                }.frame(width:32,height:48).background(ShelfTheme.background,in:RoundedRectangle(cornerRadius:6)).clipShape(RoundedRectangle(cornerRadius:6))
                VStack(alignment:.leading,spacing:3){
                    Text("继续阅读").font(.caption).foregroundStyle(ShelfTheme.accent)
                    Text(recent?.book.title ?? "从下一次阅读开始记录").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(!library.locateMessage.isEmpty ? library.locateMessage:(recent.map{$0.book.isMissing ? "本地文件缺失":(library.base==nil ? "连接书库后继续":"上次读到 \($0.position+1) / \($0.pageCount)"+($0.pageNumber != $0.position+1 ? " · 原页码 \($0.pageNumber)":""))} ?? "只记住最近一本，不改变书库顺序"))
                        .font(.caption2).monospacedDigit().foregroundStyle(ShelfTheme.secondary).lineLimit(1)
                }.frame(maxWidth:.infinity,alignment:.leading)
                Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ShelfTheme.secondary)
            }.frame(minHeight:48).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!available)
        .accessibilityIdentifier("continueReading")
        .accessibilityLabel(recent.map{"继续阅读，\($0.book.title)"} ?? "继续阅读，暂无记录")
        .accessibilityValue(recent.map{"第 \($0.position+1) 页，共 \($0.pageCount) 页"+(library.coversHidden ? "，封面已隐藏":"")} ?? "暂无记录")
        Divider().frame(height:40)
        Button {
            if library.locatingRecent{locateTask?.cancel();return}
            locateTask=Task{if let index=await library.locateRecentBook(),!Task.isCancelled{shelfSeek=ShelfSeek(index:index,centered:true);shelfScrub=Double(index);atShelfBottom=false}}
        }label:{VStack(spacing:4){Image(systemName:library.locatingRecent ? "xmark":"scope");Text(library.locatingRecent ? "取消":"定位").font(.caption2)}.frame(width:44,height:48)}
        .buttonStyle(.plain).foregroundStyle(ShelfTheme.accent)
        .disabled(!library.locatingRecent && (recent==nil || library.base==nil || library.loading))
        .accessibilityIdentifier("locateRecentReading").accessibilityLabel(library.locatingRecent ? "取消定位":"在书库中定位")
        .accessibilityValue(library.locateMessage)
        }.padding(10).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:ShelfTheme.corner))
    }
    private var shelfHeader:some View {
            HStack(spacing:8){
                Menu {
                    Picker("封面布局",selection:$storedColumns){Text("舒适两列").tag(2);Text("紧凑三列").tag(3)}
                    Picker("每页数量",selection:$library.pageSize){ForEach(Array(stride(from:50,through:500,by:50)),id:\.self){Text("\($0) 本 / 页").tag($0)}}.disabled(library.loading)
                }label:{Label("\(columns) 列 · \(library.pageSize) 本 / 页",systemImage:"square.grid.2x2").font(.subheadline)}
                .frame(minHeight:44).accessibilityIdentifier("shelfLayout")
                Spacer()
                Button{showingSettings=true}label:{
                    if library.browsingCachedCatalog{Text("目录预览").font(.caption).accessibilityIdentifier("cachedCatalogBanner")}
                    else{Image(systemName:library.loading || library.startupPending ? "arrow.triangle.2.circlepath":(!library.error.isEmpty ? "wifi.exclamationmark":(library.base==nil ? "wifi.slash":"wifi")))}
                }.frame(minWidth:44,minHeight:44).foregroundStyle(library.error.isEmpty ? ShelfTheme.accent:.orange)
                    .accessibilityIdentifier("connectionStatus")
                    .accessibilityLabel(library.browsingCachedCatalog ? "本地目录预览，正文需连接后阅读":(library.loading || library.startupPending ? "正在连接书库":(!library.error.isEmpty ? "需检查连接":(library.base==nil ? "未连接":"已连接"))))
                Button("刷新书库",systemImage:"arrow.clockwise"){Task{await library.more()}}
                    .labelStyle(.iconOnly).frame(width:44,height:44).disabled(library.loading || library.base==nil).accessibilityIdentifier("refreshCatalog")
            }
    }
    @ViewBuilder private var pinControls:some View {
        SecureField("6 位数字配对码",text:$pairingDigits).keyboardType(.numberPad).textContentType(.oneTimeCode).disabled(library.loading)
            .onChange(of:pairingDigits){_,value in pairingDigits=String(value.filter{"0123456789".contains($0)}.prefix(6))}
        Button("使用六位码配对"){
            let value=pairingDigits;pairingDigits=""
            Task{await library.connect(pin:value);if library.base != nil && library.error.isEmpty{showingSettings=false}}
        }.disabled(library.loading || pairingDigits.count != 6)
    }
    private var settingsView:some View {
        NavigationStack {
            Form {
                Section {
                    Button(library.coversHidden ? "显示所有封面":"隐藏所有封面",systemImage:library.coversHidden ? "eye":"eye.slash"){
                        library.coversHidden.toggle()
                    }.accessibilityIdentifier("hideAllCovers").accessibilityValue(library.coversHidden ? "1":"0")
                } header:{Text("隐私显示")} footer:{Text("隐藏封面不影响标题、顺序或正文。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    Picker("书库服务器",selection:Binding(get:{library.serverTarget},set:{target in Task{await library.selectServer(target)}})){
                        ForEach(ServerTarget.allCases){Text($0.title).tag($0)}
                    }.pickerStyle(.segmented).disabled(library.loading).accessibilityIdentifier("serverTarget")
                    Text(library.pairingStatus).foregroundStyle(ShelfTheme.secondary)
                    if !library.error.isEmpty{Text(library.error).foregroundStyle(.orange)}
                    if library.paired != nil {
                        Button("重新连接"){Task{await library.reconnect()}}.disabled(library.loading)
                    }
                    if library.serverTarget == .android{Button("扫码连接安卓",systemImage:"qrcode.viewfinder"){Task{await scan()}}.disabled(library.loading || requestingCamera)}
                    if library.paired==nil || library.serverTarget == .nas {
                        TextField(library.serverTarget == .nas ? "NAS 阅读地址：http://192.168.…:8089":"安卓地址：http://192.168.…:8088",text:$library.address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(library.loading).accessibilityIdentifier("serverAddress")
                        if library.serverTarget == .nas {
                            SecureField("NAS 固定密码",text:$nasPassword).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable).disabled(library.loading).accessibilityIdentifier("nasPassword")
                            Button("使用密码连接"){
                                let value=nasPassword;nasPassword=""
                                Task{await library.connect(password:value);if library.base != nil && library.error.isEmpty{showingSettings=false}}
                            }.disabled(library.loading || (try? NASPassword.body(nasPassword))==nil).accessibilityIdentifier("connectNASPassword")
                        }else{pinControls}
                    }
                    if library.serverTarget == .nas {
                        Button("一键连接诊断",systemImage:"stethoscope"){showingDiagnostics=true}
                            .accessibilityIdentifier("connectionDiagnostics")
                    }
                } header:{Text("连接与配对")} footer:{Text("首次成功后自动连接。仅在可信局域网使用；HTTP 未加密，不开放公网。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    LabeledContent("磁盘缓存上限",value:"2 GB")
                    Text(library.cacheUsage).monospacedDigit()
                    if !library.cacheMessage.isEmpty{Text(library.cacheMessage).font(.footnote).foregroundStyle(ShelfTheme.secondary)}
                } header:{Text("缓存")} footer:{Text("封面和近期正文共用 2 GB。缓存不是备份，不修改服务器上的文件。")}
                .listRowBackground(ShelfTheme.surface)
                Section {
                    Button("高级设置",systemImage:"slider.horizontal.3"){showingAdvanced=true}.accessibilityIdentifier("advancedSettings")
                }.listRowBackground(ShelfTheme.surface)
                Section {
                    Button(library.cacheBusy ? "清理中…":"清空封面与正文缓存",role:.destructive){confirmingCacheClear=true}.disabled(library.cacheBusy)
                    if library.paired != nil{Button("解除配对",role:.destructive){confirmingForget=true}}
                    Button("重置所有漫画阅读进度",role:.destructive){confirmingProgressReset=true}.foregroundStyle(.red).accessibilityIdentifier("resetReadingProgress")
                    if !progressResetMessage.isEmpty{Text(progressResetMessage).font(.footnote).foregroundStyle(ShelfTheme.secondary)}
                } header:{Text("清理与重置")} footer:{Text("操作前会再次确认。重置阅读进度不会删除漫画；安卓和 NAS 的本机阅读位置都会重置。")}
                .listRowBackground(ShelfTheme.surface).tint(.red)
            }.scrollContentBackground(.hidden).background(ShelfTheme.background)
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){showingSettings=false}.accessibilityIdentifier("closeShelfSettings")}}
            .navigationDestination(isPresented:$showingAdvanced){advancedSettings}
            .navigationDestination(isPresented:$showingDiagnostics){ConnectionDiagnosticView(library:library)}
        }.tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.primary).preferredColorScheme(.dark)
        .pageEdgeReturn(enabled:!showingAdvanced && !showingDiagnostics && !scanning && !confirmingForget && !confirmingCacheClear && !confirmingProgressReset){showingSettings=false}
        .task{await library.refreshCacheUsage()}
        .sheet(isPresented:$scanning){
            NavigationStack {
                scannerContent.navigationTitle("扫描安卓配对码").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){scanning=false}}}
            }.preferredColorScheme(.dark).tint(ShelfTheme.accent)
            .pageEdgeReturn{scanning=false}
        }
        .alert("解除这台 iPhone 的配对？",isPresented:$confirmingForget){
            Button("解除本机配对",role:.destructive){library.forget()}
            Button("取消",role:.cancel){}
        } message:{Text("只解除当前服务器的本机配对；另一服务器、阅读记录和漫画保留。撤销旧凭据需要在对应服务端操作。")}
        .alert("清空本机封面和正文缓存？",isPresented:$confirmingCacheClear){
            Button("清空缓存",role:.destructive){Task{await library.clearCoverCache()}}
            Button("取消",role:.cancel){}
        } message:{Text("不会删除 NAS 或安卓文件，也不影响阅读进度。缓存会按需重新下载；播放器使用中的文件释放后清除。")}
        .alert("重置所有漫画阅读进度？",isPresented:$confirmingProgressReset){
            Button("确认重置所有进度",role:.destructive){let count=library.resetReadingProgress();progressResetMessage="已重置 \(count) 条本机阅读位置"}
            Button("取消",role:.cancel){}
        } message:{Text("此操作不可撤销。下次打开漫画将从第一页开始；漫画、封面缓存、书库顺序和配对信息均保留。")}
    }
    private var advancedSettings:some View {
        Form {
            Section {
                Button(meter.recording ? "停止记录":"记录 15 秒交互耗时"){
                    if meter.recording{meter.stop()}else{meter.start();showingSettings=false}
                }.accessibilityIdentifier("recordInteraction")
                Text(meter.report).font(.footnote).monospacedDigit().foregroundStyle(ShelfTheme.secondary)
            } header:{Text("交互诊断")} footer:{Text("记录仅保存在内存，不包含漫画内容，也不是 GPU 实际呈现帧率。")}
            .listRowBackground(ShelfTheme.surface)
            if library.serverTarget == .nas {
                Section {
                    Text(library.catalogStatus.isEmpty ? "连接已发布的 NAS 书库后，后台保存完整目录":library.catalogStatus).font(.footnote).accessibilityIdentifier("localCatalogStatus")
                    Button("更新本地书库目录"){Task{await library.refreshLocalCatalog()}}.disabled(library.base==nil || library.loading).accessibilityIdentifier("refreshLocalCatalog")
                } header:{Text("本地书库目录")} footer:{Text("仅保存标题、ID、顺序和封面标识。未连接时可预览目录与已缓存封面，正文仍需连接；整份校验成功才替换旧目录。")}
                .listRowBackground(ShelfTheme.surface)
            }
            Section {
                if library.serverTarget == .nas{DisclosureGroup("旧版 NAS 六位码"){pinControls}}
                else{DisclosureGroup("旧版安卓临时连接"){
                    SecureField("旧版完整访问口令",text:$library.secret).disabled(library.loading)
                    Button("手动临时连接"){Task{await library.connect()}}.disabled(library.loading || library.paired != nil)
                }}
                Text(library.serverTarget == .nas ? "固定密码无五分钟期限；连续输错 5 次需等待 15 分钟。App 只保存随机阅读凭据，不保存输入的密码。":"六位码 5 分钟有效，最多尝试 5 次，成功后失效；之后使用本机钥匙串中的配对凭据自动连接。").font(.footnote).foregroundStyle(ShelfTheme.secondary)
            } header:{Text("连接说明与兼容")}
            .listRowBackground(ShelfTheme.surface)
            Section {
                Text("封面 1.488 GB，近期正文 512 MB；正文缓存按内容校验，旧服务保持联网读取。").font(.footnote)
                Text("按导入的清单顺序展示漫画；漫画内部按数字页码阅读。").font(.footnote)
                if !library.orderNotice.isEmpty{Text(library.orderNotice).font(.footnote).accessibilityIdentifier("libraryOrderNotice")}
            } header:{Text("书库与缓存说明")}
            .listRowBackground(ShelfTheme.surface)
        }.scrollContentBackground(.hidden).background(ShelfTheme.background)
            .navigationTitle("高级设置").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar{ToolbarItem(placement:.navigationBarLeading){Button("设置",systemImage:"chevron.left"){showingAdvanced=false}.accessibilityIdentifier("closeAdvancedSettings")}}
            .pageEdgeReturn{showingAdvanced=false}
    }
    @ViewBuilder private var scannerContent:some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--edge-return-demo"){
            Color.black.overlay(Text("扫码页返回测试 · 无相机")).accessibilityIdentifier("scannerFixture")
        }else{liveScanner}
        #else
        liveScanner
        #endif
    }
    private var liveScanner:some View {
        PairingScanner {result in
            scanning=false
            switch result{
            case .success(let code):Task{await library.connect(code:code);if library.base != nil && library.error.isEmpty{showingSettings=false}}
            case .failure:library.error="扫码失败或不是有效的 LocalShelf 局域网配对码，请重新扫描。"
            }
        }
    }
    @MainActor private func scan()async{
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--edge-return-demo"){scanning=true;return}
        #endif
        requestingCamera=true;defer{requestingCamera=false}
        guard DataScannerViewController.isSupported else{library.error="此设备不支持扫码，请使用手动输入。";return}
        guard await AVCaptureDevice.requestAccess(for:.video) else{library.error="相机未授权，可在系统设置中允许相机，或手动输入。";return}
        guard DataScannerViewController.isAvailable else{library.error="相机暂不可用，请稍后再试或手动输入。";return}
        scanning=true
    }
    private func browsePage(_ page:Int){Task{await library.loadPage(page)}}
    var pageControls:some View {
        HStack(spacing:12) {
            Button{browsePage(library.pageIndex-1)}label:{Label("上一页",systemImage:"chevron.left").font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}
                .disabled(library.pageIndex==0||library.loading||(!library.canBrowseCatalog)).accessibilityIdentifier("shelfPreviousPage")
            Spacer()
            Menu {
                // Priority keeps page 1 nearest the bottom trigger and initially
                // visible; pages grow upward without changing the catalog order.
                ForEach(0..<library.pageCount,id:\.self){page in Button("第 \(page+1) 页"){browsePage(page)}}
            }label:{HStack(spacing:6){Text("\(library.pageIndex+1) / \(library.pageCount) 页").monospacedDigit();Image(systemName:"chevron.down").font(.caption2)}.font(.subheadline.weight(.medium)).frame(minHeight:44).contentShape(Rectangle())}
                .menuOrder(.priority)
                .disabled(library.loading||(!library.canBrowseCatalog)).accessibilityIdentifier("shelfPageMenu")
            Spacer()
            Button{browsePage(library.pageIndex+1)}label:{HStack{Text("下一页");Image(systemName:"chevron.right")}.font(.subheadline).frame(minHeight:44).contentShape(Rectangle())}
                .disabled(library.pageIndex+1>=library.pageCount||library.loading||(!library.canBrowseCatalog)).accessibilityIdentifier("shelfNextPage")
        }.buttonStyle(.plain).padding(.horizontal,20).padding(.vertical,4).background(ShelfTheme.surface)
    }
}
