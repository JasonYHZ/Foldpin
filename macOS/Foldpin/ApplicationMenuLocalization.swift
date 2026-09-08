import AppKit

/// Update labels in place; AppKit and SwiftUI keep owning actions, validation,
/// keyboard shortcuts, and the system's window-management menu contents.
@MainActor
enum ApplicationMenuLocalization {
    static func update(_ menu: NSMenu, bundle: Bundle) {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                if let title = sectionTitle(item.title, bundle: bundle) {
                    item.title = title
                    submenu.title = title
                }
                // Services belong to other apps, not Foldpin's string catalog.
                if submenu !== NSApp.servicesMenu { update(submenu, bundle: bundle) }
            }
            guard let action = item.action else { continue }
            let title: String?
            switch NSStringFromSelector(action) {
            case "orderFrontStandardAboutPanel:": title = String(localized: "About Foldpin", bundle: bundle)
            case "hide:": title = String(localized: "Hide Foldpin", bundle: bundle)
            case "hideOtherApplications:": title = String(localized: "Hide Others", bundle: bundle)
            case "unhideAllApplications:": title = String(localized: "Show All", bundle: bundle)
            case "terminate:": title = String(localized: "Quit Foldpin", bundle: bundle)
            case "performClose:": title = String(localized: "Close Window", bundle: bundle)
            case "cut:": title = String(localized: "Cut", bundle: bundle)
            case "copy:": title = String(localized: "Copy", bundle: bundle)
            case "paste:": title = String(localized: "Paste", bundle: bundle)
            case "selectAll:": title = String(localized: "Select All", bundle: bundle)
            case "performMiniaturize:": title = String(localized: "Minimize", bundle: bundle)
            case "performZoom:": title = String(localized: "Zoom", bundle: bundle)
            case "arrangeInFront:": title = String(localized: "Bring All to Front", bundle: bundle)
            // Preserve the undo manager's more specific action titles, if present.
            case "undo:" where ["Undo", "撤销"].contains(item.title): title = String(localized: "Undo", bundle: bundle)
            case "redo:" where ["Redo", "重做"].contains(item.title): title = String(localized: "Redo", bundle: bundle)
            default: title = nil
            }
            if let title, item.title != title { item.title = title }
        }
    }

    private static func sectionTitle(_ current: String, bundle: Bundle) -> String? {
        switch current {
        case "File", "文件": String(localized: "File", bundle: bundle)
        case "Edit", "编辑": String(localized: "Edit", bundle: bundle)
        case "View", "显示", "视图": String(localized: "View", bundle: bundle)
        case "Window", "窗口": String(localized: "Window", bundle: bundle)
        case "Help", "帮助": String(localized: "Help", bundle: bundle)
        case "Services", "服务": String(localized: "Services", bundle: bundle)
        default: nil
        }
    }
}
