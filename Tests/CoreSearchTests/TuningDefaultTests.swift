import Foundation
import Testing

@testable import CoreSearch

/// **The bug.** `RetrievalTuning` had two defaults that disagreed. `.default` carried the
/// measured `denseWeight: 0.0`; the initialiser's parameter default was `1.0`, kept
/// deliberately so that callers omitting the argument would get the pre-measurement behaviour.
///
/// `AppSettings.tuning` omitted the argument. So the macOS app ran every query at
/// `denseWeight: 1.0` while `opencore` ran at 0.0, because the CLI happened to start from
/// `var tuning = RetrievalTuning.default` and mutate it. The two surfaces answered the same
/// question differently for two days, and the app was the bad one: the sweep on 2026-08-09
/// measured fused nDCG@6 at **0.073 at weight 1.0 against 0.422 at 0**, so the app was running
/// at roughly a sixth of its measured retrieval quality. Nothing surfaced it, because
/// `denseWeight` appeared nowhere in the app at all — there was no control to look wrong, no
/// value to read back, and every test passed.
///
/// Two independent things have to hold to keep this fixed, so they are asserted separately.
/// The first is that the initialiser cannot hand out a rejected configuration. The second is
/// that `.default` still carries the measured value, which is what the first is compared
/// against and would otherwise be free to drift.

@Test("omitting the leg weights yields the measured configuration, not the rejected one")
func initialiserDefaultsToTheMeasuredConfiguration() {
    // Exactly the call shape that produced the bug: every field the Settings screen exposes,
    // and nothing else.
    let omitted = RetrievalTuning(
        rrfK: RetrievalTuning.default.rrfK,
        mmrLambda: RetrievalTuning.default.mmrLambda,
        candidatesPerLeg: RetrievalTuning.default.candidatesPerLeg,
        signalScale: RetrievalTuning.default.signalScale
    )

    #expect(omitted == RetrievalTuning.default)

    // Named separately from the equality above. If a field is added to `RetrievalTuning` with
    // a mismatched default, the equality catches it; this says which one mattered here.
    #expect(omitted.denseWeight == 0.0)
}

@Test("the measured default still disables the dense leg")
func measuredDefaultDisablesTheDenseLeg() {
    // Not a magic number: 0.0 is the only value in the 2026-08-09 sweep at which fusion beats
    // its own lexical leg (0.422 against 0.420) rather than scoring a sixth of it. Raising it
    // is a legitimate change to make the day the embedding question is settled, and it should
    // fail this test loudly and be made on purpose rather than by omitting an argument.
    #expect(RetrievalTuning.default.denseWeight == 0.0)
    #expect(RetrievalTuning.default.lexicalWeight == 1.0)
}
