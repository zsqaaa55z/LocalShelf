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

// Shared by the grid and resume card: title/rank changes must not restart images.
private struct ShelfCoverIdentity:Equatable {
    let owner:ObjectIdentifier,id:String,epoch:Int,hidden:Bool,missing:Bool,revision:String?,scope:String?
    @MainActor init(_ library:Library,_ book:Book){
        owner=ObjectIdentifier(library);id=book.id;epoch=library.coverEpoch
        hidden=library.coversHidden;missing=book.isMissing;revision=book.coverIdentity;scope=library.coverDisplayScope
    }
    func canKeepPixels(from old:Self?)->Bool {
        guard let old,scope != nil,revision != nil else{return false}
        return owner==old.owner && id==old.id && scope==old.scope && revision==old.revision && !hidden && !missing && !old.hidden && !old.missing
    }
}

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
        private var key:ShelfCoverIdentity?,path:String?,subscription:UUID?
        func configure(_ view:UIImageView,library:Library,book:Book){
            let key=ShelfCoverIdentity(library,book)
            guard self.key != key else{return}
            let keep=key.canKeepPixels(from:self.key);stop();self.key=key;self.library=library;if !keep{view.image=nil}
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
    private let placeholderIcon=UIImageView()
    private let possibleBadge=UILabel()
    let pageCountBadge=UILabel()
    private weak var library:Library?
    private var path:String?,subscription:UUID?
    private var identity:ShelfCoverIdentity?
    #if DEBUG && targetEnvironment(simulator)
    private(set) var configurations=0,imageRestarts=0
    #endif
    override init(frame:CGRect){
        super.init(frame:frame);backgroundColor = .black
        picture.contentMode = .scaleAspectFit;picture.backgroundColor=UIColor(white:0.075,alpha:1)
        picture.layer.cornerRadius=12;picture.layer.cornerCurve = .continuous;picture.clipsToBounds=true
        placeholder.textAlignment = .center;placeholder.font = .preferredFont(forTextStyle:.caption1);placeholder.textColor=UIColor(white:0.68,alpha:1)
        placeholder.numberOfLines=2;placeholder.adjustsFontForContentSizeCategory=true
        placeholderIcon.contentMode = .scaleAspectFit;placeholderIcon.tintColor=UIColor(white:0.38,alpha:1)
        title.font = .preferredFont(forTextStyle:.subheadline);title.numberOfLines=2;title.textColor=UIColor(white:0.94,alpha:1);title.adjustsFontForContentSizeCategory=true
        possibleBadge.text="可能匹配";possibleBadge.font = .preferredFont(forTextStyle:.caption2)
        possibleBadge.textColor = .white;possibleBadge.backgroundColor=UIColor(white:0.1,alpha:0.94)
        possibleBadge.textAlignment = .center;possibleBadge.layer.cornerRadius=6;possibleBadge.clipsToBounds=true;possibleBadge.isHidden=true
        // Selected style A: compact round rectangle, not an interactive pill.
        pageCountBadge.font = .monospacedDigitSystemFont(ofSize:13,weight:.semibold)
        pageCountBadge.textColor = .white;pageCountBadge.backgroundColor=UIColor(white:0,alpha:0.88)
        pageCountBadge.textAlignment = .center;pageCountBadge.layer.cornerRadius=7;pageCountBadge.clipsToBounds=true;pageCountBadge.isHidden=true
        pageCountBadge.layer.borderWidth=0.5;pageCountBadge.layer.borderColor=UIColor(white:1,alpha:0.18).cgColor
        pageCountBadge.isAccessibilityElement=false
        for view in [picture,placeholderIcon,placeholder,title,possibleBadge,pageCountBadge]{contentView.addSubview(view)}
        isAccessibilityElement=true;accessibilityTraits = .button
    }
    required init?(coder:NSCoder){fatalError()}
    override func layoutSubviews(){
        super.layoutSubviews();let height=bounds.width*1.5
        picture.frame=CGRect(x:0,y:0,width:bounds.width,height:height)
        placeholderIcon.frame=CGRect(x:bounds.midX-16,y:height/2-30,width:32,height:32)
        placeholder.frame=CGRect(x:8,y:height/2+10,width:max(0,bounds.width-16),height:min(60,height/2-12))
        title.frame=CGRect(x:0,y:height+8,width:bounds.width,height:max(44,bounds.height-height-8))
        let badgeSize=possibleBadge.intrinsicContentSize
        possibleBadge.frame=CGRect(x:6,y:6,width:min(max(0,bounds.width-12),badgeSize.width+12),height:badgeSize.height+8)
        let countSize=pageCountBadge.intrinsicContentSize
        let countWidth=min(max(0,bounds.width-14),ceil(countSize.width)+12),countHeight=ceil(countSize.height)+6
        pageCountBadge.frame=CGRect(x:max(7,bounds.width-7-countWidth),y:height-7-countHeight,width:countWidth,height:countHeight)
    }
    func configure(book:Book,library:Library,possibleMatch:Bool=false,partLabel:String?=nil,matchNote:RelatedMatchNote?=nil){
        #if DEBUG && targetEnvironment(simulator)
        configurations+=1
        #endif
        let key=ShelfCoverIdentity(library,book)
        title.text=book.title;accessibilityLabel=book.title;accessibilityIdentifier="shelf-book-\(book.id)"
        let badge=matchNote?.label ?? (possibleMatch ? "可能匹配":partLabel)
        possibleBadge.text=badge;possibleBadge.isHidden=badge==nil
        if let badge{accessibilityLabel=book.title+"，"+(matchNote?.explanation ?? badge)+(partLabel.map{"，"+$0} ?? "")}
        // Update metadata before the image-identity early return: page-count-only
        // changes must retain the bitmap, cache key and in-flight subscription.
        pageCountBadge.text=book.pageCountLabel;pageCountBadge.isHidden=book.pageCountLabel==nil
        if let count=book.pageCountLabel{accessibilityLabel=(accessibilityLabel ?? book.title)+"，\(count) 页"}
        setNeedsLayout()
        title.textColor=book.isMissing ? .lightGray:UIColor(white:0.94,alpha:1)
        guard identity != key else{return}
        let keep=key.canKeepPixels(from:identity);stop();identity=key;self.library=library;if !keep{picture.image=nil}
        #if DEBUG && targetEnvironment(simulator)
        imageRestarts+=1
        #endif
        placeholder.text=library.coversHidden ? "封面已隐藏":(book.isMissing ? "本地文件缺失":(picture.image==nil ? "载入封面":nil))
        placeholderIcon.image=UIImage(systemName:library.coversHidden ? "eye.slash":(book.isMissing ? "doc.questionmark":"book.closed"));placeholderIcon.isHidden=picture.image != nil
        accessibilityValue=library.coversHidden ? "封面已隐藏":nil
        guard !library.coversHidden,!book.isMissing else{return}
        let path="/v1/books/\(book.id)/cover",ticket=UUID();self.path=path;subscription=ticket
        library.covers.subscribe(path,id:ticket,load:{[weak library] in guard let library,!library.coversHidden else{throw CancellationError()};return try await library.data(path)}){[weak self] result in
            guard let self,self.subscription==ticket,self.library?.coversHidden==false else{return}
            switch result {
            case .success(let image):self.picture.image=image;self.placeholder.text=nil;self.placeholderIcon.isHidden=true
            case .failure(let error):if !(error is CancellationError),self.picture.image==nil{self.placeholder.text="封面暂不可用"}
            }
        }
    }
    func stop(){if let path,let subscription{library?.covers.cancel(path,id:subscription)};subscription=nil;path=nil;identity=nil}
    func markLocated(_ selected:Bool){contentView.layer.borderWidth=selected ? 2:0;contentView.layer.borderColor=UIColor.systemTeal.cgColor;contentView.layer.cornerRadius=10}
    override func prepareForReuse(){super.prepareForReuse();stop();picture.image=nil;placeholderIcon.isHidden=true;possibleBadge.isHidden=true;pageCountBadge.isHidden=true;pageCountBadge.text=nil;title.text=nil;accessibilityLabel=nil;accessibilityValue=nil}
}

