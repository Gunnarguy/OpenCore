---
paths:
  - "Apps/OpenCoreMac/Sources/ComputerControlView.swift"
  - "Apps/OpenCoreMac/Sources/ComputerUsePowerhouse.swift"
  - "Apps/OpenCoreMac/Sources/OperatorConsoleService.swift"
  - "Apps/OpenCoreMac/Sources/HardwareUSBView.swift"
  - "Apps/OpenCoreMac/Sources/BetterDisplay*.swift"
  - "Apps/OpenCoreMac/Sources/ConnectedDisplay*.swift"
  - "Apps/OpenCoreMac/Sources/Model*.swift"
  - "Apps/OpenCoreMac/Sources/Provider*.swift"
  - "Apps/OpenCoreMac/Sources/Monitor*.swift"
  - "Apps/OpenCoreMac/Sources/JarvisHUDView.swift"
  - "Sources/CoreTelemetry/**/*.swift"
---

# Operator console rules

The operator half acts on the Mac and writes no objects and no receipts. It is not evidence, and
nothing here may be described as if it were. It shares no data path with the store except fleet-fed
file sync.

## Never, from an agent

- **No write to a physical monitor, USB device or the Local Hub** to test a layout or a change. An
  unknown-outcome display write blocks every later write until BetterDisplay replies.
- **No live computer control.** An agent never clicks or types live to test it. The app-side safety
  decisions are in `CoreTelemetry/ComputerUseControl.swift`, and the Local Hub gaps in `Docs/ai/STATE.md`
  are still open.
- **No edit to the Local Hub repository from here.** It is a separate repository, runs an installed
  snapshot, and has its own uncommitted work. Report what it needs.

## Display writes

Display logic that can be tested lives in `CoreTelemetry`. Writes go through the lease and read-back in
`BetterDisplayControlStore`, and a native mode change keeps its Keep or Revert window. An input or power
change needs a named confirmation. A saved value that reads back is provider state, not a measurement of
the panel, and an empty or failed read never certifies a timestamp.

## Private values

The Hub's path and identity and the automation tool's path come from `LocalPrivateNames.localAutomation`.
With the file missing the Hub reads as not running and no token is fetched. Never print the Hub's token,
and name no monitor, drive or machine in a tracked file: a vendor table may name a company, and nothing
may say which one is the owner's.

## Child processes

Use `BoundedProcess` from `CoreTelemetry`, which drains both pipes and enforces a timeout. Nothing in the
app kills another process, and that stays true.
