import SwiftUI
import UIKit

// Built-in UIKit shelf. No third-party source is copied.

// Display-link intervals detect main-run-loop stalls; they do not measure GPU
// presentation FPS. Only aggregates are retained, never titles, URLs or images.
@MainActor final class InteractionMeter:ObservableObject {
    static let shared=InteractionMeter()
    @Published private(set) var recording=false
    @Published private(set) var report="未记录。请在图片已加载后开始，再连续滚动或翻页。"
    private var link:CADisplayLink?
    private var timeout:Task<Void,Never>?
    private var last:CFTimeInterval=0
    private var samples:[Double]=[]
    private var late=0
    private var budgets:[Double]=[]
    @MainActor private class Target:NSObject {
        weak var meter:InteractionMeter?
        @objc func tick(_ link:CADisplayLink){meter?.tick(link)}
    }
    func start(){
        stop(save:false);samples.removeAll(keepingCapacity:true);budgets.removeAll(keepingCapacity:true);late=0;last=0
        let target=Target();target.meter=self
        let link=CADisplayLink(target:target,selector:#selector(Target.tick(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:120,preferred:120)
        self.link=link;recording=true;report="记录中：请关闭设置，连续滚动或翻页 15 秒。"
        link.add(to:.main,forMode:.common)
        timeout=Task{[weak self] in try? await Task.sleep(for:.seconds(15));guard !Task.isCancelled else{return};self?.stop()}
    }
    private func tick(_ link:CADisplayLink){
        defer{last=link.timestamp}
        guard last>0,samples.count<4000 else{return}
        let elapsed=link.timestamp-last,budget=link.targetTimestamp-link.timestamp
        guard elapsed>0,budget>0 else{return}
        samples.append(elapsed*1000);budgets.append(budget*1000)
        if elapsed>budget*1.5{late+=1}
    }
    func stop(save:Bool=true){
        link?.invalidate();link=nil;timeout?.cancel();timeout=nil
        guard recording else{return};recording=false
        guard save,!samples.isEmpty else{return}
        let sorted=samples.sorted(),p95=sorted[min(sorted.count-1,Int(Double(sorted.count-1)*0.95))]
        let target=budgets.reduce(0,+)/Double(budgets.count)
        report=String(format:"%@ / %@\n%d 次回调 · P95 %.1f ms · 最大 %.1f ms\n超过当次帧间隔 1.5 倍：%d 次\n平均目标间隔 %.1f ms；非 GPU 实际呈现帧率。","UIKit 书库","原分页",samples.count,p95,sorted.last ?? 0,late,target)
    }
}

struct ShelfSeek:Equatable {let ticket=UUID();var index:Int?;var centered=false}

// One visible thumbnail, using the existing shared requests and memory/disk cache.
struct RecentReadingCover:UIViewRepresentable {
    let library:Library,book:Book
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeUIView(context:Context)->UIImageView {
        let view=UIImageView();view.contentMode = .scaleAspectFit;view.clipsToBounds=true
        view.setContentHuggingPriority(.defaultLow,for:.horizontal);view.setContentHuggingPriority(.defaultLow,for:.vertical)
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);view.setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        view.isAccessibilityElement=false;return view
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UIImageView,context:Context)->CGSize? {
        CGSize(width:proposal.width ?? 40,height:proposal.height ?? 60)
    }
    func updateUIView(_ view:UIImageView,context:Context){context.coordinator.configure(view,library:library,book:book)}
    static func dismantleUIView(_ view:UIImageView,coordinator:Coordinator){coordinator.stop();view.image=nil}
    @MainActor final class Coordinator {
        private weak var library:Library?
        private var key:String?,path:String?,subscription:UUID?
        func configure(_ view:UIImageView,library:Library,book:Book){
            let key="\(book.id):\(library.coverEpoch):\(library.coversHidden):\(book.isMissing)"
            guard self.key != key else{return};stop();self.key=key;self.library=library;view.image=nil
            guard !library.coversHidden,!book.isMissing else{return}
            let path="/v1/books/\(book.id)/cover",ticket=UUID();self.path=path;subscription=ticket
            library.covers.subscribe(path,id:ticket,load:{[weak library] in
                guard let library,!library.coversHidden else{throw CancellationError()};return try await library.data(path)
            }){[weak self,weak view] result in
                guard let self,self.subscription==ticket,self.library?.coversHidden==false else{return}
                if case .success(let image)=result{view?.image=image}
            }
        }
        func stop(){
            if let path,let subscription{library?.covers.cancel(path,id:subscription)}
            subscription=nil;path=nil;key=nil
        }
    }
}

