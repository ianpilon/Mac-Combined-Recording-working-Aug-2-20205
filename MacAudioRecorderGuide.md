# MacAudioRecorder Project Guide

## Project Overview
MacAudioRecorder is a macOS application built with SwiftUI that allows users to record, play, and save audio files. This document provides a comprehensive guide to the project structure, key files, and instructions for resolving common issues.

## Key Files

### 1. AudioRecorderApp.swift
```swift
import SwiftUI

@main
struct AudioRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 500, height: 300)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
```

### 2. ContentView.swift
```swift
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@available(macOS 11.0, *)
struct ContentView: View {
    @StateObject private var viewModel = AudioRecorderViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Recorder")
                .font(.largeTitle)
                .padding(.top, 20)
            
            Text(viewModel.statusMessage)
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .systemGray))
                .cornerRadius(8)
            
            HStack(spacing: 20) {
                // Record button
                Button(action: viewModel.toggleRecording) {
                    Label(
                        viewModel.isRecording ? "Stop Recording" : "Record",
                        systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(minWidth: 120)
                }
                .disabled(viewModel.isPlaying)
                .buttonStyle(.borderedProminent)
                .foregroundColor(.white)
                .background(Color.red)
                
                // Play button
                Button(action: viewModel.togglePlayback) {
                    Label(
                        viewModel.isPlaying ? "Stop" : "Play",
                        systemImage: viewModel.isPlaying ? "stop.circle.fill" : "play.circle.fill"
                    )
                    .frame(minWidth: 120)
                }
                .disabled(viewModel.isRecording)
                .buttonStyle(.borderedProminent)
                .foregroundColor(.white)
                .background(Color.blue)
                
                // Save button
                Button(action: viewModel.saveRecording) {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(minWidth: 120)
                }
                .disabled(viewModel.isRecording || viewModel.isPlaying)
                .buttonStyle(.borderedProminent)
                .foregroundColor(.white)
                .background(Color.green)
            }
            .padding()
            
            Spacer()
        }
        .padding()
    }
}

class AudioRecorderViewModel: ObservableObject {
    private let audioRecorder = AudioRecorder()
    
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var statusMessage = "Ready to record"
    
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
    
    func toggleRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
        } else {
            // Check for microphone access
            audioRecorder.requestPermission { [weak self] hasInputDevices in
                if hasInputDevices {
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
```

### 3. AudioRecorder.swift
```swift
import AVFoundation

class AudioRecorder: NSObject {
    
    // Audio recording properties
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    
    // Recording state
    private(set) var isRecording = false
    private(set) var isPlaying = false
    
    // File URL for recordings
    private var recordingURL: URL
    
    // Completion handlers
    var recordingStateChanged: ((Bool) -> Void)?
    var playbackStateChanged: ((Bool) -> Void)?
    
    override init() {
        // Set up recording file URL in the Documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.recordingURL = documentsPath.appendingPathComponent("recording.m4a")
        
        super.init()
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        // On macOS, we don't need to request permission explicitly like on iOS
        // But we can verify if audio input devices are available
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified)
        let hasInputDevices = !discoverySession.devices.isEmpty
        
        DispatchQueue.main.async {
            completion(hasInputDevices)
        }
    }
    
    func startRecording() -> Bool {
        if isRecording {
            print("Already recording")
            return false
        }
        
        do {
            // Set up recording settings
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            // Create audio recorder
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()
            
            // Start recording
            if audioRecorder?.record() == true {
                isRecording = true
                recordingStateChanged?(true)
                return true
            }
        } catch {
            print("Error starting recording: \(error)")
        }
        
        return false
    }
    
    func stopRecording() {
        if isRecording, let recorder = audioRecorder {
            recorder.stop()
            isRecording = false
            recordingStateChanged?(false)
        }
    }
    
    func startPlayback() -> Bool {
        if isPlaying {
            print("Already playing")
            return false
        }
        
        do {
            // Create audio player
            audioPlayer = try AVAudioPlayer(contentsOf: recordingURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            // Start playback
            if audioPlayer?.play() == true {
                isPlaying = true
                playbackStateChanged?(true)
                return true
            }
        } catch {
            print("Error starting playback: \(error)")
        }
        
        return false
    }
    
    func stopPlayback() {
        if isPlaying, let player = audioPlayer {
            player.stop()
            isPlaying = false
            playbackStateChanged?(false)
        }
    }
    
    func saveRecording(to url: URL, completion: @escaping (Bool) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try FileManager.default.copyItem(at: recordingURL, to: url)
                completion(true)
            } else {
                completion(false)
            }
        } catch {
            print("Error saving recording: \(error)")
            completion(false)
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        isRecording = false
        recordingStateChanged?(false)
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording error: \(error)")
        }
        isRecording = false
        recordingStateChanged?(false)
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        playbackStateChanged?(false)
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print("Playback error: \(error)")
        }
        isPlaying = false
        playbackStateChanged?(false)
    }
}
```

### 4. Info.plist
Ensure this file contains:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSMicrophoneUsageDescription</key>
	<string>We need access to your microphone to record audio.</string>
</dict>
</plist>
```

## Fixing Duplicate File Issues

Your current project has multiple ContentView definitions across different files, causing build errors. To fix this:

1. **Clean up duplicate files**:
   - In Xcode, in the project navigator (left panel), search for "ContentView"
   - For each duplicate (except for the main one at `/Users/ianpilon/CascadeProjects/MacAudioRecorder/ContentView.swift`):
     - Select the file
     - In the File Inspector (right panel), find "Target Membership"
     - Uncheck the box for "MacAudioRecorder"

2. **Fix app entry point conflicts**:
   - Only one file should have the `@main` attribute
   - Either use AudioRecorderApp.swift or MacAudioRecorderApp.swift, not both

3. **Remove AppDelegate.swift if not needed**:
   - If using the SwiftUI App lifecycle, you don't need AppDelegate.swift

4. **Clean build folder and rebuild**:
   - Product → Clean Build Folder (⇧⌘K)
   - Build again (⌘B)

## Project Configuration

- **Deployment Target**: macOS 11.0 (minimum for SwiftUI compatibility)
- **Privacy Permissions**: Microphone access required
- **App Sandbox**: Enable with microphone and file access permissions

## Using the App

1. Click the **Record** button to start recording audio
2. Click **Stop Recording** when finished
3. Click **Play** to listen to the recording
4. Click **Save** to save the recording as an .m4a file

## Next Steps for Enhancement

- Add waveform visualization
- Implement audio level meters
- Add audio format options
- Create recording list management
