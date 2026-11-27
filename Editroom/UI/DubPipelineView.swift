import AppKit
import SwiftUI

/// Subtitles › Translate and Dub…: the lesson's way through the translator (OpenClaw-Artist-Management), one
/// step at a time, with Maya's checks in between. The pipeline keeps running if this is closed.
struct DubPipelineView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var pipeline = DubPipeline.shared
    @AppStorage(DubPipeline.folderKey) private var folder = ""
    @State private var showLog = false
    @Environment(\.dismiss) private var dismiss

    private var job: DubJob? { model.project.dubJob }
    private var stage: DubStage { job?.stage ?? .send }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Translate and Dub").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if let job { Text(job.stem).font(.system(size: 12)).foregroundStyle(Theme.textDim) }
            }
            Text("Chinese from this edit goes to the translator. Claude cleans it up and translates it by the translator's own rules, and ElevenLabs voices it. The subtitles and the voice come back onto the timeline. You check the Chinese, the English and the first lines of the voice before each paid step.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)

            let missing = pipeline.missing()
            if !missing.isEmpty { setup(missing) }

            steps

            if pipeline.cutChanged(model), stage > .cleanup {
                notice("The edit changed after the Chinese was sent. The dub is timed to the old edit, so it won't line up.",
                       button: "Start Again from This Edit") { Task { await pipeline.restart(model) } }
            }

            action

            if let p = pipeline.problem {
                Text(p).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xE5735C)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = job?.lastReport, !report.isEmpty {
                ScrollView {
                    Text(report).font(.system(size: 11.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            }
            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    Text(pipeline.log.isEmpty ? "Nothing yet." : String(pipeline.log.suffix(20_000)))
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            } label: {
                Text("What's happening").font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
            }
            HStack {
                if job != nil, pipeline.running == nil {
                    Button("Forget This Lesson") { model.mutate { $0.dubJob = nil } }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                }
                Spacer()
                PillButton(title: "Close", prominent: false) { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.panel)
    }

    // MARK: Parts

    private func setup(_ missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needed first").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            ForEach(missing, id: \.self) { m in
                Text("• " + m).font(.system(size: 11.5)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                PillButton(title: "Choose Translator Folder…", prominent: false) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.message = "Choose OpenClaw-Artist-Management (or its translator folder)."
                    if panel.runModal() == .OK, let u = panel.url { folder = u.path }
                }
                if !folder.isEmpty { Text(folder).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(DubStage.allCases.filter { $0 != .done }, id: \.self) { s in
                HStack(spacing: 8) {
                    Image(systemName: s < stage || stage == .done ? "checkmark.circle.fill" : s == stage ? (s.isGate ? "person.crop.circle" : "circle.inset.filled") : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(s < stage || stage == .done ? Theme.textDim : s == stage ? Theme.text : Theme.textFaint)
                    Text(s.title).font(.system(size: 12, weight: s == stage ? .semibold : .regular))
                        .foregroundStyle(s == stage ? Theme.text : Theme.textDim)
                    if s.isGate { Text("you").font(.system(size: 10)).foregroundStyle(Theme.textFaint) }
                }
            }
        }
    }

    private func notice(_ text: String, button: String, _ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            PillButton(title: button, prominent: false, action: action)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.08)))
    }

    /// What to do now: what's running, Maya's check, or the next step's button.
    @ViewBuilder private var action: some View {
        if let running = pipeline.running {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(running + "…").font(.system(size: 12)).foregroundStyle(Theme.text)
                Spacer()
                PillButton(title: "Stop", prominent: false) { pipeline.stop() }
            }
        } else if let fix = pipeline.fixable {
            notice(fix, button: "Let Claude Fix It and Try Again") { Task { await pipeline.fixAndRetry(model) } }
        } else {
            let words = Self.words(for: stage)
            let note = words.0, title = words.1
            VStack(alignment: .leading, spacing: 10) {
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 10) {
                    if let title {
                        PillButton(title: title, prominent: true) { Task { await pipeline.next(model) } }
                            .disabled(!pipeline.missing().isEmpty)
                    }
                    if stage == .reviewCleanup || stage == .reviewTranslation {
                        PillButton(title: "Show Subtitle List", prominent: false) {
                            let name = stage == .reviewCleanup ? DubPlan.cleanLayer : DubPlan.englishLayer
                            if let l = model.project.layer(named: name) { model.showSubtitleLayer(l.id) }
                            model.focusCaptions()
                            dismiss()
                        }
                    }
                    if stage == .reviewAudition {
                        PillButton(title: "Play the Start", prominent: false) { model.seek(to: 0); model.play(); dismiss() }
                    }
                    if stage == .deliver {
                        PillButton(title: "Skip", prominent: false) { model.mutate { $0.dubJob?.stage = .done } }
                    }
                }
            }
        }
    }

    static func words(for stage: DubStage) -> (String?, String?) {
        switch stage {
        case .send:
            return ("Sends the captions now on the timeline (what's heard, or Maya's own Chinese layer if it's showing) to the translator, timed to this edit, and cleans them up. Finish the edit first: the voice is timed to it.", "Send the Chinese and Clean Up")
        case .cleanup:
            return ("The cleanup didn't finish.", "Clean Up Again")
        case .reviewCleanup:
            return ("The cleaned Chinese (中文 (清理)) is on the caption track. Read it in the subtitle list and fix anything: your wording and cuts win. Claude's report is below.", "Approve and Translate")
        case .translate:
            return ("The translation didn't finish.", "Translate Again")
        case .reviewTranslation:
            return ("The English is on the caption track. Read it through and change any line. Changed lines go back to Claude, who fixes the translation itself, so the subtitles and the voice agree.", "Approve and Audition")
        case .audition:
            return ("Voices the first few lines, to check the voice before paying for the whole lesson.", "Audition")
        case .reviewAudition:
            return ("The first lines are on the timeline as a dub track, with the camera sound turned down. Play the start and listen.", "Sounds Right: Dub Everything")
        case .dub:
            return ("Voices the whole lesson. Lines already voiced come from the cache for free.", "Dub")
        case .retime:
            return ("Times the English and Chinese subtitles to the words the voice says, Maya's rule for every dub.", "Time Subtitles to the Voice")
        case .deliver:
            return ("Done on the timeline: the English voice, English subtitles (shown) and Chinese subtitles. Claude can now put the files in 交付 and on main, by the translator's delivery rules.", "Deliver")
        case .done:
            return ("Finished. Switch between English and 中文 in Subtitles › Show, then export the video.", nil)
        }
    }
}
