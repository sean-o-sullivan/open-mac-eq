import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class RealtimeDiagnosticsModel: ObservableObject {
    @Published private(set) var snapshot = PassThroughSnapshot.zero

    func publish(_ snapshot: PassThroughSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}

@MainActor
final class SpikeViewModel: ObservableObject {
    @Published private(set) var devices: [AudioDeviceDescriptor] = []
    @Published var selectedUID = ""
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Looking for the default output…"
    @Published private(set) var logLines: [String] = []
    @Published var dspEnabled = true {
        didSet { publishDSPConfiguration() }
    }
    @Published var testFrequencyLog10 = log10(1_000.0) {
        didSet { publishDSPConfiguration() }
    }
    @Published var testGainDb = 0.0 {
        didSet { publishDSPConfiguration() }
    }
    @Published var testQ = 1.0 {
        didSet { publishDSPConfiguration() }
    }
    @Published var stressBandCount = 10 {
        didSet { publishDSPConfiguration() }
    }
    @Published private(set) var profiles: [EQProfile] = []
    @Published private(set) var activeProfile: EQProfile?
    @Published private(set) var pendingProfileOffer: EQProfile?
    @Published var profileNameDraft = "My openEq profile"
    @Published private(set) var autoApplyBehavior: ProfileAutoApplyBehavior = .ask
    @Published var selectedBandID: UUID?
    @Published var showPhaseResponse = false
    @Published var profileTextDraft = ""
    @Published var autoStartWhenOutputSelected = SpikeViewModel.initialAutoStartPreference() {
        didSet {
            UserDefaults.standard.set(
                autoStartWhenOutputSelected,
                forKey: "autoStartWhenOutputSelected"
            )
            scheduleAutoStartIfNeeded()
        }
    }
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published var hideDeviceIdentity = UserDefaults.standard.object(
        forKey: "hideDeviceIdentity"
    ) == nil ? true : UserDefaults.standard.bool(forKey: "hideDeviceIdentity") {
        didSet {
            UserDefaults.standard.set(hideDeviceIdentity, forKey: "hideDeviceIdentity")
            refreshDevices()
        }
    }

    private let engine: TapPassThroughEngine?
    private let profileStore: EQProfileStore?
    private let associationStore: DeviceProfileAssociationStore?
    let diagnostics = RealtimeDiagnosticsModel()
    private var runningDeviceUID: String?
    private var runningSampleRate: Double?
    private var lastObservedDefaultOutputUID: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var deviceRefreshTimer: Timer?
    private var pendingDeviceRefresh: DispatchWorkItem?
    private var deviceChangeObserver: AudioDeviceChangeObserver?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressureLevel = SystemMemoryPressureLevel.normal
    private var reliabilityMonitor = AudioReliabilityMonitor()
    private var recentRecoveryTimes: [TimeInterval] = []
    private var isRecovering = false
    private var latestSnapshot = PassThroughSnapshot.zero
    private var lastDiagnosticsPublicationTime = -Double.infinity
    private var lastSuppressedRecoveryLogTime = -Double.infinity

    init() {
        engine = TapPassThroughEngine()
        profileStore = try? EQProfileStore.applicationSupport()
        associationStore = try? DeviceProfileAssociationStore.applicationSupport()
        if engine == nil {
            status = "Could not allocate real-time diagnostics."
            appendLog(status)
        }
        migrateLegacyBundledProfiles()
        reloadProfiles()
        refreshDevices()
        publishDSPConfiguration()
        appendLog("Discovered \(devices.count) output device(s).")
        devices.forEach { device in
            appendLog(
                "Output device: default=\(device.isDefaultOutput), " +
                "alive=\(device.isAlive), rate=\(device.sampleRate), " +
                "buffer=\(device.bufferFrameSize), transport=\(device.transportName)"
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--auto-start") {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
        }
        installWorkspaceObservers()
        installDeviceChangeObserver()
        installMemoryPressureMonitor()
        installMonitoringTimers()
    }

    deinit {
        healthTimer?.invalidate()
        deviceRefreshTimer?.invalidate()
        pendingDeviceRefresh?.cancel()
        memoryPressureSource?.cancel()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var selectedDevice: AudioDeviceDescriptor? {
        devices.first { $0.uid == selectedUID }
    }

    var canStart: Bool {
        guard let device = selectedDevice else { return false }
        return !isRunning && OutputDevicePolicy.isProcessable(device) && engine != nil
    }

    var testFrequencyHz: Double {
        pow(10, testFrequencyLog10)
    }

    var profilesForSelectedDevice: [EQProfile] {
        profiles.filter { $0.deviceUID == selectedUID }
    }

    var graphSampleRate: Double {
        runningSampleRate ?? selectedDevice?.sampleRate ?? 48_000
    }

    var isActiveProfileSaved: Bool {
        guard let activeProfile else { return false }
        return profiles.contains { $0.id == activeProfile.id }
    }

    func displayName(for device: AudioDeviceDescriptor) -> String {
        guard hideDeviceIdentity else { return device.name }
        return "Output device (identity hidden)"
    }

    func refreshDevices() {
        do {
            let updated = try AudioDeviceCatalog.outputDevices()
            if devices != updated {
                devices = updated
            }

            guard validateRunningRoute(using: updated) else { return }
            if !isRunning { refreshSelectionAfterPoll(updated) }
            observeDefaultOutputProfileOpportunity()
        } catch {
            if !isRunning {
                setStatus(error.localizedDescription)
                appendLog("Device refresh failed: \(error.localizedDescription)")
            }
        }
    }

    func start() {
        guard let device = selectedDevice, let engine else { return }
        guard OutputDevicePolicy.isProcessable(device) else {
            updateIdleStatus(using: devices)
            return
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            let otherInstances = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).filter { $0.processIdentifier != getpid() }
            guard otherInstances.isEmpty else {
                status = "Another openEq instance is already running."
                appendLog(status)
                return
            }
        }
        do {
            try configureDSP(sampleRate: device.sampleRate)
            let configuration = try engine.start(device: device)
            runningDeviceUID = device.uid
            runningSampleRate = device.sampleRate
            isRunning = true
            setStatus("DSP active. Play audio and adjust the validation controls.")
            latestSnapshot = engine.snapshot()
            publishLatestDiagnostics(force: true)
            reliabilityMonitor.reset(
                callbackCount: latestSnapshot.callbackCount,
                overloadCount: latestSnapshot.processorOverloadCount,
                now: ProcessInfo.processInfo.systemUptime
            )
            recentRecoveryTimes.removeAll(keepingCapacity: true)
            appendLog("Started fail-open real-time DSP path.")
            configuration.diagnosticLines.forEach(appendLog)
        } catch {
            status = "Start failed: \(error.localizedDescription)"
            appendLog(status)
            stop(reason: nil)
        }
    }

    func stopButtonPressed() {
        stop(reason: "Stopped by user.")
    }

    func poll() {
        guard isRunning, let engine else { return }
        latestSnapshot = engine.snapshot()
        let now = ProcessInfo.processInfo.systemUptime
        publishLatestDiagnostics(now: now)

        if let trigger = reliabilityMonitor.observe(
            callbackCount: latestSnapshot.callbackCount,
            overloadCount: latestSnapshot.processorOverloadCount,
            expectsCallbacks: engine.expectsCallbacks,
            now: now
        ) {
            recoverAudioPath(trigger: trigger)
        }
    }

    private func refreshSelectionAfterPoll(_ updated: [AudioDeviceDescriptor]) {
        if !updated.contains(where: { $0.uid == selectedUID }) {
            selectedUID = updated.first(where: \.isDefaultOutput)?.uid
                ?? updated.first(where: \.isAlive)?.uid
                ?? updated.first?.uid
                ?? ""
        }
        updateIdleStatus(using: updated)
    }

    private func validateRunningRoute(using updated: [AudioDeviceDescriptor]) -> Bool {
        guard isRunning, let runningDeviceUID else { return true }
        guard let current = updated.first(where: { $0.uid == runningDeviceUID }) else {
            stop(reason: "Output device disconnected; tap destroyed.")
            return false
        }
        guard current.isDefaultOutput else {
            stop(reason: "Default output changed; tap destroyed.")
            return false
        }
        guard current.isAlive else {
            stop(reason: "Output device became unavailable; tap destroyed.")
            return false
        }
        if let runningSampleRate, abs(current.sampleRate - runningSampleRate) >= 0.5 {
            stop(reason: "Device sample rate changed; stopped for a safe rebuild.")
            return false
        }
        return true
    }

    func createProfileFromValidationControls() {
        guard let profileStore, !selectedUID.isEmpty else { return }
        do {
            let profile = EQProfile(
                name: profileNameDraft,
                deviceUID: selectedUID,
                bands: [
                    EQBand(
                        type: .peaking,
                        frequencyHz: testFrequencyHz,
                        gainDb: testGainDb,
                        q: testQ
                    ),
                ]
            )
            let saved = try profileStore.save(profile)
            reloadProfiles()
            try activateProfile(saved, rememberForDevice: true)
            appendLog("Saved profile \"\(saved.name)\".")
        } catch {
            status = "Profile save failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func createNewProfile() {
        guard !selectedUID.isEmpty else { return }
        let band = EQBand()
        activeProfile = EQProfile(
            name: "Untitled openEq profile",
            deviceUID: selectedUID,
            bands: [band]
        )
        profileNameDraft = "Untitled openEq profile"
        selectedBandID = band.id
        publishDSPConfiguration()
    }

    func applyPastedProfileText() {
        do {
            try activateImportedProfile(EQTextProfileImporter.decode(
                text: profileTextDraft,
                name: profileNameDraft,
                deviceUID: selectedUID
            ))
        } catch {
            status = "EQ text import failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func importProfileFile(from url: URL) {
        do {
            let data = try readImportData(from: url)
            if url.pathExtension.lowercased() == "json" {
                var profile = try EQProfileCodec.decode(data)
                profile.deviceUID = selectedUID
                try activateImportedProfile(profile)
            } else {
                try activateImportedProfile(EQTextProfileImporter.decode(
                    data: data,
                    name: url.deletingPathExtension().lastPathComponent,
                    deviceUID: selectedUID
                ))
            }
        } catch {
            status = "Profile import failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func loadBuiltInSongbirdJM1Profile() {
        do {
            try activateImportedProfile(bundledSongbirdProfile(deviceUID: selectedUID))
        } catch {
            status = "Built-in profile failed to load: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func exportActiveProfileJSON() {
        guard let activeProfile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = activeProfile.name
            .replacingOccurrences(of: "/", with: "-") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EQProfileCodec.encode(activeProfile).write(to: url, options: .atomic)
            appendLog("Exported profile JSON to \(url.path).")
        } catch {
            status = "Profile export failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func selectProfile(id: UUID?) {
        guard let id else {
            activeProfile = nil
            selectedBandID = nil
            publishDSPConfiguration()
            return
        }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        do {
            try activateProfile(profile, rememberForDevice: true)
        } catch {
            status = "Profile load failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func renameActiveProfile() {
        guard let profileStore, let activeProfile else { return }
        do {
            let renamed = try profileStore.rename(id: activeProfile.id, to: profileNameDraft)
            reloadProfiles()
            self.activeProfile = renamed
            appendLog("Renamed profile to \"\(renamed.name)\".")
        } catch {
            status = "Profile rename failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func saveActiveProfileChanges() {
        guard let profileStore, var activeProfile else { return }
        do {
            activeProfile.name = profileNameDraft
            activeProfile.deviceUID = selectedUID
            let saved = try profileStore.save(activeProfile)
            self.activeProfile = saved
            reloadProfiles()
            try rememberActiveProfileForDevice()
            appendLog("Saved profile \"\(saved.name)\" with \(saved.bands.count) band(s).")
        } catch {
            status = "Profile save failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func updateBand(_ updatedBand: EQBand) {
        guard var profile = activeProfile,
              let index = profile.bands.firstIndex(where: { $0.id == updatedBand.id }) else { return }
        profile.bands[index] = updatedBand
        activeProfile = profile
        selectedBandID = updatedBand.id
        publishDSPConfiguration()
    }

    func addBand(type: BiquadFilterType = .peaking) {
        guard var profile = activeProfile,
              profile.bands.count < EQProfile.maximumBandCount else { return }
        let band = EQBand(type: type)
        profile.bands.append(band)
        activeProfile = profile
        selectedBandID = band.id
        publishDSPConfiguration()
    }

    func removeBand(id: UUID) {
        guard var profile = activeProfile else { return }
        profile.bands.removeAll { $0.id == id }
        activeProfile = profile
        if selectedBandID == id {
            selectedBandID = profile.bands.first?.id
        }
        publishDSPConfiguration()
    }

    func moveBand(id: UUID, offset: Int) {
        guard var profile = activeProfile,
              let source = profile.bands.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard profile.bands.indices.contains(destination) else { return }
        let band = profile.bands.remove(at: source)
        profile.bands.insert(band, at: destination)
        activeProfile = profile
        publishDSPConfiguration()
    }

    func updatePreamp(_ value: Double) {
        guard var profile = activeProfile, value.isFinite else { return }
        profile.preampDb = min(max(value, -24), 12)
        activeProfile = profile
        publishDSPConfiguration()
    }

    func importReferenceCurve(from url: URL) {
        guard var profile = activeProfile else { return }
        do {
            profile.referenceCurve = try ReferenceCurveImporter.decode(
                data: readImportData(from: url),
                name: url.deletingPathExtension().lastPathComponent
            )
            activeProfile = profile
            appendLog("Loaded reference curve \"\(profile.referenceCurve?.name ?? "")\".")
        } catch {
            status = "Reference curve import failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func clearReferenceCurve() {
        guard var profile = activeProfile else { return }
        profile.referenceCurve = nil
        activeProfile = profile
    }

    func deleteActiveProfile() {
        guard let profileStore, let activeProfile else { return }
        do {
            try profileStore.delete(id: activeProfile.id)
            self.activeProfile = nil
            selectedBandID = nil
            reloadProfiles()
            if let associationStore {
                try associationStore.save(DeviceProfileAssociation(
                    deviceUID: selectedUID,
                    lastProfileID: nil,
                    autoApplyBehavior: autoApplyBehavior
                ))
            }
            publishDSPConfiguration()
            appendLog("Deleted profile \"\(activeProfile.name)\".")
        } catch {
            status = "Profile delete failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func applyPendingProfile(always: Bool) {
        guard let pendingProfileOffer else { return }
        do {
            if always {
                try setAutoApplyBehavior(.always)
            }
            try activateProfile(pendingProfileOffer, rememberForDevice: true)
            self.pendingProfileOffer = nil
        } catch {
            status = "Profile apply failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    func dismissPendingProfile() {
        pendingProfileOffer = nil
    }

    func setAutoApplyBehavior(_ behavior: ProfileAutoApplyBehavior) throws {
        autoApplyBehavior = behavior
        guard let associationStore, !selectedUID.isEmpty else { return }
        let rememberedProfileID = isActiveProfileSaved
            ? activeProfile?.id
            : try associationStore.association(for: selectedUID)?.lastProfileID
        try associationStore.save(DeviceProfileAssociation(
            deviceUID: selectedUID,
            lastProfileID: rememberedProfileID,
            autoApplyBehavior: behavior
        ))
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            appendLog("Launch at login \(launchAtLoginEnabled ? "enabled" : "disabled").")
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            status = "Launch-at-login change failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    private func stop(reason: String?) {
        engine?.stop()
        isRunning = false
        runningDeviceUID = nil
        runningSampleRate = nil
        reliabilityMonitor.reset(now: ProcessInfo.processInfo.systemUptime)
        recentRecoveryTimes.removeAll(keepingCapacity: true)
        lastSuppressedRecoveryLogTime = -Double.infinity
        if let reason {
            setStatus(reason)
            appendLog(reason)
        }
        refreshDevices()
    }

    private func recoverAudioPath(trigger: AudioRecoveryTrigger) {
        guard !isRecovering, isRunning, let engine, let runningDeviceUID else { return }
        isRecovering = true
        defer { isRecovering = false }

        let now = ProcessInfo.processInfo.systemUptime
        let previousFrameSize = engine.configuration?.requestedBufferFrameSize
            ?? AudioBufferPolicy.lowLatencyFrameSize
        let action = AudioRecoveryPolicy.action(
            for: trigger,
            currentFrameSize: previousFrameSize,
            memoryPressure: memoryPressureLevel
        )
        switch action {
        case .deferUntilPressureClears:
            if now - lastSuppressedRecoveryLogTime >= 30 {
                appendLog("\(trigger.description); keeping the current route during system memory pressure.")
                lastSuppressedRecoveryLogTime = now
            }
            return
        case .keepCurrentRoute:
            if now - lastSuppressedRecoveryLogTime >= 30 {
                appendLog("\(trigger.description); already at the maximum buffer, so the current route was kept.")
                lastSuppressedRecoveryLogTime = now
            }
            return
        case .rebuild:
            lastSuppressedRecoveryLogTime = -Double.infinity
        }

        recentRecoveryTimes.removeAll { now - $0 > 60 }
        guard recentRecoveryTimes.count < 2 else {
            stop(reason: "Repeated audio-route failures; EQ stopped and direct audio was restored.")
            return
        }
        recentRecoveryTimes.append(now)

        guard case let .rebuild(recoveryFrameSize) = action else { return }
        setStatus("Recovering audio route at \(recoveryFrameSize) frames…")
        appendLog("\(trigger.description); rebuilding at \(recoveryFrameSize) frames.")

        engine.stop()
        do {
            let refreshed = try AudioDeviceCatalog.outputDevices()
            if devices != refreshed {
                devices = refreshed
            }
            guard let device = refreshed.first(where: { $0.uid == runningDeviceUID }),
                  OutputDevicePolicy.isProcessable(device) else {
                throw SpikeError("The selected output is no longer available as the default device.")
            }

            try configureDSP(sampleRate: device.sampleRate)
            let configuration = try engine.start(
                device: device,
                requestedBufferFrameSize: recoveryFrameSize
            )
            runningSampleRate = device.sampleRate
            latestSnapshot = engine.snapshot()
            publishLatestDiagnostics(force: true)
            reliabilityMonitor.reset(
                callbackCount: latestSnapshot.callbackCount,
                overloadCount: latestSnapshot.processorOverloadCount,
                now: ProcessInfo.processInfo.systemUptime
            )
            setStatus("DSP recovered at \(configuration.aggregateBufferFrameSize) frames.")
            appendLog(status)
        } catch {
            stop(reason: "Audio recovery failed; EQ stopped and direct audio was restored: \(error.localizedDescription)")
        }
    }

    private func installMonitoringTimers() {
        let healthTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(healthTimer, forMode: .common)
        self.healthTimer = healthTimer

        let deviceRefreshTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        RunLoop.main.add(deviceRefreshTimer, forMode: .common)
        self.deviceRefreshTimer = deviceRefreshTimer
    }

    private func installDeviceChangeObserver() {
        do {
            deviceChangeObserver = try AudioDeviceChangeObserver { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDeviceRefresh()
                }
            }
        } catch {
            appendLog("Core Audio change notifications unavailable; using the 10-second safety refresh.")
        }
    }

    private func scheduleDeviceRefresh() {
        pendingDeviceRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingDeviceRefresh = nil
            self?.refreshDevices()
        }
        pendingDeviceRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self, let source = self.memoryPressureSource else { return }
            self.handleMemoryPressureEvent(source.data)
        }
        source.resume()
    }

    private func handleMemoryPressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
        let updatedLevel: SystemMemoryPressureLevel
        if event.contains(.critical) {
            updatedLevel = .critical
        } else if event.contains(.warning) {
            updatedLevel = .warning
        } else {
            updatedLevel = .normal
        }
        guard updatedLevel != memoryPressureLevel else { return }

        let previousLevel = memoryPressureLevel
        memoryPressureLevel = updatedLevel
        lastSuppressedRecoveryLogTime = -Double.infinity
        if isRunning {
            reliabilityMonitor.reset(
                callbackCount: latestSnapshot.callbackCount,
                overloadCount: latestSnapshot.processorOverloadCount,
                now: ProcessInfo.processInfo.systemUptime
            )
        }
        if updatedLevel == .normal {
            if previousLevel != .normal {
                appendLog("System memory pressure returned to normal; audio-route recovery re-enabled.")
            }
        } else {
            appendLog("System memory pressure is \(updatedLevel == .critical ? "critical" : "elevated"); disruptive audio-route rebuilds are deferred.")
        }
    }

    private func publishLatestDiagnostics(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        force: Bool = false
    ) {
        guard force || now - lastDiagnosticsPublicationTime >= 1 else { return }
        diagnostics.publish(latestSnapshot)
        lastDiagnosticsPublicationTime = now
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logLines.append(line)
        if let data = "\(line)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        if logLines.count > 150 {
            logLines.removeFirst(logLines.count - 150)
        }
    }

    private func publishDSPConfiguration() {
        guard let sampleRate = runningSampleRate ?? selectedDevice?.sampleRate else { return }
        do {
            try configureDSP(sampleRate: sampleRate)
        } catch {
            status = "DSP update rejected: \(error.localizedDescription)"
        }
    }

    private func configureDSP(sampleRate: Double) throws {
        guard let engine else { return }
        guard dspEnabled else {
            try engine.setDSPConfiguration(coefficients: [])
            return
        }

        if let activeProfile {
            try engine.setDSPConfiguration(
                coefficients: activeProfile.coefficients(sampleRate: sampleRate),
                preampDb: activeProfile.preampDb
            )
            return
        }

        let count = min(max(stressBandCount, 1), Int(EQRealtimeDSPMaximumBandCount))
        let maximumFrequency = min(20_000, sampleRate * 0.49)
        let primaryFrequency = min(max(testFrequencyHz, 20), maximumFrequency)
        var coefficients = [BiquadCoefficients]()
        coefficients.reserveCapacity(count)

        coefficients.append(try RBJBiquadDesigner.coefficients(
            for: BiquadParameters(
                type: .peaking,
                frequencyHz: primaryFrequency,
                gainDb: min(max(testGainDb, -12), 12),
                q: min(max(testQ, 0.1), 20)
            ),
            sampleRate: sampleRate
        ))

        if count > 1 {
            let low = log10(30.0)
            let high = log10(maximumFrequency)
            for index in 1..<count {
                let position = Double(index - 1) / Double(max(count - 2, 1))
                let frequency = pow(10, low + (high - low) * position)
                coefficients.append(try RBJBiquadDesigner.coefficients(
                    for: BiquadParameters(
                        type: .peaking,
                        frequencyHz: frequency,
                        gainDb: 0,
                        q: 0.5 + Double(index % 7) * 0.35
                    ),
                    sampleRate: sampleRate
                ))
            }
        }

        try engine.setDSPConfiguration(coefficients: coefficients)
    }

    private func reloadProfiles() {
        guard let profileStore else { return }
        do {
            profiles = try profileStore.loadAll()
            if let activeProfile,
               let refreshed = profiles.first(where: { $0.id == activeProfile.id }) {
                self.activeProfile = refreshed
            }
        } catch {
            status = "Profile library failed to load: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    private func migrateLegacyBundledProfiles() {
        guard let profileStore else { return }
        do {
            var migratedCount = 0
            for profile in try profileStore.loadAll() {
                let replacement = try bundledSongbirdProfile(deviceUID: profile.deviceUID)
                guard let migrated = LegacyBundledPresetMigration.replacingExactLegacyPreset(
                    profile,
                    with: replacement
                ) else { continue }
                _ = try profileStore.save(migrated)
                migratedCount += 1
            }
            if migratedCount > 0 {
                let noun = migratedCount == 1 ? "copy" : "copies"
                appendLog(
                    "Replaced \(migratedCount) exact legacy built-in preset \(noun) " +
                    "with the Songbird six-band baseline."
                )
            }
        } catch {
            status = "Built-in profile migration failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    private func bundledSongbirdProfile(deviceUID: String) throws -> EQProfile {
        guard let url = Bundle.main.url(
            forResource: "airpods-pro-3-songbird-jm1-6band",
            withExtension: "txt"
        ) else {
            throw SpikeError("Built-in Songbird JM-1 preset resource is missing.")
        }
        return try EQTextProfileImporter.decode(
            data: Data(contentsOf: url),
            name: "AirPods Pro 3 — Songbird JM-1 6-band",
            deviceUID: deviceUID
        )
    }

    private func activateProfile(_ profile: EQProfile, rememberForDevice: Bool) throws {
        guard profile.deviceUID == selectedUID else {
            throw SpikeError("Profile belongs to a different Core Audio device UID.")
        }
        activeProfile = try profile.validated()
        profileNameDraft = profile.name
        selectedBandID = profile.bands.first?.id
        try configureDSP(sampleRate: runningSampleRate ?? selectedDevice?.sampleRate ?? 48_000)

        if rememberForDevice {
            try rememberActiveProfileForDevice()
        }
        appendLog("Applied profile \"\(profile.name)\" to the selected output device.")
    }

    private func activateImportedProfile(_ profile: EQProfile) throws {
        activeProfile = try profile.validated()
        profileNameDraft = profile.name
        selectedBandID = profile.bands.first?.id
        profileTextDraft = ""
        try configureDSP(sampleRate: graphSampleRate)
        appendLog("Imported \(profile.bands.count)-band profile \"\(profile.name)\"; save to retain it.")
    }

    private func rememberActiveProfileForDevice() throws {
        guard let associationStore else { return }
        try associationStore.save(DeviceProfileAssociation(
            deviceUID: selectedUID,
            lastProfileID: activeProfile?.id,
            autoApplyBehavior: autoApplyBehavior
        ))
    }

    private func observeDefaultOutputProfileOpportunity() {
        let currentUID = devices.first(where: \.isDefaultOutput)?.uid
        guard currentUID != lastObservedDefaultOutputUID else { return }
        lastObservedDefaultOutputUID = currentUID
        pendingProfileOffer = nil
        guard let currentUID else { return }
        if !isRunning {
            selectedUID = currentUID
        }
        if activeProfile?.deviceUID != currentUID {
            activeProfile = nil
        }
        guard let associationStore else {
            autoApplyBehavior = .ask
            return
        }

        do {
            if let association = try associationStore.association(for: currentUID) {
                autoApplyBehavior = association.autoApplyBehavior
                if let profileID = association.lastProfileID,
                   let profile = profiles.first(where: {
                       $0.id == profileID && $0.deviceUID == currentUID
                   }) {
                    switch association.autoApplyBehavior {
                    case .always:
                        try activateProfile(profile, rememberForDevice: false)
                    case .ask:
                        pendingProfileOffer = profile
                    case .never:
                        break
                    }
                }
            } else {
                autoApplyBehavior = .ask
            }
            scheduleAutoStartIfNeeded()
        } catch {
            status = "Device profile association failed: \(error.localizedDescription)"
            appendLog(status)
        }
    }

    private func scheduleAutoStartIfNeeded() {
        guard autoStartWhenOutputSelected,
              !isRunning,
              activeProfile != nil,
              pendingProfileOffer == nil,
              canStart else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.autoStartWhenOutputSelected,
                  !self.isRunning,
                  self.pendingProfileOffer == nil,
                  self.canStart else { return }
            self.start()
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isRunning {
                    self.stop(reason: "Mac is sleeping; stopped DSP and restored direct audio.")
                }
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastObservedDefaultOutputUID = nil
                self.refreshDevices()
                self.appendLog("Mac woke; refreshed output-device and profile association state.")
            }
        })
    }

    private func updateIdleStatus(using devices: [AudioDeviceDescriptor]) {
        if let selected = devices.first(where: { $0.uid == selectedUID }), selected.isAlive {
            if selected.isDefaultOutput {
                setStatus("Ready: \(displayName(for: selected)) is the default output.")
            } else {
                setStatus("Select this device as the macOS default output.")
            }
        } else if devices.contains(where: { $0.isDefaultOutput && $0.isAlive }) {
            setStatus("Select the live default output device.")
        } else {
            setStatus("No live output device is available.")
        }
    }

    private static func initialAutoStartPreference() -> Bool {
        let defaults = UserDefaults.standard
        let key = "autoStartWhenOutputSelected"
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }

        let legacyKey = "autoStartWhenAirPodsSelected"
        guard defaults.object(forKey: legacyKey) != nil else { return false }
        let legacyValue = defaults.bool(forKey: legacyKey)
        defaults.set(legacyValue, forKey: key)
        return legacyValue
    }

    private func readImportData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw SpikeError("Import source must be a regular file.")
        }
        let maximumBytes = 5 * 1_024 * 1_024
        if let fileSize = values.fileSize, fileSize > maximumBytes {
            throw SpikeError("Import files are limited to 5 MB.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else {
            throw SpikeError("Import files are limited to 5 MB.")
        }
        return data
    }
}
