import SwiftUI

struct UIGalleryView: View {
    private let swatches: [(String, BrassColor)] = [
        ("Coal", .coal),
        ("Iron", .iron),
        ("Brass", .brass),
        ("Fog", .fog),
        ("Paper", .paper),
        ("Danger", .danger)
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 92), spacing: BrassSpacing.medium)
    ]

    private let resourceColumns = [
        GridItem(.adaptive(minimum: 168), spacing: BrassSpacing.medium)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrassSpacing.xLarge) {
                Text("UI 设计系统")
                    .font(BrassTypography.display)

                sectionTitle("色板")
                LazyVGrid(columns: columns, spacing: BrassSpacing.medium) {
                    ForEach(swatches, id: \.0) { name, color in
                        swatch(name, color)
                    }
                }

                sectionTitle("字体")
                typographySamples

                sectionTitle("组件")
                Button("主要按钮") {}
                    .buttonStyle(BrassPrimaryButtonStyle())
                Text("BrassPanel 将内容组织成清晰、可读的工业卡面。")
                    .font(BrassTypography.body)
                    .brassPanel()

                sectionTitle("交互与无障碍状态")
                stateMatrix

                sectionTitle("长玩家名")
                VStack(alignment: .leading, spacing: BrassSpacing.small) {
                    Text("中文玩家名 · 伯明翰运河与铁路联合制造厂代表")
                        .accessibilityIdentifier("gallery.player.longChinese")
                    Text("English player name · Cadbury-Langname Industrial Consortium")
                        .accessibilityIdentifier("gallery.player.longEnglish")
                }
                .font(BrassTypography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .brassPanel()

                sectionTitle("玩家色觉辅助符号")
                VStack(spacing: BrassSpacing.medium) {
                    ForEach(PlayerColor.allCases, id: \.self) { playerColor in
                        playerSymbol(playerColor)
                    }
                }

                sectionTitle("资源市场")
                LazyVGrid(columns: resourceColumns, spacing: BrassSpacing.medium) {
                    resourceChip(name: "煤", symbol: "seal.fill", count: 9, lowestPrice: 1, color: .coal)
                    resourceChip(name: "铁", symbol: "cube.fill", count: 7, lowestPrice: 2, color: .iron)
                }
            }
            .foregroundStyle(BrassColor.paper.color)
            .padding(BrassSpacing.large)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(BrassColor.coal.color.ignoresSafeArea())
        .navigationTitle("UI 展示")
    }

    private var stateMatrix: some View {
        VStack(alignment: .leading, spacing: BrassSpacing.large) {
            galleryComponentSection("Button") { state in
                galleryButton(state)
            }
            galleryComponentSection("BrassPanel") { state in
                galleryPanel(state)
            }
            galleryComponentSection("Player item") { state in
                galleryPlayer(state)
            }
            galleryComponentSection("Resource chip") { state in
                galleryResource(state)
            }
        }
    }

    private func galleryComponentSection<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping (GalleryInteractionState) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BrassSpacing.small) {
            Text(title)
                .font(BrassTypography.label)
                .foregroundStyle(BrassColor.fog.color)
            ForEach(GalleryInteractionState.allCases) { state in
                content(state)
            }
        }
    }

    private func galleryButton(_ state: GalleryInteractionState) -> some View {
        Button {} label: {
            galleryStateLabel(state, prefix: "执行行动")
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(state.fillColor)
                .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
                .overlay { stateBorder(state) }
        }
        .buttonStyle(.plain)
        .disabled(state == .disabled)
        .opacity(state.opacity)
        .scaleEffect(state == .pressed ? 0.96 : 1)
        .accessibilityLabel("Button · \(state.title)")
        .accessibilityIdentifier("gallery.button.\(state.rawValue)")
    }

    private func galleryPanel(_ state: GalleryInteractionState) -> some View {
        galleryStateLabel(state, prefix: "工业面板")
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .brassPanel()
            .overlay { stateBorder(state) }
            .opacity(state.opacity)
            .scaleEffect(state == .pressed ? 0.98 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("BrassPanel · \(state.title)")
            .accessibilityIdentifier("gallery.panel.\(state.rawValue)")
    }

    private func galleryPlayer(_ state: GalleryInteractionState) -> some View {
        HStack(spacing: BrassSpacing.medium) {
            Image(systemName: state == .disconnected ? "wifi.slash" : "diamond.fill")
                .foregroundStyle(state.accentColor)
            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                Text("伯明翰玩家")
                    .font(BrassTypography.body)
                Text(state.title)
                    .font(BrassTypography.label)
                    .foregroundStyle(state.accentColor)
            }
            Spacer()
            Image(systemName: state.symbol)
        }
        .padding(.horizontal, BrassSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(state.fillColor.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
        .overlay { stateBorder(state) }
        .opacity(state.opacity)
        .scaleEffect(state == .pressed ? 0.98 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Player item · \(state.title)")
        .accessibilityIdentifier("gallery.player.\(state.rawValue)")
    }

    private func galleryResource(_ state: GalleryInteractionState) -> some View {
        HStack(spacing: BrassSpacing.medium) {
            Image(systemName: state == .disconnected ? "bolt.slash.fill" : "cube.fill")
                .foregroundStyle(state.accentColor)
            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                Text("铁 × 7")
                    .font(BrassTypography.number)
                Text("最低价 £2 · \(state.title)")
                    .font(BrassTypography.label)
            }
            Spacer()
            Image(systemName: state.symbol)
        }
        .padding(.horizontal, BrassSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(state.fillColor.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: BrassRadius.card))
        .overlay { stateBorder(state) }
        .opacity(state.opacity)
        .scaleEffect(state == .pressed ? 0.98 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resource chip · \(state.title)")
        .accessibilityIdentifier("gallery.resource.\(state.rawValue)")
    }

    private func galleryStateLabel(
        _ state: GalleryInteractionState,
        prefix: String
    ) -> some View {
        HStack(spacing: BrassSpacing.small) {
            if state == .waiting {
                ProgressView()
                    .tint(BrassColor.paper.color)
            } else {
                Image(systemName: state.symbol)
            }
            Text("\(prefix) · \(state.title)")
                .font(BrassTypography.label)
        }
        .foregroundStyle(state.accentColor)
        .padding(.horizontal, BrassSpacing.medium)
    }

    private func stateBorder(_ state: GalleryInteractionState) -> some View {
        RoundedRectangle(cornerRadius: BrassRadius.card)
            .stroke(state.accentColor, lineWidth: state.borderWidth)
    }

    private var typographySamples: some View {
        VStack(alignment: .leading, spacing: BrassSpacing.medium) {
            Text("Display 工业城市").font(BrassTypography.display)
            Text("Title 运河时代").font(BrassTypography.title)
            Text("Body 煤必须连接到来源。").font(BrassTypography.body)
            Text("LABEL PLAYER TURN").font(BrassTypography.label)
            Text("£ 24  •  VP 36").font(BrassTypography.number)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(BrassTypography.title)
            .foregroundStyle(BrassColor.brass.color)
    }

    private func swatch(_ name: String, _ value: BrassColor) -> some View {
        VStack(spacing: BrassSpacing.small) {
            RoundedRectangle(cornerRadius: BrassRadius.card)
                .fill(value.color)
                .frame(height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: BrassRadius.card)
                        .stroke(BrassColor.paper.color.opacity(0.3))
                }
            Text(name).font(BrassTypography.label)
        }
    }

    private func playerSymbol(_ playerColor: PlayerColor) -> some View {
        VStack(spacing: BrassSpacing.small) {
            Image(systemName: playerColor.symbol)
                .font(.title2)
                .foregroundStyle(symbolColor(for: playerColor).color)
            Text(playerColor.rawValue.capitalized)
                .font(BrassTypography.label)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .brassPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playerColor.rawValue.capitalized) · \(playerColor.symbol)")
        .accessibilityIdentifier("gallery.colorAssist.\(playerColor.rawValue)")
    }

    private func symbolColor(for playerColor: PlayerColor) -> BrassColor {
        switch playerColor {
        case .amber: .brass
        case .crimson: .danger
        case .teal: .fog
        case .violet: .paper
        }
    }

    private func resourceChip(
        name: String,
        symbol: String,
        count: Int,
        lowestPrice: Int,
        color: BrassColor
    ) -> some View {
        HStack(spacing: BrassSpacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(color.color)
            VStack(alignment: .leading, spacing: BrassSpacing.xSmall) {
                Text("\(name) × \(count)").font(BrassTypography.number)
                Text("最低价 £\(lowestPrice)").font(BrassTypography.label)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .brassPanel()
    }
}

private enum GalleryInteractionState: String, CaseIterable, Identifiable {
    case normal
    case pressed
    case disabled
    case selected
    case illegal
    case waiting
    case disconnected
    case reducedMotion = "reduced-motion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "正常 Normal"
        case .pressed: "按下 Pressed"
        case .disabled: "禁用 Disabled"
        case .selected: "选中 Selected"
        case .illegal: "非法 Illegal"
        case .waiting: "等待 Waiting"
        case .disconnected: "断开 Disconnected"
        case .reducedMotion: "减少动态 Reduced Motion"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "circle"
        case .pressed: "hand.tap.fill"
        case .disabled: "nosign"
        case .selected: "checkmark.circle.fill"
        case .illegal: "exclamationmark.octagon.fill"
        case .waiting: "clock.fill"
        case .disconnected: "wifi.slash"
        case .reducedMotion: "figure.walk.motion"
        }
    }

    var accentColor: Color {
        switch self {
        case .illegal: BrassColor.danger.color
        case .selected, .waiting: BrassColor.brass.color
        case .disconnected, .disabled: BrassColor.fog.color
        case .normal, .pressed, .reducedMotion: BrassColor.paper.color
        }
    }

    var fillColor: Color {
        switch self {
        case .selected: BrassColor.brass.color.opacity(0.34)
        case .illegal: BrassColor.danger.color.opacity(0.24)
        case .waiting: BrassColor.brass.color.opacity(0.2)
        case .disconnected: BrassColor.coal.color.opacity(0.8)
        case .disabled: BrassColor.iron.color.opacity(0.16)
        case .pressed: BrassColor.iron.color.opacity(0.6)
        case .normal, .reducedMotion: BrassColor.iron.color.opacity(0.38)
        }
    }

    var opacity: Double {
        switch self {
        case .disabled: 0.5
        case .disconnected: 0.72
        case .pressed: 0.86
        case .normal, .selected, .illegal, .waiting, .reducedMotion: 1
        }
    }

    var borderWidth: Double {
        switch self {
        case .selected, .illegal: 3
        case .normal, .pressed, .disabled, .waiting, .disconnected, .reducedMotion: 1
        }
    }
}
