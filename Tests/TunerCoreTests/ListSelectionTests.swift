import Testing
@testable import TunerCore

private struct Item: Identifiable {
    var id: Int
    var gone = false
}

private func items(_ ids: [Int], gone: Set<Int> = []) -> [Item] {
    ids.map { Item(id: $0, gone: gone.contains($0)) }
}

private func selection(_ rows: [Item], selected: Int?) -> Int? {
    ListSelection.afterRemoving(from: rows, where: \.gone, selected: selected)
}

@Suite struct ListSelectionTests {
    @Test func aSelectedRowThatStaysStaysSelected() {
        #expect(selection(items([1, 2, 3], gone: [2]), selected: 1) == 1)
        #expect(selection(items([1, 2, 3], gone: [2]), selected: 3) == 3)
    }

    @Test func aRemovedSelectionMovesToTheRowThatTakesItsPlace() {
        #expect(selection(items([1, 2, 3], gone: [2]), selected: 2) == 3)
        #expect(selection(items([1, 2, 3], gone: [1]), selected: 1) == 2)
    }

    @Test func aRemovedLastRowSelectsTheRowBeforeIt() {
        #expect(selection(items([1, 2, 3], gone: [3]), selected: 3) == 2)
    }

    @Test func rowsRemovedWithTheSelectionArePassedOver() {
        let rows = items([1, 2, 3, 4, 5], gone: [2, 3, 5])
        #expect(selection(rows, selected: 2) == 4)
        #expect(selection(rows, selected: 3) == 4)
        #expect(selection(rows, selected: 5) == 4)
        #expect(selection(items([1, 2, 3], gone: [2, 3]), selected: 2) == 1)
    }

    @Test func nothingLeftSelectsNothing() {
        #expect(selection(items([1, 2], gone: [1, 2]), selected: 1) == nil)
        #expect(selection(items([1], gone: [1]), selected: 1) == nil)
    }

    @Test func noSelectionStaysNone() {
        #expect(selection(items([1, 2, 3], gone: [2]), selected: nil) == nil)
    }

    @Test func aSelectionNotListedIsLeftAsItIs() {
        #expect(selection(items([1, 2, 3], gone: [2]), selected: 9) == 9)
        #expect(selection([], selected: 9) == 9)
    }
}
