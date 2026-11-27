import SwiftUI

/// Every subtitle in order, each with its time and its words to retype in place, so a whole class can be
/// read through and fixed while editing it. The one under the playhead is marked, and followed while playing.
struct SubtitleList: View {
    @ObservedObject var model: EditorModel
    /// Changes once a frame while playing: just enough to move the mark along.
    @ObservedObject var clock: Clock
    let blocks: [CaptionBlock]

    private var current: String? {
        let t = Double(clock.frame) / max(1, model.project.fps)
        // The last subtitle starting by now (they're in order), if it's still showing.
        var lo = 0, hi = blocks.count
        while lo < hi { let m = (lo + hi) / 2; if blocks[m].start <= t + 1e-6 { lo = m + 1 } else { hi = m } }
        guard lo > 0, t < blocks[lo - 1].end else { return nil }
        return blocks[lo - 1].id
    }

    var body: some View {
        let now = current
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(blocks) { b in
                        HStack(alignment: .top, spacing: 8) {
                            Button { model.seek(to: b.start + 0.01) } label: {
                                Text(Timecode.simple(b.start))
                                    .font(Theme.mono(10.5))
                                    .foregroundStyle(b.id == now ? Theme.text : Theme.textFaint)
                                    .frame(width: 58, alignment: .leading)
                                    .padding(.top, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Go to this subtitle")
                            CaptionTextField(model: model, block: b)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(b.id == now ? Theme.ink.opacity(0.10) : .clear))
                        .id(b.id)
                    }
                }
            }
            .frame(height: blocks.isEmpty ? 40 : min(420, CGFloat(blocks.count) * 40 + 8))
            .overlay {
                if blocks.isEmpty {
                    Text(model.captionsWaiting ? "Listening…" : "No subtitles yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            // While playing, the list keeps the subtitle being said in view.
            .onChange(of: now) { _, id in
                guard model.isPlaying, let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
