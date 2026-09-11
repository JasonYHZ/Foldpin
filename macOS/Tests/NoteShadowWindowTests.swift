import AppKit
import Testing
@testable import FoldpinCore

@Test @MainActor func shadowDecorationKeepsSpacesButIsExcludedFromMissionControlAndCycle() {
    for option: NSWindow.CollectionBehavior in [[], [.managed, .participatesInCycle], [.stationary, .ignoresCycle]] {
        let shared: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        let behavior = NoteShadowWindow.behavior(for: shared.union(option))
        #expect(behavior.isSuperset(of: shared))
        #expect(behavior.contains(.transient) && behavior.contains(.ignoresCycle))
        #expect(!behavior.contains(.managed) && !behavior.contains(.stationary) && !behavior.contains(.participatesInCycle))
    }
}

@Test @MainActor func shadowDecorationRepairsDisplacedFrameWithoutChangingPaperGeometry() {
    let paper = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 360, height: 340), styleMask: [.borderless], backing: .buffered, defer: true)
    let shadow = NoteShadowWindow()
    defer { shadow.close(); paper.close() }
    let destinations = [NSRect(x: 300, y: 100, width: 360, height: 340),
                        NSRect(x: -1400, y: -1800, width: 360, height: 340),
                        NSRect(x: 150, y: 2100, width: 360, height: 52)]
    for destination in destinations {
        paper.setFrame(destination, display: false)
        let actual = paper.frame
        shadow.setFrame(NSRect(x: 1500, y: -900, width: 100, height: 100), display: false)
        shadow.updateFrame(for: paper)
        #expect(shadow.frame == actual.insetBy(dx: -36, dy: -36))
        #expect(paper.frame == actual)
        shadow.updateFrame(for: paper)
        #expect(shadow.frame == actual.insetBy(dx: -36, dy: -36))
    }
    #expect(!shadow.canBecomeKey && !shadow.canBecomeMain && shadow.ignoresMouseEvents)
    let outside = NSRect(x: 0, y: 10000, width: 432, height: 412)
    #expect(shadow.constrainFrameRect(outside, to: NSScreen.main) == outside)
}