// A page identity is separate from its contents: reordering the same page is
// not navigation. Apply it when the corresponding book revision arrives.
private struct ShelfPageIdentity:Equatable {
    let owner:ObjectIdentifier,server:String,scope:String?,page:Int,size:Int
    @MainActor init(_ library:Library){owner=ObjectIdentifier(library);server=library.serverTarget.rawValue;scope=library.recentScope;page=library.pageIndex;size=library.pageSize}
}

private struct ShelfHeaderState:Equatable {
    let columns:Int,size:Int,total:Int,empty:Bool,loading:Bool,connected:Bool,error:String,pending:Bool,preview:Bool
    let scope:String?,recent:Int,locating:Bool,message:String,hidden:Bool,epoch:Int
    @MainActor init(_ library:Library,columns:Int){
        self.columns=columns;size=library.pageSize;total=library.total;empty=library.books.isEmpty
        loading=library.loading;connected=library.base != nil;error=library.error;scope=library.recentScope
        recent=library.recentRevision;locating=library.locatingRecent;message=library.locateMessage
        hidden=library.coversHidden;epoch=library.coverEpoch
        pending=library.startupPending;preview=library.browsingCachedCatalog
    }
}

private struct ShelfCellState:Equatable {
    let epoch:Int,hidden:Bool,located:String?
    @MainActor init(_ library:Library){epoch=library.coverEpoch;hidden=library.coversHidden;located=library.locatedBookID}
}

