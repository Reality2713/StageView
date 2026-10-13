import CoreGraphics
import Foundation
import Testing
@testable import RealityKitStageView

struct ViewportFrameCaptureTests {
    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        var values: [Result<CGImage, Error>] = []
        func add(_ r: Result<CGImage, Error>) { lock.withLock { values.append(r) } }
        var count: Int { lock.withLock { values.count } }
    }

    private struct Timeout: Error {}

    @Test func cancellingAPendingCaptureFailsItOnce() {
        let capture = ViewportFrameCapture()
        let results = Results()
        let id = UUID()
        capture.request(id: id, colorSpace: CGColorSpaceCreateDeviceRGB()) { results.add($0) }
        capture.cancel(id: id, error: Timeout())
        capture.cancel(id: id, error: Timeout())   // already gone: no second completion
        #expect(results.count == 1)
        if case .failure(let error)? = results.values.first { #expect(error is Timeout) } else { Issue.record("expected a failure") }
    }

    @Test func cancellingAnUnknownCaptureDoesNothing() {
        let capture = ViewportFrameCapture()
        let results = Results()
        capture.request(colorSpace: CGColorSpaceCreateDeviceRGB()) { results.add($0) }
        capture.cancel(id: UUID(), error: Timeout())
        #expect(results.count == 0)
    }
}
