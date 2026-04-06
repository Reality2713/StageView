import Testing
import SwiftUI
@testable import StageViewOverlay

// MARK: - Anchored Priority Ordering Tests

@Suite("Anchored Priority Ordering")
struct AnchoredPriorityOrderingTests {

    @Test
    func leadingAnchorsSortHigherPriorityFirst() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading, priority: 5) { Text("Low") }
            .hostAccessory(anchor: .topLeading, priority: 10) { Text("High") }
            .hostAccessory(anchor: .topLeading, priority: 0) { Text("Lowest") }

        let grouped = collection.groupedAndSortedForDisplay()
        let items = grouped[.topLeading] ?? []

        #expect(items.count == 3)
        // Higher priority should be first for leading anchors
        #expect(items[0].priority == 10)
        #expect(items[1].priority == 5)
        #expect(items[2].priority == 0)
    }

    @Test
    func trailingAnchorsSortLowerPriorityFirst() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topTrailing, priority: 5) { Text("Low") }
            .hostAccessory(anchor: .topTrailing, priority: 10) { Text("High") }
            .hostAccessory(anchor: .topTrailing, priority: 0) { Text("Lowest") }

        let grouped = collection.groupedAndSortedForDisplay()
        let items = grouped[.topTrailing] ?? []

        #expect(items.count == 3)
        // Lower priority should be first for trailing anchors (closer to edge)
        #expect(items[0].priority == 0)
        #expect(items[1].priority == 5)
        #expect(items[2].priority == 10)
    }

    @Test
    func bottomTrailingAnchorSortsLowerPriorityFirst() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .bottomTrailing, priority: 1) { Text("A") }
            .hostAccessory(anchor: .bottomTrailing, priority: 2) { Text("B") }

        let grouped = collection.groupedAndSortedForDisplay()
        let items = grouped[.bottomTrailing] ?? []

        #expect(items.count == 2)
        #expect(items[0].priority == 1)
        #expect(items[1].priority == 2)
    }

    @Test
    func bottomLeadingAnchorSortsHigherPriorityFirst() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .bottomLeading, priority: 1) { Text("A") }
            .hostAccessory(anchor: .bottomLeading, priority: 2) { Text("B") }

        let grouped = collection.groupedAndSortedForDisplay()
        let items = grouped[.bottomLeading] ?? []

        #expect(items.count == 2)
        #expect(items[0].priority == 2)
        #expect(items[1].priority == 1)
    }

    @Test
    func mixedPrioritiesAcrossMultipleAnchors() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading, priority: 5) { Text("TL") }
            .hostAccessory(anchor: .topTrailing, priority: 5) { Text("TT") }
            .hostAccessory(anchor: .bottomLeading, priority: 5) { Text("BL") }
            .hostAccessory(anchor: .bottomTrailing, priority: 5) { Text("BT") }

        let grouped = collection.groupedAndSortedForDisplay()

        // All anchors should have exactly one item with priority 5
        #expect(grouped[.topLeading]?.first?.priority == 5)
        #expect(grouped[.topTrailing]?.first?.priority == 5)
        #expect(grouped[.bottomLeading]?.first?.priority == 5)
        #expect(grouped[.bottomTrailing]?.first?.priority == 5)
    }
}

// MARK: - Host/Domain Accessory Tests

@Suite("Host and Domain Accessory Rendering")
struct AccessoryRenderingTests {

    @Test
    func hostAccessoryWithContentStoresView() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading) { Text("Badge") }

        let item = collection.items.first
        #expect(item != nil)
        #expect(item?.role == .hostAccessory)
        #expect(item?.anchor == .topLeading)
        #expect(item?.content != nil)
    }

    @Test
    func domainAccessoryWithContentStoresView() {
        let collection = ViewportOverlayCollection()
            .domainAccessory(anchor: .bottomTrailing) { Text("Picker") }

        let item = collection.items.first
        #expect(item != nil)
        #expect(item?.role == .domainAccessory)
        #expect(item?.anchor == .bottomTrailing)
        #expect(item?.content != nil)
    }

    @Test
    func hostAccessoryWithoutContentHasNilContent() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading)

        let item = collection.items.first
        #expect(item != nil)
        #expect(item?.content == nil)
    }

    @Test
    func domainAccessoryWithoutContentHasNilContent() {
        let collection = ViewportOverlayCollection()
            .domainAccessory(anchor: .bottomTrailing)

        let item = collection.items.first
        #expect(item != nil)
        #expect(item?.content == nil)
    }

    @Test
    func mixedAccessoriesWithAndWithoutContent() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading) { Text("With Content") }
            .hostAccessory(anchor: .topTrailing)

        #expect(collection.items.count == 2)
        #expect(collection.items[0].content != nil)
        #expect(collection.items[1].content == nil)
    }

    @Test
    func builtInComponentsDoNotHaveContent() {
        let collection = ViewportOverlayCollection()
            .orientationGizmo(anchor: .bottomLeading)
            .scaleIndicator(anchor: .top)

        #expect(collection.items.count == 2)
        #expect(collection.items[0].role == .orientationGizmo)
        #expect(collection.items[0].content == nil)
        #expect(collection.items[1].role == .scaleIndicator)
        #expect(collection.items[1].content == nil)
    }

    @Test
    func priorityDefaultsToZero() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading) { Text("Badge") }

        #expect(collection.items.first?.priority == 0)
    }

    @Test
    func priorityCanBeSpecified() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading, priority: 10) { Text("Badge") }

        #expect(collection.items.first?.priority == 10)
    }
}

