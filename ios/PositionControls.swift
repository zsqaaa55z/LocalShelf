import SwiftUI
import UIKit

struct PageJumpSheet:View {
    let title:String,current:Int,count:Int
    let commit:(Int)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var entry=""
    @FocusState private var editing:Bool
    private var target:Int?{PageJumpRules.index(entry,count:count)}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20){
                    Text("当前第 \(current+1) 页，共 \(count) 页").font(.subheadline).foregroundStyle(ShelfTheme.secondary)
                    HStack {
                        Text("页码").foregroundStyle(ShelfTheme.secondary)
                        TextField("输入页码",text:$entry).keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($editing)
                            .font(.title2.weight(.semibold)).monospacedDigit().accessibilityIdentifier("jumpPageInput")
                            // Preserve invalid pasted signs/decimals so validation
                            // rejects them, rather than silently turning -1 into 1.
                            .onChange(of:entry){_,text in if text.count>32{entry=String(text.prefix(32))}}
                            .onSubmit{submit()}
                        if !entry.isEmpty{Button("清空页码",systemImage:"xmark.circle.fill"){entry="";editing=true}
                            .labelStyle(.iconOnly).frame(width:44,height:44).foregroundStyle(ShelfTheme.secondary).accessibilityIdentifier("clearPageJump")}
                    }.padding(16).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:ShelfTheme.corner))
                    if target==nil{Text("请输入 1–\(count) 之间的页码").font(.caption).foregroundStyle(ShelfTheme.secondary)}
                    HStack(spacing:8){
                        ForEach(PageJumpRules.nearby(current:current,count:count),id:\.self){page in
                            Button{entry=String(page+1);editing=false}label:{
                                VStack(spacing:4){Text(page==0 ? "首页":(page==count-1 ? "末页":(page==current ? "当前":"附近"))).font(.caption2);Text("\(page+1)").font(.subheadline.weight(.semibold)).monospacedDigit()}
                                    .frame(maxWidth:.infinity,minHeight:54).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:10))
                            }.buttonStyle(.plain).accessibilityLabel("第 \(page+1) 页").accessibilityIdentifier("jumpShortcut-\(page+1)")
                        }
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).background(ShelfTheme.background)
                .safeAreaInset(edge:.bottom,spacing:0){
                    Button{submit()}label:{Text("跳转").foregroundStyle(target==nil ? ShelfTheme.secondary:Color.black).frame(maxWidth:.infinity,minHeight:44)}.buttonStyle(.borderedProminent)
                        .disabled(target==nil).accessibilityIdentifier("confirmPageJump").padding(20).background(ShelfTheme.background)
                }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}.accessibilityIdentifier("cancelPageJump")}}
        }.tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.primary).preferredColorScheme(.dark)
            .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
            .pageEdgeReturn{dismiss()}
    }
    private func submit(){guard let target else{return};editing=false;commit(target);dismiss()}
}

