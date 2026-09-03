import SwiftUI

/// The small popover under the pills: preset chips, plus the only way to
/// reach Settings and Quit while nothing is running.
struct PresetPopoverView: View {
    let manager: SessionManager
    let mode: MenuBarModel.Mode
    let onPick: (TimeInterval) -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.openSettings) private var openSettings

    private var presets: [TimeInterval] {
        manager.config.presets.isEmpty ? Config.defaultPresets : manager.config.presets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .extend ? "Extend by" : "Keep awake for")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            FlowRow(spacing: 6) {
                ForEach(presets, id: \.self) { p in
                    Chip(title: chipLabel(for: p), prominent: p == manager.config.defaultPreset) {
                        onPick(p)
                    }
                }
            }

            if let err = manager.lastError {
                ErrorRow(message: err)
            }

            Divider()

            HStack {
                Text(mode == .extend ? "Enter extends · Esc cancels" : "Enter starts · Esc closes")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Settings…") {
                    onSettings()
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Button("Quit", action: onQuit)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// Subtle red line for `manager.lastError`.
struct ErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.red.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

/// Wraps chips onto multiple lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
