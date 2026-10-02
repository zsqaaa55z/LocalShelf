import SwiftUI
import UIKit

final class ZoomCanvas:UIView,UIScrollViewDelegate,UIGestureRecognizerDelegate {
    let scroll=UIScrollView(),picture=UIImageView()
    var zoomChanged:((Bool)->Void)?
    var tapped:((Double)->Void)?
    private var previousSize=CGSize.zero
    private var resetID = -1
    private var active=false
    private var reportedZoom=false
    override init(frame:CGRect){
        super.init(frame:frame)
        isUserInteractionEnabled=false
        backgroundColor = .black;scroll.backgroundColor = .black
        scroll.minimumZoomScale=1;scroll.maximumZoomScale=1;scroll.bouncesZoom=false
        scroll.pinchGestureRecognizer?.isEnabled=false
        scroll.showsHorizontalScrollIndicator=false;scroll.showsVerticalScrollIndicator=false
        scroll.contentInsetAdjustmentBehavior = .never;scroll.delegate=self
        scroll.panGestureRecognizer.isEnabled=false
        scroll.pinchGestureRecognizer?.isEnabled=false
        addSubview(scroll);scroll.addSubview(picture)
        picture.contentMode = .scaleToFill;picture.isAccessibilityElement=true
        picture.accessibilityLabel="漫画页面";picture.accessibilityHint="左右滑动翻页；轻点显示或隐藏工具栏；从左侧边缘向右滑返回书库"
        let singleTap=UITapGestureRecognizer(target:self,action:#selector(singleTapped(_:)))
        scroll.addGestureRecognizer(singleTap)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func configure(image:UIImage,active:Bool,resetID:Int){
        // Replacing the preview with detail must not reset the focal point or scale.
        let imageChanged=picture.image !== image
        if imageChanged{picture.image=image}
        let needsReset=self.resetID != resetID || (self.active && !active)
        if self.active != active{isUserInteractionEnabled=active}
        self.active=active
        if needsReset {
            previousSize = .zero
            self.resetID=resetID;scroll.setZoomScale(1,animated:false);report(false)
        }
        if imageChanged || needsReset{setNeedsLayout()}
    }
    override func layoutSubviews(){
        super.layoutSubviews()
        if scroll.frame != bounds{scroll.frame=bounds}
        guard bounds.width>0,bounds.height>0,let image=picture.image else{return}
        if previousSize != bounds.size || picture.bounds.size == .zero {
            previousSize=bounds.size;scroll.setZoomScale(1,animated:false)
            let factor=min(bounds.width/image.size.width,bounds.height/image.size.height)
            picture.frame=CGRect(origin:.zero,size:CGSize(width:image.size.width*factor,height:image.size.height*factor))
            scroll.contentSize=picture.bounds.size;report(false)
        }
        centerPicture()
    }
    private func centerPicture(){
        let inset=UIEdgeInsets(top:max(0,(scroll.bounds.height-picture.frame.height)/2),left:max(0,(scroll.bounds.width-picture.frame.width)/2),bottom:0,right:0)
        if scroll.contentInset != inset{scroll.contentInset=inset}
        // Insets define the fit-scale origin: zero offset would pin a reused page
        // to the top. Reapply that origin even when the inset has not changed.
        // While zoomed, preserve the user's focal point / pan position instead.
        if scroll.zoomScale<=1.0001 {
            let origin=CGPoint(x:-inset.left,y:-inset.top)
            if scroll.contentOffset != origin{scroll.setContentOffset(origin,animated:false)}
        }
    }
    private func report(_ zoomed:Bool){
        scroll.panGestureRecognizer.isEnabled=zoomed
        guard reportedZoom != zoomed else{return};reportedZoom=zoomed
        // UIKit layout can run inside updateUIView; publish after that update finishes.
        DispatchQueue.main.async{[weak self] in guard let self,self.active,self.reportedZoom==zoomed else{return};self.zoomChanged?(zoomed)}
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView?{picture}
    func scrollViewWillBeginZooming(_ scrollView:UIScrollView,with view:UIView?){report(true)}
    func scrollViewDidZoom(_ scrollView:UIScrollView){centerPicture()}
    func scrollViewDidEndZooming(_ scrollView:UIScrollView,with view:UIView?,atScale scale:CGFloat){report(scale>1.01)}
    func prioritizeEdge(_ edge:UIGestureRecognizer){
        scroll.panGestureRecognizer.require(toFail:edge)
    }
    @objc private func singleTapped(_ gesture:UITapGestureRecognizer){
        guard active else{return}
        let fraction=gesture.location(in:self).x/max(1,bounds.width)
        tapped?(scroll.zoomScale>1.01 ? 0.5 : Double(fraction))
    }
}

// Native slots persist across page changes. Dragging never writes SwiftUI state.
final class NativePageSlot:UIView {
    let canvas=ZoomCanvas()
    let spinner=UIActivityIndicatorView(style:.large)
    let retry=UIButton(type:.system)
    var position:Int?
    private var number:Int?
    private var resetGeneration=0
    private var shownFailed=false,shownActive=false
    private var shownIssue:PageReadFailure?
    #if DEBUG && targetEnvironment(simulator)
    private(set) var showUpdates=0
    #endif
    var onRetry:(()->Void)?
    override init(frame:CGRect){
        super.init(frame:frame);backgroundColor = .black
        addSubview(canvas);spinner.color = .white;addSubview(spinner)
        var style=UIButton.Configuration.tinted();style.title="本页暂时无法加载";style.subtitle="点击重试 · 请确认安卓共享与 Wi-Fi"
        style.image=UIImage(systemName:"arrow.clockwise");style.imagePadding=10;style.cornerStyle = .large
        style.baseForegroundColor = .white;style.baseBackgroundColor=UIColor(white:0.12,alpha:1);retry.configuration=style
        retry.addTarget(self,action:#selector(retryTapped),for:.touchUpInside);addSubview(retry)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    @objc private func retryTapped(){onRetry?()}
    override func layoutSubviews(){
        super.layoutSubviews();canvas.frame=bounds
        spinner.center=CGPoint(x:bounds.midX,y:bounds.midY)
        let width=min(340,max(0,bounds.width-32));retry.frame=CGRect(x:(bounds.width-width)/2,y:bounds.midY-38,width:width,height:76)
    }
    func show(number:Int,image:UIImage?,failed:Bool,active:Bool,reset:Bool,issue:PageReadFailure?=nil){
        guard self.number != number || reset || shownFailed != failed || shownActive != active ||
              shownIssue != issue || canvas.picture.image !== image || canvas.isHidden != (image==nil) else{return}
        #if DEBUG && targetEnvironment(simulator)
        showUpdates+=1
        #endif
        shownFailed=failed;shownActive=active
        shownIssue=issue
        if failed{var style=retry.configuration;style?.title=(issue ?? .other).title;style?.subtitle=(issue ?? .other).message;retry.configuration=style}
        if self.number != number || reset {resetGeneration+=1}
        self.number=number
        canvas.isHidden=image==nil
        retry.isHidden=image != nil || !failed;retry.isEnabled=active
        if let image {
            spinner.stopAnimating()
            canvas.configure(image:image,active:active,resetID:resetGeneration)
        }else{
            // Do not retain an evicted page through an invisible UIImageView.
            canvas.picture.image=nil
            if failed{spinner.stopAnimating()}else{spinner.startAnimating()}
        }
        accessibilityElementsHidden = !active
    }
}

// Stop an in-flight settle at touch-down, before UIKit's pan recognition slop.
// A tap or rejected pan resumes the held settle rather than leaving a stuck page.
final class ReaderPanGestureRecognizer:UIPanGestureRecognizer {
    var contact:((CGPoint)->Void)?
    var released:(()->Void)?
    private var origin:CGPoint?
    var initialLocation:CGPoint?{origin}
    private(set) var contactTranslation=CGPoint.zero
    private(set) var swipeMotion=ReaderSwipeMotion()
    private var contactRevision=0
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent){
        contactRevision+=1
        if touches.count==1,numberOfTouches==0,let touch=touches.first,let view{
            let point=touch.location(in:view);origin=point;contactTranslation = .zero
            swipeMotion.reset(time:touch.timestamp);contact?(point)
        }
        super.touchesBegan(touches,with:event)
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent){updateContact(touches,event:event);super.touchesMoved(touches,with:event)}
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent){updateContact(touches,event:event);super.touchesEnded(touches,with:event);finishContact()}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent){super.touchesCancelled(touches,with:event);finishContact()}
    override func reset(){super.reset();finishContact()}
    private func updateContact(_ touches:Set<UITouch>,event:UIEvent){
        guard let origin,let touch=touches.first,let view else{return}
        for sample in event.coalescedTouches(for:touch) ?? [] {
            swipeMotion.record(x:Double(sample.location(in:view).x-origin.x),time:sample.timestamp)
        }
        let point=touch.location(in:view);contactTranslation=CGPoint(x:point.x-origin.x,y:point.y-origin.y)
        swipeMotion.record(x:Double(contactTranslation.x),time:touch.timestamp)
    }
    private func finishContact(){
        let ticket=contactRevision
        DispatchQueue.main.async{[weak self] in guard let self,self.contactRevision==ticket else{return};self.released?()}
    }
}

// Shared edge-return policy for app-owned modal pages. Attach to that page's
// controller, never UIWindow: a sheet must not also dismiss its presenting page.
// The reader keeps its existing recognizer and animation; system file pickers
// and confirmation dialogs keep their own navigation/cancel behavior.
struct PageEdgeReturn:UIViewControllerRepresentable {
    var enabled:Bool=true
    let perform:()->Void
    func makeUIViewController(context:Context)->Controller{Controller()}
    func updateUIViewController(_ controller:Controller,context:Context){controller.enabled=enabled;controller.perform=perform;controller.attach()}
    static func dismantleUIViewController(_ controller:Controller,coordinator:()){controller.detach();controller.perform=nil}
    final class Controller:UIViewController,UIGestureRecognizerDelegate {
        var enabled=true
        var perform:(()->Void)?
        private weak var host:UIViewController?
        private let pan=ReaderPanGestureRecognizer()
        private var fired=false
        override func loadView(){view=UIView();view.backgroundColor = .clear;view.isUserInteractionEnabled=false}
        override func viewDidLoad(){
            super.viewDidLoad();pan.maximumNumberOfTouches=1;pan.delegate=self
            pan.addTarget(self,action:#selector(dragged(_:)))
        }
        override func didMove(toParent parent:UIViewController?){super.didMove(toParent:parent);if parent==nil{detach()}else{attach()}}
        override func viewDidAppear(_ animated:Bool){super.viewDidAppear(animated);attach()}
        override func viewDidLayoutSubviews(){super.viewDidLayoutSubviews();attach()}
        override func viewDidDisappear(_ animated:Bool){super.viewDidDisappear(animated);detach()}
        func attach(){
            guard isViewLoaded,view.window != nil,var owner=parent else{return}
            while let parent=owner.parent,!(owner is UINavigationController){owner=parent}
            if host !== owner{detach();host=owner;owner.view.addGestureRecognizer(pan)}
            if pan.isEnabled != enabled{pan.isEnabled=enabled}
        }
        func detach(){pan.view?.removeGestureRecognizer(pan);host=nil}
        private var canReturn:Bool{enabled && viewIfLoaded?.window != nil && host != nil && host?.presentedViewController==nil && host?.isBeingDismissed==false}
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
            guard canReturn,let surface=pan.view,PagingRules.edgeStart(x:Double(touch.location(in:surface).x),width:Double(surface.bounds.width)) else{return false}
            var target=touch.view
            while let node=target,node !== surface {
                if node is UIControl || node is UITextView{return false}
                target=node.superview
            }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool {
            guard canReturn,let surface=pan.view else{return false}
            let velocity=pan.velocity(in:surface)
            return PagingRules.edgeStart(x:Double(pan.initialLocation?.x ?? -1),width:Double(surface.bounds.width)) && velocity.x>0 && velocity.x>abs(velocity.y)*1.2
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer)->Bool {
            // No failure dependency on vertical scrolling: ordinary Form scrolling
            // begins immediately, and a horizontal return doesn't move its content.
            other.view is UIScrollView
        }
        @objc private func dragged(_ gesture:UIPanGestureRecognizer){
            if gesture.state == .began{fired=false}
            guard gesture.state == .ended,!fired,canReturn,let surface=pan.view else{return}
            let translation=pan.contactTranslation,velocity=pan.velocity(in:surface)
            guard PagingRules.edgeReturns(x:Double(translation.x),y:Double(translation.y),velocityX:Double(velocity.x),width:Double(surface.bounds.width)) else{return}
            fired=true;surface.endEditing(true);perform?()
        }
    }
}

extension View {
    func pageEdgeReturn(enabled:Bool=true,perform:@escaping()->Void)->some View {
        background(PageEdgeReturn(enabled:enabled,perform:perform).allowsHitTesting(false))
    }
}

final class NativeReadingPager:UIView,UIGestureRecognizerDelegate {
    let animationPlayer=AnimatedPagePlayer()
    let content=UIView()
    let slots=(0..<3).map{_ in NativePageSlot()}
    private(set) var index=0
    private var pages:[Page]=[]
    private var pageRevision:UUID?
    private weak var cache:ReadingCache?
    private var lastReset = -1
    private var previousSize=CGSize.zero
    private var offset:CGFloat=0
    private var zoomed=false
    private var animator:UIViewPropertyAnimator?
    private var settlingTarget:Int?
    private var heldTarget:Int?
    private var dragResumeTarget:Int?
    private var dragCancelTarget:Int?
    private var dragging=false
    private var dragOrigin:CGFloat=0
    let pagePan=ReaderPanGestureRecognizer()
    // A committed incoming page may play during settling, never during a tentative drag.
    private var playbackTarget:Int?
    private var playbackPosition:Int{playbackTarget ?? index}
    let edgeReturn=ReaderPanGestureRecognizer()
    #if DEBUG && targetEnvironment(simulator)
    var motionActive:Bool {animator != nil}
    private(set) var comparedPageNumbers=0
    private var lastPanDistance:CGFloat=0,lastPanVelocity:CGFloat=0
    override var accessibilityValue:String? {
        get {let canvas=slots.first{$0.position==index}?.canvas;return "page=\(index);zoom=\(Int((canvas?.scroll.zoomScale ?? 1)*100));native=\(!edgeReturn.isEnabled);image=\(canvas?.picture.image != nil);anim=\(animationPlayer.key ?? "none");frames=\(animationPlayer.displayedFrames);pan=\(Int(lastPanDistance)),\(Int(lastPanVelocity))"}
        set {}
    }
    #endif
    private var revision=0
    var select:((Int)->Void)?
    var zoomChanged:((Bool)->Void)?
    var toggleControls:(()->Void)?
    var returnToLibrary:(()->Void)?
    private var stride:CGFloat {bounds.width+12}
    override init(frame:CGRect){
        super.init(frame:frame);backgroundColor = .black;clipsToBounds=true
        #if DEBUG && targetEnvironment(simulator)
        isAccessibilityElement=true;accessibilityIdentifier="native-reader"
        #endif
        addSubview(content)
        edgeReturn.maximumNumberOfTouches=1;edgeReturn.delegate=self;edgeReturn.addTarget(self,action:#selector(edgeDragged(_:)));addGestureRecognizer(edgeReturn)
        pagePan.maximumNumberOfTouches=1;pagePan.delegate=self
        pagePan.addTarget(self,action:#selector(pageDragged(_:)));addGestureRecognizer(pagePan)
        pagePan.require(toFail:edgeReturn)
        pagePan.contact={[weak self] point in self?.beginContact(at:point)}
        pagePan.released={[weak self] in self?.finishContact()}
        for slot in slots{content.addSubview(slot);slot.canvas.prioritizeEdge(edgeReturn)}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool {
        if gestureRecognizer===pagePan {
            let v=pagePan.velocity(in:self)
            return canDrag && abs(v.x)>abs(v.y)*1.5
        }
        guard gestureRecognizer===edgeReturn else{return true}
        let v=edgeReturn.velocity(in:self)
        return PagingRules.edgeStart(x:Double(edgeReturn.initialLocation?.x ?? -1),width:Double(bounds.width)) && v.x>0 && v.x>abs(v.y)*1.2
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
        guard gestureRecognizer===pagePan || gestureRecognizer===edgeReturn else{return true}
        if gestureRecognizer===edgeReturn,!PagingRules.edgeStart(x:Double(touch.location(in:self).x),width:Double(bounds.width)){return false}
        var view=touch.view
        while let current=view,current !== self{if current is UIControl{return false};view=current.superview}
        return true
    }
    private var canDrag:Bool {
        guard !zoomed,!pages.isEmpty,bounds.width>0 else{return false}
        let scroll=slots.first{$0.position==index}?.canvas.scroll
        return (scroll?.zoomScale ?? 1)<=1.01 && scroll?.isZooming != true
    }
    @objc private func pageDragged(_ gesture:UIPanGestureRecognizer){
        // Include UIKit's recognition slop in the actual finger travel. Otherwise
        // a real 34pt flick may be reported as just 8pt and incorrectly rejected.
        let p=pagePan.contactTranslation,v=gesture.velocity(in:self)
        switch gesture.state {
        case .began:beginDrag(direction:p.x);if dragging{drag(CGSize(width:p.x,height:p.y),ended:false)}
        case .changed:if dragging{drag(CGSize(width:p.x,height:p.y),ended:false)}
        case .ended:if dragging{
            let release=pagePan.swipeMotion.release(fallbackVelocity:Double(v.x))
            drag(CGSize(width:p.x,height:p.y),ended:true,velocityX:CGFloat(release.velocityX),cancelled:release.reversed,resumeInterrupted:!release.paused)
        }
        case .cancelled,.failed:if dragging{dragging=false;settle(target:dragCancelTarget ?? index)}else{finishContact()}
        default:break
        }
    }
    func beginContact(at point:CGPoint){
        guard canDrag,!PagingRules.edgeStart(x:Double(point.x),width:Double(bounds.width)),animator != nil else{return}
        captureMotion()
    }
    func finishContact(){
        guard !dragging,animator==nil,let target=heldTarget else{return}
        guard canDrag else{cancelMotion();return}
        heldTarget=nil;settle(target:target)
    }
    private func captureMotion(){
        guard let motion=animator else{return}
        let visible=content.layer.presentation()?.affineTransform().tx ?? offset
        let target=settlingTarget
        revision+=1;motion.stopAnimation(true);animator=nil;settlingTarget=nil
        offset=visible;heldTarget=target
        UIView.performWithoutAnimation{content.transform=CGAffineTransform(translationX:visible,y:0)}
    }
    func beginDrag(direction:CGFloat=0){
        guard canDrag else{return}
        captureMotion();dragResumeTarget=heldTarget;heldTarget=nil;dragging=true
        // Rebase to the page nearest the viewport while preserving every visible
        // pixel's screen position. The next gesture can now continue another page.
        let nearest=PagingRules.index(index+Int((-offset/stride).rounded()),count:pages.count)
        dragCancelTarget=nearest
        // A second forward flick counts from the already accepted destination,
        // even before it reaches halfway. Rebase without moving visible pixels;
        // the previous, incoming and next page still fit the same three slots.
        let base:Int
        if let resume=dragResumeTarget,CGFloat(resume-index)*direction<0,
           abs(offset+CGFloat(resume-index)*stride)<=stride{base=resume}else{base=nearest}
        let old=index
        index=base;offset+=CGFloat(base-old)*stride;playbackTarget=nil
        UIView.performWithoutAnimation{
            content.transform=CGAffineTransform(translationX:offset,y:0);render(reset:false);layoutIfNeeded()
        }
        let edge=(index==0 && offset>0)||(index==pages.count-1 && offset<0)
        dragOrigin=edge ? offset/0.18 : offset
        if base != old{select?(base)}
    }
    @objc private func edgeDragged(_ gesture:UIPanGestureRecognizer){
        if gesture.state == .began{cancelMotion()}
        finishEdgeReturn(translation:edgeReturn.contactTranslation,velocity:gesture.velocity(in:self),ended:gesture.state == .ended)
    }
    func finishEdgeReturn(translation:CGPoint,velocity:CGPoint,ended:Bool){
        guard ended,PagingRules.edgeReturns(x:Double(translation.x),y:Double(translation.y),velocityX:Double(velocity.x),width:Double(bounds.width)) else{return}
        cancelMotion();returnToLibrary?()
    }
    func configure(cache:ReadingCache,pages:[Page],index:Int,resetID:Int,pageRevision:UUID?=nil){
        let changedCache=self.cache !== cache
        if changedCache{cancelMotion(restorePlayback:false);stopAnimationPlayback()}
        self.cache=cache
        let changedPages:Bool
        if let pageRevision{changedPages=changedCache || self.pageRevision != pageRevision}
        else{changedPages = !self.pages.elementsEqual(pages,by:{a,b in
            #if DEBUG && targetEnvironment(simulator)
            comparedPageNumbers+=1
            #endif
            return a.number==b.number
        })}
        if changedPages,let number=Int(animationPlayer.key ?? "") {
            let old=self.pages.first{$0.number==number},next=pages.first{$0.number==number}
            if old?.sha256==nil || next==nil || old?.sha256 != next?.sha256 || old?.size != next?.size{stopAnimationPlayback()}
        }
        let changed=changedCache || self.index != index || changedPages
        let reset=lastReset != resetID || changed
        if reset {cancelMotion(restorePlayback:false);zoomed=false}
        self.index=index;if changedPages{self.pages=pages};self.pageRevision=pageRevision;lastReset=resetID
        render(reset:reset)
    }
    override func layoutSubviews(){
        super.layoutSubviews()
        if previousSize != bounds.size {
            previousSize=bounds.size;cancelMotion()
            content.bounds=CGRect(origin:.zero,size:bounds.size);content.center=CGPoint(x:bounds.midX,y:bounds.midY)
            render(reset:true)
        }
    }
    private func render(reset:Bool){
        guard let cache,!pages.isEmpty,pages.indices.contains(index) else{return}
        let wanted=Set(max(0,index-1)..<min(pages.count,index+2))
        for slot in slots where !wanted.contains(slot.position ?? -1){slot.position=nil;slot.isHidden=true;slot.canvas.picture.image=nil}
        for position in wanted.sorted(){
            guard let slot=slots.first(where:{$0.position==position}) ?? slots.first(where:{$0.position==nil}) else{continue}
            let rebound=slot.position != position || reset
            slot.position=position;slot.isHidden=false
            let frame=CGRect(x:CGFloat(position-index)*stride,y:0,width:bounds.width,height:bounds.height)
            if slot.frame != frame{slot.frame=frame}
            let number=pages[position].number
            let playing=position==playbackPosition && animationPlayer.key=="\(number)" && cache.canAnimate
            let image=(playing ? slot.canvas.picture.image : nil) ?? (cache.detailNumber==number ? cache.detailImage : nil) ?? cache.images[number] ?? cache.preparedAnimation(number)?.first.0
            slot.show(number:number,image:image,failed:cache.failed.contains(number),active:position==index,reset:reset,issue:cache.failures[number])
            if rebound {
            slot.onRetry={[weak cache] in cache?.retry(number)}
            slot.canvas.tapped={[weak self] fraction in
                guard let self,self.index==position,self.animator==nil else{return}
                self.toggleControls?()
            }
            slot.canvas.zoomChanged={[weak self] value in
                guard let self,self.index==position else{return}
                self.zoomed=value;if value{self.cancelMotion()};self.zoomChanged?(value)
            }
            }
        }
        updateAnimationPlayback()
    }
    func updateAnimationPlayback(){
        let position=playbackPosition
        guard let cache,pages.indices.contains(position),cache.canAnimate,
              cache.animated.contains(pages[position].number),let slot=slots.first(where:{$0.position==position}),
              slot.canvas.picture.image != nil else{animationPlayer.stop();return}
        let number=pages[position].number
        animationPlayer.play(key:"\(number)",prepared:cache.preparedAnimation(number),prepare:{[weak cache] firstReady in guard let cache else{throw CancellationError()};return try await cache.prepareAnimation(number,firstReady:firstReady)},load:{[weak cache] in guard let cache else{throw CancellationError()};return try await cache.animationData(number)},display:{[weak self,weak slot] image in
            guard let self,let slot,self.playbackPosition==position,slot.position==position,
                  self.pages.indices.contains(position),self.pages[position].number==number else{return}
            // Replace pixels directly; no SwiftUI state, layout or zoom reset per frame.
            slot.canvas.picture.image=image
        },failed:{[weak cache] failure in cache?.animationFailed(failure,number:number)})
    }
    func stopAnimationPlayback(){animationPlayer.stop()}
    func endPresentation(){cancelMotion(restorePlayback:false);stopAnimationPlayback()}
    func drag(_ translation:CGSize,ended:Bool,velocityX:CGFloat=0,cancelled:Bool=false,resumeInterrupted:Bool=true){
        guard canDrag else{return}
        if !dragging{beginDrag(direction:translation.width)}
        let x=dragOrigin+translation.width
        let edge=(index==0 && x>0)||(index==pages.count-1 && x<0)
        offset=edge ? x*0.18 : min(stride,max(-stride,x))
        content.transform=CGAffineTransform(translationX:offset,y:0)
        if ended{
            dragging=false
            #if DEBUG && targetEnvironment(simulator)
            lastPanDistance=translation.width;lastPanVelocity=velocityX
            #endif
            let step=cancelled ? 0 : PagingRules.swipeStep(x:Double(translation.width),y:0,width:Double(bounds.width),velocityX:Double(velocityX))
            var target=step==0 ? (dragCancelTarget ?? index) : PagingRules.index(index+step,count:pages.count)
            // A tiny same-direction catch isn't a request to undo the previous
            // accepted turn. Explicit reversal/hold/cancel still settles here.
            if step==0,!cancelled,resumeInterrupted,let resume=dragResumeTarget,
               CGFloat(resume-(dragCancelTarget ?? index))*translation.width<=0{target=resume}
            settle(target:target,velocityX:velocityX)
        }
    }
    func settle(target:Int,animated:Bool=true,velocityX:CGFloat=0){
        guard !pages.isEmpty else{return}
        captureMotion();heldTarget=nil;dragResumeTarget=nil;dragCancelTarget=nil;dragging=false
        let target=PagingRules.index(target,count:pages.count)
        let destination = -CGFloat(target-index)*stride
        if destination==offset && target==index{playbackTarget=nil;updateAnimationPlayback();return}
        let ticket=revision
        let complete:()->Void = {[weak self] in
            guard let self,self.revision==ticket else{return}
            self.animator=nil;self.settlingTarget=nil
            let changed=self.index != target;self.index=target;self.playbackTarget=nil;self.offset=0
            UIView.performWithoutAnimation{
                self.content.transform = .identity;self.render(reset:changed);self.layoutIfNeeded()
            }
            if changed{self.zoomed=false;self.zoomChanged?(false);self.select?(target)}
        }
        if !animated || UIAccessibility.isReduceMotionEnabled{complete();return}
        var duration=min(0.26,max(0.16,Double(abs(destination-offset)/max(1,stride))*0.26))
        if velocityX.isFinite,(destination-offset)*velocityX>0,abs(velocityX)>650{duration=min(duration,max(0.10,Double(abs(destination-offset)/min(4000,abs(velocityX)))))}
        let motion=UIViewPropertyAnimator(duration:duration,controlPoint1:CGPoint(x:0.22,y:1),controlPoint2:CGPoint(x:0.36,y:1))
        animator=motion;settlingTarget=target
        playbackTarget=target != index ? target : nil;updateAnimationPlayback()
        motion.addAnimations{[weak self] in self?.content.transform=CGAffineTransform(translationX:destination,y:0)}
        motion.addCompletion{_ in complete()}
        motion.startAnimation()
    }
    func cancelMotion(restorePlayback:Bool=true){
        revision+=1;animator?.stopAnimation(true);animator=nil;offset=0;content.transform = .identity
        settlingTarget=nil;heldTarget=nil;dragResumeTarget=nil;dragCancelTarget=nil;dragging=false;dragOrigin=0
        if playbackTarget != nil{playbackTarget=nil;stopAnimationPlayback();if restorePlayback{updateAnimationPlayback()}}
    }
    func dispose(){
        stopAnimationPlayback()
        cancelMotion(restorePlayback:false);cache=nil;select=nil;zoomChanged=nil;toggleControls=nil;returnToLibrary=nil
        for slot in slots {
            slot.canvas.zoomChanged=nil;slot.canvas.tapped=nil
            slot.canvas.picture.image=nil;slot.onRetry=nil
        }
    }
}

// Keep the previous threshold-based edge return. Disable competing system pops
// only while reading; restore their original state when leaving the reader.
final class NativeReaderController:UIViewController {
    let pager=NativeReadingPager()
    private weak var edge:UIGestureRecognizer?
    private var savedEnabled=false
    private weak var contentPop:UIGestureRecognizer?
    private var contentEnabled=false
    var readingChanged:((Bool)->Void)?
    var releaseCache:(()->Void)?
    override func loadView(){view=pager}
    override func viewDidAppear(_ animated:Bool){
        super.viewDidAppear(animated);installEdge();readingChanged?(true)
    }
    override func viewWillDisappear(_ animated:Bool){
        super.viewWillDisappear(animated)
        pager.endPresentation()
    }
    override func viewDidDisappear(_ animated:Bool){
        super.viewDidDisappear(animated)
        if transitionCoordinator?.isCancelled != true{restoreEdge()}
    }
    func installEdge(){
        guard let nav=navigationController,let top=nav.topViewController,
              nav.viewControllers.count>1,let gesture=nav.interactivePopGestureRecognizer else{return}
        var ancestor:UIViewController?=self
        while let current=ancestor,current !== top{ancestor=current.parent}
        guard ancestor === top else{return}
        if edge !== gesture {
            restoreEdge();edge=gesture;savedEnabled=gesture.isEnabled
            if #available(iOS 26.0,*) {
                contentPop=nav.interactiveContentPopGestureRecognizer
                contentEnabled=contentPop?.isEnabled ?? false
            }
        }
        gesture.isEnabled=false;contentPop?.isEnabled=false
        pager.edgeReturn.isEnabled=true
    }
    func restoreEdge(){
        if let edge {
            edge.isEnabled=savedEnabled
        }
        contentPop?.isEnabled=contentEnabled
        edge=nil;contentPop=nil
        pager.edgeReturn.isEnabled=true
    }
    func dispose(){restoreEdge();pager.dispose();releaseCache?();releaseCache=nil;readingChanged=nil}
}

struct ReadingPager:UIViewControllerRepresentable {
    @ObservedObject var cache:ReadingCache
    let pages:[Page]
    let pageRevision:UUID
    @Binding var index:Int
    @Binding var zoomed:Bool
    let resetID:Int
    let toggleControls:()->Void
    let returnToLibrary:()->Void
    let readingChanged:(Bool)->Void
    func makeUIViewController(context:Context)->NativeReaderController{let controller=NativeReaderController();updateUIViewController(controller,context:context);return controller}
    func updateUIViewController(_ controller:NativeReaderController,context:Context){
        let view=controller.pager
        controller.readingChanged=readingChanged;controller.releaseCache={[weak cache] in cache?.clear()}
        view.select={index=$0};view.zoomChanged={zoomed=$0}
        view.toggleControls=toggleControls;view.returnToLibrary=returnToLibrary
        view.configure(cache:cache,pages:pages,index:index,resetID:resetID,pageRevision:pageRevision)
    }
    static func dismantleUIViewController(_ controller:NativeReaderController,coordinator:()){controller.dispose()}
}

// A 44pt hit area: touching anywhere previews the position; release commits once.
// Keep UIKit tracking local, so scrubbing does not initiate network requests.
