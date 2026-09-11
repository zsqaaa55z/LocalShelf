import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var count=0
        func pass(_ condition:Bool,_ name:String){precondition(condition,name);count+=1;print("PASS \(name)")}
        func rejects(_ name:String,_ run:()throws->Void){do{try run();fatalError(name)}catch{count+=1;print("PASS \(name)")}}
        pass(PagingRules.prefetchIndices(current:3,count:8,direction:-1)==[3,2,4,1,5],"反向翻页优先前方邻页，保持双侧两页窗口")
        pass(PagingRules.prefetchIndices(current:0,count:8,direction:-1)==[0,1,2],"反向预取在首页不越界")
        let suite="localshelf-progress-check-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(5,forKey:"page.123");defaults.set(10,forKey:"page.456")
        defaults.set("keep",forKey:"pairing");defaults.set(500,forKey:"pageSize");defaults.set("keep",forKey:"page.invalid")
        pass(ReadingProgress.reset(in:defaults)==2,"重置删除所有合法漫画进度键")
        pass(defaults.object(forKey:"page.123")==nil && defaults.object(forKey:"page.456")==nil,"重置后不再恢复旧页码")
        pass(defaults.string(forKey:"pairing")=="keep" && defaults.integer(forKey:"pageSize")==500 && defaults.string(forKey:"page.invalid")=="keep","重置保留其他偏好与非进度数据")
        pass(ReadingProgress.reset(in:defaults)==0,"空进度重复重置安全")
        let recent=RecentReading(scope:"device/library",book:Book(id:"123",title:"本机测试",rank:12),pageNumber:8,position:2,pageCount:5)
        defaults.set(try JSONEncoder().encode(recent),forKey:RecentReading.key)
        pass(ProgressBackup.capture(in:defaults).libraries.first?.recent==recent,"升级后未重连也能导出旧版最近阅读")
        recent.save(in:defaults)
        pass(RecentReading.load(scope:"device/library",in:defaults)==recent,"最近阅读持久化原页码与列表位置")
        pass(RecentReading.load(scope:"other/library",in:defaults)==nil,"不同设备不能恢复同 ID 的最近阅读")
        pass(RecentReading.load(scope:"device/other",in:defaults)==nil,"不同下载目录隔离最近阅读")
        let replacement=RecentReading(scope:"device/library",book:Book(id:"456",title:"下一本",rank:20),pageNumber:1,position:0,pageCount:1)
        replacement.save(in:defaults)
        pass(RecentReading.load(scope:"device/library",in:defaults)==replacement,"只保留最近一本，不积累历史列表")
        pass(!RecentReading(scope:"x",book:Book(id:"../1",title:"bad",rank:0),pageNumber:1,position:0,pageCount:1).valid,"最近阅读拒绝非法漫画 ID")
        pass(!RecentReading(scope:"x",book:Book(id:"1",title:"bad",rank:0),pageNumber:0,position:0,pageCount:1).valid,"最近阅读拒绝无效原页码")
        pass(!RecentReading(scope:"x",book:Book(id:"1",title:"bad",rank:0),pageNumber:1,position:3,pageCount:3).valid,"最近阅读位置必须落在页序内")
        pass(!RecentReading(scope:"x",book:Book(id:"1",title:String(repeating:"a",count:16385),rank:0),pageNumber:1,position:0,pageCount:1).valid,"最近阅读元数据有界")
        defaults.set(Data("broken".utf8),forKey:RecentReading.key)
        pass(RecentReading.load(scope:"device/library",in:defaults)==replacement,"按书库保存的记录不受旧兼容键损坏影响")
        defaults.set(Data("broken".utf8),forKey:RecentReading.key+"."+ReadingProgress.hash("device/library"))
        pass(RecentReading.load(scope:"device/library",in:defaults)==nil,"损坏最近阅读安全忽略")
        recent.save(in:defaults);_ = ReadingProgress.reset(in:defaults)
        pass(RecentReading.load(scope:"device/library",in:defaults)==nil,"重置所有进度也清除继续阅读")
        pass(defaults.string(forKey:"pairing")=="keep","清除继续阅读保留配对")
        defaults.set(9,forKey:"page.123")
        ReadingProgress.register(scope:"nas/library",server:.nas,in:defaults)
        pass(ReadingProgress.page(scope:"nas/library",id:"123",in:defaults)==0,"NAS 不自动认领旧安卓进度")
        ReadingProgress.register(scope:"android/library",server:.android,in:defaults)
        pass(ReadingProgress.page(scope:"android/library",id:"123",in:defaults)==9,"首次安卓书库兼容旧进度")
        ReadingProgress.register(scope:"android/other",server:.android,in:defaults)
        pass(ReadingProgress.page(scope:"android/other",id:"123",in:defaults)==0,"其他安卓书库不认领旧进度")
        ReadingProgress.save(17,scope:"nas/library",id:"123",in:defaults)
        pass(ReadingProgress.page(scope:"android/library",id:"123",in:defaults)==9,"同漫画 ID 的两服务器进度隔离")
        let androidRecent=RecentReading(scope:"android/library",book:Book(id:"123",title:"Synthetic Android",rank:0),pageNumber:9,position:8,pageCount:20)
        let nasRecent=RecentReading(scope:"nas/library",book:Book(id:"123",title:"Synthetic NAS",rank:1),pageNumber:17,position:16,pageCount:20)
        androidRecent.save(in:defaults);nasRecent.save(in:defaults)
        pass(RecentReading.load(scope:"android/library",in:defaults)==androidRecent,"切换书库保留双方继续阅读")
        let archive=try ProgressBackup.decode(ProgressBackup.capture(in:defaults).data())
        let json=String(decoding:try archive.data(),as:UTF8.self)
        pass(!json.contains("pairing") && !json.contains("pageSize") && !json.contains("token"),"导出仅包含白名单阅读元数据")
        _ = ReadingProgress.reset(in:defaults)
        ReadingProgress.save(19,scope:"nas/library",id:"123",in:defaults)
        _ = archive.restore(in:defaults)
        pass(ReadingProgress.page(scope:"nas/library",id:"123",in:defaults)==19,"恢复备份不覆盖目标已有页码")
        pass(ReadingProgress.page(scope:"android/library",id:"123",in:defaults)==9,"恢复备份补充缺失阅读位置")
        pass(RecentReading.load(scope:"android/library",in:defaults)==androidRecent,"恢复双方最近阅读")
        rejects("拒绝损坏阅读备份"){_ = try ProgressBackup.decode(Data("broken".utf8))}
        rejects("拒绝不支持备份版本"){_ = try ProgressBackup(version:2,libraries:[],legacy:[:]).data()}
        rejects("拒绝备份非法漫画 ID"){_ = try ProgressBackup(version:1,libraries:[],legacy:["../1":1]).data()}
        rejects("拒绝超大备份"){_ = try ProgressBackup.decode(Data(count:8*1024*1024+1))}
        pass(ReaderService(app:"localshelf-reader",version:1,serverKind:"nas",capabilities:["reader-v1","pair-v2","locate-v1"]).compatible,"NAS 阅读服务能力验证")
        pass(!ReaderService(app:"localshelf-sync",version:1,serverKind:"nas",capabilities:[]).compatible,"备份接收端不被误认作阅读服务")
        func locatorPage(_ page:Int,_ size:Int,_ changed:Bool=false)->BookList{
            let books=(page*size..<max(page*size,min(1200,(page+1)*size))).map{Book(id:String($0+1),title:"test",rank:$0*2)}
            return BookList(orderVerified:true,total:1200,books:books,catalogRevision:String(repeating:changed ? "b":"a",count:64),libraryId:String(repeating:"c",count:64))
        }
        var locateCalls=0
        let located=try await CatalogLocator.find(id:"701",rankHint:1400){page,size in locateCalls+=1;return locatorPage(page,size)}
        pass(located?.offset==700 && located?.book.id=="701","定位按 ID 与实际偏移，不把有间隔的 rank 当作位置")
        pass(locateCalls==3,"旧位置失效时逐批查询元数据")
        pass(located!.offset/50==14 && located!.offset/500==1,"定位适配当前每页 50 或 500 本")
        let absent=try await CatalogLocator.find(id:"9999",rankHint:0){page,size in locatorPage(page,size)}
        pass(absent==nil,"漫画已不在清单时不猜测邻近漫画")
        do{
            _ = try await CatalogLocator.find(id:"701",rankHint:0){page,size in locatorPage(page,size,page>0)}
            fatalError("changed snapshot accepted")
        }catch{pass(true,"定位期间清单版本变化则中止")}
        let cancelled=Task{try await CatalogLocator.find(id:"701",rankHint:0){page,size in locatorPage(page,size)}}
        cancelled.cancel()
        do{_ = try await cancelled.value;fatalError("cancel ignored")}catch{pass(error is CancellationError,"用户取消中断定位")}
        pass(CoverRules.diskBudget==2_000_000_000,"磁盘封面上限为 2 GB，不分配正文缓存")
        let coverKey=CoverRules.key(scope:"device/catalog",path:"/v1/books/1/cover")
        pass(coverKey?.count==64 && coverKey==CoverRules.key(scope:"device/catalog",path:"/v1/books/1/cover"),"同一设备书库封面键稳定")
        pass(coverKey != CoverRules.key(scope:"device/changed",path:"/v1/books/1/cover") && coverKey != CoverRules.key(scope:"other/catalog",path:"/v1/books/1/cover"),"不同设备和书库版本隔离")
        pass(CoverRules.key(scope:"scope",path:"/v1/books/1/pages/1")==nil && CoverRules.key(scope:"scope",path:"../cover")==nil,"正文及路径穿越不进入磁盘缓存")
        pass(CoverRules.prefetch(anchor:0,count:100,screen:6,direction:1)==Array(6..<12),"向下只预取下一屏")
        pass(CoverRules.prefetch(anchor:20,count:100,screen:6,direction:-1)==[19,18,17,16,15,14],"向上预取前一屏并按距离排序")
        pass(CoverRules.prefetch(anchor:98,count:100,screen:6,direction:1).isEmpty && CoverRules.prefetch(anchor:0,count:0,screen:6,direction:1).isEmpty,"预取不越过分页末尾或空列表")
        pass(CoverRules.prefetch(anchor:0,count:100,screen:100,direction:1).count==18,"预取窗口有硬上限")
        rejects("拒绝无效书库缓存版本"){try LibraryRules.validate(BookList(orderVerified:true,total:0,books:[],catalogRevision:"bad"))}
        rejects("拒绝无效稳定书库身份"){try LibraryRules.validate(BookList(orderVerified:true,total:0,books:[],libraryId:"bad"))}
        rejects("拒绝无效单本封面身份"){try LibraryRules.validate(BookList(orderVerified:true,total:1,books:[Book(id:"1",title:"test",rank:0,coverIdentity:"bad")]))}
        let stable=String(repeating:"a",count:64)
        try LibraryRules.validate(BookList(orderVerified:true,total:1,books:[Book(id:"1",title:"test",rank:0,coverIdentity:stable)],libraryId:stable))
        pass(true,"兼容稳定书库和单本身份，不改变原始 rank")
        pass(PagingRules.edgeReturns(x:100,y:5,velocityX:100,width:390),"左边缘足够距离右滑返回")
        pass(PagingRules.edgeReturns(x:40,y:5,velocityX:1000,width:390),"左边缘快速右滑返回")
        pass(!PagingRules.edgeReturns(x:15,y:0,velocityX:1500,width:390),"极短边缘滑动不误退")
        pass(!PagingRules.edgeReturns(x:0,y:150,velocityX:0,width:390),"下滑不再返回")
        pass(!PagingRules.edgeReturns(x:0,y:-150,velocityX:0,width:390),"上滑不返回")
        pass(!PagingRules.edgeReturns(x:-150,y:0,velocityX:-1000,width:390),"向左滑不返回")
        pass(!PagingRules.edgeReturns(x:100,y:100,velocityX:1000,width:390),"斜向手势不误退")
        pass(PagingRules.edgeStart(x:48,width:390) && !PagingRules.edgeStart(x:49,width:390),"左侧 48 点为返回热区，中间区域不抢翻页")
        pass(!PagingRules.edgeStart(x:-1,width:390) && !PagingRules.edgeStart(x:.nan,width:390),"异常返回起点无效")
        pass(PagingRules.edgeReturns(x:44,y:4,velocityX:0,width:390),"慢拖 44 点即可返回")
        pass(PagingRules.edgeReturns(x:24,y:3,velocityX:650,width:390),"快速短甩通过位移加速度预测返回")
        pass(!PagingRules.edgeReturns(x:28,y:1,velocityX:0,width:390),"短慢拖不误退")
        pass(!PagingRules.edgeReturns(x:90,y:1,velocityX:-400,width:390),"松手反向收回取消返回")
        pass(!PagingRules.edgeReturns(x:60,y:1,velocityX:.infinity,width:390),"异常返回速度不通过")
        pass(PagingRules.sliderIndex(position:50,length:100,count:101)==50,"点击轨道中点定位中间页")
        pass(PagingRules.sliderIndex(position:-10,length:100,count:101)==0,"滑块左上越界钳制首项")
        pass(PagingRules.sliderIndex(position:110,length:100,count:101)==100,"滑块右下越界钳制末项")
        pass(PagingRules.sliderIndex(position:50,length:0,count:100)==0 && PagingRules.sliderIndex(position:.nan,length:100,count:100)==0,"零长度和无效坐标安全返回")
        pass(PagingRules.sliderIndex(position:50,length:100,count:1)==0,"单页滑块不越界")
        for count in [50,500,71,21]{
            pass(PagingRules.sliderIndex(position:100,length:100,count:count)==count-1,"本页 \(count) 本滑块末端只映射本页末项")
            pass(PagingRules.sliderIndex(position:0,length:100,count:count)==0,"本页 \(count) 本滑块始端映射本页首项")
        }
        pass(PagingRules.sliderIndex(position:100,length:100,count:0)==0,"空书库滑块安全返回")
        var transfer=TransferBuffer(limit:5)
        try transfer.append(Data([1,2]));try transfer.append(Data([3,4,5]))
        pass(transfer.data.count==5,"分块下载允许恰好达到限额")
        rejects("未知长度响应超限立即拒绝"){try transfer.append(Data([6]))}
        pass(transfer.data.count==5,"超限数据不加入缓冲")
        pass(transfer.acceptsLength(-1) && transfer.acceptsLength(5) && !transfer.acceptsLength(6),"响应头已知和未知长度校验")
        let keep=ReadingBudget.keep(costs:[1:10,2:8,3:8],priority:[1,2,3],available:18)
        pass(keep==Set([1,2]),"阅读内存优先当前页与近邻")
        pass(ReadingBudget.keep(costs:[1:10],priority:[1],available:0).isEmpty,"无预算不保留缓存")
        pass(ReadingBudget.keep(costs:[1:10],priority:[1,1],available:20)==Set([1]),"预算不重复保留同页")
        pass(ReadingBudget.normal+32*1024*1024==96*1024*1024 && ReadingBudget.compressed<ReadingBudget.pressure,"阅读与封面缓存预算分区")
        var covers=CostLRU<String,String>(budget:10,countLimit:2)
        covers.insert("A",for:"a",cost:4);covers.insert("B",for:"b",cost:4)
        pass(covers.value(for:"a")=="A","封面缓存命中并更新最近使用")
        covers.insert("C",for:"c",cost:4)
        pass(covers.value(for:"b")==nil && covers.cost==8,"淘汰最久未用封面")
        covers.insert("D",for:"d",cost:9)
        pass(covers.cost==9 && covers.value(for:"a")==nil,"按实际解码成本限额")
        covers.insert("TOO BIG",for:"huge",cost:11)
        pass(covers.cost==9 && covers.value(for:"huge")==nil,"超过预算的图片不进入缓存")
        covers.insert("replacement",for:"d",cost:2)
        pass(covers.cost==2,"替换封面不会重复计费")
        covers.removeAll();pass(covers.cost==0 && covers.value(for:"d")==nil,"清理书库/内存警告清除缓存")
        pass(PagingRules.tapStep(fraction:0.1)==0,"左侧轻点不翻页")
        pass(PagingRules.tapStep(fraction:0.5)==0,"中央轻点切换工具栏")
        pass(PagingRules.tapStep(fraction:0.9)==0,"右侧轻点不翻页")
        pass(PagingRules.tapStep(fraction:0.3)==0 && PagingRules.tapStep(fraction:0.7)==0,"点击分区边界属于中央")
        pass(PagingRules.detailPixelLimit(width:1200,height:1800)==1800,"高清不放大小尺寸源图")
        pass(PagingRules.detailPixelLimit(width:6000,height:9000)==4096,"高清最长边限制")
        let square=PagingRules.detailPixelLimit(width:10000,height:10000)
        pass(square*square<=12_000_000,"方图解码像素预算")
        pass(PagingRules.detailPixelLimit(width:0,height:100)==2048,"异常图尺寸安全退回预览限制")
        pass(PagingRules.swipeStep(x:-60,y:5,width:390)==1,"横向左拖进入下一页")
        pass(PagingRules.swipeStep(x:60,y:5,width:390)==(-1),"横向右拖返回上一页")
        pass(PagingRules.swipeStep(x:15,y:0,width:390)==0,"短距离拖动回弹")
        pass(PagingRules.swipeStep(x:50,y:60,width:390)==0,"纵向拖动不翻页")
        pass(PagingRules.swipeStep(x:60,y:0,width:0)==0,"无效尺寸不翻页")
        pass(PagingRules.swipeStep(x:-20,y:1,width:390,velocityX:-1000)==1,"快速短甩向下一页")
        pass(PagingRules.swipeStep(x:20,y:1,width:390,velocityX:1000)==(-1),"快速短甩向上一页")
        pass(PagingRules.swipeStep(x:20,y:1,width:390,velocityX:200)==0,"慢速短拖仍然回弹")
        pass(PagingRules.swipeStep(x:5,y:0,width:390,velocityX:2000)==0,"极短抖动不触发快速翻页")
        pass(PagingRules.swipeStep(x:-120,y:0,width:390,velocityX:1000)==0,"松手前明确反向则收回当前页")
        pass(PagingRules.swipeStep(x:120,y:0,width:390,velocityX:-1000)==0,"反向收回不跨过当前页误跳")
        pass(PagingRules.swipeStep(x:20,y:40,width:390,velocityX:2000)==0,"纵向快速滑动不翻页")
        pass(PagingRules.swipeStep(x:.nan,y:0,width:390,velocityX:1000)==0 && PagingRules.swipeStep(x:20,y:0,width:390,velocityX:.infinity)==0,"异常速度或位移安全忽略")
        pass(PagingRules.prefetchIndices(current:4,count:10)==[4,5,3,6,2],"第 5 张预取第 3–7 张，优先当前和相邻")
        pass(PagingRules.prefetchIndices(current:0,count:10)==[0,1,2],"首页预取不越界")
        pass(PagingRules.prefetchIndices(current:9,count:10)==[9,8,7],"末页预取不越界")
        pass(PagingRules.prefetchIndices(current:0,count:0).isEmpty,"空页序不预取")
        pass(PagingRules.prefetchIndices(current:0,count:1)==[0],"单页不重复请求")
        pass(PagingRules.count(total:12071,size:50)==242,"50 本分页及尾页")
        pass(PagingRules.count(total:12071,size:500)==25,"500 本分页及尾页")
        pass(PagingRules.count(total:0,size:100)==1,"空书库分页边界")
        pass(PagingRules.index(-1,count:3)==0 && PagingRules.index(99,count:3)==2,"阅读滑块上下界")
        let qr="{\"app\":\"localshelf\",\"version\":1,\"address\":\"http://192.168.240.2:8088\",\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\"}"
        pass(try PairingCode.parse(qr).address == "http://192.168.240.2:8088","配对码解析地址和口令")
        rejects("拒绝公网配对码"){_=try PairingCode.parse(qr.replacingOccurrences(of:"192.168.240.2",with:"8.8.8.8"))}
        rejects("拒绝非本应用二维码"){_=try PairingCode.parse(qr.replacingOccurrences(of:"localshelf",with:"other"))}
        rejects("拒绝不支持的配对协议"){_=try PairingCode.parse(qr.replacingOccurrences(of:"\"version\":1",with:"\"version\":3"))}
        let v2=qr.replacingOccurrences(of:"\"version\":1",with:"\"version\":2,\"deviceId\":\"0123456789abcdef0123456789abcdef\"")
        let paired=try PairingCode.parse(v2),nonce=String(repeating:"0",count:64)
        pass(paired.version==2 && paired.deviceId != nil,"新版配对包含设备身份")
        rejects("新版配对拒绝缺失设备身份"){_=try PairingCode.parse(qr.replacingOccurrences(of:"\"version\":1",with:"\"version\":2"))}
        rejects("拒绝无效设备身份"){_=try PairingCode.parse(v2.replacingOccurrences(of:"0123456789abcdef0123456789abcdef",with:"untrusted"))}
        let proof=IdentityProof(deviceId:paired.deviceId!,proof:"4158f25901741dac27207668651dbf5cea7a26608c06f30291ea1d642bb569a6")
        pass(PairingProof.verify(proof,code:paired,nonce:nonce),"Android/Swift HMAC 与独立 OpenSSL 向量一致")
        pass(!PairingProof.verify(proof,code:paired,nonce:String(repeating:"1",count:64)),"拒绝重放旧挑战证明")
        pass(!PairingProof.verify(IdentityProof(deviceId:String(repeating:"f",count:32),proof:proof.proof),code:paired,nonce:nonce),"拒绝另一台设备身份")
        pass(!PairingProof.verify(IdentityProof(deviceId:paired.deviceId!,proof:String(repeating:"0",count:64)),code:paired,nonce:nonce),"拒绝伪造服务器证明")
        rejects("拒绝超长扫码内容"){_=try PairingCode.parse(String(repeating:"a",count:2049))}
        let good=BookList(orderVerified:true,total:2,books:[Book(id:"2",title:"合成 B",rank:0),Book(id:"1",title:"合成 A",rank:1)])
        try LibraryRules.validate(good);pass(good.books.first?.id=="2","原清单顺序不按 gid 或标题重排")
        rejects("拒绝未确认书库顺序"){try LibraryRules.validate(BookList(orderVerified:false,total:0,books:[]))}
        let snapshot=try JSONDecoder().decode(BookList.self,from:Data("{\"orderVerified\":false,\"orderPolicy\":\"snapshot-query\",\"total\":0,\"books\":[]}".utf8))
        try LibraryRules.validate(snapshot);pass(snapshot.orderPolicy=="snapshot-query","接受明确标注的备份查询顺序且保留未验证标记")
        let missing=try JSONDecoder().decode(BookList.self,from:Data("{\"orderVerified\":false,\"orderPolicy\":\"snapshot-query\",\"total\":3,\"books\":[{\"id\":\"1\",\"title\":\"a\",\"rank\":0,\"available\":true},{\"id\":\"2\",\"title\":\"b\",\"rank\":1,\"available\":false},{\"id\":\"3\",\"title\":\"c\",\"rank\":2,\"available\":true}]}".utf8))
        try LibraryRules.validate(missing);pass(missing.books.count==3 && missing.books[1].isMissing && !missing.books[2].isMissing && missing.books[2].rank==2,"缺失项保留位置且后续记录可用")
        rejects("拒绝重复排名"){try LibraryRules.validate(BookList(orderVerified:true,total:2,books:[Book(id:"1",title:"a",rank:0),Book(id:"2",title:"b",rank:0)]))}
        rejects("拒绝路径型 id"){try LibraryRules.validate(BookList(orderVerified:true,total:1,books:[Book(id:"../x",title:"a",rank:0)]))}
        try LibraryRules.validate(Pages(pages:[Page(number:1),Page(number:3),Page(number:10)]));pass(true,"缺页保留原编号")
        rejects("拒绝词典序页码"){try LibraryRules.validate(Pages(pages:[Page(number:1),Page(number:10),Page(number:2)]))}
        rejects("拒绝重复页码"){try LibraryRules.validate(Pages(pages:[Page(number:1),Page(number:1)]))}
        _=try LibraryRules.address("http://192.168.240.2:8088");pass(true,"接受私人局域网地址")
        for s in ["http://example.com","http://8.8.8.8","http://192.168.240.2.evil.test","http://a:b@192.168.240.2","http://192.168.240.2/?key=a"]{rejects("拒绝非预期地址"){_=try LibraryRules.address(s)}}
        var catalog=CatalogPageCache()
        let time=Date(timeIntervalSince1970:1000),rev=String(repeating:"a",count:64),root=String(repeating:"b",count:64)
        func list(_ page:Int,_ size:Int=50,_ revision:String=rev,_ title:String="fixture")->BookList {
            BookList(orderVerified:false,total:20000,books:(page*size..<page*size+size).map{Book(id:String($0+1),title:title,rank:$0)},orderPolicy:"snapshot-query",catalogRevision:revision,libraryId:root)
        }
        try catalog.store(list(0),page:0,size:50,owner:"device-A",now:time)
        pass(catalog.value(page:0,size:50,now:time)?.books.first?.id=="1","分页缓存保留源顺序")
        pass(catalog.value(page:0,size:100,now:time)==nil,"每页数量隔离缓存")
        pass(catalog.value(page:0,size:50,now:time.addingTimeInterval(59)) != nil,"校验后 60 秒内复用分页")
        pass(catalog.value(page:0,size:50,now:time.addingTimeInterval(60))==nil,"命中不延长网络快照有效期")
        pass(catalog.value(page:0,size:50,now:time.addingTimeInterval(-1))==nil,"时钟回拨不复用分页")
        try catalog.store(list(1),page:1,size:50,owner:"device-A",now:time)
        pass(catalog.value(page:0,size:50,now:time) != nil,"相同版本的不同页可以同时缓存")
        try catalog.store(list(2,50,String(repeating:"c",count:64)),page:2,size:50,owner:"device-A",now:time)
        pass(catalog.value(page:1,size:50,now:time)==nil,"清单版本改变清除旧页")
        try catalog.store(list(0),page:0,size:50,owner:"device-B",now:time)
        pass(catalog.value(page:2,size:50,now:time)==nil,"不同设备不混用列表")
        var changedRoot=list(1);changedRoot.libraryId=String(repeating:"d",count:64)
        try catalog.store(changedRoot,page:1,size:50,owner:"device-B",now:time)
        pass(catalog.value(page:0,size:50,now:time)==nil,"不同下载根不混用列表")
        var legacy=list(0);legacy.catalogRevision=nil
        pass(try !catalog.store(legacy,page:0,size:50,owner:"device-A",now:time),"无版本的旧服务不启用分页缓存")
        pass(catalog.cost==0,"旧服务响应清掉先前缓存")
        pass(try !catalog.store(list(0),page:0,size:50,owner:nil,now:time),"临时未验证身份不复用分页")
        rejects("分页缺项不进入缓存"){try catalog.store(BookList(orderVerified:true,total:300,books:[]),page:0,size:50,owner:"device-A")}
        rejects("非法分页大小不进入缓存"){try catalog.store(list(0),page:0,size:51,owner:"device-A")}
        for page in 0..<24{try catalog.store(list(page,500,rev,String(repeating:"图",count:400)),page:page,size:500,owner:"device-A",now:time)}
        pass(catalog.cost<=4*1024*1024 && catalog.value(page:0,size:500,now:time)==nil,"列表 LRU 按保守字符串成本执行 4 MiB 上限")
        pass(catalog.value(page:23,size:500,now:time)?.books.first?.id=="11501","淘汰后最近分页仍可用且未重排")
        catalog.clear();pass(catalog.cost==0 && catalog.value(page:23,size:500,now:time)==nil,"清理与内存告警释放所有分页引用")
        var pageLists=PageListCache();let pageValue=try PageListCache.validated(Pages(pages:[Page(number:1),Page(number:3),Page(number:10)]))
        pass(!pageLists.store(pageValue,book:"1",now:time),"页码清单未绑定书库时不缓存")
        pageLists.configure("device/root/revision")
        pass(pageLists.store(pageValue,book:"1",now:time),"已绑定书库缓存页码清单")
        pass(pageLists.value("1",now:time)?.pages.map(\.number)==[1,3,10],"页码缓存保留数字缺页")
        pass(pageLists.value("2",now:time)==nil,"不同漫画页码不混用")
        pass(pageLists.value("1",now:time.addingTimeInterval(14)) != nil,"页码清单 15 秒内命中")
        pass(pageLists.value("1",now:time.addingTimeInterval(15))==nil,"页码缓存命中不延长有效期")
        pageLists.store(pageValue,book:"1",now:time)
        pass(pageLists.value("1",now:time.addingTimeInterval(-1))==nil,"时钟回拨不复用页码清单")
        pass(try !pageLists.store(PageListCache.validated(Pages(pages:[])),book:"1",now:time),"空页序不缓存以免阻碍新下载")
        pageLists.store(pageValue,book:"1",now:time);pageLists.configure("device/new-root/revision")
        pass(pageLists.value("1",now:time)==nil,"书库身份变化隔离页码清单")
        pageLists.store(pageValue,book:"1",now:time);pageLists.invalidate("1")
        pass(pageLists.value("1",now:time)==nil,"单本刷新或读取失败失效")
        for i in 0..<17{pageLists.store(pageValue,book:String(i),now:time)}
        pass(pageLists.value("0",now:time)==nil && pageLists.value("16",now:time) != nil,"页码缓存最多保留 16 本")
        let large=try PageListCache.validated(Pages(pages:(1...20000).map{Page(number:$0)}))
        for i in 0..<16{pageLists.store(large,book:String(i),now:time)}
        pass(pageLists.cost<=1024*1024 && pageLists.value("0",now:time)==nil,"页码缓存按计费执行 1 MiB 上限")
        pass(try !pageLists.store(PageListCache.validated(Pages(pages:(1...20001).map{Page(number:$0)})),book:"huge",now:time),"超两万页可解析但不常驻缓存")
        pageLists.clear();pass(pageLists.cost==0,"内存清理释放页码缓存")
        rejects("页码缓存拒绝重复页"){_=try PageListCache.validated(Pages(pages:[Page(number:1),Page(number:1)]))}
        pass(try PairingPIN.body("001234")==Data("001234".utf8),"配对码保留前导零")
        for bad in ["12345","1234567","１２３４５６","12345a","123 45",""]{rejects("拒绝非六位 ASCII 配对码"){_=try PairingPIN.body(bad)}}
        let pinReply=Data("{\"app\":\"localshelf\",\"version\":2,\"deviceId\":\"0123456789abcdef0123456789abcdef\",\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\"}".utf8)
        pass(try PairingPIN.response(pinReply,address:"http://192.168.240.2:8088").version==2,"配对码响应转换为强随机凭据")
        rejects("配对码响应拒绝公网地址"){_=try PairingPIN.response(pinReply,address:"https://example.com")}
        rejects("配对码响应拒绝超限数据"){_=try PairingPIN.response(Data(repeating:0,count:2049),address:"http://192.168.240.2:8088")}
        print("\(count) protocol checks passed")
    }
}
