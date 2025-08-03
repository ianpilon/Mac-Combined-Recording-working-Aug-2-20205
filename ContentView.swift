import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

class AudioRecorderViewModel: ObservableObject {
    private let audioRecorder = AudioRecorder()
    
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var statusMessage = "Ready to record"
    @Published var selectedSource: AudioSource = .microphone
    
    init() {
        // Set up observers for recording/playback state changes
        audioRecorder.recordingStateChanged = { [weak self] isRecording in
            DispatchQueue.main.async {
                self?.isRecording = isRecording
                self?.statusMessage = isRecording ? "Recording..." : "Ready"
            }
        }
        
        audioRecorder.playbackStateChanged = { [weak self] isPlaying in
            DispatchQueue.main.async {
                self?.isPlaying = isPlaying
                self?.statusMessage = isPlaying ? "Playing..." : "Ready"
            }
        }
    }
    
    func setAudioSource(_ source: AudioSource) {
        selectedSource = source
        audioRecorder.setAudioSource(source)
    }
    
    func toggleRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
        } else {
            // For system audio and combined recording, explicitly check screen recording permission
            if selectedSource == .systemAudio || selectedSource == .combined {
                let hasPermission = CGPreflightScreenCaptureAccess()
                if !hasPermission {
                    // Show alert about screen recording permission
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Screen Recording Permission Required"
                        let featureName = self.selectedSource == .combined ? "combined recording" : "system audio"
                        alert.informativeText = "To record \(featureName), you must grant screen recording permission for this app in System Settings > Privacy & Security > Screen Recording."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Open Settings")
                        alert.addButton(withTitle: "Cancel")
                        
                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    self.statusMessage = "Screen recording permission required"
                    return
                }
            }
            
            // Standard permission check
            audioRecorder.requestPermission { [weak self] hasInputDevices in
                if hasInputDevices {
                    // Set the audio source before recording
                    if let source = self?.selectedSource {
                        self?.audioRecorder.setAudioSource(source)
                    }
                    _ = self?.audioRecorder.startRecording()
                } else {
                    self?.statusMessage = "No audio input devices found"
                }
            }
        }
    }
    
    func togglePlayback() {
        if audioRecorder.isPlaying {
            audioRecorder.stopPlayback()
        } else {
            _ = audioRecorder.startPlayback()
        }
    }
    
    func saveRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a")!]
        panel.nameFieldStringValue = "recording.m4a"
        panel.message = "Save your recording"
        
        panel.begin { [weak self] result in
            if result == .OK, let url = panel.url {
                self?.audioRecorder.saveRecording(to: url) { success in
                    DispatchQueue.main.async {
                        self?.statusMessage = success ? "Recording saved" : "Failed to save"
                    }
                }
            }
        }
    }
}

// ContentView definition with modular components
@available(macOS 11.0, *)
struct ContentView: View {
    @StateObject private var viewModel = AudioRecorderViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Recorder")
                .font(.largeTitle)
                .padding(.top, 30)
            
            // Audio source picker
            sourcePickerView
                .padding(.horizontal)
                .padding(.top, 10)
            
            Text(viewModel.statusMessage)
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(8)
            
            HStack(spacing: 20) {
                // Record button
                recordButton
                
                // Play button
                playButton
                    
                // Save button
                saveButton
            }
            
            // Combined Recording is now part of the source picker above
            
            Spacer()
        }
        .padding()
        .frame(width: 500, height: 300)
        // No longer need the sheet presentation for combined recording
    }
    
    // MARK: - UI Components
    
    private var sourcePickerView: some View {
        VStack(alignment: .leading) {
            Text("Recording Source:")
                .font(.headline)
                .padding(.bottom, 5)
            
            Picker("", selection: $viewModel.selectedSource) {
                Text("Microphone Only").tag(AudioSource.microphone)
                Text("System Audio Only").tag(AudioSource.systemAudio)
                Text("Combined Recording").tag(AudioSource.combined)
            }
            .pickerStyle(SegmentedPickerStyle())
            .onChange(of: viewModel.selectedSource) { newSource in
                viewModel.setAudioSource(newSource)
            }
        }
    }
    
    // MARK: - Button Views
    
    private var recordButton: some View {
        Button(action: viewModel.toggleRecording) {
            Label(
                viewModel.isRecording ? "Stop Recording" : "Record",
                systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .frame(minWidth: 120)
        }
        .disabled(viewModel.isPlaying)
        .applyButtonStyling(color: .red)
    }
    
    private var playButton: some View {
        Button(action: viewModel.togglePlayback) {
            Label(
                viewModel.isPlaying ? "Stop Playback" : "Play",
                systemImage: viewModel.isPlaying ? "stop.circle.fill" : "play.circle.fill"
            )
            .frame(minWidth: 120)
        }
        .disabled(viewModel.isRecording)
        .applyButtonStyling(color: .blue)
    }
    
    private var saveButton: some View {
        Button(action: viewModel.saveRecording) {
            Label("Save", systemImage: "square.and.arrow.down")
                .frame(minWidth: 120)
        }
        .disabled(viewModel.isRecording || viewModel.isPlaying)
        .applyButtonStyling(color: .green)
    }
}

// Custom view extension to handle different macOS versions
extension View {
    @ViewBuilder
    func applyButtonStyling(color: Color) -> some View {
        if #available(macOS 12.0, *) {
            // Use modern styling for macOS 12.0+
            self.buttonStyle(.borderedProminent)
                .tint(color)
        } else {
            // Fallback for older macOS versions
            self.padding(6)
                .background(color)
                .cornerRadius(8)
                .foregroundColor(.white)
        }
    }
}

// Custom modifier for button styling (for use in older styling code)
struct ButtonStyleModifier: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        // Use traditional styling approaches for backward compatibility
        content
            .foregroundColor(.white)
            .background(color)
    }
}

@available(macOS 11.0, *)
#Preview {
    ContentView()
}
