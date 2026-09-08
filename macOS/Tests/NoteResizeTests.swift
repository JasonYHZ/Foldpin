import Foundation
import Testing
@testable import FoldpinCore

@Test func resizePerimeterLeavesTitlebarButtonsAndEditorAvailable() {
    let bounds = CGRect(x: 0, y: 0, width: 360, height: 340)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 180, y: 323), in: bounds, allowsVertical: true).isEmpty)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 21, y: 323), in: bounds, allowsVertical: true).isEmpty)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 339, y: 323), in: bounds, allowsVertical: true).isEmpty)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 180, y: 180), in: bounds, allowsVertical: true).isEmpty)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 3, y: 170), in: bounds, allowsVertical: true) == .left)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 357, y: 170), in: bounds, allowsVertical: true) == .right)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 180, y: 337), in: bounds, allowsVertical: true) == .top)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 180, y: 3), in: bounds, allowsVertical: true) == .bottom)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 8, y: 332), in: bounds, allowsVertical: true) == [.left, .top])
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 352, y: 332), in: bounds, allowsVertical: true) == [.right, .top])
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 8, y: 8), in: bounds, allowsVertical: true) == [.left, .bottom])
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 352, y: 8), in: bounds, allowsVertical: true) == [.right, .bottom])
}

@Test func resizeKeepsOppositeCornerFixedAndHonorsLimits() {
    let start = CGRect(x: -600, y: 200, width: 360, height: 340)
    let minimum = CGSize(width: 280, height: 220)
    let maximum = CGSize(width: 800, height: 700)
    let resized = NoteResizeEdges([.left, .bottom]).resizing(start, by: CGSize(width: -100, height: -60), minimum: minimum, maximum: maximum)
    #expect(resized == CGRect(x: -700, y: 140, width: 460, height: 400))
    let smallest = NoteResizeEdges([.left, .bottom]).resizing(start, by: CGSize(width: 1_000, height: 1_000), minimum: minimum, maximum: maximum)
    #expect(smallest == CGRect(x: -520, y: 320, width: 280, height: 220))
    let largest = NoteResizeEdges([.right, .top]).resizing(start, by: CGSize(width: 1_000, height: 1_000), minimum: minimum, maximum: maximum)
    #expect(largest == CGRect(x: -600, y: 200, width: 800, height: 700))
    // Returning the pointer to its starting location restores the original
    // frame even after a limit was reached; deltas aren't accumulated per frame.
    #expect(NoteResizeEdges([.left, .bottom]).resizing(start, by: .zero, minimum: minimum, maximum: maximum) == start)
}

@Test func resizeCollapsedNoteChangesOnlyWidth() {
    let height = NoteLayout.headerHeight
    let bounds = CGRect(x: 0, y: 0, width: 360, height: height)
    #expect(NoteResizeEdges.hit(at: CGPoint(x: 180, y: height - 2), in: bounds, allowsVertical: false).isEmpty)
    let edges = NoteResizeEdges.hit(at: CGPoint(x: 2, y: height - 2), in: bounds, allowsVertical: false)
    #expect(edges == .left)
    let start = CGRect(x: 100, y: 500, width: 360, height: height)
    let result = edges.resizing(start, by: CGSize(width: -40, height: 100),
                                minimum: CGSize(width: 280, height: height), maximum: CGSize(width: 800, height: height))
    #expect(result == CGRect(x: 60, y: 500, width: 400, height: height))
    #expect(NoteLayout.expandedFrame(window: result, collapsed: true, rememberedHeight: 340).height == 340)
}
