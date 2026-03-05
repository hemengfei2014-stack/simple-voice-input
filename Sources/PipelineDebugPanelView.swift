import SwiftUI

struct PipelineDebugPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if !appState.debugStatusMessage.isEmpty {
                    HStack(spacing: 8) {
                        Text("Status:")
                            .font(.caption.weight(.semibold))
                        Text(appState.debugStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !appState.lastTranscriptionStatus.isEmpty {
                    HStack(spacing: 8) {
                        Text("Processing Status:")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastTranscriptionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !appState.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcript:")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastTranscript)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                    }
                }
            }

            if appState.lastTranscript.isEmpty {
                Text("Run a dictation pass to populate debug output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 620, height: 640, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline Debug")
                .font(.title3)
            Text("Live data for the Gemini audio processing pipeline.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
