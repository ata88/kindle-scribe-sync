import Testing
@testable import KSSCore

@Suite struct MergeTests {
    @Test func noCorrectionsTakesNewOCR() {
        #expect(Merge.threeWay(base: "a b", ours: "a b", theirs: "a b c") == "a b c")
    }

    @Test func correctionKeptWhenPageExtended() {
        let base = "Termin mit Muller am Mo"
        let ours = "Termin mit Müller am Mo"
        let theirs = "Termin mit Muller am Mo\nDanach Einkaufen gehen"
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs)
                == "Termin mit Müller am Mo\nDanach Einkaufen gehen")
    }

    @Test func appendedWordsAfterCorrectedWord() {
        let merged = Merge.threeWay(base: "Termin Mo", ours: "Termin Montag", theirs: "Termin Mo 10 Uhr")
        #expect(merged == "Termin Montag 10 Uhr")
    }

    @Test func independentChangesBothApplied() {
        let base = "eins zwei drei vier fünf"
        let ours = "eins ZWEI drei vier fünf"
        let theirs = "eins zwei drei vier fünf sechs"
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs) == "eins ZWEI drei vier fünf sechs")
    }

    @Test func conflictPrefersUser() {
        let merged = Merge.threeWay(base: "Haus am See", ours: "Haus am Meer", theirs: "Haus am Seo")
        #expect(merged == "Haus am Meer")
    }

    @Test func userDeletionsSurvive() {
        let merged = Merge.threeWay(base: "a xx b", ours: "a b", theirs: "a xx b c")
        #expect(merged == "a b c")
    }

    @Test func newLineInsertedAtTopKeepsLaterCorrection() {
        let base = "# Liste\n- Mlich\n- Brot"
        let ours = "# Liste\n- Milch\n- Brot"
        let theirs = "Montag\n# Liste\n- Mlich\n- Brot\n- Käse"
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs)
                == "Montag\n# Liste\n- Milch\n- Brot\n- Käse")
    }

    @Test func tokenizeRoundTrips() {
        let s = "  Hallo  Welt\n\n- [ ] Punkt\t x "
        #expect(Merge.tokenize(s).joined() == s)
    }
}
