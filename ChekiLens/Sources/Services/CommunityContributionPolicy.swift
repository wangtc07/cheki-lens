import Foundation

// MARK: - Domain State Machine

/// Explicit domain state for community alignment sharing and Pro entitlement tier.
nonisolated enum CommunityContributionState: Equatable, Sendable {
    case optedOutFree
    case optedInFree
    case lockedByContributorPro
    case standardPro(isSharingEnabled: Bool)

    var isProUnlocked: Bool {
        switch self {
        case .optedOutFree, .optedInFree:
            return false
        case .lockedByContributorPro, .standardPro:
            return true
        }
    }

    var isSharingEnabled: Bool {
        switch self {
        case .optedOutFree:
            return false
        case .optedInFree, .lockedByContributorPro:
            return true
        case .standardPro(let isSharingEnabled):
            return isSharingEnabled
        }
    }

    /// Once unlocked via the half-price Contributor Pro tier, the sharing toggle is permanently locked on.
    var isSharingToggleLocked: Bool {
        if case .lockedByContributorPro = self {
            return true
        }
        return false
    }

    /// Free users who opt in to sharing are eligible for the half-price Contributor Pro offer.
    var isEligibleForHalfPricePro: Bool {
        if case .optedInFree = self {
            return true
        }
        return false
    }

    var fallbackDisplayPrice: String {
        isEligibleForHalfPricePro ? "NT$60 / ¥300" : "NT$120 / ¥600"
    }
}

nonisolated enum CommunityContributionAction: Equatable, Sendable {
    case setSharingPreference(Bool)
    case unlockContributorPro
    case unlockStandardPro
    case revokeAllProEntitlements
}

// MARK: - Pure Reducer

nonisolated enum CommunityContributionPolicy {
    static func reduce(
        state: CommunityContributionState,
        action: CommunityContributionAction
    ) -> CommunityContributionState {
        switch action {
        case .setSharingPreference(let enabled):
            switch state {
            case .optedOutFree, .optedInFree:
                return enabled ? .optedInFree : .optedOutFree
            case .lockedByContributorPro:
                return .lockedByContributorPro
            case .standardPro:
                return .standardPro(isSharingEnabled: enabled)
            }

        case .unlockContributorPro:
            return .lockedByContributorPro

        case .unlockStandardPro:
            return .standardPro(isSharingEnabled: state.isSharingEnabled)

        case .revokeAllProEntitlements:
            return state.isSharingEnabled ? .optedInFree : .optedOutFree
        }
    }
}

// MARK: - Persistence Adapter

nonisolated struct CommunityContributionStore: Sendable {
    static let sharingEnabledStorageKey = "isCommunityAlignmentSharingEnabled"
    static let contributorProLockedStorageKey = "isContributorHalfPriceProLocked"
    static let proUnlockedStorageKey = "isProLifetimeUnlocked"

    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadState() -> CommunityContributionState {
        let isContributorLocked = defaults.bool(forKey: Self.contributorProLockedStorageKey)
        if isContributorLocked {
            return .lockedByContributorPro
        }

        let isPro = defaults.bool(forKey: Self.proUnlockedStorageKey)
        let isSharing = defaults.bool(forKey: Self.sharingEnabledStorageKey)
        if isPro {
            return .standardPro(isSharingEnabled: isSharing)
        }
        return isSharing ? .optedInFree : .optedOutFree
    }

    @discardableResult
    func apply(_ action: CommunityContributionAction) -> CommunityContributionState {
        let current = loadState()
        let next = CommunityContributionPolicy.reduce(state: current, action: action)
        saveState(next)
        return next
    }

    func saveState(_ state: CommunityContributionState) {
        switch state {
        case .optedOutFree:
            defaults.set(false, forKey: Self.proUnlockedStorageKey)
            defaults.set(false, forKey: Self.contributorProLockedStorageKey)
            defaults.set(false, forKey: Self.sharingEnabledStorageKey)

        case .optedInFree:
            defaults.set(false, forKey: Self.proUnlockedStorageKey)
            defaults.set(false, forKey: Self.contributorProLockedStorageKey)
            defaults.set(true, forKey: Self.sharingEnabledStorageKey)

        case .lockedByContributorPro:
            defaults.set(true, forKey: Self.proUnlockedStorageKey)
            defaults.set(true, forKey: Self.contributorProLockedStorageKey)
            defaults.set(true, forKey: Self.sharingEnabledStorageKey)

        case .standardPro(let isSharingEnabled):
            defaults.set(true, forKey: Self.proUnlockedStorageKey)
            defaults.set(false, forKey: Self.contributorProLockedStorageKey)
            defaults.set(isSharingEnabled, forKey: Self.sharingEnabledStorageKey)
        }
    }
}
