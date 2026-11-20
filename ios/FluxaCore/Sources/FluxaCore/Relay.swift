import Foundation

// Le relais de partage de FLUXA : un mandataire ouvert sur l'iPhone, par lequel passe le
// trafic des appareils du partage réglés sur lui (voir ios/Shaper/src/relay.rs). Le
// relais pose réellement le plafond et le confirme : la limite est alors « partielle »,
// appliquée au trafic relayé, et à lui seul. iOS ne permet pas de limiter le partage
// lui-même.

extension FluxaEngine {
    /// Le plafond appliqué par le relais. Il remplace la réponse de la dernière demande :
    /// statut `partial`, plafond effectif égal au plafond demandé.
    @discardableResult
    public func confirmRelayLimit(_ policy: BandwidthPolicy) throws -> ApplyResult {
        try Rules.validate(policy)
        let result = ApplyResult(
            requested: policy,
            effective: policy,
            status: .partial,
            reason: Rules.relayLimitReason,
            capability: .hotspotLimit,
            date: now()
        )
        state.lastApplyResult = result
        state.policyLog.append(result)
        if state.policyLog.count > Self.policyLogCapacity {
            state.policyLog.removeFirst(state.policyLog.count - Self.policyLogCapacity)
        }
        log(.info, "Limite appliquée par le relais au trafic relayé (partielle).", at: result.date)
        saveQuietly()
        return result
    }

    /// Le relais s'est arrêté : une limite qu'il appliquait redevient simulée.
    public func relayStopped() {
        guard let result = state.lastApplyResult, result.status == .partial else { return }
        request(result.requested, forDevice: false)
        log(.info, "Relais arrêté : la limite redevient simulée.")
        saveQuietly()
    }
}