final class PositionControl:UIControl {
    var vertical=false
    var edgeOverlay=false
    var count=1
    private(set) var value=0
    private(set) var scrubbing=false
    private var initial=0
    var preview:((Int)->Void)?
    var commit:((Int)->Void)?
    var editing:((Bool)->Void)?
    private let rail=CALayer(),fill=CALayer(),thumb=CALayer()
    override init(frame:CGRect){
        super.init(frame:frame);isExclusiveTouch=true;isAccessibilityElement=true;accessibilityTraits=[.adjustable]
        rail.backgroundColor=UIColor(white:0.25,alpha:1).cgColor;fill.backgroundColor=UIColor(red:0.4,green:0.8,blue:0.73,alpha:1).cgColor
        thumb.backgroundColor=UIColor.white.cgColor
        for part in [rail,fill,thumb]{layer.addSublayer(part)}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func setValue(_ value:Int){guard !scrubbing else{return};self.value=PagingRules.index(value,count:count);setNeedsLayout()}
    override func layoutSubviews(){
        super.layoutSubviews()
        let length=max(0,(vertical ? bounds.height : bounds.width)-36)
        let fraction=count>1 ? CGFloat(value)/CGFloat(count-1) : 0
        let point=18+length*fraction
        CATransaction.begin();CATransaction.setDisableActions(true)
        rail.cornerRadius=2;fill.cornerRadius=2;thumb.cornerRadius=9
        if vertical {
            let center=edgeOverlay ? bounds.maxX-7:bounds.midX
            rail.frame=CGRect(x:center-1,y:18,width:2,height:length)
            fill.frame=CGRect(x:center-1,y:18,width:2,height:length*fraction)
            let width:CGFloat=scrubbing ? 8:4
            thumb.frame=CGRect(x:center-width/2,y:point-14,width:width,height:28);thumb.cornerRadius=width/2
        }else{
            rail.frame=CGRect(x:18,y:bounds.midY-2,width:length,height:4)
            fill.frame=CGRect(x:18,y:bounds.midY-2,width:length*fraction,height:4)
            thumb.frame=CGRect(x:point-9,y:bounds.midY-9,width:18,height:18)
        }
        layer.opacity=isEnabled ? 1 : 0.35
        CATransaction.commit()
        accessibilityValue="\(value+1) / \(count)"
    }
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool{
        guard super.point(inside:point,with:event) else{return false}
        // A 44pt-wide thumb target, but unused space passes cover taps through.
        guard edgeOverlay else{return true}
        return scrubbing || point.x>=bounds.maxX-16 || abs(point.y-thumb.frame.midY)<=22
    }
    func begin(at point:CGPoint){
        guard isEnabled,count>1 else{return};initial=value;scrubbing=true;editing?(true);update(at:point)
    }
    func update(at point:CGPoint){
        guard scrubbing else{return}
        value=PagingRules.sliderIndex(position:Double((vertical ? point.y : point.x)-18),length:Double((vertical ? bounds.height : bounds.width)-36),count:count)
        preview?(value);setNeedsLayout()
    }
    func finish(cancelled:Bool){
        guard scrubbing else{return};scrubbing=false
        if cancelled{value=initial;preview?(initial)}else{commit?(value)}
        editing?(false);setNeedsLayout()
    }
    override func beginTracking(_ touch:UITouch,with event:UIEvent?)->Bool{begin(at:touch.location(in:self));return scrubbing}
    override func continueTracking(_ touch:UITouch,with event:UIEvent?)->Bool{update(at:touch.location(in:self));return scrubbing}
    override func endTracking(_ touch:UITouch?,with event:UIEvent?){if let touch{update(at:touch.location(in:self))};finish(cancelled:false)}
    override func cancelTracking(with event:UIEvent?){finish(cancelled:true)}
    private func adjust(_ step:Int){guard isEnabled,count>1 else{return};value=PagingRules.index(value+step,count:count);preview?(value);commit?(value);setNeedsLayout()}
    override func accessibilityIncrement(){adjust(1)}
    override func accessibilityDecrement(){adjust(-1)}
}

struct PositionSlider:UIViewRepresentable {
    @Binding var value:Double
    let count:Int
    var vertical=false
    var edgeOverlay=false
    let label:String
    var editing:(Bool)->Void={_ in}
    let commit:(Int)->Void
    func makeUIView(context:Context)->PositionControl{let view=PositionControl();updateUIView(view,context:context);return view}
    func updateUIView(_ view:PositionControl,context:Context){
        view.vertical=vertical;view.edgeOverlay=edgeOverlay;view.count=max(1,count);view.isEnabled=count>1 && context.environment.isEnabled;view.accessibilityLabel=label
        view.accessibilityIdentifier=edgeOverlay ? "shelfPositionRail":"readerPositionSlider"
        view.preview={value=Double($0)};view.commit=commit;view.editing=editing;view.setValue(Int(value));view.setNeedsLayout()
    }
    static func dismantleUIView(_ view:PositionControl,coordinator:()){view.preview=nil;view.commit=nil;view.editing=nil}
}

// Isolate drag previews from the 50–500-card shelf view's state updates.
struct ShelfPositionRail:View {
    let position:Int,total:Int,enabled:Bool
    let commit:(Int)->Void
    @State private var preview=0.0
    @State private var dragging=false
    var body:some View {
        GeometryReader{geometry in
            PositionSlider(value:$preview,count:total,vertical:true,edgeOverlay:true,label:"本页漫画定位",editing:{dragging=$0},commit:commit)
                .frame(height:max(44,min(300,geometry.size.height-32))).disabled(!enabled)
                .overlay(alignment:.trailing){if dragging{Text("本页 \(Int(preview)+1) / \(total) 本").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(ShelfTheme.accent).padding(12).background(ShelfTheme.surface,in:RoundedRectangle(cornerRadius:12)).fixedSize().offset(x:-44).allowsHitTesting(false)}}
                .frame(maxHeight:.infinity)
        }.frame(width:44)
        .onAppear{preview=Double(position)}
        .onChange(of:position){_,value in if !dragging{preview=Double(value)}}
        .onChange(of:total){_,_ in if !dragging{preview=Double(PagingRules.index(position,count:total))}}
    }
}
