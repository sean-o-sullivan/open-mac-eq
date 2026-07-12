import AppKit
import SwiftUI

struct FrequencyResponseGraph: View {
    let profile: EQProfile
    let sampleRate: Double
    let selectedBandID: UUID?
    let showPhase: Bool
    let onSelectBand: (UUID?) -> Void
    let onUpdateBand: (EQBand) -> Void

    private let gainRange = -24.0...24.0

    var body: some View {
        Canvas { context, size in
            let layout = GraphLayout(size: size, sampleRate: sampleRate, gainRange: gainRange)
            drawBackground(in: &context, layout: layout)
            drawReferenceCurve(in: &context, layout: layout)
            drawCombinedResponse(in: &context, layout: layout)
            drawBandNodes(in: &context, layout: layout)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            FrequencyGraphInteraction(
                bands: profile.bands,
                selectedBandID: selectedBandID,
                sampleRate: sampleRate,
                gainRange: gainRange,
                onSelectBand: onSelectBand,
                onUpdateBand: onUpdateBand
            )
        }
        .accessibilityLabel("Parametric EQ frequency response graph")
    }

    private func drawBackground(in context: inout GraphicsContext, layout: GraphLayout) {
        for frequency in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
            where frequency <= layout.maximumFrequency {
            let x = layout.x(for: frequency)
            var line = Path()
            line.move(to: CGPoint(x: x, y: layout.plotRect.minY))
            line.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
            context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
            context.draw(
                Text(Self.frequencyLabel(frequency)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: layout.plotRect.maxY + 13)
            )
        }

        for gain in stride(from: -24.0, through: 24.0, by: 6.0) {
            let y = layout.y(forGain: gain)
            var line = Path()
            line.move(to: CGPoint(x: layout.plotRect.minX, y: y))
            line.addLine(to: CGPoint(x: layout.plotRect.maxX, y: y))
            context.stroke(
                line,
                with: .color(gain == 0 ? .secondary.opacity(0.5) : .secondary.opacity(0.16)),
                lineWidth: gain == 0 ? 1.5 : 1
            )
            context.draw(
                Text(String(format: "%+.0f", gain)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: layout.plotRect.minX - 19, y: y)
            )
        }
    }

    private func drawCombinedResponse(in context: inout GraphicsContext, layout: GraphLayout) {
        guard let coefficients = try? profile.coefficients(sampleRate: sampleRate) else { return }
        let count = 512
        let low = log10(layout.minimumFrequency)
        let high = log10(layout.maximumFrequency)
        let frequencies = (0..<count).map { index in
            pow(10, low + (high - low) * Double(index) / Double(count - 1))
        }
        guard let response = try? BiquadResponseEvaluator.evaluate(
            coefficients: coefficients,
            preampDb: profile.preampDb,
            frequenciesHz: frequencies,
            sampleRate: sampleRate
        ) else { return }

        var magnitude = Path()
        for (index, point) in response.enumerated() {
            let coordinate = CGPoint(
                x: layout.x(for: point.frequencyHz),
                y: layout.y(forGain: point.magnitudeDb)
            )
            index == 0 ? magnitude.move(to: coordinate) : magnitude.addLine(to: coordinate)
        }
        context.stroke(magnitude, with: .color(.accentColor), lineWidth: 2.5)

        if showPhase {
            var phase = Path()
            for (index, point) in response.enumerated() {
                let degrees = point.phaseRadians * 180 / .pi
                let coordinate = CGPoint(
                    x: layout.x(for: point.frequencyHz),
                    y: layout.y(forPhaseDegrees: degrees)
                )
                index == 0 ? phase.move(to: coordinate) : phase.addLine(to: coordinate)
            }
            context.stroke(
                phase,
                with: .color(.orange.opacity(0.8)),
                style: StrokeStyle(lineWidth: 1.5, dash: [7, 4])
            )
        }
    }

    private func drawReferenceCurve(in context: inout GraphicsContext, layout: GraphLayout) {
        guard let curve = profile.referenceCurve, curve.points.count > 1 else { return }
        var path = Path()
        var hasPoint = false
        for point in curve.points
            where point.frequencyHz >= layout.minimumFrequency && point.frequencyHz <= layout.maximumFrequency {
            let coordinate = CGPoint(
                x: layout.x(for: point.frequencyHz),
                y: layout.y(forGain: point.gainDb)
            )
            hasPoint ? path.addLine(to: coordinate) : path.move(to: coordinate)
            hasPoint = true
        }
        guard hasPoint else { return }
        context.stroke(
            path,
            with: .color(.secondary.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.5, dash: [3, 5])
        )
    }

    private func drawBandNodes(in context: inout GraphicsContext, layout: GraphLayout) {
        for (index, band) in profile.bands.enumerated() {
            let selected = band.id == selectedBandID
            let center = layout.nodePoint(for: band)
            let radius = selected ? 9.0 : 7.0
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.fill(circle, with: .color(band.enabled ? .accentColor : .secondary))
            context.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: selected ? 2.5 : 1.5)
            context.draw(
                Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
                at: center
            )
        }
    }

    private static func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1_000 ? String(format: "%gk", frequency / 1_000) : String(format: "%g", frequency)
    }
}

