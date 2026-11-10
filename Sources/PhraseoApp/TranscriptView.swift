import PhraseoKit
import SwiftUI

/// The words as the recognizer heard them, each one editable. Click a word to move the
/// playhead to it; the word under the playhead is marked.
struct TranscriptView: View {
    @EnvironmentObject var doc: Document

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                if let t = doc.transcript { Text("\(t.words.count) words").foregroundStyle(.secondary).font(.callout) }
                Button("Transcribe Again") { doc.retranscribe() }.disabled(doc.videoURL == nil || doc.isBusy)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let t = doc.transcript {
                ScrollViewReader { proxy in
                    ScrollView {
                        FlowLayout(spacing: 4) {
                            ForEach(t.words.indices, id: \.self) { i in
                                WordField(index: i, text: t.words[i].text, current: doc.currentWordIndex == i)
                                    .id(i)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: doc.currentWordIndex) { _, i in
                        if let i = i { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                    }
                }
            } else {
                Spacer()
                Text(doc.videoURL == nil ? "No video yet." : "Transcribing…").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}

struct WordField: View {
    @EnvironmentObject var doc: Document
    let index: Int
    let text: String
    let current: Bool
    @State private var draft: String
    @FocusState private var focused: Bool

    init(index: Int, text: String, current: Bool) {
        self.index = index; self.text = text; self.current = current
        _draft = State(initialValue: text)  // from the start, so a field focused at once is never blank
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 14, weight: current ? .semibold : .regular))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(width: max(28, CGFloat(draft.count) * 8.5 + 14))
            .background(RoundedRectangle(cornerRadius: 5).fill(current ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
            .onChange(of: text) { _, t in if !focused { draft = t } }
            .onChange(of: focused) { _, f in
                if f, let w = doc.transcript?.words[index] { doc.time = w.start + 0.01 }
                if !f, draft != text { doc.setWord(index, text: draft) }
            }
            .onSubmit { doc.setWord(index, text: draft) }
    }
}

/// Words wrap like text. A tiny flow layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
