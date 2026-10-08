import XCTest
@testable import Strand

/// Pins the #747 / #750 bond-refusal give-up: a strap that keeps REFUSING the encrypted bond
/// ("Encryption/Authentication is insufficient", no genuine bond between) eventually trips a give-up that
/// (a) pauses auto-reconnect so NOOP stops hammering it (#747) and (b) writes a one-line epitaph carrying
/// only an opaque, install-local id (no MAC, no serial; #750). Pure value type, no CoreBluetooth seam.
final class BondRefusalGiveUpTests: XCTestCase {

    // The default threshold is 5: the pairing hint already shows from streak 2, so we give the user several
    // reconnect cycles to act before pausing. The trip is reported exactly once.
    func testGivesUpAfterThresholdRefusals() {
        var g = BondRefusalGiveUp()   // default giveUpThreshold = 5
        for i in 1...4 {
            XCTAssertFalse(g.recordRefusal(), "refusal \(i) is below the give-up threshold")
            XCTAssertFalse(g.gaveUp)
        }
        XCTAssertTrue(g.recordRefusal(), "the 5th refusal freshly trips the give-up")
        XCTAssertTrue(g.gaveUp)
        XCTAssertEqual(g.refusals, 5)
        // Already gave up → no second "freshly tripped" signal (caller pauses + writes the epitaph once).
        XCTAssertFalse(g.recordRefusal())
        XCTAssertTrue(g.gaveUp)
    }

    // reset() re-arms: a genuine bond or an explicit user reconnect clears the streak so auto-reconnect works again.
    func testResetReArms() {
        var g = BondRefusalGiveUp()
        for _ in 1...5 { _ = g.recordRefusal() }
        XCTAssertTrue(g.gaveUp)
        g.reset()
        XCTAssertFalse(g.gaveUp)
        XCTAssertEqual(g.refusals, 0)
        // After reset it takes the full threshold again to re-trip.
        for _ in 1...4 { XCTAssertFalse(g.recordRefusal()) }
        XCTAssertTrue(g.recordRefusal())
    }

    // A custom (lower) threshold trips sooner; used to keep the tests fast and to document the knob.
    func testCustomThreshold() {
        var g = BondRefusalGiveUp(giveUpThreshold: 2)
        XCTAssertFalse(g.recordRefusal())
        XCTAssertTrue(g.recordRefusal())
        XCTAssertTrue(g.gaveUp)
    }

    // #750: the epitaph records the streak + opaque id and carries NO PII (no MAC pattern, no WHOOP serial).
    func testEpitaphLineHasNoPii() {
        let line = BondRefusalGiveUp.epitaphLine(refusals: 5, opaqueId: "a1b2c3d4")
        XCTAssertTrue(line.contains("refused the encrypted bond 5x"))
        XCTAssertTrue(line.contains("a1b2c3d4"))
        // No raw MAC (colon-separated hex octets) and no em-dash.
        XCTAssertFalse(line.range(of: #"[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:"#, options: .regularExpression) != nil)
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    // #750: the opaque id is just the first 8 hex chars of the install-local CB UUID; stable, no PII.
    func testOpaqueIdIsShortHexPrefix() {
        let id = BondRefusalGiveUp.opaqueId(fromLocalUUID: "A1B2C3D4-E5F6-7890-ABCD-EF0123456789")
        XCTAssertEqual(id, "a1b2c3d4")
        XCTAssertEqual(id.count, 8)
    }

    // #747: the paused hint explains the stop + the fix, with no em-dash.
    func testPausedHintWording() {
        let hint = BondRefusalGiveUp.pausedHint()
        XCTAssertTrue(hint.contains("stopped retrying"))
        XCTAssertTrue(hint.contains("Forget This Device"))
        XCTAssertFalse(hint.contains("\u{2014}"))
    }

    // MARK: - pairing mode: one procedure, WHOOP's own

    /// The wizard said "on your wrist and awake", and none of the hints said to take the band off first.
    /// WHOOP's procedure starts from an off-wrist band with its green lights dark. Pinned verbatim because the
    /// Kotlin twin must carry the same bytes. Kotlin twin: `BondRefusalGiveUpTest."the pairing-mode steps are
    /// WHOOP's off-wrist procedure"`.
    func testPairingModeStepsAreTheOffWristProcedure() {
        XCTAssertEqual(
            "take the band off your wrist and wait for the green lights underneath to go dark, then tap the top of the band quickly and repeatedly until its light flashes blue",
            BondRefusalGiveUp.whoopPairingModeSteps)
        XCTAssertFalse(BondRefusalGiveUp.whoopPairingModeSteps.contains("\u{2014}"))
    }

    /// Every hint that sends someone to pairing mode reads the one procedure, so they cannot drift apart.
    func testEveryHintThatNamesPairingModeCarriesTheSharedSteps() {
        for t in [BondRefusalGiveUp.pausedHint(), BondRefusalGiveUp.helloSuppressedHint(),
                  BondRefusalGiveUp.refusingToPairHint()] {
            XCTAssertTrue(t.contains("pairing mode: \(BondRefusalGiveUp.whoopPairingModeSteps)"), t)
            XCTAssertFalse(t.contains("flash blue (pairing mode)"), t)
            XCTAssertTrue(t.contains("straight away"), t)
        }
    }

    /// The pairing window is the step that runs out, so it comes after the phone's Bluetooth settings, in
    /// WHOOP's order. Both hints used to send people to pairing mode first and then into Settings.
    func testForgettingTheOldPairingComesBeforePairingMode() {
        for t in [BondRefusalGiveUp.pausedHint(), BondRefusalGiveUp.refusingToPairHint()] {
            let forget = t.range(of: "Forget This Device")
            let pairing = t.range(of: "pairing mode")
            XCTAssertNotNil(forget, t)
            XCTAssertNotNil(pairing, t)
            if let forget, let pairing { XCTAssertLessThan(forget.lowerBound, pairing.lowerBound, t) }
        }
    }

    /// A per-refusal threshold moves the crossing without duplicating it. Kotlin twin:
    /// `BondRefusalGiveUpTest."a lower threshold latches sooner, and the latch still reports once"`.
    func testPerRefusalThresholdLatchesSoonerAndStillReportsOnce() {
        var g = BondRefusalGiveUp()          // pause threshold 5
        XCTAssertFalse(g.recordRefusal(threshold: 3))
        XCTAssertFalse(g.recordRefusal(threshold: 3))
        XCTAssertTrue(g.recordRefusal(threshold: 3), "crossed at 3, not 5")
        XCTAssertTrue(g.gaveUp)
        XCTAssertFalse(g.recordRefusal(threshold: 3), "the latch reports exactly once")
        XCTAssertEqual(4, g.refusals)
    }

    /// Omitting it keeps the constructed threshold, so every existing caller is unchanged.
    func testOmittingTheThresholdKeepsTheConstructedOne() {
        var g = BondRefusalGiveUp()
        XCTAssertEqual(5, g.giveUpThreshold)
        for _ in 1...4 { XCTAssertFalse(g.recordRefusal()) }
        XCTAssertTrue(g.recordRefusal())
    }

}