private struct GraphLayout {
    let plotRect: CGRect
    let minimumFrequency = 20.0
    let maximumFrequency: Double
    let gainRange: ClosedRange<Double>

    init(size: CGSize, sampleRate: Double, gainRange: ClosedRange<Double>) {
        plotRect = CGRect(x: 43, y: 12, width: max(size.width - 59, 1), height: max(size.height - 42, 1))
        maximumFrequency = min(20_000, sampleRate * 0.49)
        self.gainRange = gainRange
    }

    func x(for frequency: Double) -> Double {
        let position = (log10(max(frequency, minimumFrequency)) - log10(minimumFrequency)) /
            (log10(maximumFrequency) - log10(minimumFrequency))
        return plotRect.minX + min(max(position, 0), 1) * plotRect.width
    }

    func frequency(forX x: Double) -> Double {
        let position = min(max((x - plotRect.minX) / plotRect.width, 0), 1)
        return pow(
            10,
            log10(minimumFrequency) + position * (log10(maximumFrequency) - log10(minimumFrequency))
        )
    }

    func y(forGain gain: Double) -> Double {
        let clamped = min(max(gain, gainRange.lowerBound), gainRange.upperBound)
        let position = (gainRange.upperBound - clamped) /
            (gainRange.upperBound - gainRange.lowerBound)
        return plotRect.minY + position * plotRect.height
    }

    func y(forPhaseDegrees degrees: Double) -> Double {
        let clamped = min(max(degrees, -360), 360)
        let position = (360 - clamped) / 720
        return plotRect.minY + position * plotRect.height
    }

    func nodePoint(for band: EQBand) -> CGPoint {
        CGPoint(
            x: x(for: band.frequencyHz),
            y: y(forGain: band.type.usesGain ? band.gainDb : 0)
        )
    }
}

private struct FrequencyGraphInteraction: NSViewRepresentable {
    let bands: [EQBand]
    let selectedBandID: UUID?
    let sampleRate: Double
    let gainRange: ClosedRange<Double>
    let onSelectBand: (UUID?) -> Void
    let onUpdateBand: (EQBand) -> Void

    func makeNSView(context: Context) -> FrequencyGraphInteractionView {
        FrequencyGraphInteractionView()
    }

    func updateNSView(_ view: FrequencyGraphInteractionView, context: Context) {
        view.bands = bands
        view.selectedBandID = selectedBandID
        view.sampleRate = sampleRate
        view.gainRange = gainRange
        view.onSelectBand = onSelectBand
        view.onUpdateBand = onUpdateBand
    }
}

private final class FrequencyGraphInteractionView: NSView {
    var bands: [EQBand] = []
    var selectedBandID: UUID?
    var sampleRate = 48_000.0
    var gainRange = -24.0...24.0
    var onSelectBand: ((UUID?) -> Void)?
    var onUpdateBand: ((EQBand) -> Void)?

    private var dragStartPoint: CGPoint?
    private var dragStartBand: EQBand?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let band = nearestBand(to: point, maximumDistance: 28) else {
            onSelectBand?(nil)
            return
        }
        window?.makeFirstResponder(self)
        selectedBandID = band.id
        dragStartBand = band
        dragStartPoint = point
        onSelectBand?(band.id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let original = dragStartBand, let start = dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let layout = GraphLayout(size: bounds.size, sampleRate: sampleRate, gainRange: gainRange)
        let fine = event.modifierFlags.contains(.shift) ? 0.2 : 1.0
        let logSpan = log10(layout.maximumFrequency) - log10(layout.minimumFrequency)
        let logFrequency = log10(original.frequencyHz) +
            (point.x - start.x) / layout.plotRect.width * logSpan * fine

        var updated = original
        updated.frequencyHz = min(
            max(pow(10, logFrequency), layout.minimumFrequency),
            layout.maximumFrequency
        )
        if original.type.usesGain {
            let gainSpan = gainRange.upperBound - gainRange.lowerBound
            updated.gainDb = min(
                max(original.gainDb - (point.y - start.y) / layout.plotRect.height * gainSpan * fine,
                    gainRange.lowerBound),
                gainRange.upperBound
            )
        }
        onUpdateBand?(updated)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        dragStartBand = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard var band = nearestBand(to: point, maximumDistance: 32)
            ?? bands.first(where: { $0.id == selectedBandID }) else { return }
        let fine = event.modifierFlags.contains(.shift) ? 0.2 : 1.0
        band.q = min(max(band.q * exp(-event.scrollingDeltaY * 0.035 * fine), 0.1), 20)
        selectedBandID = band.id
        onSelectBand?(band.id)
        onUpdateBand?(band)
    }

    private func nearestBand(to point: CGPoint, maximumDistance: Double) -> EQBand? {
        let layout = GraphLayout(size: bounds.size, sampleRate: sampleRate, gainRange: gainRange)
        return bands
            .map { band in (band, hypot(layout.nodePoint(for: band).x - point.x, layout.nodePoint(for: band).y - point.y)) }
            .filter { $0.1 <= maximumDistance }
            .min { $0.1 < $1.1 }?
            .0
    }
}
