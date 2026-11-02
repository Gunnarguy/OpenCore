import Foundation

extension Receipt {
    public var isRequestAudit: Bool { stages.contains { $0.name == "cloud.request-audit" } }
    /// Recorded app activity, not a packet audit or an assertion about other processes.
    public var hasOutboundActivity: Bool {
        objectsTransmitted > 0 || stages.contains {
            $0.name == "companion.delivery" || ($0.name == "cloud.request" && $0.counters["request_submitted"] == 1)
        }
    }

    public var hasUnconfirmedCloudDelivery: Bool {
        stages.contains { $0.name == "cloud.request" && $0.counters["request_submitted"] == 1 && $0.counters["application_acknowledged"] != 1 }
    }

    public var outboundStatusLabel: String {
        if hasUnconfirmedCloudDelivery { return "CLOUD DELIVERY UNCONFIRMED" }
        return hasOutboundActivity ? "OUTBOUND ACTIVITY RECORDED" : "NO OUTBOUND DELIVERY RECORDED"
    }

    /// One presentation shared by Mac, phone, CLI and model-facing traces. Counts refer to
    /// source objects only, excluding question/instruction bytes and provider retention.
    public var outboundDescription: String {
        var descriptions: [String] = []
        if isRequestAudit {
            descriptions.append("Request audit; no completed answer delivery recorded.")
        }
        for stage in stages where stage.name == "cloud.request" {
            guard stage.counters["request_submitted"] == 1 else {
                descriptions.append("Cloud request not submitted.")
                continue
            }
            let count = stage.counters["objects_submitted"].map(String.init) ?? "unmeasured"
            if stage.counters["application_acknowledged"] == 1 {
                descriptions.append("Cloud response acknowledged: \(count) source objects; " +
                    (stage.counters["answer_decoded"] == 1 ? "answer decoded." : "no usable answer decoded."))
            } else {
                descriptions.append("Cloud submission: \(count) source objects; delivery unconfirmed.")
            }
        }
        for stage in stages where stage.name == "companion.delivery" {
            let count = stage.counters["phone_objects"].map(String.init) ?? "unmeasured"
            descriptions.append("Phone delivery acknowledged: \(count) source objects.")
        }
        if descriptions.isEmpty {
            descriptions.append("Recorded source-object transmissions: \(objectsTransmitted). Attempt details unavailable.")
        }
        return descriptions.joined(separator: " ")
    }
}
