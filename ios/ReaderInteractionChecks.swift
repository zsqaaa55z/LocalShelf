import XCTest

final class ReaderInteractionChecks:XCTestCase {
    func testConnectionDiagnosticEntryCopyAndReturn(){
        continueAfterFailure=false
        // The demo isolates the library and keychain. An invalid address ensures
        // this UI test cannot send diagnostic traffic to any LAN device.
        let app=XCUIApplication();app.launchArguments=["--manual-library-demo"];app.launch()
        XCTAssertTrue(app.cells["shelf-book-1"].waitForExistence(timeout:20))
        app.buttons["shelfSettings"].tap()
        let address=app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:10));address.tap()
        address.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:100)+"invalid-address")
        app.buttons["closeShelfSettings"].tap()
        app.buttons["shelfSettings"].tap()
        let entry=app.buttons["connectionDiagnostics"]
        for _ in 0..<4 {
            if entry.isHittable{break}
            app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.65)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.43)))
        }
        XCTAssertTrue(entry.isHittable);entry.tap()
        XCTAssertTrue(app.staticTexts["地址格式需要调整"].waitForExistence(timeout:10))
        let copy=app.buttons["copyConnectionDiagnostics"]
        XCTAssertTrue(copy.isEnabled);copy.tap()
        XCTAssertEqual(copy.label,"已复制脱敏摘要")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Connection-Diagnostics-Redacted";shot.lifetime = .keepAlways;add(shot)
        app.navigationBars["连接诊断"].buttons["BackButton"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout:5))
        app.buttons["closeShelfSettings"].tap()
        XCTAssertTrue(app.cells["shelf-book-1"].waitForExistence(timeout:10))
    }

    func testManualLibraryTopSwitcher(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--manual-library-demo","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        let switcher=app.segmentedControls["shelfSourceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout:20))
        let first=app.cells["shelf-book-1"]
        XCTAssertTrue(first.waitForExistence(timeout:20))
        func expectTitle(_ value:String){
            let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@",value),object:first)
            XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:15),.completed)
        }
        expectTitle("Eh ·")
        XCTAssertLessThan(switcher.frame.maxY,app.frame.height/3)
        switcher.buttons["手动上传"].tap();expectTitle("手动 ·")
        XCTAssertTrue(switcher.buttons["手动上传"].isSelected)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Manual-Library-Top-Switcher";shot.lifetime = .keepAlways;add(shot)
        app.swipeUp();XCTAssertTrue(switcher.buttons["Eh 同步"].isHittable)
        switcher.buttons["Eh 同步"].tap();expectTitle("Eh ·")
        XCTAssertTrue(switcher.buttons["Eh 同步"].isSelected)
    }
    func testRelaxedRelatedEvidenceAndReturn(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--related-demo","--related-relaxed-demo","-server.selected","nas","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15));first.press(forDuration:0.7)
        app.buttons["查看同系列作品"].tap()
        XCTAssertTrue(app.staticTexts["relatedMatchSummary"].waitForExistence(timeout:10))
        XCTAssertTrue(first.label.contains("作者写法或署名线索相符"))
        let second=app.cells["shelf-book-3"];XCTAssertTrue(second.label.contains("主标题格式或少量文字相近"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Relaxed-Series-Evidence";shot.lifetime = .keepAlways;add(shot)
        second.tap();XCTAssertTrue(app.otherElements["native-reader"].waitForExistence(timeout:8))
        app.buttons["返回同系列作品"].tap();XCTAssertTrue(second.waitForExistence(timeout:8))
        app.navigationBars.buttons.element(boundBy:0).tap();XCTAssertTrue(first.waitForExistence(timeout:8))
        XCTAssertFalse(first.label.contains("待确认"))
        first.press(forDuration:0.7);app.buttons["查看同作者漫画"].tap()
        XCTAssertTrue(app.buttons["relatedNextPage"].waitForExistence(timeout:8));app.buttons["relatedNextPage"].tap()
        let candidate=app.cells["shelf-book-201"];XCTAssertTrue(candidate.waitForExistence(timeout:8))
        XCTAssertTrue(candidate.label.contains("同作品不同语言版本出现不同署名"))
        let authorShot=XCTAttachment(screenshot:app.screenshot());authorShot.name="Relaxed-Author-Evidence";authorShot.lifetime = .keepAlways;add(authorShot)
    }

    func testShelfNumericPageCounts(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        let first=app.cells["shelf-book-1"],sixth=app.cells["shelf-book-6"]
        XCTAssertTrue(first.waitForExistence(timeout:15));XCTAssertTrue(sixth.waitForExistence(timeout:8))
        XCTAssertTrue(first.label.hasSuffix("24 页"));XCTAssertTrue(sixth.label.hasSuffix("1024 页"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Numeric-Page-Count-13pt-Three-Columns";shot.lifetime = .keepAlways;add(shot)
        app.swipeUp();app.swipeDown()
        XCTAssertTrue(first.waitForExistence(timeout:8));XCTAssertTrue(first.label.hasSuffix("24 页"))
        app.buttons["shelfSettings"].tap();let hide=app.buttons["hideAllCovers"]
        XCTAssertTrue(hide.waitForExistence(timeout:5));hide.tap()
        app.buttons["closeShelfSettings"].tap()
        XCTAssertTrue(first.waitForExistence(timeout:8));XCTAssertTrue(first.label.hasSuffix("24 页"))
        XCTAssertEqual(first.value as? String,"封面已隐藏")
    }
    func testReaderSliderTapDragAndButtons(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo"];app.launch()
        let page=app.buttons["readerPageJump"]
        XCTAssertTrue(page.waitForExistence(timeout:12))
        let reader=app.otherElements["native-reader"]
        func expectPage(_ index:Int){
            let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","page=\(index)"),object:reader)
            XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:5),.completed)
        }
        let slider=app.descendants(matching:.any).matching(identifier:"readerPositionSlider").firstMatch;XCTAssertTrue(slider.waitForExistence(timeout:5))
        slider.coordinate(withNormalizedOffset:CGVector(dx:0,dy:0.5)).tap();expectPage(0)
        let frame=reader.frame
        slider.coordinate(withNormalizedOffset:CGVector(dx:0.1,dy:0.5)).press(forDuration:0.5,thenDragTo:slider.coordinate(withNormalizedOffset:CGVector(dx:1,dy:0.5)))
        expectPage(2)
        XCTAssertEqual(reader.frame,frame)
        app.buttons["上一页"].tap();expectPage(1)
        app.buttons["下一页"].tap();expectPage(2)
        slider.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap();expectPage(1)
    }
    func testExpandedRelatedEvidenceAndReaderReturn(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--related-demo","--related-expanded-demo","-server.selected","nas","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15));first.press(forDuration:0.7)
        app.buttons["查看同系列作品"].tap()
        XCTAssertTrue(app.staticTexts["relatedMatchSummary"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["relatedMatchSummary"].label.contains("102 本可能匹配"))
        XCTAssertTrue(first.label.contains("同作不同版本"))
        let second=app.cells["shelf-book-3"];XCTAssertTrue(second.label.contains("副标题关联"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Expanded-Series-Evidence";shot.lifetime = .keepAlways;add(shot)
        second.tap();XCTAssertTrue(app.otherElements["native-reader"].waitForExistence(timeout:8))
        app.buttons["返回同系列作品"].tap();XCTAssertTrue(second.waitForExistence(timeout:8))
        app.buttons["relatedNextPage"].tap();XCTAssertTrue(app.cells["shelf-book-201"].waitForExistence(timeout:8))
        app.navigationBars.buttons.element(boundBy:0).tap();XCTAssertTrue(first.waitForExistence(timeout:8))
        XCTAssertFalse(first.label.contains("同作不同版本"))
        first.press(forDuration:0.7);app.buttons["查看同作者漫画"].tap()
        XCTAssertTrue(app.buttons["relatedNextPage"].waitForExistence(timeout:8));app.buttons["relatedNextPage"].tap()
        let circle=app.cells["shelf-book-201"];XCTAssertTrue(circle.waitForExistence(timeout:8))
        XCTAssertTrue(circle.label.contains("同社团，作者待确认"))
        let circleShot=XCTAttachment(screenshot:app.screenshot());circleShot.name="Expanded-Circle-Evidence";circleShot.lifetime = .keepAlways;add(circleShot)
    }
    func testRelatedPossibleEvidenceAndReuse(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--related-demo","--related-possible-demo","-server.selected","nas","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15));first.press(forDuration:0.7)
        app.buttons["查看同作者漫画"].tap()
        XCTAssertTrue(app.staticTexts["relatedMatchSummary"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["relatedMatchSummary"].label.contains("12 本可能匹配"))
        app.buttons["relatedNextPage"].tap()
        let candidate=app.cells["shelf-book-201"];XCTAssertTrue(candidate.waitForExistence(timeout:8))
        XCTAssertTrue(candidate.label.contains("可能匹配"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Related-Possible-Evidence";shot.lifetime = .keepAlways;add(shot)
        app.buttons["relatedPreviousPage"].tap();XCTAssertTrue(first.waitForExistence(timeout:8))
        XCTAssertFalse(first.label.contains("可能匹配"))
    }
    func testRelatedAuthorReaderAndReturn(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--related-demo","-server.selected","nas","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15))
        first.press(forDuration:0.7)
        let action=app.buttons["查看同作者漫画"];XCTAssertTrue(action.waitForExistence(timeout:5));action.tap()
        XCTAssertTrue(app.buttons["relatedNextPage"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["102 本 · 按下载顺序"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Related-Author-Grid";shot.lifetime = .keepAlways;add(shot)
        app.buttons["relatedPageMenu"].tap()
        let pageOne=app.buttons["第 1 页"],pageTwo=app.buttons["第 2 页"]
        XCTAssertTrue(pageOne.waitForExistence(timeout:5));XCTAssertTrue(pageTwo.isHittable)
        XCTAssertGreaterThan(pageOne.frame.minY,pageTwo.frame.minY)
        pageTwo.tap();let tail=app.cells["shelf-book-201"]
        XCTAssertTrue(tail.waitForExistence(timeout:8));tail.tap()
        XCTAssertTrue(app.otherElements["native-reader"].waitForExistence(timeout:8))
        app.buttons["返回同作者漫画"].tap()
        XCTAssertTrue(tail.waitForExistence(timeout:8));XCTAssertTrue(app.buttons["relatedPageMenu"].label.contains("2 / 2"))
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(first.waitForExistence(timeout:8));XCTAssertTrue(app.buttons["shelfPageMenu"].label.contains("1 / 101"))
    }
    func testRelatedSeriesAndHiddenCovers(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--related-demo","-server.selected","nas","-shelf.columns","3","-shelf.hideCovers","YES"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15));first.press(forDuration:0.7)
        app.buttons["查看同系列作品"].tap()
        XCTAssertTrue(app.buttons["relatedNextPage"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["夜空"].exists)
        XCTAssertEqual(app.cells["shelf-book-1"].value as? String,"封面已隐藏")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Related-Series-Hidden";shot.lifetime = .keepAlways;add(shot)
        let window=app.windows.firstMatch
        window.coordinate(withNormalizedOffset:CGVector(dx:0.015,dy:0.5)).press(forDuration:0.1,thenDragTo:window.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.5)))
        XCTAssertTrue(app.buttons["shelfPageMenu"].waitForExistence(timeout:8))
    }
    private func openAdvanced(_ app:XCUIApplication){
        let button=app.buttons["advancedSettings"]
        for _ in 0..<8{if button.isHittable{break};app.swipeUp()}
        XCTAssertTrue(button.isHittable);button.tap()
        XCTAssertTrue(app.buttons["closeAdvancedSettings"].waitForExistence(timeout:5))
    }
    func testShelfPageMenuStartsAtPageOne(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15))
        func openMenu(_ name:String){
            app.buttons["shelfPageMenu"].tap()
            let one=app.buttons["第 1 页"],two=app.buttons["第 2 页"],three=app.buttons["第 3 页"]
            XCTAssertTrue(one.waitForExistence(timeout:5));XCTAssertTrue(one.isHittable,"page 1 must be visible without scrolling")
            XCTAssertTrue(two.isHittable);XCTAssertTrue(three.isHittable)
            XCTAssertGreaterThan(one.frame.minY,two.frame.minY,"page 1 is below page 2")
            XCTAssertGreaterThan(two.frame.minY,three.frame.minY,"page 2 is below page 3")
            XCTAssertFalse(app.textFields["jumpPageInput"].exists,"shelf keeps its original native menu")
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)
        }
        for size in [500,100,50]{
            if size != 500{app.buttons["shelfLayout"].tap();app.buttons["\(size) 本 / 页"].tap()}
            let count=(10071+size-1)/size
            XCTAssertTrue(app.buttons["shelfPageMenu"].label.contains("1 / \(count)"))
            openMenu("Page-Menu-\(count)-Pages")
            app.buttons["第 2 页"].tap()
            XCTAssertTrue(app.cells["shelf-book-\(size+1)"].waitForExistence(timeout:8))
            XCTAssertTrue(app.buttons["shelfPageMenu"].label.contains("2 / \(count)"))
            app.buttons["shelfNextPage"].tap();XCTAssertTrue(app.cells["shelf-book-\(size*2+1)"].waitForExistence(timeout:8))
            app.buttons["shelfPreviousPage"].tap();XCTAssertTrue(app.cells["shelf-book-\(size+1)"].waitForExistence(timeout:8))
            openMenu("Page-Menu-Reopen-\(count)-Pages")
            app.buttons["第 1 页"].tap();XCTAssertTrue(first.waitForExistence(timeout:8))
            XCTAssertFalse(app.buttons["shelfPreviousPage"].isEnabled)
            XCTAssertTrue(app.cells["shelf-book-2"].isHittable,"book order is not reversed with the menu")
        }
    }
    func testReaderPageJumpPanel(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:15));first.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:8))
        app.buttons["readerPageJump"].tap();let input=app.textFields["jumpPageInput"];XCTAssertTrue(input.waitForExistence(timeout:5))
        input.tap();input.typeText("999")
        XCTAssertEqual(input.value as? String,"999")
        XCTAssertFalse(app.buttons["confirmPageJump"].isEnabled)
        app.buttons["clearPageJump"].tap();input.typeText("2")
        XCTAssertEqual(input.value as? String,"2");XCTAssertTrue(app.buttons["confirmPageJump"].isEnabled)
        let keyboard=XCTAttachment(screenshot:app.screenshot());keyboard.name="Reader-Jump-Keyboard";keyboard.lifetime = .keepAlways;add(keyboard)
        app.buttons["confirmPageJump"].tap()
        let afterJump=XCTAttachment(screenshot:app.screenshot());afterJump.name="Reader-After-Jump";afterJump.lifetime = .keepAlways;add(afterJump)
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","page=1"),object:reader)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:5),.completed)
        XCTAssertFalse(app.staticTexts["readerOriginalPage"].exists,"continuous original numbers need no duplicate subtitle")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Compact-Reader";shot.lifetime = .keepAlways;add(shot)
    }
    func testAdvancedSettingsWithoutFeedback(){
        continueAfterFailure=false
        // A previously enabled preference must not restore the removed feature.
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","-interface.haptics","YES"];app.launch()
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:15));app.buttons["shelfSettings"].tap()
        XCTAssertTrue(app.buttons["hideAllCovers"].waitForExistence(timeout:5))
        XCTAssertFalse(app.switches["interfaceHaptics"].exists);XCTAssertFalse(app.staticTexts["轻触反馈"].exists)
        let main=XCTAttachment(screenshot:app.screenshot());main.name="Common-Settings";main.lifetime = .keepAlways;add(main)
        XCTAssertFalse(app.buttons["recordInteraction"].exists)
        openAdvanced(app);XCTAssertTrue(app.buttons["recordInteraction"].exists)
        XCTAssertFalse(app.switches["interfaceHaptics"].exists);XCTAssertFalse(app.staticTexts["轻触反馈"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Advanced-Settings";shot.lifetime = .keepAlways;add(shot)
        let window=app.windows.firstMatch
        window.coordinate(withNormalizedOffset:CGVector(dx:0.025,dy:0.5)).press(forDuration:0.05,thenDragTo:window.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.5)))
        XCTAssertTrue(app.buttons["advancedSettings"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["recordInteraction"].exists)
        app.buttons["closeShelfSettings"].tap();app.terminate();app.launch();app.buttons["shelfSettings"].tap()
        XCTAssertTrue(app.buttons["hideAllCovers"].waitForExistence(timeout:5))
        XCTAssertFalse(app.switches["interfaceHaptics"].exists);XCTAssertFalse(app.staticTexts["轻触反馈"].exists)
    }
    func testColdStartPlaceholderToCatalog(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--cold-start-demo","-server.selected","nas","-shelf.columns","3","-shelf.hideCovers","NO"];app.launch()
        XCTAssertTrue(app.staticTexts["正在恢复书库…"].waitForExistence(timeout:2))
        XCTAssertFalse(app.buttons["连接与配对"].exists)
        let loading=XCTAttachment(screenshot:app.screenshot());loading.name="Cold-Start-Placeholder";loading.lifetime = .keepAlways;add(loading)
        XCTAssertTrue(app.cells["shelf-book-2"].waitForExistence(timeout:12))
        XCTAssertFalse(app.staticTexts["正在恢复书库…"].exists)
        XCTAssertTrue(app.buttons["connectionStatus"].label.contains("已连接"))
        let ready=XCTAttachment(screenshot:app.screenshot());ready.name="Cold-Start-Ready";ready.lifetime = .keepAlways;add(ready)
    }
    func testColdStartFailureDoesNotStick(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--cold-start-demo","--cold-start-error","-server.selected","nas"];app.launch()
        XCTAssertTrue(app.staticTexts["书库暂时无法更新"].waitForExistence(timeout:12))
        XCTAssertFalse(app.staticTexts["正在恢复书库…"].exists)
        XCTAssertTrue(app.buttons["连接设置"].isHittable)
    }
    func testNASLocalCatalogPreviewAndSettings(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--nas-cache-demo","-server.selected","nas","-shelf.hideCovers","NO","-shelf.columns","3"];app.launch()
        XCTAssertTrue(app.buttons["connectionStatus"].waitForExistence(timeout:15))
        XCTAssertTrue(app.buttons["connectionStatus"].label.contains("目录预览"))
        let book=app.cells["shelf-book-2"]
        XCTAssertTrue(book.waitForExistence(timeout:8))
        let first=XCTAttachment(screenshot:app.screenshot());first.name="NAS-Cached-Catalog-Preview";first.lifetime = .keepAlways;add(first)
        book.tap();XCTAssertFalse(app.otherElements["native-reader"].exists)
        XCTAssertTrue(app.buttons["connectionStatus"].label.contains("目录预览"))
        app.buttons["shelfNextPage"].tap()
        XCTAssertTrue(app.cells["shelf-book-101"].waitForExistence(timeout:8))
        XCTAssertTrue(app.buttons["shelfPageMenu"].label.contains("2 / 6"))
        app.buttons["shelfSettings"].tap()
        openAdvanced(app)
        let update=app.buttons["refreshLocalCatalog"]
        for _ in 0..<8{if update.exists && update.isHittable{break};app.swipeUp()}
        XCTAssertTrue(update.exists);XCTAssertFalse(update.isEnabled)
        XCTAssertTrue(app.staticTexts["localCatalogStatus"].exists)
        let settings=XCTAttachment(screenshot:app.screenshot());settings.name="NAS-Cached-Catalog-Settings";settings.lifetime = .keepAlways;add(settings)
        app.buttons["closeAdvancedSettings"].tap();app.buttons["closeShelfSettings"].tap()
        XCTAssertTrue(app.buttons["connectionStatus"].label.contains("目录预览"))
    }
    func testEdgeReturnAcrossSettingsAndScanner(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","--edge-return-demo"];app.launch()
        XCTAssertTrue(app.buttons["shelfNextPage"].waitForExistence(timeout:15));app.buttons["shelfNextPage"].tap()
        XCTAssertTrue(app.cells["shelf-book-501"].waitForExistence(timeout:8))
        let original=app.buttons["shelfPageMenu"].label
        func drag(_ x:CGFloat,_ y:CGFloat,_ endX:CGFloat,_ endY:CGFloat){
            let window=app.windows.firstMatch
            window.coordinate(withNormalizedOffset:CGVector(dx:x,dy:y)).press(forDuration:0.05,thenDragTo:window.coordinate(withNormalizedOffset:CGVector(dx:endX,dy:endY)))
        }
        // The shelf is a root, not a previous-page shortcut or an app exit.
        drag(0.025,0.5,0.45,0.5);XCTAssertEqual(app.buttons["shelfPageMenu"].label,original)
        app.buttons["shelfSettings"].tap()
        XCTAssertTrue(app.buttons["closeShelfSettings"].waitForExistence(timeout:5))
        drag(0.35,0.5,0.75,0.5);XCTAssertTrue(app.buttons["closeShelfSettings"].exists)
        drag(0.025,0.7,0.025,0.35);XCTAssertTrue(app.buttons["closeShelfSettings"].exists)
        drag(0.025,0.5,0.45,0.5)
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["closeShelfSettings"].exists)
        XCTAssertEqual(app.buttons["shelfPageMenu"].label,original)
        app.buttons["shelfSettings"].tap()
        let scan=app.buttons["扫码连接安卓"]
        for _ in 0..<5{if scan.exists && scan.isHittable{break};app.swipeUp()}
        XCTAssertTrue(scan.waitForExistence(timeout:5));scan.tap()
        XCTAssertTrue(app.navigationBars["扫描安卓配对码"].waitForExistence(timeout:5))
        drag(0.025,0.5,0.45,0.5)
        XCTAssertTrue(app.buttons["closeShelfSettings"].waitForExistence(timeout:5));XCTAssertFalse(app.navigationBars["扫描安卓配对码"].exists)
        // Only the top page closes; the same recognizer works after returning.
        drag(0.025,0.5,0.45,0.5)
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["closeShelfSettings"].exists)
        XCTAssertEqual(app.buttons["shelfPageMenu"].label,original)
    }
    func testEdgeReturnDoesNotDismissConfirmation(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:15));app.buttons["shelfSettings"].tap()
        let reset=app.buttons["resetReadingProgress"]
        for _ in 0..<7{if reset.exists && reset.isHittable{break};app.swipeUp()}
        reset.tap();XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:5))
        let window=app.windows.firstMatch
        window.coordinate(withNormalizedOffset:CGVector(dx:0.025,dy:0.25)).press(forDuration:0.05,thenDragTo:window.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.25)))
        XCTAssertTrue(app.alerts.firstMatch.exists);app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["closeShelfSettings"].exists)
        window.coordinate(withNormalizedOffset:CGVector(dx:0.025,dy:0.5)).press(forDuration:0.05,thenDragTo:window.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.5)))
        XCTAssertFalse(app.buttons["closeShelfSettings"].exists)
    }
    func testServerProfilesAndProgressTools(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:15));app.buttons["shelfSettings"].tap()
        let nas=app.buttons["NAS 书库"]
        for _ in 0..<4{if nas.exists && nas.isHittable{break};app.swipeUp()}
        XCTAssertTrue(nas.waitForExistence(timeout:5));nas.tap()
        let address=app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5));XCTAssertTrue(address.placeholderValue?.contains("8089")==true)
        XCTAssertTrue(app.secureTextFields["nasPassword"].exists)
        XCTAssertTrue(app.buttons["connectNASPassword"].exists)
        XCTAssertFalse(app.buttons["connectNASPassword"].isEnabled)
        XCTAssertFalse(app.secureTextFields["6 位数字配对码"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="NAS-Server-Settings";shot.lifetime = .keepAlways;add(shot)
        func checkResetOnly() {
            let reset=app.buttons["resetReadingProgress"]
            for _ in 0..<6{if reset.exists && reset.isHittable{break};app.swipeUp()}
            XCTAssertTrue(reset.waitForExistence(timeout:5));XCTAssertTrue(reset.isHittable)
            XCTAssertFalse(app.buttons["exportReadingProgress"].exists)
            XCTAssertFalse(app.buttons["从备份恢复（不覆盖已有进度）"].exists)
            XCTAssertFalse(app.buttons["migrateReadingProgress"].exists)
        }
        checkResetOnly()
        let compact=XCTAttachment(screenshot:app.screenshot());compact.name="Reading-Progress-Reset-Only";compact.lifetime = .keepAlways;add(compact)
        let android=app.buttons["安卓桥接"]
        for _ in 0..<7{if android.exists && android.isHittable{break};app.swipeDown()}
        XCTAssertTrue(android.isHittable);android.tap();checkResetOnly()
    }
    func testLocateRecentReadingAtDifferentPageSizes(){
        continueAfterFailure=false
        // This fixture emulates the Android catalog, not NAS position endpoints.
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","-server.selected","android"];app.launch()
        XCTAssertTrue(app.buttons["shelfNextPage"].waitForExistence(timeout:15));app.buttons["shelfNextPage"].tap()
        let target=app.cells["shelf-book-501"]
        XCTAssertTrue(target.waitForExistence(timeout:8));target.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:8))
        expectation(for:NSPredicate(format:"value CONTAINS %@","image=true"),evaluatedWith:reader);waitForExpectations(timeout:8)
        app.buttons["返回书库"].tap();app.buttons["shelfPreviousPage"].tap()
        let locate=app.buttons["locateRecentReading"];XCTAssertTrue(locate.waitForExistence(timeout:8));locate.tap()
        XCTAssertTrue(target.waitForExistence(timeout:10));XCTAssertTrue(target.isHittable)
        XCTAssertFalse(reader.exists);XCTAssertTrue(app.cells["shelf-book-502"].isHittable)
        app.buttons["shelfPreviousPage"].tap()
        app.buttons["shelfLayout"].tap();app.buttons["50 本 / 页"].tap()
        let first=app.cells["shelf-book-1"];XCTAssertTrue(first.waitForExistence(timeout:8))
        locate.tap();XCTAssertTrue(target.waitForExistence(timeout:10));XCTAssertTrue(target.isHittable)
        XCTAssertTrue(app.buttons["shelfPageMenu"].label.contains("11 /"))
        XCTAssertTrue(app.cells["shelf-book-502"].isHittable)
        Thread.sleep(forTimeInterval:0.8)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Located-Recent-Book";shot.lifetime = .keepAlways;add(shot)
    }
    func testContinueReadingAcrossPagesAndRelaunch(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let book=app.cells["shelf-book-1"]
        XCTAssertTrue(book.waitForExistence(timeout:15));book.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<4{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        app.buttons["下一页"].tap();app.buttons["返回书库"].tap()
        let resume=app.buttons["continueReading"]
        XCTAssertTrue(resume.waitForExistence(timeout:8));XCTAssertTrue(resume.isEnabled)
        XCTAssertTrue(resume.label.contains("第 1 本"));XCTAssertTrue((resume.value as? String ?? "").contains("第 2 页"))
        app.buttons["shelfNextPage"].tap()
        XCTAssertTrue(app.cells["shelf-book-501"].waitForExistence(timeout:8))
        let pageLabel=app.buttons["shelfPageMenu"].label
        resume.tap();XCTAssertTrue(reader.waitForExistence(timeout:8))
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=1"),evaluatedWith:reader);waitForExpectations(timeout:8)
        app.buttons["返回书库"].tap();XCTAssertEqual(app.buttons["shelfPageMenu"].label,pageLabel)
        XCTAssertTrue(app.cells["shelf-book-501"].isHittable)
        app.terminate();app.launch()
        XCTAssertTrue(resume.waitForExistence(timeout:15));XCTAssertTrue(resume.label.contains("第 1 本"))
        resume.tap();XCTAssertTrue(reader.waitForExistence(timeout:8))
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=1"),evaluatedWith:reader);waitForExpectations(timeout:8)
        app.buttons["返回书库"].tap()
        // Let the navigation transition finish before taking a visual artifact.
        Thread.sleep(forTimeInterval:0.8)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Continue-Reading";shot.lifetime = .keepAlways;add(shot)
    }
    func testContinueReadingPrivacyAndReset(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let book=app.cells["shelf-book-1"];XCTAssertTrue(book.waitForExistence(timeout:15));book.tap()
        XCTAssertTrue(app.buttons["返回书库"].waitForExistence(timeout:8));app.buttons["返回书库"].tap()
        app.buttons["shelfSettings"].tap()
        let hide=app.buttons["hideAllCovers"];if hide.value as? String != "1"{hide.tap()}
        app.buttons["closeShelfSettings"].tap()
        let resume=app.buttons["continueReading"]
        XCTAssertTrue((resume.value as? String ?? "").contains("封面已隐藏"));XCTAssertTrue(resume.isEnabled)
        Thread.sleep(forTimeInterval:0.8)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Continue-Reading-Hidden";shot.lifetime = .keepAlways;add(shot)
        app.buttons["shelfSettings"].tap()
        hide.tap()
        let reset=app.buttons["resetReadingProgress"]
        for _ in 0..<6{if reset.exists && reset.isHittable{break};app.swipeUp()}
        reset.tap();app.buttons["取消"].tap();app.buttons["closeShelfSettings"].tap();XCTAssertTrue(resume.isEnabled)
        app.buttons["shelfSettings"].tap()
        for _ in 0..<6{if reset.exists && reset.isHittable{break};app.swipeUp()}
        reset.tap();app.buttons["确认重置所有进度"].tap();app.buttons["closeShelfSettings"].tap()
        XCTAssertFalse(resume.exists,"no empty continue-reading card after reset")
        app.terminate();app.launch();XCTAssertTrue(book.waitForExistence(timeout:15));XCTAssertFalse(resume.exists)
        book.tap();XCTAssertTrue(app.otherElements["native-reader"].waitForExistence(timeout:8))
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=0"),evaluatedWith:app.otherElements["native-reader"]);waitForExpectations(timeout:8)
    }
    func testBuiltInInteractionProfile(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","-experiment.nativeGrid","NO","-experiment.systemPager","YES"];app.launch()
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:15));app.buttons["shelfSettings"].tap()
        XCTAssertFalse(app.switches["nativeGridOption"].exists)
        XCTAssertFalse(app.switches["systemPagerOption"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Selected-Interaction-Profile";shot.lifetime = .keepAlways;add(shot)
        app.buttons["closeShelfSettings"].tap()
        let rail=app.descendants(matching:.any).matching(identifier:"shelfPositionRail").firstMatch
        rail.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.98)).tap()
        expectation(for:NSPredicate(format:"value == %@","500 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        rail.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.02)).tap()
        expectation(for:NSPredicate(format:"value == %@","1 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        let book=app.descendants(matching:.any).matching(identifier:"shelf-book-1").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout:10));let y=book.frame.minY;book.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        XCTAssertTrue((reader.value as? String ?? "").contains("native=false"),"Selected combination keeps original pager")
        for _ in 0..<4{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        reader.swipeLeft()
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=1"),evaluatedWith:reader);waitForExpectations(timeout:8)
        app.buttons["返回书库"].tap();XCTAssertTrue(book.waitForExistence(timeout:8));XCTAssertEqual(book.frame.minY,y,accuracy:3)
    }
    func testAnimationSwipeSwitching(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--animation-demo"];app.launch()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<3{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        func state(_ text:String){expectation(for:NSPredicate(format:"value CONTAINS %@",text),evaluatedWith:reader);waitForExpectations(timeout:8)}
        state("anim=1");reader.swipeLeft();state("anim=2")
        app.buttons["暂停动图"].tap();state("anim=none")
        app.buttons["播放动图"].tap();state("anim=2")
        reader.swipeRight();state("anim=1");state("zoom=100")
    }
    func testInteractionRecording(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:15));app.buttons["shelfSettings"].tap()
        openAdvanced(app)
        app.buttons["recordInteraction"].tap()
        XCTAssertFalse(app.buttons["closeShelfSettings"].exists)
        app.collectionViews.firstMatch.swipeUp();app.collectionViews.firstMatch.swipeDown()
        app.buttons["shelfSettings"].tap()
        openAdvanced(app)
        let report=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","P95")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout:20))
        XCTAssertTrue(report.label.contains("非 GPU 实际呈现帧率"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Interaction-Meter-Simulator-Not-FPS";shot.lifetime = .keepAlways;add(shot)
    }
    func testHiddenCoversPersistAndRestore(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        XCTAssertTrue(app.buttons["shelfSettings"].waitForExistence(timeout:15));app.buttons["shelfSettings"].tap()
        let toggle=app.buttons["hideAllCovers"];XCTAssertTrue(toggle.waitForExistence(timeout:5))
        if toggle.value as? String != "1"{toggle.tap()}
        XCTAssertEqual(toggle.value as? String,"1")
        app.buttons["closeShelfSettings"].tap()
        let book=app.cells["shelf-book-1"]
        expectation(for:NSPredicate(format:"value == %@","封面已隐藏"),evaluatedWith:book);waitForExpectations(timeout:5)
        app.terminate();app.launch()
        XCTAssertTrue(book.waitForExistence(timeout:15));XCTAssertEqual(book.value as? String,"封面已隐藏")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Hidden-Covers";shot.lifetime = .keepAlways;add(shot)
        app.buttons["shelfSettings"].tap();XCTAssertEqual(toggle.value as? String,"1")
        toggle.tap();app.buttons["closeShelfSettings"].tap()
        XCTAssertNotEqual(book.value as? String,"封面已隐藏")
    }
    func testUIKitShelfReadingRoundTrip(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let rail=app.descendants(matching:.any).matching(identifier:"shelfPositionRail").firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout:15))
        rail.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.98)).tap()
        expectation(for:NSPredicate(format:"value == %@","500 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        rail.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.02)).tap()
        let book=app.descendants(matching:.any).matching(identifier:"shelf-book-1").firstMatch
        expectation(for:NSPredicate(format:"value == %@","1 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        XCTAssertTrue(book.waitForExistence(timeout:10));XCTAssertTrue(book.isHittable)
        let y=book.frame.minY
        book.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<5{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        reader.swipeLeft()
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=1"),evaluatedWith:reader);waitForExpectations(timeout:8)
        reader.swipeRight()
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=0"),evaluatedWith:reader);waitForExpectations(timeout:8)
        app.buttons["下一页"].tap()
        expectation(for:NSPredicate(format:"value CONTAINS %@","page=1"),evaluatedWith:reader);waitForExpectations(timeout:8)
        let start=reader.coordinate(withNormalizedOffset:CGVector(dx:0.025,dy:0.5)),end=reader.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.51))
        start.press(forDuration:0.05,thenDragTo:end)
        XCTAssertTrue(book.waitForExistence(timeout:8));XCTAssertTrue(book.isHittable);XCTAssertEqual(book.frame.minY,y,accuracy:3)
        expectation(for:NSPredicate(format:"value == %@","1 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="UIKit-Grid";shot.lifetime = .keepAlways;add(shot)
    }
    func testCurrentPageRailScrollAndTouch(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let rail=app.descendants(matching:.any).matching(identifier:"shelfPositionRail").firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout:15))
        XCTAssertEqual(rail.value as? String,"1 / 500")
        let scroll=app.collectionViews.firstMatch
        scroll.swipeUp();scroll.swipeUp()
        XCTAssertNotEqual(rail.value as? String,"1 / 500","Finger scrolling updates page-local position")
        let pager=app.buttons["shelfPageMenu"],page=pager.label
        rail.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.98)).tap()
        expectation(for:NSPredicate(format:"value == %@","500 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        XCTAssertEqual(pager.label,page,"Rail does not change pagination")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Shelf-Local-Rail-Bottom";shot.lifetime = .keepAlways;add(shot)
        rail.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.02)).tap()
        expectation(for:NSPredicate(format:"value == %@","1 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        app.buttons["shelfNextPage"].tap()
        expectation(for:NSPredicate(format:"value == %@","1 / 500"),evaluatedWith:rail);waitForExpectations(timeout:8)
        XCTAssertNotEqual(pager.label,page)
        let book=app.cells["shelf-book-501"]
        XCTAssertTrue(book.waitForExistence(timeout:10));XCTAssertTrue(book.isHittable)
    }
    func testOrderNoticeOnlyInSettings(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","--order-notice-demo"];app.launch()
        let book=app.cells["shelf-book-1"]
        XCTAssertTrue(book.waitForExistence(timeout:15));XCTAssertTrue(book.isHittable)
        XCTAssertFalse(app.staticTexts["列表同值位置待核对"].exists)
        XCTAssertFalse(app.staticTexts["libraryOrderNotice"].exists)
        app.buttons["shelfSettings"].tap()
        openAdvanced(app)
        let notice=app.staticTexts["libraryOrderNotice"]
        for _ in 0..<5{if notice.exists && notice.isHittable{break};app.swipeUp()}
        XCTAssertTrue(notice.exists);XCTAssertTrue(notice.isHittable)
        XCTAssertTrue(notice.label.contains("同值记录位置待核对"))
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Library-Explanation";screenshot.lifetime = .keepAlways;add(screenshot)
        app.buttons["closeAdvancedSettings"].tap();app.buttons["closeShelfSettings"].tap()
        XCTAssertTrue(book.isHittable);XCTAssertFalse(notice.exists)
        app.buttons["refreshCatalog"].tap()
        XCTAssertTrue(book.waitForExistence(timeout:10));XCTAssertFalse(app.staticTexts["列表同值位置待核对"].exists)
    }
    func testRefreshPageListKeepsPosition(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo"];app.launch()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<3{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        app.buttons["下一页"].tap()
        let refresh=app.buttons["readerOptions"];XCTAssertTrue(refresh.waitForExistence(timeout:5));refresh.tap();app.buttons["refreshPageList"].tap()
        expectation(for:NSPredicate(format:"value == %@","已刷新1次"),evaluatedWith:refresh);waitForExpectations(timeout:10)
        XCTAssertTrue(NSPredicate(format:"value CONTAINS %@","page=1").evaluate(with:reader))
        XCTAssertTrue(NSPredicate(format:"value CONTAINS %@","image=true").evaluate(with:reader))
    }
    func testPageFailureDoesNotRefreshWholeBook(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo","--fail-page-image"];app.launch()
        let refresh=app.buttons["readerOptions"];XCTAssertTrue(refresh.waitForExistence(timeout:10))
        expectation(for:NSPredicate(format:"value == %@","已刷新0次"),evaluatedWith:refresh);waitForExpectations(timeout:10)
        let repeated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value != %@","已刷新0次"),object:refresh);repeated.isInverted=true
        XCTAssertEqual(XCTWaiter.wait(for:[repeated],timeout:3),.completed,"Failed page must not cause an endless directory refresh")
        refresh.tap();app.buttons["refreshPageList"].tap();expectation(for:NSPredicate(format:"value == %@","已刷新1次"),evaluatedWith:refresh);waitForExpectations(timeout:10)
    }
    func testChangedPageRefreshesOnlyOnce(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo","--changed-page-image"];app.launch()
        let refresh=app.buttons["readerOptions"];XCTAssertTrue(refresh.waitForExistence(timeout:10))
        expectation(for:NSPredicate(format:"value == %@","已刷新1次"),evaluatedWith:refresh);waitForExpectations(timeout:10)
        let repeated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","已刷新2次"),object:refresh);repeated.isInverted=true
        XCTAssertEqual(XCTWaiter.wait(for:[repeated],timeout:3),.completed,"Content conflict gets only one automatic manifest refresh per page")
    }
    func testRefreshCatalogControl(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let refresh=app.buttons["refreshCatalog"]
        XCTAssertTrue(refresh.waitForExistence(timeout:15));XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        let book=app.cells["shelf-book-1"]
        XCTAssertTrue(book.waitForExistence(timeout:10));XCTAssertTrue(refresh.isEnabled)
        book.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        app.buttons["返回书库"].tap()
        XCTAssertTrue(refresh.waitForExistence(timeout:10));XCTAssertTrue(book.isHittable)
    }
    func testResetProgressConfirmation(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let book=app.cells["shelf-book-1"]
        XCTAssertTrue(book.waitForExistence(timeout:15))
        book.tap()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<5{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        app.buttons["下一页"].tap()
        app.buttons["返回书库"].tap()
        app.buttons["shelfSettings"].tap()
        let reset=app.buttons["resetReadingProgress"]
        func revealReset(){for _ in 0..<6{if reset.exists && reset.isHittable{return};app.swipeUp()}}
        revealReset();XCTAssertTrue(reset.waitForExistence(timeout:5));reset.tap()
        app.buttons["取消"].tap()
        app.buttons["closeShelfSettings"].tap()
        book.tap();XCTAssertTrue(reader.waitForExistence(timeout:8))
        XCTAssertFalse(NSPredicate(format:"value CONTAINS %@","page=0").evaluate(with:reader),"Cancelling must retain progress")
        app.buttons["返回书库"].tap();app.buttons["shelfSettings"].tap();revealReset();reset.tap();app.buttons["确认重置所有进度"].tap()
        app.buttons["closeShelfSettings"].tap()
        book.tap();XCTAssertTrue(reader.waitForExistence(timeout:8))
        XCTAssertTrue(NSPredicate(format:"value CONTAINS %@","page=0").evaluate(with:reader),"Confirmed reset opens first page")
    }
    func testShelfAppearanceAndSettings(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo","-server.selected","android"];app.launch()
        func capture(_ name:String){let shot=XCTAttachment(screenshot:app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)}
        let book=app.cells["shelf-book-1"]
        XCTAssertTrue(book.waitForExistence(timeout:15));XCTAssertTrue(book.isHittable)
        XCTAssertFalse(app.buttons["resetReadingProgress"].exists)
        XCTAssertEqual(app.buttons.matching(identifier:"shelfPageMenu").count,1)
        let pager=app.buttons["shelfPageMenu"];XCTAssertTrue(pager.isHittable)
        let pagerY=pager.frame.minY
        app.collectionViews.firstMatch.swipeUp();XCTAssertTrue(pager.isHittable);XCTAssertEqual(pager.frame.minY,pagerY,accuracy:2)
        app.collectionViews.firstMatch.swipeDown()
        let layout=app.buttons["shelfLayout"]
        if !layout.label.contains("2 列"){layout.tap();app.buttons["舒适两列"].tap()}
        let layoutY=layout.frame.minY
        layout.tap();app.buttons["紧凑三列"].tap()
        XCTAssertTrue(layout.isHittable);XCTAssertEqual(layout.frame.minY,layoutY,accuracy:3)
        XCTAssertTrue(layout.label.contains("3 列"));XCTAssertTrue(book.isHittable)
        let compactWidth=book.frame.width
        capture("Shelf-Three-Columns")
        app.terminate();app.launch()
        XCTAssertTrue(layout.waitForExistence(timeout:10));XCTAssertTrue(layout.label.contains("3 列"),"Density persists across relaunch")
        layout.tap();app.buttons["舒适两列"].tap()
        XCTAssertTrue(layout.label.contains("2 列"));XCTAssertGreaterThan(book.frame.width,compactWidth)
        capture("Shelf-Two-Columns")
        book.press(forDuration:1.2);app.buttons["查看完整名称"].tap()
        XCTAssertTrue(app.staticTexts["fullBookTitle"].waitForExistence(timeout:5))
        capture("Book-Full-Title");app.buttons["copyBookTitle"].tap();XCTAssertTrue(app.buttons["copyBookTitle"].label.contains("已复制"));app.buttons["closeBookTitle"].tap()
        app.buttons["shelfSettings"].tap()
        XCTAssertTrue(app.buttons["扫码连接安卓"].waitForExistence(timeout:5))
        XCTAssertTrue(app.secureTextFields["6 位数字配对码"].exists)
        XCTAssertFalse(app.buttons["使用六位码配对"].isEnabled)
        let cache=app.buttons["清空封面与正文缓存"]
        for _ in 0..<3{if cache.isHittable{break};app.swipeUp()}
        // LabeledContent exposes its trailing text as an accessibility value on
        // newer iOS, rather than as a separate StaticText child.
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@ OR value CONTAINS %@","2 GB","2 GB")).firstMatch.exists)
        capture("Shelf-Settings")
        cache.tap();app.buttons["取消"].tap()
        app.buttons["closeShelfSettings"].tap()
        XCTAssertTrue(book.isHittable)
    }
    func testSimplifiedReaderControls(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo"];app.launch()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<3{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        func state(_ value:String){XCTAssertTrue(NSPredicate(format:"value CONTAINS %@",value).evaluate(with:reader),"\(reader.value ?? "no state")")}
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.5)).tap();state("page=0")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap();state("page=0")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap();state("zoom=100");state("page=0")
        reader.pinch(withScale:2,velocity:1);state("zoom=100");state("page=0")
        if !app.buttons["下一页"].isHittable{reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()}
        XCTAssertFalse(app.buttons["还原大小"].exists)
        app.buttons["下一页"].tap();state("page=1")
        app.buttons["上一页"].tap();state("page=0")
    }
    func testFastShortFlicks(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo"];app.launch()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<3{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        func waitPage(_ index:Int){let check=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","page=\(index)"),object:reader);XCTAssertEqual(XCTWaiter.wait(for:[check],timeout:5),.completed,"\(reader.value ?? "no reader state")")}
        func flick(_ direction:Double){
            reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.01,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.5+direction*0.085,dy:0.5)),withVelocity:.fast,thenHoldForDuration:0)
        }
        flick(-1);waitPage(1)
        flick(-1);waitPage(2)
        flick(1);waitPage(1)
        flick(1);waitPage(0)
        // Book edges remain bounded even with repeated fast input.
        flick(1);waitPage(0)
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap()
        expectation(for:NSPredicate(format:"value CONTAINS %@","zoom=100"),evaluatedWith:reader);waitForExpectations(timeout:5)
        flick(-1);waitPage(1)
    }
    func testShortFlickLiftOffAndHold(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo"];app.launch()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<3{if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        func waitPage(_ index:Int){let check=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","page=\(index)"),object:reader);XCTAssertEqual(XCTWaiter.wait(for:[check],timeout:5),.completed,"\(reader.value ?? "no reader state")")}
        func flick(_ delta:CGFloat,_ hold:TimeInterval){
            let center=reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            center.press(forDuration:0.01,thenDragTo:center.withOffset(CGVector(dx:delta,dy:0)),withVelocity:.fast,thenHoldForDuration:hold)
        }
        // A brief lift-off pause may reduce UIKit's final velocity to zero.
        flick(-28,0.025);waitPage(1)
        flick(28,0.025);waitPage(0)
        flick(-28,0.2);waitPage(0)
        // No explicit wait-for-page between these gestures. XCTest itself still
        // adds event latency; sub-animation intervals are covered by runtime tests.
        flick(-28,0);flick(-28,0);waitPage(2)
        flick(28,0);flick(28,0);waitPage(0)
        XCTAssertTrue(NSPredicate(format:"value CONTAINS %@","zoom=100").evaluate(with:reader))
    }
    func testThresholdEdgeReturn() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
        let books=app.cells.matching(NSPredicate(format:"label CONTAINS %@","合成封面 · 第"))
        XCTAssertTrue(books.firstMatch.waitForExistence(timeout:15))
        app.collectionViews.firstMatch.swipeUp(velocity:.slow)
        guard let book=books.allElementsBoundByIndex.first(where:{$0.isHittable && $0.frame.midY>200 && $0.frame.midY<600}) else{XCTFail("No visible synthetic book");return}
        let shelfY=book.frame.minY;book.tap()
        let reader=app.otherElements["native-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout:10))
        func state(_ fragment:String){XCTAssertTrue(NSPredicate(format:"value CONTAINS %@",fragment).evaluate(with:reader),reader.value as? String ?? "missing reader state")}
        state("native=false")
        for _ in 0..<2 {if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        // Ordinary center swipe is page navigation, never full-content return.
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)).press(forDuration:0.1,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.3)
        XCTAssertTrue(reader.exists);state("page=1");state("image=true")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.5)).press(forDuration:0.1,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.3)
        XCTAssertTrue(reader.exists);state("page=0")
        app.buttons["下一页"].tap();state("page=1")
        // Short edge gestures below the legacy threshold do not navigate.
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.002,dy:0.5)).press(forDuration:0.05,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.07,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.6)
        XCTAssertTrue(reader.waitForExistence(timeout:5));state("page=1");state("image=true");state("native=false")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap()
        XCTAssertTrue(NSPredicate(format:"value CONTAINS %@","zoom=100").evaluate(with:reader))
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.002,dy:0.5)).press(forDuration:0.05,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.07,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.6)
        state("zoom=100");state("page=1");state("image=true")
        // Start 32pt inside the screen, not on its physical edge; a quick short
        // right flick returns without requiring a long drag across the display.
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:0.5)).press(forDuration:0.01,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.16,dy:0.5)),withVelocity:.fast,thenHoldForDuration:0)
        XCTAssertTrue(book.waitForExistence(timeout:8));XCTAssertFalse(reader.exists)
        XCTAssertEqual(book.frame.minY,shelfY,accuracy:2,"Returning must preserve shelf scroll position")
        book.tap();XCTAssertTrue(reader.waitForExistence(timeout:8));state("native=false");state("page=1")
        app.buttons["返回书库"].tap();XCTAssertTrue(book.waitForExistence(timeout:8))
    }
    func testAnimationControls(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--animation-demo"];app.launch()
        let reader=app.otherElements["native-reader"];XCTAssertTrue(reader.waitForExistence(timeout:10))
        for _ in 0..<3 {if app.buttons["上一页"].isEnabled{app.buttons["上一页"].tap()}}
        func waitState(_ text:String){let predicate=NSPredicate(format:"value CONTAINS %@",text);expectation(for:predicate,evaluatedWith:reader);waitForExpectations(timeout:6)}
        waitState("anim=1")
        let animationShot=XCTAttachment(screenshot:app.screenshot());animationShot.name="Compact-Animated-Reader";animationShot.lifetime = .keepAlways;add(animationShot)
        app.buttons["暂停动图"].tap();waitState("anim=none")
        app.buttons["播放动图"].tap();waitState("anim=1")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap();waitState("zoom=100");waitState("anim=1")
        app.buttons["下一页"].tap();waitState("anim=2");waitState("zoom=100")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)).press(forDuration:0.1,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.3)
        waitState("page=2");waitState("anim=3")
        reader.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.5)).press(forDuration:0.1,thenDragTo:reader.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.3)
        waitState("page=1");waitState("anim=2")
        app.buttons["下一页"].tap();waitState("anim=3")
        XCUIDevice.shared.press(.home);app.activate();waitState("anim=3")
        app.buttons["下一页"].tap();waitState("anim=none");XCTAssertFalse(app.buttons["暂停动图"].exists)
    }
}
