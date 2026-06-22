import SwiftUI

struct PopoverQuotaCard: View {
    @EnvironmentObject private var appState: AppState

    private var topModels: [(name: String, tokens: Int)] {
        (appState.today.models ?? [:])
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, tokens: $0.value) }
    }

    private var totalModelTokens: Int {
        topModels.map(\.tokens).reduce(0, +)
    }

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.tokenGreen)
                        .frame(width: 8, height: 8)
                    Text(L("今日模型用量"))
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Spacer()
                }

                if topModels.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "cube")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.tokenGreen)
                            .frame(width: 28, height: 28)
                            .background(Color.tokenMint.opacity(0.22), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("暂无模型用量数据"))
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(Color.tokenInk.opacity(0.76))
                            Text(L("使用支持的 Agent 后这里会显示模型分布。"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(topModels.enumerated()), id: \.offset) { _, model in
                            modelRow(model)
                        }
                    }
                }
            }
        }
        .padding(.vertical, -2)
    }

    private func modelRow(_ model: (name: String, tokens: Int)) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.tokenGreen)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.tokenInk.opacity(0.82))
                        .lineLimit(1)
                    Spacer()
                    Text(TokenStepFormat.tokens(model.tokens, compact: true))
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.tokenInk.opacity(0.72))
                }

                HStack(spacing: 6) {
                    Spacer()
                    Text(costText(for: model.name))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.tokenInk.opacity(0.54))
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.tokenGreen.opacity(0.10))
                        if totalModelTokens > 0 {
                            Capsule()
                                .fill(Color.tokenGreen)
                                .frame(width: max(5, proxy.size.width * CGFloat(model.tokens) / CGFloat(totalModelTokens)))
                        }
                    }
                }
                .frame(height: 5)
            }
        }
    }

    private func costText(for model: String) -> String {
        let usd = appState.today.modelCostUSD?[model] ?? 0
        let cny = appState.today.modelCostCNY?[model] ?? 0
        if usd == 0 && cny == 0 {
            return "-"
        }
        if prefersUSDDisplay(model), usd > 0 {
            return "\(TokenStepFormat.money(usd)) / \(TokenStepFormat.moneyCNY(cny))"
        }
        if cny > 0 {
            return TokenStepFormat.moneyCNY(cny)
        }
        return TokenStepFormat.money(usd)
    }
}
