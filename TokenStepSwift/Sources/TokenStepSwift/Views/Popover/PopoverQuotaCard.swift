import SwiftUI

struct PopoverQuotaCard: View {
    @EnvironmentObject private var appState: AppState

    private var topModels: [ModelUsage] {
        Array(appState.snapshot.models.sorted { $0.tokens > $1.tokens }.prefix(5))
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
                    Text(L("模型用量"))
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
                        ForEach(topModels) { model in
                            modelRow(model)
                        }
                    }
                }
            }
        }
        .padding(.vertical, -2)
    }

    private func modelRow(_ model: ModelUsage) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tokenToolColor(model.tool ?? ""))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.model)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.tokenInk.opacity(0.82))
                        .lineLimit(1)
                    if let tool = model.tool, !tool.isEmpty, tool != model.model {
                        Text(tool)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(TokenStepFormat.tokens(model.tokens, compact: true))
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.tokenInk.opacity(0.72))
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.tokenGreen.opacity(0.10))
                        if totalModelTokens > 0 {
                            Capsule()
                                .fill(tokenToolColor(model.tool ?? ""))
                                .frame(width: max(5, proxy.size.width * CGFloat(model.tokens) / CGFloat(totalModelTokens)))
                        }
                    }
                }
                .frame(height: 5)
            }
        }
    }
}
