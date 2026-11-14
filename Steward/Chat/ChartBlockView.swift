import Charts
import StewardCore
import SwiftUI

extension Palette {
    /// Bars and lines that give context to the one picked out in orange.
    static let chartRest = dynamic(light: 0xA9A9B1, dark: 0x4A5266)
    /// Grid lines: a whisper, so the data leads.
    static let chartGrid = dynamic(light: 0xE6E6EB, dark: 0x232836)
}

/// A chart block, drawn natively: real values on the marks, one mark in
/// orange, and, when the block carries one, a "what if" the owner can change
/// to watch the result move. Chat and Insights both draw charts with this.
struct ChartBlockView: View {
    let chart: ReplyBlock.Chart
    /// False draws every mark at zero; turning it true grows them in.
    var drawn = true

    @State private var input: Double?

    private var value: Double? { input ?? chart.whatIf?.current }

    var body: some View {
        let result = chart.projected(value)
        VStack(alignment: .leading, spacing: 14) {
            switch chart.style {
            case .columns:
                ColumnsChart(points: result.points, highlight: chart.highlight, unit: chart.unit, drawn: drawn)
            case .bars:
                BarsChart(points: result.points, highlight: chart.highlight, unit: chart.unit, drawn: drawn)
            case .trend:
                TrendChart(points: chart.points, projection: result.projection, target: chart.target,
                           unit: chart.unit, period: chart.whatIf?.period ?? "week", drawn: drawn,
                           changed: input != nil && input != chart.whatIf?.current)
            }
            if let whatIf = chart.whatIf {
                WhatIfControl(chart: chart, whatIf: whatIf, value: Binding(
                    get: { value ?? whatIf.current },
                    set: { newValue in withAnimation(.snappy) { input = newValue } }
                ))
            }
        }
    }
}

func chartNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
}

// MARK: Columns

/// One column per labelled period, such as the days of a week.
private struct ColumnsChart: View {
    let points: [ReplyBlock.Chart.Point]
    let highlight: Int?
    let unit: String
    let drawn: Bool

    /// Grows with the reader's text size, so the numbers never crush the columns.
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 132
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { item in
            let picked = item.offset == highlight
            BarMark(x: .value("Period", String(item.offset)), y: .value(unit, drawn ? item.element.value : 0), width: .ratio(0.62))
                .cornerRadius(4)
                .foregroundStyle(picked ? Palette.orange : Palette.chartRest)
                .annotation(position: .top, spacing: 4) {
                    Text(chartNumber(item.element.value))
                        .font(.caption.weight(picked ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(picked ? Palette.ink : Palette.muted)
                        .opacity(drawn ? 1 : 0)
                }
                .accessibilityLabel(item.element.label)
                .accessibilityValue("\(chartNumber(item.element.value)) \(unit)")
        }
        .chartYScale(domain: 0...max(points.map(\.value).max() ?? 1, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    Text(label(value.as(String.self).flatMap(Int.init) ?? 0))
                }
                .font(.caption)
                .foregroundStyle(Palette.muted)
            }
        }
        .frame(height: height)
    }

    /// At the largest text sizes, labels shrink to their first letter so all still fit.
    private func label(_ index: Int) -> String {
        guard points.indices.contains(index) else { return "" }
        let full = points[index].label
        return typeSize >= .accessibility2 ? String(full.prefix(1)) : full
    }
}

// MARK: Bars

/// Labelled bars: each label and its value on one line, the bar beneath.
/// Drawn by hand, so long labels and large text never collide.
private struct BarsChart: View {
    let points: [ReplyBlock.Chart.Point]
    let highlight: Int?
    let unit: String
    let drawn: Bool

    private var top: Double { max(points.map(\.value).max() ?? 1, .ulpOfOne) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(unit.prefix(1).uppercased() + unit.dropFirst())
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            ForEach(Array(points.enumerated()), id: \.offset) { item in
                let picked = item.offset == highlight
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.element.label)
                            .font(.subheadline.weight(picked ? .semibold : .regular))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        Text(chartNumber(item.element.value))
                            .font(.subheadline.weight(picked ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(picked ? Palette.ink : Palette.muted)
                            .contentTransition(.numericText(value: item.element.value))
                    }
                    GeometryReader { proxy in
                        Capsule()
                            .fill(picked ? Palette.orange : Palette.chartRest)
                            .frame(width: drawn ? max(6, proxy.size.width * item.element.value / top) : 6)
                    }
                    .frame(height: 10)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.element.label)
                .accessibilityValue("\(chartNumber(item.element.value)) \(unit)")
            }
        }
    }
}

// MARK: Trend

/// A series over time, against a target when there is one, with the
/// owner's "what if" projected ahead as a dashed orange line.
private struct TrendChart: View {
    let points: [ReplyBlock.Chart.Point]
    let projection: [Double]
    let target: Double?
    let unit: String
    let period: String
    let drawn: Bool
    /// The owner moved the "what if": the projection turns orange. As things
    /// are, it stays grey, a forecast rather than a choice.
    let changed: Bool

    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 150

    private var lastIndex: Int { points.count - 1 }
    private var endIndex: Int { lastIndex + projection.count }
    private var top: Double { max(target ?? 0, (points.map(\.value) + projection).max() ?? 1) * 1.2 }

