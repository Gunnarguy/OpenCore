import CorePresentation
import CoreStore

// Production ownership stays at the app boundary; the value/state implementation has no
// standard-defaults fallback and cannot reach an app/controller singleton.
typealias AppSettings = CorePresentation.AppSettings

extension CorePresentation.AppSettings {
    @MainActor static let shared: AppSettings = AppSettings(
        defaults: .standard,
        effects: .init(
            scheduledSyncChanged: { AppModel.shared.scheduledSyncSettingChanged() },
            returnToDryRun: { ComputerControlManager.shared.returnToDryRun() },
            mcpExposureChanged: { enabled in
                let result = SharedConfig.setMCPExposure(enabled)
                if let message = result.failureDescription {
                    AppModel.shared.recordAuditFailure("MCP startup preference: " + message)
                }
                return result
            }
        )
    )
}
