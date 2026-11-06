import AppKit
import Foundation
import Testing
@testable import Mancia

@Suite("Oops keyboard-layout fixer")
struct OopsTests {
    @Test("English typed on the Hebrew layout comes back as Hebrew", arguments: [
        ("akuo", "שלום"),
        ("t,k akuo", "אתל שלום"),
        ("AKUO", "שלום"),
        ("aש", "שש"), // Ties choose Hebrew.
        ("aaש", "ששש"),
        ("akuo,./", "שלוםתץ."),
    ])
    func englishToHebrew(input: String, expected: String) {
        let conversion = KeyboardLayoutConverter.conversion(of: input)
        #expect(conversion.text == expected)
        #expect(conversion.language == .hebrew)
    }

    @Test("Hebrew typed on the English layout comes back as English", arguments: [
        ("שלום עולם", "akuo guko"), ("ששa", "aaa"),
    ])
    func hebrewToEnglish(input: String, expected: String) {
        let conversion = KeyboardLayoutConverter.conversion(of: input)
        #expect(conversion.text == expected)
        #expect(conversion.language == .english)
    }

    @Test("Shifted Hebrew keys map back to their English capitals and symbols")
    func shiftedHebrewKeys() {
        #expect(KeyboardLayoutConverter.conversion(of: "„שלום₪").text == "Dakuo&")
    }

    @Test("Digits, spaces, and newlines survive the conversion")
    func preservesUnmappedCharacters() {
        #expect(KeyboardLayoutConverter.conversion(of: "akuo 123\nakuo").text == "שלום 123\nשלום")
    }

    @Test("Text with no letters is returned unchanged and names no language")
    func noLettersNoDirection() {
        let conversion = KeyboardLayoutConverter.conversion(of: "123 !?")
        #expect(conversion.text == "123 !?")
        #expect(conversion.language == nil)
    }

    @Test("Oops is parsed from the CLI and never treated as a provider prompt")
    func actionIdentity() {
        #expect(EditAction.parse("oops") == .oops)
        #expect(EditAction.oops.isLocal)
        #expect(!EditAction.improve.isLocal)
    }

    @MainActor
    @Test("The Oops setting is off until the user turns it on, and persists")
    func settingDefaultsOff() {
        let suite = "mancia-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults, modelCatalog: { [] })
        #expect(!settings.showOopsAction)
        settings.showOopsAction = true
        #expect(AppSettings(defaults: defaults, modelCatalog: { [] }).showOopsAction)
    }

    @MainActor
    @Test("A hidden Oops has no slot, label, or shortcut, and 6 runs nothing")
    func hiddenOopsIsInert() {
        let model = PanelModel()
        model.reset(hasSelection: true)
        var ran: [EditAction] = []
        model.onPerform = { action, _ in ran.append(action) }

        #expect(model.actionDisplayOrder == PanelModel.actionIndices)
        #expect(model.actionTitle(at: PanelModel.oopsActionIndex) == nil)
        #expect(model.actionShortcut(at: PanelModel.oopsActionIndex) == nil)
        model.activateAction(at: PanelModel.oopsActionIndex)
        #expect(ran.isEmpty)
    }

    @MainActor
    @Test("A shown Oops follows Custom, owns 6, runs at once, and survives a set switch")
    func shownOopsRuns() {
        let model = PanelModel()
        model.reset(hasSelection: true)
        model.showsOops = true
        var ran: [EditAction] = []
        model.onPerform = { action, _ in ran.append(action) }

        let oops = PanelModel.oopsActionIndex
        #expect(model.actionDisplayOrder.last == oops)
        #expect(model.actionTitle(at: oops) == "Oops")
        #expect(model.actionShortcut(at: oops) == "6")
        #expect(model.actionLabelCandidates(at: oops).contains("Fixing layout"))

        model.activateAction(at: oops)
        #expect(ran == [.oops])
        #expect(model.isActionSelected(at: oops))
        #expect(model.focusedCell == .action(oops))

        model.cyclePresetGroup()
        #expect(model.isActionSelected(at: oops), "Oops sits outside the preset groups")
    }

    @Test("The lane with Oops fits under the width cap, so placement keeps it whole")
    func placementFitsOops() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = RibbonPlacement.standardWidth(showsOops: true)

        let resolved = RibbonPlacement.resolve(
            height: 56,
            in: .init(
                screenFrame: screen,
                visibleFrame: screen,
                preferredWidth: width,
                minimumContentWidth: width))
        #expect(resolved.frame.width == width)
    }
}
