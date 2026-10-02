import SwiftUI
import UIKit

enum RelatedLoadError:Error {case unavailable}
struct RelatedRequest:Identifiable {let id=UUID();let book:Book;let kind:RelatedKind}

// Independent state: never writes Library.books/total/pageIndex or its window
// anchor. Covers and the reader still share the existing bounded pipelines.
@MainActor final class RelatedShelfModel:ObservableObject {
    @Published private(set) var options:[RelatedChoice]=[]
    @Published private(set) var result:RelatedResult?
    @Published private(set) var loading=false
    @Published private(set) var message=""
    private var context:String?,ticket=UUID()
    private var task:Task<Void,Never>?
    private(set) var size=100
    var page:Int{(result?.offset ?? 0)/size}
    var count:Int{PagingRules.count(total:result?.catalog.total ?? 0,size:size)}
    func cancel(){ticket=UUID();task?.cancel();task=nil;loading=false}
    func start(library:Library,request:RelatedRequest,force:Bool=false){
        let next=library.relatedContext
        if !force,context==next,result==nil,options.count==1,!loading,message.isEmpty {
            select(options[0],library:library,request:request);return
        }
        guard force || context != next || (result==nil && options.isEmpty && !loading) else{return}
        cancel();context=next;options=[];result=nil;message="";size=library.pageSize
        guard library.supportsRelated(request.kind) else{message="需要连接支持此功能的新版 NAS 阅读服务。";return}
        let ticket=self.ticket;loading=true
        task=Task{[weak self] in
            do{
                let response=try await library.relatedOptions(book:request.book.id,kind:request.kind)
                guard let self,self.ticket==ticket,context==library.relatedContext,!Task.isCancelled else{return}
                options=response.options;loading=false
                if let first=options.first,options.count==1{select(first,library:library,request:request)}
                else if options.isEmpty{message=request.kind.empty+"。\n"+request.kind.explanation}
            }catch{self?.failed(error,ticket:ticket)}
        }
    }
    func select(_ choice:RelatedChoice,library:Library,request:RelatedRequest,page:Int=0,allowRefresh:Bool=true){
        guard context==library.relatedContext else{start(library:library,request:request);return}
        cancel();message="";loading=true
        if result?.option.id != choice.id{result=nil}
        let ticket=self.ticket,context=self.context,size=self.size
        task=Task{[weak self] in
            do{
                let response=try await library.relatedResult(book:request.book.id,kind:request.kind,choice:choice.id,page:page,size:size)
                guard let self,self.ticket==ticket,context==library.relatedContext,!Task.isCancelled else{return}
                library.registerRelatedCovers(response.catalog.books)
                result=response;loading=false
            }catch{
                // One bounded recovery if a source credit itself was renamed
                // or removed. Never loop, or silently choose among new authors.
                if allowRefresh,case ServerFailure.status(404)=error {
                    do{
                        let refreshed=try await library.relatedOptions(book:request.book.id,kind:request.kind)
                        guard let self,self.ticket==ticket,context==library.relatedContext,!Task.isCancelled else{return}
                        options=refreshed.options
                        if options.count==1{select(options[0],library:library,request:request,page:page,allowRefresh:false)}
                        else{result=nil;loading=false;message=options.isEmpty ? request.kind.empty:"书目已更新，请重新选择。"}
                    }catch{self?.failed(error,ticket:ticket)}
                }else{self?.failed(error,ticket:ticket)}
            }
        }
    }
    private func failed(_ error:Error,ticket:UUID){
        guard self.ticket==ticket else{return};loading=false
        if error is CancellationError{return}
        message="暂时无法读取匹配结果。可能是连接中断或书目已更新，请重试。"
    }
}