final class CollectionShelfController:UIViewController,UICollectionViewDelegateFlowLayout {
    let layout=UICollectionViewFlowLayout()
    lazy var collection=UICollectionView(frame:.zero,collectionViewLayout:layout)
    let header=UIHostingController(rootView:AnyView(EmptyView()))
    var library:Library!
    private var books:[Book]=[]
    private var byID:[String:Book]=[:]
    private var source:UICollectionViewDiffableDataSource<Int,String>!
    private var bookRevision = -1,pageIdentity:ShelfPageIdentity?,headerState:ShelfHeaderState?
    private var cellState:ShelfCellState?
    private var headerHeight:CGFloat=0,previousWidth:CGFloat=0
    private var lastSeek:UUID?,lastVisible = -1
    private var lastBottom=false
    private var applying=false,disposed=false,valid=true
    private var pending:(Library,Int,AnyView,ShelfSeek?)?
    var columns=2
    #if DEBUG && targetEnvironment(simulator)
    private(set) var experimentReloads=0
    private(set) var snapshotUpdates=0
    private(set) var headerUpdates=0
    var displayedIDs:[String]{source.snapshot().itemIdentifiers}
    var isUpdating:Bool{applying}
    #endif
    var select:((Book)->Void)?,fullTitle:((String)->Void)?,position:((Int,Bool)->Void)?
    var related:((Book,RelatedKind)->Void)?
    override func loadView(){
        view=collection;collection.backgroundColor = .black;collection.delegate=self
        collection.contentInsetAdjustmentBehavior = .never;collection.showsVerticalScrollIndicator=false
        layout.minimumInteritemSpacing=12;layout.minimumLineSpacing=18;layout.sectionInset=UIEdgeInsets(top:8,left:16,bottom:16,right:16)
        collection.register(ShelfCoverCell.self,forCellWithReuseIdentifier:"cover")
        collection.register(UICollectionReusableView.self,forSupplementaryViewOfKind:UICollectionView.elementKindSectionHeader,withReuseIdentifier:"header")
        addChild(header);header.view.backgroundColor = .clear;header.didMove(toParent:self)
        source=UICollectionViewDiffableDataSource<Int,String>(collectionView:collection){[weak self] collection,path,id in
            let cell=collection.dequeueReusableCell(withReuseIdentifier:"cover",for:path) as! ShelfCoverCell
            if let self,let book=self.byID[id]{self.configure(cell,book:book)}
            return cell
        }
        source.supplementaryViewProvider={[weak self] collection,kind,path in
            let view=collection.dequeueReusableSupplementaryView(ofKind:kind,withReuseIdentifier:"header",for:path)
            if let self{view.addSubview(self.header.view);self.header.view.frame=CGRect(x:0,y:0,width:collection.bounds.width,height:self.headerHeight)}
            return view
        }
    }
    func configure(library:Library,columns:Int,header:AnyView,seek:ShelfSeek?){
        guard !disposed else{return};loadViewIfNeeded()
        // UIKit completes snapshots asynchronously. Coalesce re-entrant updates
        // instead of mutating its data source during a previous transaction.
        if applying{pending=(library,columns,header,seek);return}
        let changedOwner=self.library !== library
        let changedBooks=changedOwner || bookRevision != library.booksRevision
        let nextHeader=ShelfHeaderState(library,columns:columns),nextCells=ShelfCellState(library)
        let changedHeader=changedOwner || headerState != nextHeader
        let changedCells=changedOwner || cellState != nextCells
        let changedColumns=self.columns != columns
        guard changedBooks || changedHeader || changedCells || changedColumns || (seek != nil && lastSeek != seek?.ticket) else{return}
        if changedBooks,Set(library.books.map(\.id)).count != library.books.count {
            valid=false
            let message="书库标识重复，保留原列表，请刷新书库。"
            if library.error != message{library.error=message}
            return // Never deduplicate silently or pass duplicate IDs to UIKit.
        }
        valid=true
        let anchor=captureAnchor(),oldOffset=collection.contentOffset.y,headerVisible=oldOffset<headerHeight
        let nextPage=ShelfPageIdentity(library)
        let preservesAnchor = !changedOwner && library.anchorPreservingRevision==library.booksRevision && pageIdentity?.scope==nextPage.scope && pageIdentity?.size==nextPage.size && pageIdentity?.server==nextPage.server
        let crossedAnchoredPage=preservesAnchor && pageIdentity != nextPage
        let changedPage=changedBooks && pageIdentity != nextPage && !preservesAnchor
        let oldIDs=changedBooks ? books.map(\.id):[]
        let contentChanges=changedBooks ? Set(library.books.filter{book in
            guard let old=byID[book.id] else{return true}
            return old.title != book.title || old.isMissing != book.isMissing || old.coverIdentity != book.coverIdentity || old.pageCount != book.pageCount
        }.map(\.id)):Set<String>()
        self.library=library;self.columns=columns
        if changedBooks{books=library.books;byID=Dictionary(uniqueKeysWithValues:books.map{($0.id,$0)});bookRevision=library.booksRevision;pageIdentity=nextPage}
        cellState=nextCells
        if changedHeader {
            headerState=nextHeader;self.header.rootView=header;measureHeader()
            #if DEBUG && targetEnvironment(simulator)
            headerUpdates+=1
            #endif
        }
        if changedColumns{layout.invalidateLayout()}
        let newIDs=changedBooks ? books.map(\.id):[]
        let structural=changedBooks && oldIDs != newIDs
        // Only visible cells need content/cover/selection reconciliation. Their
        // typed image identity keeps unchanged subscriptions and bitmaps alive.
        let finish={ [weak self] in
            guard let self,!self.disposed else{return}
            self.collection.layoutIfNeeded()
            if changedCells || !contentChanges.isEmpty{self.refreshVisibleCells(ids:changedCells ? nil:contentChanges)}
            if changedPage{self.setOffset(0);self.lastVisible = -1}
            else if headerVisible && !crossedAnchoredPage{self.setOffset(oldOffset)}
            else{self.restoreAnchor(anchor,fallback:oldOffset,alignTop:changedColumns)}
            self.applySeek(seek)
            self.applying=false;self.publishPosition()
            if let pending=self.pending{self.pending=nil;self.configure(library:pending.0,columns:pending.1,header:pending.2,seek:pending.3)}
        }
        if structural || changedPage || source.snapshot().sectionIdentifiers.isEmpty {
            var snapshot=NSDiffableDataSourceSnapshot<Int,String>();snapshot.appendSections([0]);snapshot.appendItems(newIDs)
            let changes=newIDs.difference(from:oldIDs).count
            let reload=changedPage || changes>max(24,max(oldIDs.count,newIDs.count)/4)
            applying=true
            #if DEBUG && targetEnvironment(simulator)
            if reload{experimentReloads+=1}else{snapshotUpdates+=1}
            #endif
            if reload{source.applySnapshotUsingReloadData(snapshot,completion:finish)}
            else{source.apply(snapshot,animatingDifferences:false,completion:finish)}
        }else{finish()}
    }
    private func configure(_ cell:ShelfCoverCell,book:Book){cell.configure(book:book,library:library);cell.markLocated(book.id==library.locatedBookID)}
    private func refreshVisibleCells(ids:Set<String>?=nil){
        for path in collection.indexPathsForVisibleItems {
            if let id=source.itemIdentifier(for:path),ids==nil || ids!.contains(id),let book=byID[id],let cell=collection.cellForItem(at:path) as? ShelfCoverCell{configure(cell,book:book)}
        }
    }
    private struct Anchor {let id:String;let y:CGFloat}
    private func captureAnchor()->[Anchor]{
        let rect=CGRect(origin:collection.contentOffset,size:collection.bounds.size)
        return (layout.layoutAttributesForElements(in:rect) ?? []).filter{$0.representedElementCategory == .cell && $0.frame.maxY>rect.minY+1}
            .sorted{$0.indexPath.item<$1.indexPath.item}.compactMap{attribute in
                source.itemIdentifier(for:attribute.indexPath).map{Anchor(id:$0,y:attribute.frame.minY-rect.minY)}
            }
    }
    private func restoreAnchor(_ anchors:[Anchor],fallback:CGFloat,alignTop:Bool){
        for anchor in anchors {
            if let path=source.indexPath(for:anchor.id),let frame=layout.layoutAttributesForItem(at:path)?.frame{setOffset(frame.minY-(alignTop ? 0:anchor.y));return}
        }
        setOffset(fallback)
    }
    private func setOffset(_ y:CGFloat){
        let value=max(0,min(y,max(0,collection.contentSize.height-collection.bounds.height)))
        if abs(collection.contentOffset.y-value)>0.5{collection.setContentOffset(CGPoint(x:0,y:value),animated:false)}
    }
    private func applySeek(_ seek:ShelfSeek?){
        if let seek,lastSeek != seek.ticket {
            lastSeek=seek.ticket;collection.layoutIfNeeded()
            if let index=seek.index,books.indices.contains(index){collection.scrollToItem(at:IndexPath(item:index,section:0),at:seek.centered ? .centeredVertically:(index==books.count-1 ? .bottom:.top),animated:false)}
            else{collection.setContentOffset(.zero,animated:false)}
        }
    }
    private func measureHeader(){
        let width=max(1,collection.bounds.width)
        let height=header.sizeThatFits(in:CGSize(width:width,height:CGFloat.greatestFiniteMagnitude)).height
        if abs(height-headerHeight)>0.5 || layout.headerReferenceSize.width != width {
            headerHeight=height;layout.headerReferenceSize=CGSize(width:width,height:height);layout.invalidateLayout()
        }
    }
    override func viewDidLayoutSubviews(){
        super.viewDidLayoutSubviews()
        if previousWidth != collection.bounds.width{previousWidth=collection.bounds.width;measureHeader();layout.invalidateLayout()}
        header.view.frame=CGRect(x:0,y:0,width:collection.bounds.width,height:headerHeight)
    }
    func collectionView(_ collectionView:UICollectionView,layout:UICollectionViewLayout,sizeForItemAt indexPath:IndexPath)->CGSize{
        let width=max(1,(collectionView.bounds.width-32-CGFloat(columns-1)*12)/CGFloat(columns))
        return CGSize(width:width,height:width*1.5+8+max(44,UIFont.preferredFont(forTextStyle:.subheadline).lineHeight*2))
    }
    func collectionView(_ collectionView:UICollectionView,didSelectItemAt indexPath:IndexPath){guard valid,!library.loading,let id=source.itemIdentifier(for:indexPath),let book=byID[id],!book.isMissing else{return};select?(book)}
    func collectionView(_ collectionView:UICollectionView,didEndDisplaying cell:UICollectionViewCell,forItemAt indexPath:IndexPath){(cell as? ShelfCoverCell)?.stop()}
    func collectionView(_ collectionView:UICollectionView,willDisplay cell:UICollectionViewCell,forItemAt indexPath:IndexPath){if let id=source.itemIdentifier(for:indexPath),let book=byID[id],let cell=cell as? ShelfCoverCell{configure(cell,book:book)}}
    func scrollViewDidScroll(_ scrollView:UIScrollView){
        guard !applying else{return};publishPosition()
    }
    func scrollViewWillBeginDragging(_ scrollView:UIScrollView){library.setShelfInteracting(true)}
    func scrollViewDidEndDragging(_ scrollView:UIScrollView,willDecelerate decelerate:Bool){if !decelerate{library.setShelfInteracting(false)}}
    func scrollViewDidEndDecelerating(_ scrollView:UIScrollView){library.setShelfInteracting(false)}
    private func publishPosition(){
        let scrollView=collection
        // During programmatic jumps visibleCells can still describe the old
        // viewport. Query layout geometry, not the previously realized cells.
        let rect=CGRect(origin:scrollView.contentOffset,size:scrollView.bounds.size)
        let visible=(layout.layoutAttributesForElements(in:rect) ?? []).filter{
            $0.representedElementCategory == .cell && $0.frame.maxY>rect.minY+1
        }.map{$0.indexPath.item}.min() ?? 0
        let bottom=scrollView.contentSize.height>0 && scrollView.contentOffset.y+scrollView.bounds.height>=scrollView.contentSize.height-18
        let value=bottom ? max(0,books.count-1):min(visible,max(0,books.count-1))
        guard value != lastVisible || bottom != lastBottom else{return};lastVisible=value;lastBottom=bottom
        let revision=bookRevision
        DispatchQueue.main.async{[weak self] in guard let self,!self.disposed,self.bookRevision==revision,self.lastVisible==value,self.lastBottom==bottom else{return};self.position?(value,bottom);self.library.recordVisibleBook(self.books.indices.contains(visible) ? self.books[visible].id:nil);self.library.scheduleCoverPrefetch(anchor:visible)}
    }
    func collectionView(_ collectionView:UICollectionView,contextMenuConfigurationForItemAt indexPath:IndexPath,point:CGPoint)->UIContextMenuConfiguration?{
        guard let id=source.itemIdentifier(for:indexPath),let book=byID[id] else{return nil}
        return UIContextMenuConfiguration(identifier:nil,previewProvider:nil){[weak self] _ in
            UIMenu(children:[UIAction(title:"查看同作者漫画",image:UIImage(systemName:"person.2")){_ in self?.related?(book,.authors)},UIAction(title:"查看同系列作品",image:UIImage(systemName:"books.vertical")){_ in self?.related?(book,.series)},UIAction(title:"查看完整名称",image:UIImage(systemName:"text.alignleft")){_ in self?.fullTitle?(book.title)},UIAction(title:"重试封面",image:UIImage(systemName:"arrow.clockwise")){_ in
                guard let self,!self.library.coversHidden,let current=self.source.indexPath(for:book.id),let book=self.byID[book.id],let cell=self.collection.cellForItem(at:current) as? ShelfCoverCell else{return}
                cell.stop();self.configure(cell,book:book)
            }])
        }
    }
    func dispose(){disposed=true;pending=nil;library?.setShelfInteracting(false);collection.delegate=nil;collection.dataSource=nil;for cell in collection.visibleCells{(cell as? ShelfCoverCell)?.stop()}}
}

struct CollectionShelf:UIViewControllerRepresentable {
    let library:Library,columns:Int,header:AnyView,seek:ShelfSeek?
    let select:(Book)->Void,fullTitle:(String)->Void,position:(Int,Bool)->Void
    var related:((Book,RelatedKind)->Void)?=nil
    func makeUIViewController(context:Context)->CollectionShelfController{CollectionShelfController()}
    func updateUIViewController(_ controller:CollectionShelfController,context:Context){
        controller.select=select;controller.fullTitle=fullTitle;controller.position=position
        controller.related=related
        controller.configure(library:library,columns:columns,header:header,seek:seek)
    }
    static func dismantleUIViewController(_ controller:CollectionShelfController,coordinator:()){controller.dispose()}
}
