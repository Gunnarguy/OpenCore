import CoreCompanion
import SwiftUI

@main
struct OpenCorePhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    model.obscured = phase != .active
                    if phase == .background { Task { await model.lock() } }
                }
        }
    }
}

struct PhoneRootView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack { PhoneHomeView() }
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                NavigationStack { PhoneChatView() }
            }
            Tab("Library", systemImage: "square.grid.2x2") {
                NavigationStack { PhoneLibraryView() }
            }
            Tab("Connection", systemImage: "iphone.and.arrow.forward") {
                NavigationStack { PhoneConnectionView() }
            }
        }
        .tint(colorScheme == .dark ? .cyan : .blue)
        .id(model.sessionID)
        .overlay {
            if model.obscured {
                Rectangle().fill(.background).ignoresSafeArea()
                    .overlay { Label("OpenCore is private", systemImage: "lock.shield").font(.title2) }
            }
        }
    }
}
