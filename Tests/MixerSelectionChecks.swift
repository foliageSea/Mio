import CoreAudio

@main
struct MixerSelectionChecks {
    static func main() {
        var selection = MixerKeyboardSelection()
        selection.move(by: 1, in: [])
        assert(selection.selectedID == nil)
        selection.reconcile([11, 22, 33])
        assert(selection.selectedID == 11)
        selection.move(by: -1, in: [11, 22, 33])
        assert(selection.selectedID == 11)
        selection.move(by: 1, in: [11, 22, 33])
        assert(selection.selectedID == 22)
        selection.reconcile([33, 22, 11])
        assert(selection.selectedID == 22)
        selection.move(by: 1, in: [33, 22, 11])
        assert(selection.selectedID == 11)
        selection.move(by: 1, in: [33, 22, 11])
        assert(selection.selectedID == 11)
        selection.select(33)
        selection.reconcile([33, 22, 11])
        assert(selection.selectedID == 33)
        selection.reconcile([22, 11])
        assert(selection.selectedID == 22)
        selection.reconcile([])
        assert(selection.selectedID == nil)
        selection.reconcile([44])
        selection.move(by: 1, in: [44])
        assert(selection.selectedID == 44)
        print("PASS: initial selection, arrow navigation, bounds, reorder, removal, mouse selection, empty list")
    }
}