struct RelatedShelfView:View {
    @ObservedObject var library:Library
    let request:RelatedRequest
    @StateObject private var model=RelatedShelfModel()
    @State private var selectedBook:Book?
    @State private var fullTitle:String?
    @AppStorage("shelf.columns") private var storedColumns=2
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0){
            if let result=model.result {
                VStack(alignment:.leading,spacing:6){
                    HStack {
                        Text(result.option.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        if model.options.count>1 {
                            Menu("切换",systemImage:"person.2"){
                                ForEach(model.options){option in Button(option.name){model.select(option,library:library,request:request)}}
                            }.accessibilityIdentifier("relatedChooseAnother")
                        }
                    }
                    Text("\(result.catalog.total) 本 · 按下载顺序").font(.subheadline).foregroundStyle(ShelfTheme.secondary)
                    if let possible=result.option.possibleCount,possible>0 {
                        Text("\(result.catalog.total-possible) 本\(request.kind == .authors ? "署名关联":"卷篇关联") · \(possible) 本可能匹配").font(.caption).foregroundStyle(ShelfTheme.accent).accessibilityIdentifier("relatedMatchSummary")
                    }
                    if let aliases=result.option.aliases,!aliases.isEmpty{Text(aliases.joined(separator:" / ")).font(.caption).foregroundStyle(ShelfTheme.secondary).lineLimit(2)}
                    Text(request.kind.explanation).font(.caption).foregroundStyle(ShelfTheme.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
                RelatedCollection(library:library,books:result.catalog.books,columns:storedColumns==3 ? 3:2,
                    pageKey:result.option.id+"/\(result.offset)",origin:request.book.id,enabled:!model.loading,possibleIDs:Set(result.possibleBookIDs ?? []),partLabels:result.partLabels ?? [:],matchNotes:result.matchNotes ?? [:],
                    select:{selectedBook=$0},fullTitle:{fullTitle=$0})
                    .accessibilityIdentifier("relatedShelfGrid")
                HStack {
                    Button("上一页",systemImage:"chevron.left"){move(-1)}.disabled(model.page==0).accessibilityIdentifier("relatedPreviousPage")
                    Spacer()
                    Menu{
                        ForEach(0..<max(1,model.count),id:\.self){page in
                            Button("第 \(page+1) 页"){model.select(result.option,library:library,request:request,page:page)}
                        }
                    }label:{HStack(spacing:6){Text("\(model.page+1) / \(max(1,model.count)) 页").monospacedDigit();Image(systemName:"chevron.down").font(.caption2)}.frame(minHeight:44)}.menuOrder(.priority).accessibilityIdentifier("relatedPageMenu")
                    Spacer()
                    Button("下一页",systemImage:"chevron.right"){move(1)}.disabled(model.page+1>=model.count).accessibilityIdentifier("relatedNextPage")
                }.font(.subheadline).frame(minHeight:48).padding(.horizontal,16).background(ShelfTheme.surface).disabled(model.loading)
            }else if !model.options.isEmpty {
                ScrollView {
                    VStack(alignment:.leading,spacing:12){
                        Text(request.kind == .authors ? "选择作者":"选择系列").font(.headline)
                        Text(request.kind.explanation).font(.caption).foregroundStyle(ShelfTheme.secondary)
                        ForEach(model.options){option in
                            Button{model.select(option,library:library,request:request)}label:{
                                HStack{Text(option.name).multilineTextAlignment(.leading);Spacer();Text("\(option.count) 本");Image(systemName:"chevron.right")}
                                    .padding(16).frame(maxWidth:.infinity).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:12))
                            }.accessibilityIdentifier("related-option-\(option.id)").disabled(model.loading)
                        }
                    }.padding(16)
                }
            }else{Spacer()}
            if !model.message.isEmpty {
                VStack(spacing:12){
                    Text(model.message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(ShelfTheme.secondary).accessibilityIdentifier("relatedMessage")
                    Button("重新查找",systemImage:"arrow.clockwise"){model.start(library:library,request:request,force:true)}.frame(minHeight:44)
                }.padding(20)
            }
            if model.result==nil{Spacer()}
        }.overlay{if model.loading{ProgressView("正在查找…").padding(20).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:14))}}
            .background(ShelfTheme.background).foregroundStyle(ShelfTheme.primary).tint(ShelfTheme.accent)
            .navigationTitle(request.kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black,for:.navigationBar).toolbarBackground(.visible,for:.navigationBar)
            .toolbar{ToolbarItem(placement:.topBarTrailing){Button("刷新",systemImage:"arrow.clockwise"){model.start(library:library,request:request,force:true)}.disabled(model.loading)}}
            .pageEdgeReturn{dismiss()}
            .onAppear{library.setReading(false);model.start(library:library,request:request)}
            .onChange(of:library.relatedContext){_,_ in selectedBook=nil;model.start(library:library,request:request)}
            .onDisappear{model.cancel()}
            .sheet(isPresented:Binding(get:{fullTitle != nil},set:{if !$0{fullTitle=nil}})){if let fullTitle{BookTitleSheet(title:fullTitle)}}
            .navigationDestination(isPresented:Binding(get:{selectedBook != nil},set:{if !$0{selectedBook=nil}})){
                if let book=selectedBook{Reader(library:library,book:book,returnLabel:"返回"+request.kind.title)}
            }
    }
    private func move(_ delta:Int){guard let option=model.result?.option else{return};model.select(option,library:library,request:request,page:model.page+delta)}
}