    var body: some View {
        Chart {
            if let target {
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(Palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Target \(chartNumber(target)) \(unit)")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    .accessibilityLabel("Target")
                    .accessibilityValue("\(chartNumber(target)) \(unit)")
            }
            ForEach(Array(points.enumerated()), id: \.offset) { item in
                LineMark(x: .value("Time", item.offset), y: .value(unit, drawn ? item.element.value : 0),
                         series: .value("Series", "Actual"))
                    .foregroundStyle(Palette.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(item.element.label)
                    .accessibilityValue("\(chartNumber(item.element.value)) \(unit)")
            }
            if !projection.isEmpty, let last = points.last {
                ForEach(Array(([last.value] + projection).enumerated()), id: \.offset) { item in
                    LineMark(x: .value("Time", lastIndex + item.offset), y: .value(unit, drawn ? item.element : 0),
                             series: .value("Series", "What if"))
                        .foregroundStyle(changed ? Palette.orange : Palette.chartRest)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                        .accessibilityHidden(item.offset == 0)
                        .accessibilityLabel("\(item.offset) \(period)\(item.offset == 1 ? "" : "s") ahead")
                        .accessibilityValue("\(chartNumber(item.element)) \(unit), projected")
                }
            }
            if let last = points.last {
                PointMark(x: .value("Time", lastIndex), y: .value(unit, drawn ? last.value : 0))
                    .symbolSize(80)
                    .foregroundStyle(Palette.orange)
                    // Above and to the left: clear of the line that led here and
                    // of the projection ahead; below if the target line is close.
                    .annotation(position: nearTarget ? .bottomLeading : .topLeading, spacing: 4) {
                        Text("\(chartNumber(last.value)) \(unit)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Palette.ink)
                            .opacity(drawn ? 1 : 0)
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: 0...max(top, 1))
        .chartXScale(domain: -0.2...(Double(endIndex) + 0.2))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Palette.chartGrid)
                AxisValueLabel().font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: projection.isEmpty ? [0, lastIndex] : [0, lastIndex, endIndex]) { value in
                let index = value.as(Int.self) ?? 0
                AxisValueLabel(anchor: index == 0 ? .topLeading : (index == endIndex ? .topTrailing : .top)) {
                    Text(label(index))
                }
                .font(.caption)
                .foregroundStyle(Palette.muted)
            }
        }
        .frame(height: height)
    }

    private var nearTarget: Bool {
        guard let target, let last = points.last?.value else { return false }
        return abs(target - last) < top * 0.15
    }

    private func label(_ index: Int) -> String {
        if points.indices.contains(index) { return points[index].label }
        let ahead = index - lastIndex
        return "In \(ahead) \(period)\(ahead == 1 ? "" : "s")"
    }
}

// MARK: What if

/// The owner's input: a native stepper, and in words what it changes.
private struct WhatIfControl: View {
    let chart: ReplyBlock.Chart
    let whatIf: ReplyBlock.Chart.WhatIf
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Palette.ticketEdge)
            HStack(alignment: .center, spacing: 12) {
                Text(whatIf.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(chartNumber(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: value))
                    .accessibilityHidden(true)
                Stepper(whatIf.label, value: $value, in: whatIf.lower...whatIf.upper, step: whatIf.step)
                    .labelsHidden()
                    .accessibilityValue(chartNumber(value))
            }
            Text(outcome)
                .font(.footnote.weight(changed ? .semibold : .regular))
                .foregroundStyle(changed ? Palette.orangeText : Palette.muted)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private var changed: Bool { value != whatIf.current }

    private var outcome: String {
        switch chart.style {
        case .trend:
            guard let target = chart.target else {
                let end = chart.projected(value).projection.last ?? 0
                return "About \(chartNumber(end)) \(chart.unit) in \(whatIf.horizon) \(whatIf.period)s."
            }
            let goal = "\(chartNumber(target)) \(chart.unit)"
            switch chart.pointsToTarget(value) {
            case 0?: return "You're at \(goal) already."
            case let weeks?:
                return changed
                    ? "You'd reach \(goal) in \(weeks) \(whatIf.period)\(weeks == 1 ? "" : "s")."
                    : "As you are, \(goal) in \(weeks) \(whatIf.period)\(weeks == 1 ? "" : "s")."
            case nil:
                return changed
                    ? "Still short of \(goal) in the next \(whatIf.horizon) \(whatIf.period)s."
                    : "As you are, you won't reach \(goal) in the next \(whatIf.horizon) \(whatIf.period)s."
            }
        case .bars, .columns:
            guard let highlight = chart.highlight, chart.points.indices.contains(highlight) else { return "" }
            let before = chart.points[highlight]
            let after = chart.projected(value).points[highlight].value
            if !changed { return "\(before.label): \(chartNumber(before.value)) \(chart.unit) now." }
            return "\(before.label): about \(chartNumber(after)) \(chart.unit), from \(chartNumber(before.value))."
        }
    }
}

// MARK: In a reply

/// A chart sent in Chat, on Steward's ticket paper.
struct ChartTicket: View {
    let chart: ReplyBlock.Chart

    var body: some View {
        Ticket(kind: "Chart") {
            VStack(alignment: .leading, spacing: 12) {
                if let title = chart.title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ChartBlockView(chart: chart)
            }
        }
    }
}