final class ShelfCoverCell:UICollectionViewCell {
    let picture=UIImageView(),placeholder=UILabel(),title=UILabel()
    private weak var library:Library?
    private var path:String?,subscription:UUID?
    private var identity:String?
    override init(frame:CGRect){
        super.init(frame:frame);backgroundColor = .black
        picture.contentMode = .scaleAspectFit;picture.backgroundColor=UIColor(white:0.075,alpha:1)
        picture.layer.cornerRadius=10;picture.clipsToBounds=true
        placeholder.textAlignment = .center;placeholder.font = .preferredFont(forTextStyle:.caption1);placeholder.textColor = .lightGray
        title.font = .preferredFont(forTextStyle:.subheadline);title.numberOfLines=2;title.textColor=UIColor(white:0.94,alpha:1)
        for view in [picture,placeholder,title]{contentView.addSubview(view)}
        isAccessibilityElement=true;accessibilityTraits = .button
    }
    required init?(coder:NSCoder){fatalError()}
    override func layoutSubviews(){
        super.layoutSubviews();let height=bounds.width*1.5
        picture.frame=CGRect(x:0,y:0,width:bounds.width,height:height);placeholder.frame=picture.frame
        title.frame=CGRect(x:0,y:height+9,width:bounds.width,height:max(44,bounds.height-height-9))
    }
    func configure(book:Book,library:Library){
        let key="\(book.id):\(library.coverEpoch):\(library.coversHidden):\(book.isMissing)"
        title.text=book.title;accessibilityLabel=book.title;accessibilityIdentifier="shelf-book-\(book.id)"
        title.textColor=book.isMissing ? .lightGray:UIColor(white:0.94,alpha:1)
        guard identity != key else{return};stop();identity=key;self.library=library;picture.image=nil
        placeholder.text=library.coversHidden ? "封面已隐藏":(book.isMissing ? "本地文件缺失":"▧")
        accessibilityValue=library.coversHidden ? "封面已隐藏":nil
        guard !library.coversHidden,!book.isMissing else{return}
        let path="/v1/books/\(book.id)/cover",ticket=UUID();self.path=path;subscription=ticket
        library.covers.subscribe(path,id:ticket,load:{[weak library] in guard let library,!library.coversHidden else{throw CancellationError()};return try await library.data(path)}){[weak self] result in
            guard let self,self.subscription==ticket,self.library?.coversHidden==false else{return}
            switch result {
            case .success(let image):self.picture.image=image;self.placeholder.text=nil
            case .failure(let error):if !(error is CancellationError){self.placeholder.text="封面暂不可用"}
            }
        }
    }
    func stop(){if let path,let subscription{library?.covers.cancel(path,id:subscription)};subscription=nil;path=nil;identity=nil}
    func markLocated(_ selected:Bool){contentView.layer.borderWidth=selected ? 2:0;contentView.layer.borderColor=UIColor.systemTeal.cgColor;contentView.layer.cornerRadius=10}
    override func prepareForReuse(){super.prepareForReuse();stop();picture.image=nil;title.text=nil;accessibilityLabel=nil;accessibilityValue=nil}
}

