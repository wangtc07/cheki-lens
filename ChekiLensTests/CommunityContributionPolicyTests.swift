import XCTest
@testable import ChekiLens

final class CommunityContributionPolicyTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CommunityContributionPolicyTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        testDefaults = nil
        try super.tearDownWithError()
    }

    func testFreeUserCanToggleSharingAndSeeHalfPriceEligibility() {
        var state = CommunityContributionState.optedOutFree
        XCTAssertFalse(state.isProUnlocked)
        XCTAssertFalse(state.isSharingEnabled)
        XCTAssertFalse(state.isSharingToggleLocked)
        XCTAssertFalse(state.isEligibleForHalfPricePro)
        XCTAssertEqual(state.fallbackDisplayPrice, "NT$120 / ¥600")

        state = CommunityContributionPolicy.reduce(state: state, action: .setSharingPreference(true))
        XCTAssertEqual(state, .optedInFree)
        XCTAssertFalse(state.isProUnlocked)
        XCTAssertTrue(state.isSharingEnabled)
        XCTAssertFalse(state.isSharingToggleLocked)
        XCTAssertTrue(state.isEligibleForHalfPricePro)
        XCTAssertEqual(state.fallbackDisplayPrice, "NT$60 / ¥300")

        state = CommunityContributionPolicy.reduce(state: state, action: .setSharingPreference(false))
        XCTAssertEqual(state, .optedOutFree)
        XCTAssertFalse(state.isSharingEnabled)
        XCTAssertFalse(state.isEligibleForHalfPricePro)
    }

    func testContributorProPermanentlyLocksSharingToggle() {
        var state = CommunityContributionState.optedInFree
        state = CommunityContributionPolicy.reduce(state: state, action: .unlockContributorPro)

        XCTAssertEqual(state, .lockedByContributorPro)
        XCTAssertTrue(state.isProUnlocked)
        XCTAssertTrue(state.isSharingEnabled)
        XCTAssertTrue(state.isSharingToggleLocked)
        XCTAssertFalse(state.isEligibleForHalfPricePro)

        // Attempting to turn off sharing after purchasing half-price Contributor Pro must be ignored
        let attemptedOptOut = CommunityContributionPolicy.reduce(state: state, action: .setSharingPreference(false))
        XCTAssertEqual(attemptedOptOut, .lockedByContributorPro)
        XCTAssertTrue(attemptedOptOut.isSharingEnabled)
        XCTAssertTrue(attemptedOptOut.isSharingToggleLocked)
    }

    func testStandardProAllowsFreeSharingToggle() {
        var state = CommunityContributionState.optedOutFree
        state = CommunityContributionPolicy.reduce(state: state, action: .unlockStandardPro)

        XCTAssertEqual(state, .standardPro(isSharingEnabled: false))
        XCTAssertTrue(state.isProUnlocked)
        XCTAssertFalse(state.isSharingEnabled)
        XCTAssertFalse(state.isSharingToggleLocked)

        state = CommunityContributionPolicy.reduce(state: state, action: .setSharingPreference(true))
        XCTAssertEqual(state, .standardPro(isSharingEnabled: true))
        XCTAssertTrue(state.isSharingEnabled)

        state = CommunityContributionPolicy.reduce(state: state, action: .setSharingPreference(false))
        XCTAssertEqual(state, .standardPro(isSharingEnabled: false))
        XCTAssertFalse(state.isSharingEnabled)
    }

    func testStorePersistenceReconcilesLockedContributorStateAcrossReloads() {
        let store = CommunityContributionStore(defaults: testDefaults)
        XCTAssertEqual(store.loadState(), .optedOutFree)

        store.apply(.setSharingPreference(true))
        XCTAssertEqual(store.loadState(), .optedInFree)

        store.apply(.unlockContributorPro)
        XCTAssertEqual(store.loadState(), .lockedByContributorPro)
        XCTAssertTrue(testDefaults.bool(forKey: CommunityContributionStore.proUnlockedStorageKey))
        XCTAssertTrue(testDefaults.bool(forKey: CommunityContributionStore.contributorProLockedStorageKey))
        XCTAssertTrue(testDefaults.bool(forKey: CommunityContributionStore.sharingEnabledStorageKey))

        // Reload in a fresh store instance and attempt to disable sharing
        let reloadedStore = CommunityContributionStore(defaults: testDefaults)
        let afterDisableAttempt = reloadedStore.apply(.setSharingPreference(false))
        XCTAssertEqual(afterDisableAttempt, .lockedByContributorPro)
        XCTAssertTrue(testDefaults.bool(forKey: CommunityContributionStore.sharingEnabledStorageKey))
    }
}
