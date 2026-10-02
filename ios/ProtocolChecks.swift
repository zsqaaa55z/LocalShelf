import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var count=0
        func pass(_ condition:Bool,_ name:String){precondition(condition,name);count+=1;print("PASS \(name)")}
        func rejects(_ name:String,_ run:()throws->Void){do{try run();fatalError(name)}catch{count+=1;print("PASS \(name)")}}
        pass(ShelfSource.manual.path("/v1/books?offset=0&limit=100",target:.nas)=="/manual/v1/books?offset=0&limit=100","手动书库目录独立路由")
        pass(ShelfSource.eh.path("/v1/books/1/pages/2",target:.nas)=="/v1/books/1/pages/2","Eh 路由完全不变")
        pass(ShelfSource.manual.path("/v2/identity?nonce=test",target:.nas)=="/v2/identity?nonce=test","配对仍属于服务器，不切换凭据")
        pass(ShelfSource.manual.path("/v1/books/1/cover?width=480",target:.android)=="/v1/books/1/cover?width=480","安卓桥接不受手动选择影响")
        let manualList=BookList(orderVerified:true,total:0,books:[],orderPolicy:ShelfSource.manualPolicy)
        try LibraryRules.validate(manualList)
        pass(ShelfSource.manual.accepts(manualList) && !ShelfSource.eh.accepts(manualList),"手动空书库可读，禁止当作 Eh 目录")
        let ehList=BookList(orderVerified:true,total:0,books:[],orderPolicy:"ehviewer-downloads-time-desc")
        pass(ShelfSource.eh.accepts(ehList) && !ShelfSource.manual.accepts(ehList),"禁止 Eh 目录串入手动书库")
        pass(CoverRules.key(scope:"server\neh",path:"/v1/books/1/cover") != CoverRules.key(scope:"server\nmanual",path:"/v1/books/1/cover"),"相同漫画编号封面缓存不串库")
        pass(ReadingProgress.key(scope:"server\neh",id:"1") != ReadingProgress.key(scope:"server\nmanual",id:"1"),"相同漫画编号阅读进度不串库")
        let oldBook=try JSONDecoder().decode(Book.self,from:Data(#"{"id":"1","title":"Legacy","rank":0}"#.utf8))
        pass(oldBook.pageCount==nil && oldBook.pageCountLabel==nil,"旧服务及旧书库快照无页数字段仍可读取")
        var counted=oldBook;counted.pageCount=128
        pass(counted.pageCountLabel=="128","封面页数只显示数字，不附加页字")
        pass(try JSONDecoder().decode(Book.self,from:JSONEncoder().encode(counted))==counted,"页数可随原书库缓存持久化")
        pass(counted != oldBook,"只有页数改变也能触发书库元数据更新")
        for pages in [0,1,1024,20000] {
            counted.pageCount=pages
            try LibraryRules.validate(BookList(orderVerified:true,total:1,books:[counted]))
            pass(counted.pageCountLabel==(pages==0 ? nil:String(pages)),"有效页数及零页状态 \(pages)")
        }
        for pages in [-1,20001] {
            counted.pageCount=pages
            rejects("拒绝非法封面页数 \(pages)"){try LibraryRules.validate(BookList(orderVerified:true,total:1,books:[counted]))}
        }
        counted.pageCount=128;counted.available=false
        pass(counted.pageCountLabel==nil,"缺失漫画不显示过期页数")
        let windowLibrary=String(repeating:"a",count:64)
        let relatedChoice=RelatedChoice(id:windowLibrary,name:"Demo",matchKind:"artist",count:1)
        let relatedOptions=RelatedOptions(bookID:"1",kind:.authors,libraryId:windowLibrary,catalogRevision:windowLibrary,options:[relatedChoice])
        try relatedOptions.validate(book:"1",kind:.authors,library:windowLibrary);pass(true,"作者候选身份与有界结果校验")
        rejects("拒绝跨类型结果"){try relatedOptions.validate(book:"1",kind:.series,library:windowLibrary)}
        rejects("拒绝跨漫画候选"){try relatedOptions.validate(book:"2",kind:.authors,library:windowLibrary)}
        rejects("拒绝跨书库作者候选"){try relatedOptions.validate(book:"1",kind:.authors,library:String(repeating:"b",count:64))}
        rejects("拒绝重复候选"){try RelatedOptions(bookID:"1",kind:.authors,libraryId:windowLibrary,catalogRevision:windowLibrary,options:[relatedChoice,relatedChoice]).validate(book:"1",kind:.authors,library:windowLibrary)}
        rejects("拒绝控制字符姓名"){try RelatedChoice(id:windowLibrary,name:"Demo\nInjected",matchKind:"artist",count:1).validate(kind:.authors)}
        rejects("拒绝超量候选计数"){try RelatedChoice(id:windowLibrary,name:"Demo",matchKind:"artist",count:20001).validate(kind:.authors)}
        let relatedList=BookList(orderVerified:true,total:1,books:[Book(id:"1",title:"Synthetic",rank:8000)],catalogRevision:windowLibrary,libraryId:windowLibrary)
        let relatedResult=RelatedResult(bookID:"1",kind:.authors,option:relatedChoice,offset:0,catalog:relatedList)
        try relatedResult.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
        pass(true,"筛选结果保留全库原 rank，无需改成局部位置")
        rejects("拒绝错误作者身份"){try relatedResult.validate(book:"1",kind:.authors,choice:String(repeating:"b",count:64),size:50,requestedOffset:0,library:windowLibrary)}
        rejects("拒绝非法筛选页大小"){try relatedResult.validate(book:"1",kind:.authors,choice:windowLibrary,size:51,requestedOffset:0,library:windowLibrary)}
        var candidateChoice=RelatedChoice(id:windowLibrary,name:"Demo",matchKind:"name",count:2,possibleCount:1)
        let candidateList=BookList(orderVerified:true,total:2,books:[Book(id:"1",title:"Demo",rank:0),Book(id:"2",title:"Variant",rank:9)],catalogRevision:windowLibrary,libraryId:windowLibrary)
        let candidateResult=RelatedResult(bookID:"1",kind:.authors,option:candidateChoice,offset:0,catalog:candidateList,possibleBookIDs:["2"])
        try candidateResult.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
        pass(true,"弱匹配有独立数量及当页证据，保留原 rank")
        for ids in [["1"],["3"],["2","2"],[]] {
            var invalid=candidateResult;invalid.possibleBookIDs=ids
            rejects("拒绝非法候选页证据 \(ids)"){try invalid.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)}
        }
        var missingEvidence=candidateResult;missingEvidence.possibleBookIDs=nil
        rejects("新协议不能遗漏证据字段"){try missingEvidence.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)}
        for count in [-1,2,20001] {
            candidateChoice.possibleCount=count
            rejects("拒绝非法弱匹配总数 \(count)"){try candidateChoice.validate(kind:.authors)}
        }
        let seriesChoice=RelatedChoice(id:windowLibrary,name:"Night",matchKind:"series",count:1)
        let annotated=RelatedResult(bookID:"1",kind:.series,option:seriesChoice,offset:0,catalog:relatedList,partLabels:["1":"第2巻"])
        try annotated.validate(book:"1",kind:.series,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
        pass(true,"分卷标签只随当前系列页返回")
        for parts in [["3":"第2巻"],["1":""],["1":"Injected\nText"]] {
            var invalid=annotated;invalid.partLabels=parts
            rejects("拒绝越页或无效卷篇标签"){try invalid.validate(book:"1",kind:.series,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)}
        }
        let v3Choice=RelatedChoice(id:windowLibrary,name:"Night",matchKind:"series",count:2,possibleCount:2,evidenceVersion:3)
        let v3Result=RelatedResult(bookID:"1",kind:.series,option:v3Choice,offset:0,catalog:candidateList,possibleBookIDs:["1","2"],partLabels:["2":"番外"],matchNotes:["1":.seriesSubtitle,"2":.seriesSubtitle])
        try v3Result.validate(book:"1",kind:.series,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
        pass(true,"v3 系列允许全组待确认，但每本必须有当页原因")
        for notes:[String:RelatedMatchNote]? in [nil,[:],["1":.seriesTitle],["1":.circle,"2":.seriesTitle],["1":.edition,"3":.edition]] {
            var invalid=v3Result;invalid.matchNotes=notes
            rejects("拒绝缺失越页或跨类别原因"){try invalid.validate(book:"1",kind:.series,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)}
        }
        var circleResult=RelatedResult(bookID:"1",kind:.authors,option:RelatedChoice(id:windowLibrary,name:"Alice",matchKind:"name",count:2,possibleCount:1,evidenceVersion:3),offset:0,catalog:candidateList,possibleBookIDs:["1"],matchNotes:["1":.circle])
        try circleResult.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
        pass(true,"社团来源本可以是候选，但不能伪装成确定作者")
        circleResult.matchNotes=["1":.creditName]
        try circleResult.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
        pass(true,"署名兜底来源本保留待确认原因")
        for note in [RelatedMatchNote.workCredit,.nameVariant]{
            var other=circleResult;other.possibleBookIDs=["2"];other.matchNotes=["2":note]
            try other.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
            pass(true,"其他作品可以携带同作署名或写法候选")
        }
        for note in [RelatedMatchNote.authorSeries,.seriesVariant]{
            var relaxed=v3Result;relaxed.matchNotes=["1":note,"2":note]
            try relaxed.validate(book:"1",kind:.series,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)
            pass(true,"联合和宽松系列保留完整证据")
        }
        circleResult.matchNotes=["1":.nameVariant]
        rejects("作者来源本不允许冒充拼写候选"){try circleResult.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)}
        for version in [0,2,4]{rejects("拒绝未支持的证据版本"){try RelatedChoice(id:windowLibrary,name:"Demo",matchKind:"series",count:1,possibleCount:0,evidenceVersion:version).validate(kind:.series)}}
        rejects("v3 不允许遗漏候选总数"){try RelatedChoice(id:windowLibrary,name:"Demo",matchKind:"series",count:1,evidenceVersion:3).validate(kind:.series)}
        var unexpectedNotes=relatedResult;unexpectedNotes.matchNotes=[:]
        rejects("旧协议不能夹带无版本证据"){try unexpectedNotes.validate(book:"1",kind:.authors,choice:windowLibrary,size:50,requestedOffset:0,library:windowLibrary)}
        for kind in RelatedKind.allCases{for note in [RelatedMatchNote.nameVariant,.circle,.creditName,.workCredit,.seriesTitle,.seriesSubtitle,.seriesVariant,.authorSeries,.directory,.edition]{
            pass(note.valid(for:kind)==(kind == .authors ? [RelatedMatchNote.nameVariant,.circle,.creditName,.workCredit].contains(note):![RelatedMatchNote.nameVariant,.circle,.creditName,.workCredit].contains(note)),"证据原因按作者和系列隔离")
        }}
        let windowList=BookList(orderVerified:true,total:1,books:[Book(id:"1",title:"Synthetic",rank:0)],catalogRevision:windowLibrary,libraryId:windowLibrary)
        let window=CatalogWindow(offset:0,anchor:"1",catalog:windowList)
        pass(try window.validated(size:50,requestedAnchor:"1",library:windowLibrary).list.books.count==1,"局部窗口校验书库身份、页大小和锚点")
        for size in [0,-50,51,550]{rejects("窗口拒绝非法分页大小 \(size)"){_=try window.validated(size:size,requestedAnchor:"1",library:windowLibrary)}}
        rejects("窗口拒绝跨书库响应"){_=try window.validated(size:50,requestedAnchor:"1",library:String(repeating:"b",count:64))}
        rejects("窗口拒绝不匹配锚点"){_=try window.validated(size:50,requestedAnchor:"2",library:windowLibrary)}
        rejects("窗口拒绝非分页边界偏移"){_=try CatalogWindow(offset:1,anchor:"1",catalog:windowList).validated(size:50,requestedAnchor:"1",library:windowLibrary)}
        pass(try CatalogWindow(offset:0,anchor:nil,catalog:windowList).validated(size:50,requestedAnchor:"2",library:windowLibrary).list.total==1,"已移除锚点允许受校验的备用页")
        pass(PageReadFailure.header(status:412,code:"page_content_changed") == .changed,"只有明确内容冲突可触发页码核对")
        pass(PageReadFailure.header(status:401,code:"page_content_changed")==nil,"错误代码不能掩盖不同 HTTP 状态")
        pass(PageReadFailure.classify(URLError(.networkConnectionLost)).automaticRetry && !PageReadFailure.missing.automaticRetry && !PageReadFailure.invalid.automaticRetry,"短暂断网可补试，缺失和无效文件不循环")
        for text in ["", "0", "-1", "1.5", "99999999", "一", "1 2", "501"]{pass(PageJumpRules.index(text,count:500)==nil,"跳页输入拒绝空值、非整数和越界")}
        pass(PageJumpRules.index(" 500 ",count:500)==499 && PageJumpRules.index("001",count:500)==0,"跳页准确转换为零起始位置")
        pass(PageJumpRules.index("1",count:0)==nil && PageJumpRules.nearby(current:0,count:0).isEmpty,"空页序没有可跳目标")
        pass(PageJumpRules.nearby(current:250,count:500)==[0,249,250,251,499],"快捷目标只有首页、附近与末页，不枚举全书库")
        pass(PageJumpRules.nearby(current:0,count:1)==[0] && PageJumpRules.nearby(current:0,count:2)==[0,1],"极少页数快捷目标不重复")
        pass(PagingRules.prefetchIndices(current:3,count:8,direction:-1)==[3,2,4,1,5],"反向翻页优先前方邻页，保持双侧两页窗口")
        pass(PagingRules.prefetchIndices(current:0,count:8,direction:-1)==[0,1,2],"反向预取在首页不越界")
        var policy=ReadingPrefetchPolicy()
        policy.moved(to:3,now:0);policy.moved(to:4,now:1)
        pass(!policy.rapid(now:1),"单次翻页保留完整相邻窗口")
        policy.moved(to:5,now:1.1)
        pass(policy.rapid(now:1.1),"连续快速翻页触发调度收缩")
        pass(policy.indices(current:5,count:9,direction:1,thermal:0,pressure:false,now:1.1)==[5,6,7],"快速预取只准备前进方向")
        pass(policy.animationIndices(current:5,count:9,direction:1,thermal:0,pressure:false,now:1.1)==[5,6],"快速动图仅预热当前和前向邻页")
        pass(policy.indices(current:5,count:9,direction:-1,thermal:0,pressure:false,now:2)==[5,4,6,3,7],"停止后恢复双侧预取")
        pass(policy.indices(current:5,count:9,direction:1,thermal:2,pressure:false,now:2)==[5,6],"高温限制后台预取")
        pass(policy.indices(current:5,count:9,direction:1,thermal:3,pressure:false,now:2)==[5],"严重高温仅保留当前页请求")
        pass(policy.indices(current:5,count:9,direction:1,thermal:0,pressure:true,now:2)==[5],"内存警告不被自动恢复覆盖")
        for count in [0,1,8] {for current in [-1,0,7,8] {for direction in [-1,1] {
            let indices=policy.indices(current:current,count:count,direction:direction,thermal:0,pressure:false,now:1.1)
            pass(indices.allSatisfy{(0..<count).contains($0)} && Set(indices).count==indices.count,"自适应预取边界安全")
        }}}
        let cover="/v1/books/123/cover"
        pass(CoverRequest.path(cover,pixels:600,thumbnails:true)==cover+"?width=640","NAS 按像素桶请求缩略图")
        pass(CoverRequest.path(cover,pixels:320,thumbnails:false)==cover,"旧 NAS 与安卓保留原封面地址")
        pass(CoverRequest.path("/v1/books/123/pages/1",pixels:640,thumbnails:true)==nil,"正文不能进入缩略图接口")
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
        pass(RecentReading.load(scope:recent.scope,in:defaults)==recent,"移除备份功能后仍兼容旧版最近阅读")
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
        let legacyOwner=defaults.string(forKey:"reading.legacyOwner")
        pass(ReadingProgress.reset(in:defaults)==3,"重置同时清除旧版、安卓和 NAS 阅读位置")
        pass(ReadingProgress.page(scope:"android/library",id:"123",in:defaults)==0 && ReadingProgress.page(scope:"nas/library",id:"123",in:defaults)==0,"重置所有服务器的页码")
        pass(RecentReading.load(scope:"android/library",in:defaults)==nil && RecentReading.load(scope:"nas/library",in:defaults)==nil,"重置所有服务器的继续阅读")
        pass(defaults.string(forKey:"reading.legacyOwner")==legacyOwner && defaults.string(forKey:"pairing")=="keep","重置保留来源隔离标记和配对")
        ReadingProgress.register(scope:"android/library",server:.android,in:defaults)
        pass(ReadingProgress.page(scope:"android/library",id:"123",in:defaults)==0,"重连不会重新认领已重置的旧页码")
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
        pass(CoverRules.diskBudget+MediaDiskBudget.body==2_000_000_000 && MediaDiskBudget.body==512_000_000,"封面和近期正文共用 2 GB 总预算")
        let pageHash=String(repeating:"a",count:64)
        let validManifest=Pages(pages:[Page(number:1,sha256:pageHash,size:100)],id:"1",libraryId:pageHash,contentRevision:pageHash)
        try LibraryRules.validate(validManifest);pass(true,"新页清单包含稳定身份与正文校验")
        rejects("拒绝缺少书库身份的页哈希清单"){try LibraryRules.validate(Pages(pages:validManifest.pages,id:"1",contentRevision:pageHash))}
        rejects("拒绝页内容哈希无效"){try LibraryRules.validate(Pages(pages:[Page(number:1,sha256:"bad",size:100)],id:"1",libraryId:pageHash,contentRevision:pageHash))}
        rejects("拒绝负文件长度"){try LibraryRules.validate(Pages(pages:[Page(number:1,sha256:pageHash,size:-1)],id:"1",libraryId:pageHash,contentRevision:pageHash))}
        rejects("拒绝不带版本却夹带页哈希"){try LibraryRules.validate(Pages(pages:validManifest.pages))}
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
        for sign in [-1.0,1.0] {
            let next=sign<0 ? 1 : -1
            for speed in [300.0,600,649,650,651] {
                pass(PagingRules.swipeStep(x:sign*24,y:0,width:400,velocityX:sign*speed)==next,"24 点短划连续速度区间均可识别，不再卡 650 门槛")
            }
            var motion=ReaderSwipeMotion();motion.reset(time:0)
            for (x,t) in [(6.0,0.01),(16.0,0.02),(24.0,0.04),(24.0,0.06)]{motion.record(x:sign*x,time:t)}
            let lift=motion.release(fallbackVelocity:0)
            pass(!lift.reversed && !lift.paused && PagingRules.swipeStep(x:sign*24,y:0,width:400,velocityX:lift.velocityX)==next,"先快划后抬手减速，近期轨迹仍识别为翻页")
            let noise=motion.release(fallbackVelocity:sign * -20)
            pass(!noise.reversed,"抬手微弱反向噪声不吞掉有效短划")
            var held=motion;held.record(x:sign*24,time:0.2)
            let stop=held.release(fallbackVelocity:sign*1400)
            pass(stop.paused && stop.velocityX==0 && PagingRules.swipeStep(x:sign*24,y:0,width:400,velocityX:stop.velocityX)==0,"短划后停住不沿用过期峰值速度")
            var reversed=motion;reversed.record(x:sign*16,time:0.075)
            pass(reversed.release(fallbackVelocity:sign*500).reversed,"回收 8 点时，即便系统速度仍滞后也取消翻页")
            pass(motion.release(fallbackVelocity:sign * -500).reversed,"明确反向末速度继续取消")
            var slow=ReaderSwipeMotion();slow.reset(time:0)
            for i in 1...12{slow.record(x:sign*Double(i)*2,time:Double(i)*0.05)}
            let slowLift=slow.release(fallbackVelocity:0)
            pass(PagingRules.swipeStep(x:sign*24,y:0,width:400,velocityX:slowLift.velocityX)==0,"慢速 24 点短拖不误翻")
            for hz in [60,120,240] {
                var sampled=ReaderSwipeMotion();sampled.reset(time:0)
                for tick in 1...(hz/10){sampled.record(x:sign*400*Double(tick)/Double(hz),time:Double(tick)/Double(hz))}
                pass(abs(sampled.release(fallbackVelocity:0).velocityX-sign*400)<0.01,"60/120/240 Hz 采样同一轨迹结果一致")
            }
        }
        var boundedMotion=ReaderSwipeMotion();boundedMotion.reset(time:0)
        for tick in 1...10000{boundedMotion.record(x:Double(tick),time:Double(tick)*0.001)}
        pass(boundedMotion.sampleCount<=32,"长手势的轨迹样本有界，不随阅读时间增长")
        let beforeInvalid=boundedMotion.release(fallbackVelocity:0).velocityX
        boundedMotion.record(x:.nan,time:11);boundedMotion.record(x:0,time:.infinity);boundedMotion.record(x:0,time:0)
        pass(boundedMotion.release(fallbackVelocity:0).velocityX==beforeInvalid,"忽略异常或乱序触摸样本")
        boundedMotion.reset(time:20);boundedMotion.record(x:0,time:21)
        pass(boundedMotion.release(fallbackVelocity:0).velocityX==0,"新触摸不会继承上一手势速度")
        for x in [0.0,5,11.9]{pass(PagingRules.swipeStep(x:-x,y:0,width:400,velocityX:-2000)==0,"极短运动仍不触发翻页")}
        pass(PagingRules.prefetchIndices(current:4,count:10)==[4,5,3,6,2],"第 5 张预取第 3–7 张，优先当前和相邻")
        pass(PagingRules.prefetchIndices(current:0,count:10)==[0,1,2],"首页预取不越界")
        pass(PagingRules.prefetchIndices(current:9,count:10)==[9,8,7],"末页预取不越界")
        pass(PagingRules.prefetchIndices(current:0,count:0).isEmpty,"空页序不预取")
        pass(PagingRules.prefetchIndices(current:0,count:1)==[0],"单页不重复请求")
        pass(PagingRules.count(total:10071,size:50)==202,"50 本分页及尾页")
        pass(PagingRules.count(total:10071,size:500)==21,"500 本分页及尾页")
        pass(PagingRules.count(total:0,size:100)==1,"空书库分页边界")
        pass(PagingRules.index(-1,count:3)==0 && PagingRules.index(99,count:3)==2,"阅读滑块上下界")
        let qr="{\"app\":\"localshelf\",\"version\":1,\"address\":\"http://192.168.1.2:8088\",\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\"}"
        pass(try PairingCode.parse(qr).address == "http://192.168.1.2:8088","配对码解析地址和口令")
        rejects("拒绝公网配对码"){_=try PairingCode.parse(qr.replacingOccurrences(of:"192.168.1.2",with:"8.8.8.8"))}
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
        _=try LibraryRules.address("http://192.168.1.2:8088");pass(true,"接受私人局域网地址")
        for s in ["http://example.com","http://8.8.8.8","http://192.168.1.2.evil.test","http://a:b@192.168.1.2","http://192.168.1.2/?key=a"]{rejects("拒绝非预期地址"){_=try LibraryRules.address(s)}}
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
        pass(try NASPassword.body("Synthetic-pass-42")==Data("Synthetic-pass-42".utf8),"NAS 固定密码支持字母与符号")
        pass(try NASPassword.body(" spaced ")==Data(" spaced ".utf8),"密码空格不被偷偷裁剪")
        for bad in ["", "short", String(repeating:"x",count:129), "password\n", "password\u{0}"]{rejects("拒绝超限或控制字符密码"){_=try NASPassword.body(bad)}}
        pass(ReaderService(app:"localshelf-reader",version:1,serverKind:"nas",capabilities:["reader-v1","pair-v2","locate-v1","password-pair-v1"]).passwordPairing,"固定密码需服务端明确能力支持")
        pass(!ReaderService(app:"localshelf-sync",version:1,serverKind:"nas",capabilities:["password-pair-v1"]).passwordPairing,"不会向上传服务发送阅读密码")
        for bad in ["12345","1234567","１２３４５６","12345a","123 45",""]{rejects("拒绝非六位 ASCII 配对码"){_=try PairingPIN.body(bad)}}
        let pinReply=Data("{\"app\":\"localshelf\",\"version\":2,\"deviceId\":\"0123456789abcdef0123456789abcdef\",\"token\":\"abcdefghijklmnopqrstuvwxyzABCDEF\"}".utf8)
        pass(try PairingPIN.response(pinReply,address:"http://192.168.1.2:8088").version==2,"配对码响应转换为强随机凭据")
        rejects("配对码响应拒绝公网地址"){_=try PairingPIN.response(pinReply,address:"https://example.com")}
        rejects("配对码响应拒绝超限数据"){_=try PairingPIN.response(Data(repeating:0,count:2049),address:"http://192.168.1.2:8088")}
        print("\(count) protocol checks passed")
    }
}
