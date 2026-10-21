import SwiftUI

private struct PlayTarget: Identifiable {
    let id: Int
}

struct ChannelListView: View {

    let source: Source
    @EnvironmentObject private var store: Store

    @State private var channels: [Channel] = []
    @State private var playTarget: PlayTarget?

    var body: some View {
        List {
            ForEach(Array(channels.enumerated()), id: \.element.id) { idx, channel in
                Button {
                    playTarget = PlayTarget(id: idx)
                } label: {
                    HStack(spacing: 10) {
                        Text(channel.name)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(channel.group)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if channel.isDASH {
                            Text(channel.hasClearKey ? "DASH·CK" : "DASH")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(source.name)
        .onAppear {
            channels = store.channels(for: source)
        }
        .overlay(
            Group {
                if channels.isEmpty {
                    Text("没有频道\n请返回上一层长按列表项刷新")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
            }
        )
        .fullScreenCover(item: $playTarget) { target in
            PlayerScreen(
                channels: channels,
                startIndex: target.id,
                sourceName: source.name
            )
        }
    }
}
