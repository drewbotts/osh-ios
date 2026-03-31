import Foundation

// MARK: - AppTab

enum AppTab: Hashable {
    case main
    case garmin
    case settings
}

// MARK: - AppNavigationState

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .main
    @Published var sidebarOpen: Bool = false

    func open(_ tab: AppTab) {
        selectedTab = tab
        sidebarOpen = false
    }

    func toggleSidebar() {
        sidebarOpen.toggle()
    }
}
