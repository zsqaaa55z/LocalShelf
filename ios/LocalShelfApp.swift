import SwiftUI

@main struct LocalShelfApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                DebugAppContent()
                #else
                ShelfView()
                #endif
            }.preferredColorScheme(.dark).background(Color.black.ignoresSafeArea())
        }
    }
}
