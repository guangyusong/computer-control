import Foundation

enum SidebarSelection: Hashable {
    case session(UUID)
    case permissions
    case activity
}
