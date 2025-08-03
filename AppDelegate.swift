import Cocoa
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// AudioRecorderViewModel is defined in ContentView.swift

// ButtonStyleModifier has been moved to its own file

@available(macOS 11.0, *)
struct AudioRecorderView: View {
    @StateObject private var viewModel = AudioRecorderViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Recorder")
                .font(.largeTitle)
                .padding(.top, 30)
            
            Spacer()
            
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
            
            Spacer()
        }
        .padding()
        .frame(width: 500, height: 300)
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

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the main window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.center()
        window.title = "Audio Recorder"
        
        // Create the SwiftUI view and host it in a window - use our explicit AudioRecorderView
        let audioRecorderView = AudioRecorderView()
        window.contentView = NSHostingView(rootView: audioRecorderView)
        window.makeKeyAndOrderFront(nil)
        
        self.window = window
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