final class CollectionShelfController:UIViewController,UICollectionViewDataSource,UICollectionViewDelegateFlowLayout {
    let layout=UICollectionViewFlowLayout()
    lazy var collection=UICollectionView(frame:.zero,collectionViewLayout:layout)
    let header=UIHostingController(rootView:AnyView(EmptyView()))
    var library:Library!
    private var books:[Book]=[]
    private var signature="",headerHeight:CGFloat=0,previousWidth:CGFloat=0
    private var lastSeek:UUID?,lastVisible = -1
    private var recentRevision = -1
    private var recentMessage=""
    var columns=2
    var select:((Book)->Void)?,fullTitle:((String)->Void)?,position:((Int,Bool)->Void)?
    private var headerContent=AnyView(EmptyView())
    override func loadView(){
        view=collection;collection.backgroundColor = .black;collection.dataSource=self;collection.delegate=self
        collection.contentInsetAdjustmentBehavior = .never;collection.showsVerticalScrollIndicator=false
        layout.minimumInteritemSpacing=12;layout.minimumLineSpacing=22;layout.sectionInset=UIEdgeInsets(top:16,left:16,bottom:16,right:16)
        collection.register(ShelfCoverCell.self,forCellWithReuseIdentifier:"cover")
        collection.register(UICollectionReusableView.self,forSupplementaryViewOfKind:UICollectionView.elementKindSectionHeader,withReuseIdentifier:"header")
        addChild(header);header.view.backgroundColor = .clear;header.didMove(toParent:self)
    }
    func configure(library:Library,columns:Int,header:AnyView,seek:ShelfSeek?){
        loadViewIfNeeded();self.library=library
        // Resume progress updates only the fixed-height header, not 500 cells.
        if recentRevision != library.recentRevision || recentMessage != library.locateMessage {
            recentRevision=library.recentRevision;recentMessage=library.locateMessage;self.header.rootView=header
        }
        let key="\(library.booksRevision):\(columns):\(library.coverEpoch):\(library.coversHidden):\(library.loading):\(library.error):\(library.base != nil):\(library.locatedBookID ?? "")"
        if key != signature {
            let first=collection.indexPathsForVisibleItems.min()?.item ?? 0
            let oldOffset=collection.contentOffset.y
            let headerVisible=oldOffset<headerHeight
            let changedPage=books.first?.id != library.books.first?.id || books.count != library.books.count
            let changedColumns=self.columns != columns
            signature=key;books=library.books;self.columns=columns;headerContent=header
            self.header.rootView=header;measureHeader();collection.reloadData();collection.layoutIfNeeded()
            if changedPage{collection.setContentOffset(.zero,animated:false);lastVisible = -1}
            else if changedColumns {
                // Keep the layout menu visible when changing density at the
                // shelf header; away from the header keep the current book.
                if headerVisible{collection.setContentOffset(CGPoint(x:0,y:max(0,min(oldOffset,headerHeight))),animated:false)}
                else if books.indices.contains(first){collection.scrollToItem(at:IndexPath(item:first,section:0),at:.top,animated:false)}
            }
        }
        if let seek,lastSeek != seek.ticket {
            lastSeek=seek.ticket;collection.layoutIfNeeded()
            if let index=seek.index,books.indices.contains(index){collection.scrollToItem(at:IndexPath(item:index,section:0),at:seek.centered ? .centeredVertically:(index==books.count-1 ? .bottom:.top),animated:false)}
            else{collection.setContentOffset(.zero,animated:false)}
        }
    }
    private func measureHeader(){
        let width=max(1,collection.bounds.width)
        headerHeight=header.sizeThatFits(in:CGSize(width:width,height:CGFloat.greatestFiniteMagnitude)).height
        layout.headerReferenceSize=CGSize(width:width,height:headerHeight)
    }
    override func viewDidLayoutSubviews(){
        super.viewDidLayoutSubviews()
        if previousWidth != collection.bounds.width{previousWidth=collection.bounds.width;measureHeader();layout.invalidateLayout()}
        header.view.frame=CGRect(x:0,y:0,width:collection.bounds.width,height:headerHeight)
    }
    func collectionView(_ collectionView:UICollectionView,numberOfItemsInSection section:Int)->Int{books.count}
    func collectionView(_ collectionView:UICollectionView,cellForItemAt indexPath:IndexPath)->UICollectionViewCell{
        let cell=collectionView.dequeueReusableCell(withReuseIdentifier:"cover",for:indexPath) as! ShelfCoverCell
        cell.configure(book:books[indexPath.item],library:library);cell.markLocated(books[indexPath.item].id==library.locatedBookID);return cell
    }
    func collectionView(_ collectionView:UICollectionView,viewForSupplementaryElementOfKind kind:String,at indexPath:IndexPath)->UICollectionReusableView{
        let view=collectionView.dequeueReusableSupplementaryView(ofKind:kind,withReuseIdentifier:"header",for:indexPath)
        view.addSubview(header.view);header.view.frame=CGRect(x:0,y:0,width:collection.bounds.width,height:headerHeight);return view
    }
    func collectionView(_ collectionView:UICollectionView,layout:UICollectionViewLayout,sizeForItemAt indexPath:IndexPath)->CGSize{
        let width=max(1,(collectionView.bounds.width-32-CGFloat(columns-1)*12)/CGFloat(columns))
        return CGSize(width:width,height:width*1.5+9+max(44,UIFont.preferredFont(forTextStyle:.subheadline).lineHeight*2))
    }
    func collectionView(_ collectionView:UICollectionView,didSelectItemAt indexPath:IndexPath){guard !library.loading,!books[indexPath.item].isMissing else{return};select?(books[indexPath.item])}
    func collectionView(_ collectionView:UICollectionView,didEndDisplaying cell:UICollectionViewCell,forItemAt indexPath:IndexPath){(cell as? ShelfCoverCell)?.stop()}
    func collectionView(_ collectionView:UICollectionView,willDisplay cell:UICollectionViewCell,forItemAt indexPath:IndexPath){(cell as? ShelfCoverCell)?.configure(book:books[indexPath.item],library:library);(cell as? ShelfCoverCell)?.markLocated(books[indexPath.item].id==library.locatedBookID)}
    func scrollViewDidScroll(_ scrollView:UIScrollView){
        // During programmatic jumps visibleCells can still describe the old
        // viewport. Query layout geometry, not the previously realized cells.
        let rect=CGRect(origin:scrollView.contentOffset,size:scrollView.bounds.size)
        let visible=(layout.layoutAttributesForElements(in:rect) ?? []).filter{
            $0.representedElementCategory == .cell && $0.frame.maxY>rect.minY+1
        }.map{$0.indexPath.item}.min() ?? 0
        let bottom=scrollView.contentSize.height>0 && scrollView.contentOffset.y+scrollView.bounds.height>=scrollView.contentSize.height-18
        let value=bottom ? max(0,books.count-1):visible
        guard value != lastVisible else{return};lastVisible=value
        DispatchQueue.main.async{[weak self] in guard let self,self.lastVisible==value else{return};self.position?(value,bottom);self.library.scheduleCoverPrefetch(anchor:visible)}
    }
    func collectionView(_ collectionView:UICollectionView,contextMenuConfigurationForItemAt indexPath:IndexPath,point:CGPoint)->UIContextMenuConfiguration?{
        let book=books[indexPath.item]
        return UIContextMenuConfiguration(identifier:nil,previewProvider:nil){[weak self] _ in
            UIMenu(children:[UIAction(title:"查看完整名称",image:UIImage(systemName:"text.alignleft")){_ in self?.fullTitle?(book.title)},UIAction(title:"重试封面",image:UIImage(systemName:"arrow.clockwise")){_ in
                guard let self,!self.library.coversHidden,let current=self.books.firstIndex(where:{$0.id==book.id}) else{return}
                self.collection.reloadItems(at:[IndexPath(item:current,section:0)])
            }])
        }
    }
    func dispose(){collection.delegate=nil;collection.dataSource=nil;for cell in collection.visibleCells{(cell as? ShelfCoverCell)?.stop()}}
}

struct CollectionShelf:UIViewControllerRepresentable {
    let library:Library,columns:Int,header:AnyView,seek:ShelfSeek?
    let select:(Book)->Void,fullTitle:(String)->Void,position:(Int,Bool)->Void
    func makeUIViewController(context:Context)->CollectionShelfController{CollectionShelfController()}
    func updateUIViewController(_ controller:CollectionShelfController,context:Context){
        controller.select=select;controller.fullTitle=fullTitle;controller.position=position
        controller.configure(library:library,columns:columns,header:header,seek:seek)
    }
    static func dismantleUIViewController(_ controller:CollectionShelfController,coordinator:()){controller.dispose()}
}
