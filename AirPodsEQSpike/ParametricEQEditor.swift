import SwiftUI
import UniformTypeIdentifiers

struct ParametricEQEditor: View {
    @ObservedObject var model: SpikeViewModel
    @State private var isImportingReferenceCurve = false
    @State private var isImportingProfile = false
    @State private var isShowingProfilePaste = false

    var body: some View {
        if let profile = model.activeProfile {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Preamp")
                    Slider(
                        value: Binding(
                            get: { profile.preampDb },
                            set: { model.updatePreamp($0) }
                        ),
                        in: -24...12
                    )
                    Text(String(format: "%+.1f dB", profile.preampDb))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                    Toggle("Phase", isOn: $model.showPhaseResponse)
                        .toggleStyle(.checkbox)

                    Menu("Add band") {
                        ForEach(BiquadFilterType.allCases, id: \.self) { type in
                            Button(type.displayName) { model.addBand(type: type) }
                        }
                    }
                    Menu("Profile I/O") {
                        Button("Paste EQ text…") { isShowingProfilePaste = true }
                        Button("Import text or JSON…") { isImportingProfile = true }
                        Button("Load AirPods Pro 3 JM-1 preset") { model.loadBuiltInJM1Profile() }
                        Divider()
                        Button("Export JSON…") { model.exportActiveProfileJSON() }
                    }
                    Button("Load reference") { isImportingReferenceCurve = true }
                    if profile.referenceCurve != nil {
                        Button("Clear reference") { model.clearReferenceCurve() }
                    }
                    Button("Save profile") { model.saveActiveProfileChanges() }
                        .buttonStyle(.borderedProminent)
                }

                FrequencyResponseGraph(
                    profile: profile,
                    sampleRate: model.graphSampleRate,
                    selectedBandID: model.selectedBandID,
                    showPhase: model.showPhaseResponse,
                    onSelectBand: { model.selectedBandID = $0 },
                    onUpdateBand: model.updateBand
                )
                .frame(height: 330)

                HStack(spacing: 14) {
                    Label("Combined magnitude", systemImage: "minus")
                        .foregroundStyle(.tint)
                    if model.showPhaseResponse {
                        Label("Phase ±360°", systemImage: "line.diagonal")
                            .foregroundStyle(.orange)
                    }
                    if profile.referenceCurve != nil {
                        Label("Reference", systemImage: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Drag node: frequency/gain · Scroll: Q · Shift: fine")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                    GridRow {
                        Text("On")
                        Text("#")
                        Text("Type")
                        Text("Frequency (Hz)")
                        Text("Gain (dB)")
                        Text("Q")
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(Array(profile.bands.enumerated()), id: \.element.id) { index, band in
                        bandRow(band, index: index, total: profile.bands.count)
                    }
                }
            }
            .fileImporter(
                isPresented: $isImportingReferenceCurve,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]
            ) { result in
                guard case .success(let url) = result else { return }
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
                }
                model.importReferenceCurve(from: url)
            }
            .fileImporter(
                isPresented: $isImportingProfile,
                allowedContentTypes: [.json, .plainText]
            ) { result in
                guard case .success(let url) = result else { return }
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
                }
                model.importProfileFile(from: url)
            }
            .sheet(isPresented: $isShowingProfilePaste) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste EQ profile")
                        .font(.title2.bold())
                    Text("Accepts `Preamp:` and Equalizer APO-style `Filter n: ON PK Fc … Gain … Q …` lines.")
                        .foregroundStyle(.secondary)
                    TextField("Profile name", text: $model.profileNameDraft)
                    TextEditor(text: $model.profileTextDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 680, minHeight: 320)
                        .border(.separator)
                    HStack {
                        Spacer()
                        Button("Cancel") { isShowingProfilePaste = false }
                        Button("Apply") {
                            model.applyPastedProfileText()
                            isShowingProfilePaste = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "No profile selected",
                systemImage: "slider.horizontal.3",
                description: Text("Create a profile or save the validation peak to open the arbitrary-band editor.")
            )
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func bandRow(_ band: EQBand, index: Int, total: Int) -> some View {
        GridRow {
            Toggle("", isOn: bandBinding(band, \.enabled))
                .labelsHidden()
            Text("\(index + 1)")
                .monospacedDigit()
            Picker("", selection: bandBinding(band, \.type)) {
                ForEach(BiquadFilterType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(minWidth: 112)

            TextField("Frequency", value: bandBinding(band, \.frequencyHz), format: .number)
                .frame(minWidth: 105)
                .multilineTextAlignment(.trailing)
            TextField("Gain", value: bandBinding(band, \.gainDb), format: .number)
                .frame(minWidth: 80)
                .multilineTextAlignment(.trailing)
                .disabled(!band.type.usesGain)
            TextField("Q", value: bandBinding(band, \.q), format: .number)
                .frame(minWidth: 70)
                .multilineTextAlignment(.trailing)

            HStack(spacing: 4) {
                Button {
                    model.moveBand(id: band.id, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button {
                    model.moveBand(id: band.id, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == total - 1)
                Button(role: .destructive) {
                    model.removeBand(id: band.id)
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .background(
            band.id == model.selectedBandID ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onTapGesture { model.selectedBandID = band.id }
    }

    private func bandBinding<Value>(
        _ band: EQBand,
        _ keyPath: WritableKeyPath<EQBand, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                model.activeProfile?.bands.first(where: { $0.id == band.id })?[keyPath: keyPath]
                    ?? band[keyPath: keyPath]
            },
            set: { value in
                var updated = model.activeProfile?.bands.first(where: { $0.id == band.id }) ?? band
                updated[keyPath: keyPath] = value
                model.updateBand(updated)
            }
        )
    }
}
