import Testing
@testable import Sweep

/// Selection rules for the Bursts and Duplicates review screens.
@MainActor
struct GroupReviewModelTests {
    private let group = ReviewGroup(id: "g", assetIDs: ["a", "b", "c"], suggestedKeep: ["a"], date: nil)

    private func loadedModel() async -> GroupReviewModel {
        let model = GroupReviewModel()
        let scan = GroupScanResult(groups: [group], sizes: ["a": 300, "b": 200, "c": 100])
        await model.load { scan }
        return model
    }

    @Test func everythingButTheSuggestionStartsMarked() async {
        let model = await loadedModel()
        #expect(model.marked == ["b", "c"])
        #expect(model.markedBytes == 300)
    }

    @Test func theLastKeptPhotoCannotBeMarked() async {
        let model = await loadedModel()
        #expect(!model.canMark("a", in: group))

        model.toggle("a", in: group)
        #expect(!model.isMarked("a"), "Marking the only kept photo would delete the whole group")
    }

    @Test func keepingAnotherPhotoFreesUpTheSuggestion() async {
        let model = await loadedModel()
        model.toggle("b", in: group)
        #expect(!model.isMarked("b"))
        #expect(model.canMark("a", in: group))

        model.toggle("a", in: group)
        #expect(model.isMarked("a"))
        #expect(!model.canMark("b", in: group))
    }

    @Test func keepAllAndUseSuggestion() async {
        let model = await loadedModel()
        model.keepAll(in: group)
        #expect(model.marked.isEmpty)

        model.applySuggestion(in: group)
        #expect(model.marked == ["b", "c"])
    }

    @Test func groupsSortByReclaimableBytes() {
        let small = ReviewGroup(id: "small", assetIDs: ["s1", "s2"], suggestedKeep: ["s1"], date: nil)
        let large = ReviewGroup(id: "large", assetIDs: ["l1", "l2"], suggestedKeep: ["l1"], date: nil)
        // The kept photo's size must not count: "small" keeps a huge photo but frees little.
        var scan = GroupScanResult(groups: [small, large], sizes: ["s1": 9_000, "s2": 10, "l1": 1, "l2": 500])
        scan.sortByReclaimableBytes()
        #expect(scan.groups.map(\.id) == ["large", "small"])
    }
}
