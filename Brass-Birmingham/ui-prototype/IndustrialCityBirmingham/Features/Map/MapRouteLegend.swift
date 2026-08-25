import SwiftUI
import UIKit

@MainActor
struct MapRouteLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(.canalOnly)
            row(.railOnly)
            row(.both)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: UIColor(red: 0.93, green: 0.67, blue: 0.25, alpha: 0.75)))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("路线图例：运河专用，铁路专用，两时代通用")
    }

    private func row(_ kind: MapRouteEraKind) -> some View {
        HStack(spacing: 7) {
            MapRouteLegendLine(kind: kind).frame(width: 30, height: 9)
            Text(kind.chineseLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
        }
    }
}

@MainActor
private struct MapRouteLegendLine: View {
    let kind: MapRouteEraKind

    var body: some View {
        ZStack {
            if kind != .railOnly {
                Capsule()
                    .fill(Color(uiColor: MapRouteEraPalette.canal))
                    .frame(height: kind == .both ? 8 : 5)
            }
            if kind == .both {
                Capsule()
                    .fill(Color(uiColor: MapRouteEraPalette.rail))
                    .frame(height: 3)
            } else if kind == .railOnly {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4.5))
                    path.addLine(to: CGPoint(x: 30, y: 4.5))
                }
                .stroke(
                    Color(uiColor: MapRouteEraPalette.rail),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [7, 4])
                )
            }
        }
    }
}