// Separate collection state, shared cell/image pipeline. At most one result
// page (500 books) is held; offscreen cells release their image subscriptions.
struct RelatedCollection:UIViewControllerRepresentable {
    let library:Library,books:[Book],columns:Int,pageKey:String,origin:String,enabled:Bool
    let possibleIDs:Set<String>
    let partLabels:[String:String]
    let matchNotes:[String:RelatedMatchNote]
    let select:(Book)->Void,fullTitle:(String)->Void
    func makeUIViewController(context:Context)->RelatedCollectionController{RelatedCollectionController()}
    func updateUIViewController(_ controller:RelatedCollectionController,context:Context){
        controller.select=select;controller.fullTitle=fullTitle;controller.enabled=enabled
        controller.configure(library:library,books:books,columns:columns,pageKey:pageKey,origin:origin,possibleIDs:possibleIDs,partLabels:partLabels,matchNotes:matchNotes)
    }
    static func dismantleUIViewController(_ controller:RelatedCollectionController,coordinator:()){controller.stop()}
}

final class RelatedCollectionController:UICollectionViewController,UICollectionViewDelegateFlowLayout {
    private var books:[Book]=[],byID:[String:Book]=[:],library:Library?
    private var columns=2,pageKey="",origin="",state=""
    private var possibleIDs=Set<String>()
    private var partLabels=[String:String]()
    private var matchNotes=[String:RelatedMatchNote]()
    var enabled=true,select:((Book)->Void)?,fullTitle:((String)->Void)?
    init(){let layout=UICollectionViewFlowLayout();layout.minimumLineSpacing=18;layout.minimumInteritemSpacing=12;layout.sectionInset=UIEdgeInsets(top:8,left:16,bottom:16,right:16);super.init(collectionViewLayout:layout)}
    required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){
        super.viewDidLoad();collectionView.backgroundColor = .black
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(ShelfCoverCell.self,forCellWithReuseIdentifier:"cover")
    }
    func configure(library:Library,books:[Book],columns:Int,pageKey:String,origin:String,possibleIDs:Set<String>=[],partLabels:[String:String]=[:],matchNotes:[String:RelatedMatchNote]=[:]){
        loadViewIfNeeded()
        let state="\(library.coverEpoch)/\(library.coversHidden)/\(library.coverDisplayScope ?? "")"
        let moved=self.pageKey != pageKey
        let changed=self.library !== library || self.books != books || self.columns != columns || self.possibleIDs != possibleIDs || self.partLabels != partLabels || self.matchNotes != matchNotes
        let countsOnly=changed && !moved && self.library === library && self.columns==columns && self.possibleIDs==possibleIDs && self.partLabels==partLabels && self.matchNotes==matchNotes && self.books.count==books.count && zip(self.books,books).allSatisfy{old,new in var previous=old;previous.pageCount=new.pageCount;return previous==new}
        self.possibleIDs=possibleIDs;self.partLabels=partLabels;self.matchNotes=matchNotes
        self.library=library;self.origin=origin;self.columns=columns;self.pageKey=pageKey
        if countsOnly{
            self.books=books;byID=Dictionary(uniqueKeysWithValues:books.map{($0.id,$0)})
            for index in collectionView.indexPathsForVisibleItems{if books.indices.contains(index.item),let cell=collectionView.cellForItem(at:index) as? ShelfCoverCell{configure(cell,book:books[index.item])}}
        }else if changed{
            guard books.count<=500,Set(books.map(\.id)).count==books.count else{return}
            for cell in collectionView.visibleCells{(cell as? ShelfCoverCell)?.stop()}
            self.books=books;byID=Dictionary(uniqueKeysWithValues:books.map{($0.id,$0)})
            collectionView.reloadData();collectionView.collectionViewLayout.invalidateLayout()
            if moved{collectionView.setContentOffset(.zero,animated:false)}
        }else if self.state != state{
            for index in collectionView.indexPathsForVisibleItems{if books.indices.contains(index.item),let cell=collectionView.cellForItem(at:index) as? ShelfCoverCell{configure(cell,book:books[index.item])}}
        }
        self.state=state
    }
    override func collectionView(_ collectionView:UICollectionView,numberOfItemsInSection section:Int)->Int{books.count}
    override func collectionView(_ collectionView:UICollectionView,cellForItemAt indexPath:IndexPath)->UICollectionViewCell{
        let cell=collectionView.dequeueReusableCell(withReuseIdentifier:"cover",for:indexPath) as! ShelfCoverCell
        if books.indices.contains(indexPath.item){configure(cell,book:books[indexPath.item])}
        return cell
    }
    func collectionView(_ collectionView:UICollectionView,layout:UICollectionViewLayout,sizeForItemAt indexPath:IndexPath)->CGSize{
        let width=max(1,(collectionView.bounds.width-32-CGFloat(columns-1)*12)/CGFloat(columns))
        return CGSize(width:width,height:width*1.5+8+max(44,UIFont.preferredFont(forTextStyle:.subheadline).lineHeight*2))
    }
    override func collectionView(_ collectionView:UICollectionView,didSelectItemAt indexPath:IndexPath){guard enabled,books.indices.contains(indexPath.item),!books[indexPath.item].isMissing else{return};select?(books[indexPath.item])}
    override func collectionView(_ collectionView:UICollectionView,didEndDisplaying cell:UICollectionViewCell,forItemAt indexPath:IndexPath){(cell as? ShelfCoverCell)?.stop()}
    private func configure(_ cell:ShelfCoverCell,book:Book){
        guard let library else{return}
        cell.configure(book:book,library:library,possibleMatch:possibleIDs.contains(book.id),partLabel:partLabels[book.id],matchNote:matchNotes[book.id]);cell.markLocated(book.id==origin)
    }
    override func collectionView(_ collectionView:UICollectionView,willDisplay cell:UICollectionViewCell,forItemAt indexPath:IndexPath){if books.indices.contains(indexPath.item),let cell=cell as? ShelfCoverCell{configure(cell,book:books[indexPath.item])}}
    override func collectionView(_ collectionView:UICollectionView,contextMenuConfigurationForItemAt indexPath:IndexPath,point:CGPoint)->UIContextMenuConfiguration?{
        guard books.indices.contains(indexPath.item) else{return nil};let book=books[indexPath.item]
        return UIContextMenuConfiguration(identifier:nil,previewProvider:nil){[weak self] _ in UIMenu(children:[UIAction(title:"查看完整名称",image:UIImage(systemName:"text.alignleft")){_ in self?.fullTitle?(book.title)}])}
    }
    func stop(){for cell in collectionView.visibleCells{(cell as? ShelfCoverCell)?.stop()};collectionView.delegate=nil}
}
