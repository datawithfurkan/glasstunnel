#if os(macOS)
import Foundation

enum AppNavigationTab: String, CaseIterable, Hashable {
    case workspace
    case access
    case settings

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .access: return "Access"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .workspace: return "square.grid.2x2"
        case .access: return "person.2"
        case .settings: return "slider.horizontal.3"
        }
    }
}
#endif
