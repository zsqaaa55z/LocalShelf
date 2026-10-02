#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

// Actual UIKit snapshots/layout with synthetic books. No live servers or media.
@MainActor enum ShelfUpdateChecks {
    private static var checks=0
    private static func pass(_ condition:Bool,_ message:String){precondition(condition,message);checks+=1;print("PASS "+message);fflush(stdout)}
    private static func settle(_ grid:CollectionShelfController)async {
        for _ in 0..<300 {
            if !grid.isUpdating{grid.collection.layoutIfNeeded();await Task.yield();if !grid.isUpdating{return}}
            try? await Task.sleep(for:.milliseconds(5))
        }
        preconditionFailure("snapshot did not finish")
    }
    private static func sample(_ count:Int,offset:Int=0)->[Book]{(1...count).map{Book(id:String(offset+$0),title:"Synthetic book \(offset+$0)",rank:$0)}}
    private static func top(_ grid:CollectionShelfController)->(String,CGFloat){
        let rect=CGRect(origin:grid.collection.contentOffset,size:grid.collection.bounds.size)
        let attributes=grid.layout.layoutAttributesForElements(in:rect)!.filter{$0.representedElementCategory == .cell && $0.frame.maxY>rect.minY+1}.sorted{$0.indexPath.item<$1.indexPath.item}
        let first=attributes.first!
        return (grid.displayedIDs[first.indexPath.item],first.frame.minY-rect.minY)
    }
    private static func y(_ id:String,_ grid:CollectionShelfController)->CGFloat? {
        guard let index=grid.displayedIDs.firstIndex(of:id),let frame=grid.layout.layoutAttributesForItem(at:IndexPath(item:index,section:0))?.frame else{return nil}
        return frame.minY-grid.collection.contentOffset.y
    }
    private static func cell(_ id:String,_ grid:CollectionShelfController)->ShelfCoverCell? {
        guard let index=grid.displayedIDs.firstIndex(of:id) else{return nil}
        return grid.collection.cellForItem(at:IndexPath(item:index,section:0)) as? ShelfCoverCell
    }
    static func run()async {
        let defaults=UserDefaults.standard,hidden=defaults.object(forKey:"shelf.hideCovers")
        defer{if let hidden{defaults.set(hidden,forKey:"shelf.hideCovers")}else{defaults.removeObject(forKey:"shelf.hideCovers")}}
        checks=0
        for count in [50,500] {
            let library=Library(loadPair:{nil},savePair:{_ in},removePair:{},lookup:{_ in []})
            library.setForeground(false);library.coversHidden=true;library.pageSize=count;library.total=count*3;library.books=sample(count)
            let grid=CollectionShelfController()
            let scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
            let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:402,height:874);window.rootViewController=grid;window.isHidden=false
            grid.loadViewIfNeeded();grid.view.frame=window.bounds
            var columns=3,seek:ShelfSeek?
            func update(){grid.configure(library:library,columns:columns,header:AnyView(Text(library.error.isEmpty ? "Synthetic shelf":library.error).frame(height:library.loading ? 170:100)),seek:seek)}
            update();await settle(grid)
            pass(grid.displayedIDs==library.books.map(\.id) && grid.experimentReloads==1,"\(count): first page uses one full snapshot")
            let reloads=grid.experimentReloads,updates=grid.snapshotUpdates,headers=grid.headerUpdates
            let start=ProcessInfo.processInfo.systemUptime
            for _ in 0..<1000{update()}
            pass(grid.experimentReloads==reloads && grid.snapshotUpdates==updates && grid.headerUpdates==headers,"\(count): 1000 unchanged calls skip grid and header work")
            print("METRIC shelf_\(count)_unchanged_1000_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")

            seek=ShelfSeek(index:count/2);update();await settle(grid)
            let anchor=top(grid),held=cell(anchor.0,grid)!,image=UIImage(systemName:"book")!
            held.picture.image=image
            let configures=held.configurations,restarts=held.imageRestarts
            for loading in [true,false]{library.loading=loading;update();await settle(grid)}
            library.error="Synthetic connection notice";update();await settle(grid)
            pass(grid.experimentReloads==reloads && grid.snapshotUpdates==updates,"\(count): loading and error updates cause zero grid snapshots")
            pass(cell(anchor.0,grid) === held && held.configurations==configures && held.picture.image === image,"\(count): status-only updates retain cell, bitmap and subscription")
            pass(abs(y(anchor.0,grid)!-anchor.1)<1,"\(count): header height changes preserve book-relative position")

            let at=library.books.firstIndex{$0.id==anchor.0}!
            var edited=library.books;let old=edited[at]
            edited[at]=Book(id:old.id,title:"Changed synthetic title",rank:old.rank)
            library.books=edited;update();await settle(grid)
            pass(cell(anchor.0,grid) === held && held.title.text=="Changed synthetic title" && held.imageRestarts==restarts && held.picture.image === image,"\(count): a title change updates the existing card without restarting its cover")
            pass(grid.snapshotUpdates==updates && grid.experimentReloads==reloads,"\(count): content-only change needs no structural snapshot")

            var counted=library.books;counted[at].pageCount=1024
            library.books=counted;update();await settle(grid)
            pass(cell(anchor.0,grid) === held && held.pageCountBadge.text=="1024" && !held.pageCountBadge.isHidden,"\(count): numeric page count appears on the existing card")
            pass(held.pageCountBadge.font.pointSize==13 && abs(held.pageCountBadge.frame.maxX-(held.bounds.width-7))<0.5 && abs(held.pageCountBadge.frame.maxY-(held.bounds.width*1.5-7))<0.5,"\(count): style A 13pt badge is inset 7pt from the cover bottom-right")
            pass(held.imageRestarts==restarts && held.picture.image === image && grid.snapshotUpdates==updates,"\(count): page-count update neither reloads grid nor restarts cover")
            pass(held.accessibilityLabel?.hasSuffix("1024 页")==true,"\(count): VoiceOver retains a meaningful page-count unit")
            counted[at].pageCount=nil;library.books=counted;update();await settle(grid)
            pass(held.pageCountBadge.isHidden && held.imageRestarts==restarts,"\(count): unknown count clears badge without touching pixels")

            let beforeReorder=top(grid)
            var moved=library.books;moved.append(moved.removeFirst());library.books=moved;update();await settle(grid)
            pass(grid.displayedIDs==moved.map(\.id) && grid.snapshotUpdates==updates+1 && grid.experimentReloads==reloads,"\(count): small reorder uses stable-ID incremental snapshot")
            pass(abs(y(beforeReorder.0,grid)!-beforeReorder.1)<1,"\(count): first-item change does not reset a same-page viewport")

            let beforeInsert=top(grid)
            library.books.insert(Book(id:"900001",title:"Synthetic new book",rank:0),at:0);update();await settle(grid)
            pass(grid.snapshotUpdates==updates+2 && abs(y(beforeInsert.0,grid)!-beforeInsert.1)<1,"\(count): insertion and count change preserve the visible book")
            library.books.removeAll{$0.id=="900001"};update();await settle(grid)
            pass(grid.snapshotUpdates==updates+3 && grid.displayedIDs==library.books.map(\.id),"\(count): deletion removes exactly one stable ID")

            let beforeReverse=top(grid)
            library.books.reverse();update();await settle(grid)
            pass(grid.experimentReloads==reloads+1 && grid.displayedIDs==library.books.map(\.id),"\(count): large reorder retains the full-refresh fallback")
            pass(abs(y(beforeReverse.0,grid)!-beforeReverse.1)<1,"\(count): full-refresh fallback also preserves a surviving visible book")

            let beforeColumns=top(grid),beforeColumnReloads=grid.experimentReloads
            columns=2;update();await settle(grid)
            pass(grid.experimentReloads==beforeColumnReloads && abs(y(beforeColumns.0,grid)!)<1,"\(count): density change relayouts and anchors by ID without reloading")
            let width=grid.collection.visibleCells.first!.bounds.width
            pass(width>150,"\(count): two-column layout is actually applied")

            let target=top(grid).0,targetIndex=library.books.firstIndex{$0.id==target}!
            var unavailable=library.books;let original=unavailable[targetIndex]
            unavailable[targetIndex]=Book(id:original.id,title:original.title,rank:original.rank,available:false)
            library.books=unavailable;update();await settle(grid)
            var selections=0;grid.select={_ in selections+=1}
            grid.collectionView(grid.collection,didSelectItemAt:IndexPath(item:targetIndex,section:0))
            pass(selections==0,"\(count): missing-file card cannot open after an incremental content change")
            unavailable[targetIndex]=original;library.books=unavailable;update();await settle(grid)
            grid.collectionView(grid.collection,didSelectItemAt:IndexPath(item:targetIndex,section:0))
            pass(selections==1,"\(count): selection maps to current stable-ID model after reorders")

            // Privacy toggles must clear reused images without a grid reload.
            library.coversHidden=false;update();await settle(grid)
            let privacyCell=cell(target,grid)!;privacyCell.picture.image=image
            let privacyReloads=grid.experimentReloads
            library.coversHidden=true;update();await settle(grid)
            pass(grid.experimentReloads==privacyReloads && privacyCell.picture.image==nil && privacyCell.placeholder.text=="封面已隐藏","\(count): hide-covers clears visible bitmaps without reloading")

            library.pageIndex=1;library.books=sample(count,offset:2000);seek=nil;update();await settle(grid)
            pass(grid.collection.contentOffset.y==0 && grid.displayedIDs.first=="2001","\(count): actual next-page navigation resets to the top")
            seek=ShelfSeek(index:count-1);update();await settle(grid)
            pass(grid.collection.contentOffset.y+grid.collection.bounds.height>=grid.collection.contentSize.height-18,"\(count): explicit rail seek reaches the bottom including the existing 16pt section inset")
            seek=ShelfSeek(index:0);update();await settle(grid)
            pass(grid.collection.contentOffset.y<300,"\(count): explicit first-book seek is applied")

            // New model updates during a snapshot are coalesced, never nested.
            library.pageIndex=2;library.books=sample(count,offset:4000);update()
            library.books=sample(count,offset:6000);update()
            library.books=sample(count,offset:8000);update();await settle(grid)
            pass(grid.displayedIDs==library.books.map(\.id),"\(count): rapid consecutive updates commit the latest list")
            let safe=grid.displayedIDs
            library.books.append(library.books[0]);update();await settle(grid)
            pass(grid.displayedIDs==safe && library.error.contains("标识重复"),"\(count): malformed duplicate IDs are rejected, not silently reordered")
            library.books=sample(1,offset:10000);update();await settle(grid)
            pass(grid.displayedIDs==["10001"],"\(count): one-item list recovers after rejected input")
            library.books=[];update();await settle(grid)
            pass(grid.displayedIDs.isEmpty && grid.collection.contentOffset.y==0,"\(count): empty list clamps the viewport safely")
            grid.dispose();window.isHidden=true;window.rootViewController=nil;library.setForeground(false)
        }
        badgeStyleA()
        await inFlightCovers()
        print("\(checks) shelf incremental checks passed")
    }

    private static func badgeStyleA(){
        let library=Library(loadPair:{nil},savePair:{_ in},removePair:{},lookup:{_ in []})
        library.setForeground(false);library.coversHidden=true
        let cell=ShelfCoverCell(),badge=cell.pageCountBadge
        pass(badge.font.isEqual(UIFont.monospacedDigitSystemFont(ofSize:13,weight:.semibold)),"style A uses 13pt semibold tabular digits")
        pass(badge.layer.cornerRadius==7 && badge.layer.borderWidth==0.5 && badge.layer.borderColor==UIColor(white:1,alpha:0.18).cgColor,"style A has 7pt corners and a subtle half-point border")
        pass(badge.backgroundColor==UIColor(white:0,alpha:0.88) && badge.textColor == .white,"style A retains white on 88 percent black")
        pass(!badge.isUserInteractionEnabled && !badge.isAccessibilityElement && badge.layer.shadowOpacity==0,"style A adds no tap target, separate accessibility element or shadow")
        for screenWidth in [CGFloat(320),375,402,430]{
            for columns in [2,3]{
                let width=(screenWidth-32-CGFloat(columns-1)*12)/CGFloat(columns)
                cell.frame=CGRect(x:0,y:0,width:width,height:width*1.5+52)
                for count in [1,24,128,1024,20000]{
                    cell.configure(book:Book(id:"1",title:"Synthetic count badge",rank:0,pageCount:count),library:library)
                    cell.layoutIfNeeded()
                    let size=badge.intrinsicContentSize
                    pass(badge.text==String(count) && !badge.isHidden && badge.frame.width>=ceil(size.width),"style A \(Int(screenWidth))pt / \(columns) columns / \(count) digits fit")
                    pass(abs(badge.frame.width-(ceil(size.width)+12))<0.5 && abs(badge.frame.height-(ceil(size.height)+6))<0.5 && abs(badge.frame.maxX-(width-7))<0.5 && abs(badge.frame.maxY-(width*1.5-7))<0.5,"style A \(Int(screenWidth))pt / \(columns) columns / \(count) padding and inset")
                }
            }
        }
        for count in [nil,0] as [Int?]{
            cell.configure(book:Book(id:"1",title:"Synthetic count badge",rank:0,pageCount:count),library:library)
            pass(badge.isHidden,"style A hides unknown or zero counts")
        }
        cell.configure(book:Book(id:"1",title:"Synthetic missing book",rank:0,available:false,pageCount:128),library:library)
        pass(badge.isHidden,"style A hides counts for missing books")
        cell.prepareForReuse()
        pass(badge.isHidden && badge.text==nil,"style A reuse clears numeric content")
        library.setForeground(false)
    }

    private static func inFlightCovers()async {
        let library=Library(loadPair:{nil},savePair:{_ in},removePair:{},lookup:{_ in []})
        library.setForeground(false);library.coversHidden=false;library.books=sample(3);library.total=3
        var requests=0,gates:[CheckedContinuation<LimitedHTTP.Payload,Error>]=[]
        let data=ReaderDemo.data("1")
        library.covers.variantLoad={_,_,_ in requests+=1;return try await withCheckedThrowingContinuation{gates.append($0)}}
        library.covers.suspend(false)
        let grid=CollectionShelfController(),scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first!
        let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:402,height:874);window.rootViewController=grid;window.isHidden=false
        grid.loadViewIfNeeded();grid.view.frame=window.bounds
        func update(){grid.configure(library:library,columns:3,header:AnyView(Text("Synthetic cover requests").frame(height:100)),seek:nil)}
        func wait(_ ready:()->Bool)async {
            for _ in 0..<1000{if ready(){return};try? await Task.sleep(for:.milliseconds(5))}
            preconditionFailure("cover request test timed out")
        }
        func release(){let pending=gates;gates=[];for gate in pending{gate.resume(returning:.init(data:data,status:200,etag:nil))}}
        update();await settle(grid);await wait{gates.count==3}
        let cells=(1...3).map{cell(String($0),grid)!},restarts=cells.map(\.imageRestarts),reloads=grid.experimentReloads
        library.loading=true;update();library.loading=false;update();library.error="Synthetic notice";update()
        var changed=library.books;changed[0]=Book(id:"1",title:"Renamed while loading",rank:1,pageCount:128);library.books=changed;update();await settle(grid)
        pass(cells[0].pageCountBadge.text=="128" && requests==3,"in-flight page-count change does not start a fourth cover request")
        pass(grid.experimentReloads==reloads && cells.map(\.imageRestarts)==restarts,"in-flight status/title updates do not restart the three visible cover subscriptions")
        release();await wait{library.covers.idle}
        pass(requests==3 && cells.allSatisfy{$0.picture.image != nil},"the original three pending cover responses still reach their cells, with no duplicate requests")
        library.coversHidden=true;update();library.covers.reset();library.coversHidden=false;update();await settle(grid)
        await wait{gates.count==3};library.coversHidden=true;update();await settle(grid)
        release();await wait{library.covers.idle}
        pass(cells.allSatisfy{$0.picture.image==nil && $0.placeholder.text=="封面已隐藏"},"hiding covers during pending requests rejects late images")
        cells[0].prepareForReuse()
        pass(cells[0].pageCountBadge.isHidden && cells[0].pageCountBadge.text==nil,"recycled cell never retains another book's count")
        grid.dispose();window.isHidden=true;window.rootViewController=nil;library.setForeground(false)
    }
}
#endif
