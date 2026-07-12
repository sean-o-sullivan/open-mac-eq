import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SpikeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("openEq")
                    .font(.title2.bold())
                Text("Device-specific Core Audio tap → tested biquad cascade → selected output")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("Output", selection: $model.selectedUID) {
                    if model.devices.isEmpty {
                        Text("No output devices visible").tag("")
                    }
                    ForEach(model.devices) { device in
                        Text(deviceLabel(device)).tag(device.uid)
                    }
                }
                .disabled(model.isRunning)

                Button("Refresh") {
                    model.refreshDevices()
                }
                .disabled(model.isRunning)
            }

            GroupBox("Selected device") {
                if let device = model.selectedDevice {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        detailRow("Name", model.displayName(for: device))
                        detailRow("Transport", device.transportName)
                        detailRow("Default output", device.isDefaultOutput ? "Yes" : "No")
                        detailRow("Sample rate", String(format: "%.1f Hz", device.sampleRate))
                        detailRow(
                            "Buffer",
                            "\(device.bufferFrameSize) frames" +
                            (device.bufferDurationMilliseconds.map { String(format: " (%.2f ms)", $0) } ?? "")
                        )
                        detailRow(
                            "Latency / safety",
                            "\(device.deviceLatencyFrames) / \(device.safetyOffsetFrames) frames"
                        )
                        detailRow("Profile binding", "Exact device identity stored locally")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    Toggle("Hide device identity", isOn: $model.hideDeviceIdentity)
                        .toggleStyle(.checkbox)
                } else {
                    Text("No device selected.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if model.isRunning {
                    Button("Close EQ", role: .destructive) {
                        model.stopButtonPressed()
                    }
                } else {
                    Button("Open EQ") {
                        model.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                }
                Text(model.status)
                    .foregroundStyle(model.isRunning ? .green : .secondary)
            }

            GroupBox("Profiles") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(
                        "Active profile",
                        selection: Binding<UUID?>(
                            get: { model.activeProfile?.id },
                            set: { model.selectProfile(id: $0) }
                        )
                    ) {
                        Text("Unsaved validation controls").tag(nil as UUID?)
                        if let active = model.activeProfile, !model.isActiveProfileSaved {
                            Text("\(active.name) — unsaved").tag(active.id as UUID?)
                        }
                        ForEach(model.profilesForSelectedDevice) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }

                    HStack {
                        TextField("Profile name", text: $model.profileNameDraft)
                        Button("New profile") {
                            model.createNewProfile()
                        }
                        Button("Load AirPods Pro 3 ANC preset") {
                            model.loadBuiltInJM1Profile()
                        }
                        if model.activeProfile == nil {
                            Button("Save current peak") {
                                model.createProfileFromValidationControls()
                            }
                        } else {
                            Button("Save") {
                                model.saveActiveProfileChanges()
                            }
                            if model.isActiveProfileSaved {
                                Button("Delete", role: .destructive) {
                                    model.deleteActiveProfile()
                                }
                            }
                        }
                    }

                    Picker(
                        "When this device becomes the output",
                        selection: Binding<ProfileAutoApplyBehavior>(
                            get: { model.autoApplyBehavior },
                            set: { try? model.setAutoApplyBehavior($0) }
                        )
                    ) {
                        Text("Ask").tag(ProfileAutoApplyBehavior.ask)
                        Text("Always apply last profile").tag(ProfileAutoApplyBehavior.always)
                        Text("Never auto-apply").tag(ProfileAutoApplyBehavior.never)
                    }

                    HStack {
                        Toggle(
                            "Launch at login",
                            isOn: Binding(
                                get: { model.launchAtLoginEnabled },
                                set: { model.setLaunchAtLoginEnabled($0) }
                            )
                        )
                        Toggle(
                            "Start EQ automatically when saved device/profile are ready",
                            isOn: $model.autoStartWhenOutputSelected
                        )
                    }
                    Text("Closing the window leaves EQ running from the menu-bar icon. Automatic start requires a saved profile and no pending Ask prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let offered = model.pendingProfileOffer {
                        HStack {
                            Text("Apply last-used profile \"\(offered.name)\"?")
                            Spacer()
                            Button("Not now") { model.dismissPendingProfile() }
                            Button("Apply") { model.applyPendingProfile(always: false) }
                            Button("Always apply") { model.applyPendingProfile(always: true) }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(8)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            GroupBox("Parametric editor") {
                ParametricEQEditor(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("DSP validation controls") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable real-time DSP", isOn: $model.dspEnabled)

                    HStack {
                        Text("Peak frequency")
                            .frame(width: 105, alignment: .leading)
                        Slider(
                            value: $model.testFrequencyLog10,
                            in: log10(20.0)...log10(20_000.0)
                        )
                        Text(String(format: "%.0f Hz", model.testFrequencyHz))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }

                    HStack {
                        Text("Peak gain")
                            .frame(width: 105, alignment: .leading)
                        Slider(value: $model.testGainDb, in: -12...12)
                        Text(String(format: "%+.1f dB", model.testGainDb))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }

                    HStack {
                        Text("Peak Q")
                            .frame(width: 105, alignment: .leading)
                        Slider(value: $model.testQ, in: 0.1...10)
                        Text(String(format: "%.2f", model.testQ))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }

                    Picker("Active sections", selection: $model.stressBandCount) {
                        Text("1 band").tag(1)
                        Text("10 bands").tag(10)
                        Text("32 bands").tag(32)
                    }
                    .pickerStyle(.segmented)

                    Text("Band 1 is the audible peak above; remaining sections are neutral but execute the full biquad workload. Updates crossfade between independent filter banks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!model.isRunning || model.activeProfile != nil)
            }

            GroupBox("Live diagnostics") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    detailRow("Callbacks", "\(model.snapshot.callbackCount)")
                    detailRow("Frames processed", "\(model.snapshot.frameCount)")
                    detailRow("Last callback", "\(model.snapshot.lastFrameCount) frames")
                    detailRow("Active bands", "\(model.snapshot.activeBandCount)")
                    detailRow("DSP updates", "\(model.snapshot.dspConfigurationApplyCount)")
                    detailRow("Crossfade remaining", "\(model.snapshot.crossfadeFramesRemaining) frames")
                    detailRow(
                        "Input / output buffers",
                        "\(model.snapshot.inputBufferCount) / \(model.snapshot.outputBufferCount)"
                    )
                    detailRow(
                        "Timestamp delta",
                        String(format: "%.3f ms", model.snapshot.timestampDeltaMilliseconds)
                    )
                    detailRow(
                        "Callback DSP time (last / max)",
                        String(
                            format: "%.3f / %.3f ms",
                            model.snapshot.lastProcessingMilliseconds,
                            model.snapshot.maximumProcessingMilliseconds
                        )
                    )
                    detailRow("Processor overloads", "\(model.snapshot.processorOverloadCount)")
                    detailRow("Non-finite outputs", "\(model.snapshot.nonFiniteOutputCount)")
                    detailRow("Format mismatches", "\(model.snapshot.formatMismatchCount)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .monospacedDigit()
            }

            GroupBox("Event log") {
                ScrollView {
                    Text(model.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 130)
            }
            }
            .padding(20)
        }
        .frame(minWidth: 800, minHeight: 1_080)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                model.poll()
            }
        }
    }

    private func deviceLabel(_ device: AudioDeviceDescriptor) -> String {
        let defaultSuffix = device.isDefaultOutput ? " — default" : ""
        let airPodsSuffix = device.isAirPodsPro ? " — AirPods Pro" : ""
        return "\(model.displayName(for: device))\(airPodsSuffix)\(defaultSuffix)"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
