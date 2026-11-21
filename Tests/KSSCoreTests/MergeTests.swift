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

    // The reported bug: last paragraph corrected, next day more written below it.
    private let base = "# Einkauf\n\n- Milch\n- Brot\n\nTermin am Montag mit Anan im Buro"
    private let ours = "# Einkauf\n\n- Milch\n- Brot\n\nTermin am Montag mit Anna im Büro"

    @Test func additionBelowCorrectedLastParagraph_modelKeepsOldMistakes() {
        let theirs = base + "\n\nAm Dienstag noch Blumen kaufen."
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs) == ours + "\n\nAm Dienstag noch Blumen kaufen.")
    }

    @Test func additionBelowCorrectedLastParagraph_modelRepeatsTheCorrection() {
        // the model got the corrected text as a template and wrote it out again, plus the new lines
        let theirs = ours + "\n\nAm Dienstag noch Blumen kaufen."
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs) == ours + "\n\nAm Dienstag noch Blumen kaufen.")
    }

    @Test func additionBelowCorrectedLastParagraph_modelPartlyCorrect() {
        // model fixes one of the two words itself, misreads the other differently, and adds new lines
        let theirs = "# Einkauf\n\n- Milch\n- Brot\n\nTermin am Montag mit Anna im Bür\n\nAm Dienstag noch Blumen kaufen."
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs) == ours + "\n\nAm Dienstag noch Blumen kaufen.")
    }

    @Test func wordsAddedRightAfterACorrectedWord() {
        // written on the same line, directly after the corrected word
        let theirs = "# Einkauf\n\n- Milch\n- Brot\n\nTermin am Montag mit Anna im Büro um 10 Uhr"
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs) == ours + " um 10 Uhr")
    }

    @Test func correctedWordReadAsTwoFragmentsIsNotNewText() {
        let theirs = "# Einkauf\n\n- Milch\n- Brot\n\nTermin am Montag mit An na im Büro"
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs) == ours)
    }

    @Test func newLineInsertedBeforeTheCorrectedParagraph() {
        let theirs = "# Einkauf\n\n- Milch\n- Brot\n- Eier\n\nTermin am Montag mit Anna im Büro"
        #expect(Merge.threeWay(base: base, ours: ours, theirs: theirs)
                == "# Einkauf\n\n- Milch\n- Brot\n- Eier\n\nTermin am Montag mit Anna im Büro")
    }

    @Test func repairRestoresTheDroppedEnding() {
        let corrected = "Einkauf\n\nTermin mit Anna im Büro"
        let reading = "Einkauf\n\nTermin mit Anan im Buro\n\nNoch Blumen kaufen\n- Rosen"
        #expect(Merge.restoreDroppedEnding(corrected: corrected, reading: reading)
                == "Einkauf\n\nTermin mit Anna im Büro\n\nNoch Blumen kaufen\n- Rosen")
        // nothing missing, or only the user's own edits differ: no change
        #expect(Merge.restoreDroppedEnding(corrected: corrected, reading: "Einkauf\n\nTermin mit Anan im Buro") == nil)
        #expect(Merge.restoreDroppedEnding(corrected: "a\nb\nc", reading: "a\nb\nc") == nil)
    }

    @Test func tokenizeRoundTrips() {
        let s = "  Hallo  Welt\n\n- [ ] Punkt\t x "
        #expect(Merge.tokenize(s).joined() == s)
    }
}
