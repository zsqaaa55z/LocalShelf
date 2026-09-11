import XCTest

final class ReaderInteractionChecks:XCTestCase {
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
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="NAS-Server-Settings";shot.lifetime = .keepAlways;add(shot)
        app.buttons["安卓桥接"].tap()
        let export=app.buttons["exportReadingProgress"]
        for _ in 0..<5{if export.exists && export.isHittable{break};app.swipeUp()}
        XCTAssertTrue(export.waitForExistence(timeout:5));XCTAssertTrue(export.isHittable)
        XCTAssertTrue(app.buttons["从备份恢复（不覆盖已有进度）"].exists)
    }
    func testLocateRecentReadingAtDifferentPageSizes(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
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
        XCTAssertFalse(resume.isEnabled);XCTAssertEqual(resume.value as? String,"暂无记录")
        app.terminate();app.launch();XCTAssertTrue(resume.waitForExistence(timeout:15));XCTAssertFalse(resume.isEnabled)
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
        app.buttons["recordInteraction"].tap()
        XCTAssertFalse(app.buttons["closeShelfSettings"].exists)
        app.collectionViews.firstMatch.swipeUp();app.collectionViews.firstMatch.swipeDown()
        app.buttons["shelfSettings"].tap()
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
        let notice=app.staticTexts["libraryOrderNotice"]
        for _ in 0..<5{if notice.exists && notice.isHittable{break};app.swipeUp()}
        XCTAssertTrue(notice.exists);XCTAssertTrue(notice.isHittable)
        XCTAssertTrue(notice.label.contains("同值记录位置待核对"))
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Library-Explanation";screenshot.lifetime = .keepAlways;add(screenshot)
        app.buttons["closeShelfSettings"].tap()
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
    func testPageFailureRefreshesOnlyOnce(){
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--reader-demo","--fail-page-image"];app.launch()
        let refresh=app.buttons["readerOptions"];XCTAssertTrue(refresh.waitForExistence(timeout:10))
        expectation(for:NSPredicate(format:"value == %@","已刷新1次"),evaluatedWith:refresh);waitForExpectations(timeout:10)
        let repeated=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","已刷新2次"),object:refresh);repeated.isInverted=true
        XCTAssertEqual(XCTWaiter.wait(for:[repeated],timeout:3),.completed,"Failed page must not cause an endless directory refresh")
        refresh.tap();app.buttons["refreshPageList"].tap();expectation(for:NSPredicate(format:"value == %@","已刷新2次"),evaluatedWith:refresh);waitForExpectations(timeout:10)
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
        let app=XCUIApplication();app.launchArguments=["--shelf-demo"];app.launch()
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
        XCTAssertTrue(app.alerts["漫画名称"].waitForExistence(timeout:5));app.alerts.buttons["完成"].tap()
        app.buttons["shelfSettings"].tap()
        XCTAssertTrue(app.buttons["扫码连接安卓"].waitForExistence(timeout:5))
        XCTAssertTrue(app.secureTextFields["6 位数字配对码"].exists)
        XCTAssertFalse(app.buttons["使用六位码配对"].isEnabled)
        let cache=app.buttons["清空封面缓存"]
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
