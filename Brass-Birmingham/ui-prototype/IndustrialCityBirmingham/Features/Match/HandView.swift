import SwiftUI

struct HandLayout: Equatable {
    let cardWidth: CGFloat
    let spacing: CGFloat
    let cardCount: Int
    let horizontalPadding: CGFloat

    var totalWidth: CGFloat {
        cardWidth * CGFloat(cardCount)
            + spacing * CGFloat(max(cardCount - 1, 0))
            + horizontalPadding * 2
    }
}

struct HandView: View {
    let cards: [HandCard]
    let formFactor: MatchFormFactor
    let selectedCardID: String?
    let scoutCardIDs: Set<String>
    let selectedScoutCardIDs: Set<String>
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = Self.layout(
                availableWidth: proxy.size.width,
                cardCount: min(cards.count, 8),
                formFactor: formFactor
            )

            VStack {
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: layout.spacing) {
                    ForEach(cards.prefix(8)) { card in
                        cardButton(card, width: layout.cardWidth)
                            .zIndex(card.id == selectedCardID ? 10 : selectedScoutCardIDs.contains(card.id) ? 5 : 0)
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 20)
                .padding(.bottom, 6)
                .frame(width: min(layout.totalWidth + 8, proxy.size.width))
                .background {
                    Image(IndustrialMatchAsset.woodFill.name)
                        .resizable(
                            capInsets: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
                            resizingMode: .tile
                        )
                        .overlay(BrassColor.darkWood.color.opacity(0.58))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(BrassColor.brass.color.opacity(0.62), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("match.hand")
    }

    private func cardButton(_ card: HandCard, width: CGFloat) -> some View {
        let isActionCard = card.id == selectedCardID
        let isScoutCard = selectedScoutCardIDs.contains(card.id)
        let isSelected = isActionCard || isScoutCard
        let isScoutSelectionActive = scoutCardIDs.isEmpty == false
        let isDimmed = isScoutSelectionActive
            ? !isSelected && !scoutCardIDs.contains(card.id)
            : selectedCardID != nil && !isSelected

        return Button {
            onSelect(card.id)
        } label: {
            HandCardFace(
                title: card.title,
                kind: card.kind,
                width: width,
                formFactor: formFactor,
                isSelected: isSelected,
                isScoutCard: isScoutCard
            )
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .offset(y: isActionCard ? -18 : isScoutCard ? -10 : 0)
        .scaleEffect(isActionCard ? 1.06 : isScoutCard ? 1.03 : 1, anchor: .bottom)
        .opacity(isDimmed ? 0.45 : 1)
        .animation(.snappy(duration: 0.22), value: selectedCardID)
        .accessibilityLabel(card.title)
        .accessibilityValue(accessibilityValue(for: card.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("hand.card.\(card.id)")
    }

    private func accessibilityValue(for cardID: String) -> String {
        if cardID == selectedCardID { return "行动牌已选中" }
        if selectedScoutCardIDs.contains(cardID) { return "侦察弃牌已选中" }
        if scoutCardIDs.contains(cardID) { return "可选作侦察弃牌" }
        return "未选中"
    }

    static func layout(
        availableWidth: CGFloat,
        cardCount: Int,
        formFactor: MatchFormFactor
    ) -> HandLayout {
        let count = max(cardCount, 1)
        let horizontalPadding: CGFloat = 6

        if formFactor == .tablet {
            let contentWidth = max(availableWidth - horizontalPadding * 2, 0)
            let gapCount = max(count - 1, 0)
            let spacing: CGFloat
            if gapCount == 0 {
                spacing = 0
            } else {
                spacing = min(8, max(0, (contentWidth - CGFloat(count) * 44) / CGFloat(gapCount)))
            }
            let cardWidth = min(
                112,
                max(44, (contentWidth - spacing * CGFloat(gapCount)) / CGFloat(count))
            )
            return HandLayout(
                cardWidth: cardWidth,
                spacing: spacing,
                cardCount: count,
                horizontalPadding: horizontalPadding
            )
        }

        let cardWidth = min(78, max(54, availableWidth * 0.145))
        return HandLayout(
            cardWidth: cardWidth,
            spacing: -cardWidth * 0.28,
            cardCount: count,
            horizontalPadding: horizontalPadding
        )
    }
}

private struct HandCardFace: View {
    let title: String
    let kind: HandCardKind
    let width: CGFloat
    let formFactor: MatchFormFactor
    let isSelected: Bool
    let isScoutCard: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 9,
            bottomLeadingRadius: 2,
            bottomTrailingRadius: 2,
            topTrailingRadius: 9
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            artwork
            Text(title)
                .font(.system(size: formFactor == .phone ? 9 : 11, weight: .semibold, design: .rounded))
                .lineLimit(formFactor == .phone ? 1 : 2)
                .minimumScaleFactor(0.68)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(BrassColor.paper.color)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .frame(width: width)
        .frame(minHeight: 44, maxHeight: .infinity)
        .background {
            Image(IndustrialMatchAsset.cardTexture.name)
                .resizable(
                    capInsets: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10),
                    resizingMode: .tile
                )
                .overlay(BrassColor.forgedIron.color.opacity(0.62))
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(
                isScoutCard
                    ? BrassColor.paper.color
                    : isSelected ? BrassColor.brass.color : BrassColor.brass.color.opacity(0.65),
                lineWidth: isSelected ? 2 : 1
            )
        }
        .shadow(color: .black.opacity(isSelected ? 0.45 : 0.2), radius: isSelected ? 8 : 3, y: 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var artwork: some View {
        switch kind {
        case .industry(let industry):
            Image(IndustrialMatchAsset.industryMedallion(industry).name)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: formFactor == .phone ? 24 : 30, height: formFactor == .phone ? 24 : 30)
        case .location:
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: formFactor == .phone ? 17 : 22, weight: .semibold))
        case .wildLocation:
            Image(systemName: "map.fill")
                .font(.system(size: formFactor == .phone ? 17 : 22, weight: .semibold))
        case .wildIndustry:
            Image(systemName: "building.2.fill")
                .font(.system(size: formFactor == .phone ? 17 : 22, weight: .semibold))
        }
    }
}
