import SwiftUI

@available(macOS 11.0, *)
struct CombinedRecordingView: View {
    // Environment variable to control the view's presentation state (for dismissing the sheet)
    @Environment(\.presentationMode) var presentationMode
    
    // StateObject for the combined audio engine
    @StateObject private var combinedEngine = CombinedAudioEngine()

    var body: some View {
        // Use a VStack for layout
        VStack(spacing: 20) {
            Text("Combined Recording")
                .font(.largeTitle)
                .padding(.top, 30)

            // Dynamic status from engine
            Text(combinedEngine.statusMessage)
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(8)

            HStack(spacing: 20) {
                // Record / Stop Button
                Button {
                    if combinedEngine.isRecording {
                        combinedEngine.stopRecording()
                    } else {
                        combinedEngine.startRecording()
                    }
                } label: {
                    Label(combinedEngine.isRecording ? "Stop Recording" : "Record Mic + System",
                          systemImage: combinedEngine.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .frame(minWidth: 120)
                }
                .applyButtonStyling(color: .red)

                // Placeholder Play Button
                Button {
                    print("Combined Play button tapped - TBD")
                } label: {
                    Label("Play", systemImage: "play.circle.fill")
                        .frame(minWidth: 120)
                }
                .applyButtonStyling(color: .blue)
                .disabled(combinedEngine.isRecording)

                // Save Button
                Button {
                    saveRecording()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down.fill")
                        .frame(minWidth: 120)
                }
                .applyButtonStyling(color: .green)
                .disabled(combinedEngine.isRecording || combinedEngine.completedRecordingURL == nil)
            }

            Spacer()

            // Back button to dismiss the sheet
            Button("Back") {
                presentationMode.wrappedValue.dismiss()
            }
            .padding(.bottom, 20)
            .applyButtonStyling(color: .gray)
        }
        // Add a frame to give the sheet a default size
        .frame(width: 550, height: 350)
    }

    // MARK: - Save Recording
    private func saveRecording() {
        guard let sourceURL = combinedEngine.completedRecordingURL else {
            combinedEngine.statusMessage = "Error: No recording available to save."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Combined Recording"
        panel.nameFieldStringValue = "Combined Recording.caf"
        panel.allowedFileTypes = ["caf"]
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                    combinedEngine.statusMessage = "Saved to \(destURL.lastPathComponent)"
                } catch {
                    combinedEngine.statusMessage = "Save error: \(error.localizedDescription)"
                }
            } else {
                combinedEngine.statusMessage = "Save cancelled."
            }
        }
    }
}

@available(macOS 11.0, *)
struct CombinedRecordingView_Previews: PreviewProvider {
    static var previews: some View {
        CombinedRecordingView()
    }
}
