import SwiftUI

@available(macOS 11.0, *)
struct CombinedRecordingView: View {
    // Environment variable to control the view's presentation state (for dismissing the sheet)
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var combinedEngine = CombinedAudioEngine()
    
    var body: some View {
        // Use a VStack for layout
        VStack(spacing: 20) {
            Text("Combined Recording")
                .font(.largeTitle)
                .padding(.top, 30)

            // Status message from engine
            Text(combinedEngine.statusMessage)
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(8)

            HStack(spacing: 20) {
                // Record/Stop Button
                Button {
                    if combinedEngine.isRecording {
                        print("[UI] Stop button pressed. Calling engine.stopRecording()...")
                        combinedEngine.stopRecording()
                    } else {
                        print("[UI] Record button pressed. Calling engine.startRecording()...")
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
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
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
    
    // Function to handle saving the recording
    private func saveRecording() {
        guard let sourceURL = combinedEngine.completedRecordingURL else {
            combinedEngine.statusMessage = "Error: No recording available to save."
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Save Combined Recording"
        savePanel.message = "Choose a location to save the audio file."
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        savePanel.nameFieldStringValue = "Combined Recording.caf" // Keep original extension for direct copy
        savePanel.allowedContentTypes = [.init(filenameExtension: "caf")!, .audio] // Allow .caf or general audio
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            if response == .OK,
               let destinationURL = savePanel.url {
                do {
                    // Remove existing file at destination if necessary
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    // Copy the temporary file to the chosen destination
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    combinedEngine.statusMessage = "Recording saved successfully to \(destinationURL.lastPathComponent)"
                    print("File saved to: \(destinationURL.path)")
                } catch {
                    print("Error saving file: \(error.localizedDescription)")
                    combinedEngine.statusMessage = "Error saving file: \(error.localizedDescription)"
                }
            } else {
                // User cancelled
                combinedEngine.statusMessage = "Save cancelled."
                print("Save panel cancelled.")
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