// MARK: - Collection Builder Tests

@Suite("ViewportOverlayCollection Builder")
struct CollectionBuilderTests {

    @Test
    func emptyCollectionHasNoItems() {
        let collection = ViewportOverlayCollection.empty
        #expect(collection.items.isEmpty)
    }

    @Test
    func itemsAreAppendedInOrder() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading) { Text("First") }
            .hostAccessory(anchor: .topTrailing) { Text("Second") }
            .hostAccessory(anchor: .bottomLeading) { Text("Third") }

        #expect(collection.items.count == 3)
        #expect(collection.items[0].anchor == .topLeading)
        #expect(collection.items[1].anchor == .topTrailing)
        #expect(collection.items[2].anchor == .bottomLeading)
    }

    @Test
    func groupedByAnchorGroupsCorrectly() {
        let collection = ViewportOverlayCollection()
            .hostAccessory(anchor: .topLeading) { Text("A") }
            .hostAccessory(anchor: .topLeading) { Text("B") }
            .hostAccessory(anchor: .top) { Text("C") }

        let grouped = collection.groupedByAnchor()

        #expect(grouped[.topLeading]?.count == 2)
        #expect(grouped[.top]?.count == 1)
        #expect(grouped[.bottomLeading] == nil)
    }

    @Test
    func allAnchorsAreRepresented() {
        let allAnchors: [ViewportOverlayAnchor] = [
            .top, .topLeading, .topTrailing,
            .leading, .trailing,
            .bottom, .bottomLeading, .bottomTrailing
        ]

        var collection = ViewportOverlayCollection()
        for anchor in allAnchors {
            collection = collection.hostAccessory(anchor: anchor) { Text("Test") }
        }

        let grouped = collection.groupedByAnchor()
        #expect(grouped.keys.count == 8)
    }
}

// MARK: - Anchor Configuration Tests

@Suite("Anchor Configuration")
struct AnchorConfigurationTests {

    @Test
    func topAnchorHasHorizontalAxisAndTopAlignment() {
        #expect(ViewportOverlayAnchor.top.stackAxis == .horizontal)
        #expect(ViewportOverlayAnchor.top.alignment == .top)
    }

    @Test
    func topLeadingAnchorHasHorizontalAxisAndTopLeadingAlignment() {
        #expect(ViewportOverlayAnchor.topLeading.stackAxis == .horizontal)
        #expect(ViewportOverlayAnchor.topLeading.alignment == .topLeading)
    }

    @Test
    func topTrailingAnchorHasHorizontalAxisAndTopTrailingAlignment() {
        #expect(ViewportOverlayAnchor.topTrailing.stackAxis == .horizontal)
        #expect(ViewportOverlayAnchor.topTrailing.alignment == .topTrailing)
    }

    @Test
    func bottomLeadingAnchorHasHorizontalAxisAndBottomLeadingAlignment() {
        #expect(ViewportOverlayAnchor.bottomLeading.stackAxis == .horizontal)
        #expect(ViewportOverlayAnchor.bottomLeading.alignment == .bottomLeading)
    }

    @Test
    func bottomAnchorHasHorizontalAxisAndBottomAlignment() {
        #expect(ViewportOverlayAnchor.bottom.stackAxis == .horizontal)
        #expect(ViewportOverlayAnchor.bottom.alignment == .bottom)
    }

    @Test
    func bottomTrailingAnchorHasHorizontalAxisAndBottomTrailingAlignment() {
        #expect(ViewportOverlayAnchor.bottomTrailing.stackAxis == .horizontal)
        #expect(ViewportOverlayAnchor.bottomTrailing.alignment == .bottomTrailing)
    }
}
