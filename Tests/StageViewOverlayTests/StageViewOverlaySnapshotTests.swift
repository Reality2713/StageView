import Testing
import SwiftUI
@testable import StageViewOverlay

struct StageViewOverlaySnapshotTests {
    @Test
    func showsBuiltInContentWhenEitherBuiltInElementIsVisible() {
        let empty = StageViewOverlaySnapshot(
            builtInVisibility: .init(
                showsOrientationGizmo: false,
                showsScaleIndicator: false
            )
        )
        #expect(empty.showsBuiltInContent == false)

        let scaleOnly = StageViewOverlaySnapshot(
            builtInVisibility: .init(
                showsOrientationGizmo: false,
                showsScaleIndicator: true
            )
        )
        #expect(scaleOnly.showsBuiltInContent == true)

        let gizmoOnly = StageViewOverlaySnapshot(
            builtInVisibility: .init(
                showsOrientationGizmo: true,
                showsScaleIndicator: false
            )
        )
        #expect(gizmoOnly.showsBuiltInContent == true)
    }

    @Test
    func stageViewOverlaySlotsReportsPresenceWhenAnySlotIsFilled() {
        let slots = StageViewOverlaySlots.empty.top {
            Text("Viewport")
        }
        #expect(slots.hasContent == true)
    }
}
