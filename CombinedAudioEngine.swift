import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine // For @Published properties later

// Class responsible for handling simultaneous Mic + System Audio recording
@available(macOS 12.3, *) // ScreenCaptureKit requires macOS 12.3+
class CombinedAudioEngine: NSObject, ObservableObject, SCStreamDelegate {
    
    // MARK: - Properties
    
    // --- Audio Engine --- 
    private let engine = AVAudioEngine()
    private let mixer: AVAudioMixerNode // Main mixer - accessible via engine.mainMixerNode
    private let systemAudioPlayerNode = AVAudioPlayerNode() // Node to feed system audio into
    
    // --- Screen Capture (System Audio) --- 
    private var stream: SCStream?
    private var availableContent: SCShareableContent? // Available displays/windows
    private var filter: SCContentFilter? // Filter for selecting content
    private let serialQueue = DispatchQueue(label: "com.example.MacAudioRecorder.ScreenCaptureQueue") // Dedicated queue for capture callbacks
    
    // --- File Writing ---
    private var outputFile: AVAudioFile?
    private var outputFileURL: URL? // URL for the temporary recording file
    private let outputBus = 0 // Bus 0 is standard output
    
    // --- State --- 
    @Published var isRecording: Bool = false
    @Published var statusMessage: String = "Ready"
    @Published var completedRecordingURL: URL? = nil // URL of the last completed recording
    
    // Computed property to check if the engine is running
    var isRunning: Bool {
        return engine.isRunning
    }
    // TODO: Add more specific state vars if needed (isRecordingMic, isRecordingSystem)
    
    // MARK: - Initialization
    
    override init() {
        self.mixer = engine.mainMixerNode // Get mixer reference
        super.init() // Ensure superclass is initialized (Required for NSObject subclassing)
        setupAudioEngine()
        // Start fetching shareable content immediately
        updateShareableContent()
        print("CombinedAudioEngine Initialized and basic setup done.")
    }
    
    // MARK: - Public Methods (Recording Control)
    
    // Play back the last completed recording
    func playLastRecording() -> Bool {
        // Ensure we have a recording to play
        guard let fileURL = completedRecordingURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            statusMessage = "No recording available to play"
            print("No recording available to play")
            return false
        }
        
        // Print diagnostics
        printDiagnostics()
        
        do {
            // Stop any ongoing recording/playback
            if isRecording {
                stopRecording()
            }
            
            // Create a player node for playback
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            
            // Get the file
            let audioFile = try AVAudioFile(forReading: fileURL)
            print("Playing file: \(fileURL.path)")
            
            // Connect player to the output
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)
            
            // Start the engine if needed
            if !engine.isRunning {
                try engine.start()
            }
            
            // Schedule the file for playback
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.statusMessage = "Playback finished"
                    print("Playback finished")
                    
                    // Clean up after playback
                    self?.engine.detach(playerNode)
                }
            }
            
            // Start playback
            playerNode.play()
            statusMessage = "Playing recording..."
            print("Started playback of recording")
            return true
        } catch {
            statusMessage = "Error playing recording: \(error.localizedDescription)"
            print("Error playing combined recording: \(error.localizedDescription)")
            return false
        }
    }
    
    func startRecording() {
        NSLog("🔵 COMBINED ENGINE: startRecording() called")
        print("🔵 COMBINED ENGINE: startRecording() called")
        
        // Print diagnostics before starting
        printDiagnostics()
        
        // Reset state from previous recording
        completedRecordingURL = nil
        
        // Clean up existing resources
        if engine.isRunning {
            engine.stop()
        }
        resetAudioNodes()
        
        // Check permissions (could be moved to a separate method)
        let micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let screenPermission = CGPreflightScreenCaptureAccess()
        
        if !micPermission {
            statusMessage = "Microphone permission required"
            print("Microphone permission not granted")
            return
        }
        
        if !screenPermission {
            statusMessage = "Screen recording permission required"
            print("Screen capture permission not granted")
            return
        }
        
        // Start screen capture stream
        Task(priority: .userInitiated) {
            await startScreenCapture()
        }
        
        // --- Make engine connections --- 
        let inputNode = engine.inputNode // Default Mic Input
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Connect Mic to Mixer
        engine.connect(inputNode, to: mixer, format: inputFormat)
        print("Connected Mic Input node to Mixer node.")
        
        // Define the format for the system audio source node
        // We aim to match the engine's main mixer output format
        let systemAudioFormat = mixer.outputFormat(forBus: 0)
        
        // Connect System Audio Player Node to Mixer
        engine.connect(systemAudioPlayerNode, to: mixer, format: systemAudioFormat)
        print("Connected System Audio Player node to Mixer node.")
        
        do {
            try engine.start()
            try setupFileWritingTap()
            print("AVAudioEngine started successfully and file writing tap installed.")
            // TODO: Update state properly after all setup
            isRecording = true // Placeholder
            statusMessage = "Recording Combined..." // Placeholder
        } catch {
            print("Error starting AVAudioEngine or setting up tap: \(error.localizedDescription)")
            statusMessage = "Error starting engine/tap: \(error.localizedDescription)"
            // Perform cleanup if start fails
            stopRecording()
        }
    }
    
    // Stops any ongoing playback
    func stopPlayback() {
        print("[Engine] stopPlayback() called")
        
        // Stop engine playback if it's running but not recording
        if engine.isRunning && !isRecording {
            // Find and stop any player nodes
            for node in engine.attachedNodes where node is AVAudioPlayerNode {
                if let playerNode = node as? AVAudioPlayerNode, playerNode.isPlaying {
                    playerNode.stop()
                    print("Stopped player node")
                }
            }
            
            // Only stop the engine if we're not recording
            if !isRecording {
                engine.stop()
                print("Stopped engine for playback")
            }
        }
        
        // Update status message
        statusMessage = "Ready"
    }
    
    // General stop method for the engine
    func stop() {
        print("[Engine] stop() called")
        if engine.isRunning {
            engine.stop()
            print("Engine stopped")
        }
        statusMessage = "Ready"
    }
    
    func stopRecording() {
        print("[Engine] stopRecording() called.")
        
        // Print diagnostics before stopping
        printDiagnostics()
        
        // Early return if not recording
        if !isRecording {
            print("Not recording, nothing to stop")
            return
        }
        
        // Ensure we clean up any ongoing playback
        stopPlayback()
        
        // Update state immediately
        isRecording = false 
        statusMessage = "Stopping Combined..."
        
        // Stop engine first
        if engine.isRunning {
            engine.stop()
            print("AVAudioEngine stopped.")
        }
        
        // Stop screen capture stream
        if let stream = stream {
            stream.stopCapture()
            print("SCStream stopped.")
            self.stream = nil
        }
        
        // Stop and reset system audio player node
        systemAudioPlayerNode.stop()
        systemAudioPlayerNode.reset()
        print("System audio player node stopped and reset.")
        
        // Remove tap and close file
        mixer.removeTap(onBus: outputBus)
        let finishedURL = outputFileURL // Capture URL before nil'ing outputFile
        outputFile = nil // Releases the file handle
        print("Removed mixer tap and closed output file. File available at: \(finishedURL?.path ?? "Not found")")
        
        // Update state with the completed file URL
        if let url = finishedURL, FileManager.default.fileExists(atPath: url.path) {
            completedRecordingURL = url
            statusMessage = "Recording finished. Ready to save."
            print("Recording completed successfully at: \(url.path)")
        } else {
            statusMessage = "Recording stopped. File not found."
            print("Recording stopped but file not found or not created")
        }
        
        // Reset engine to clear any lingering state
        engine.reset()
        print("AVAudioEngine reset.")
        
        // Clear outputFileURL to prevent confusion with next recording
        outputFileURL = nil
        
        // Print diagnostics after cleanup
        printDiagnostics()
    }
    
    // MARK: - Private Setup Helpers
    
    // Creates a unique file URL for each recording
    private func createUniqueOutputURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)
        let uniqueID = UUID().uuidString.prefix(8)
        return tempDir.appendingPathComponent("combined_recording_\(timestamp)_\(uniqueID)").appendingPathExtension("caf")
    }
    
    // Resets audio nodes to clean state
    private func resetAudioNodes() {
        print("Resetting audio nodes")
        // Stop and reset the player node
        systemAudioPlayerNode.stop()
        systemAudioPlayerNode.reset()
        
        // Remove any existing connections if the engine is running
        if engine.isRunning {
            engine.disconnectNodeOutput(systemAudioPlayerNode)
            // Do not disconnect the input node as it might be in use elsewhere
        }
    }
    
    // Prints diagnostic information about the current state
    func printDiagnostics() {
        print("--- CombinedAudioEngine Diagnostics ---")
        print("Engine running: \(engine.isRunning)")
        print("Is recording: \(isRecording)")
        print("Player node playing: \(systemAudioPlayerNode.isPlaying)")
        print("Completed recording URL: \(completedRecordingURL?.path ?? "None")")
        print("Current output file: \(outputFileURL?.path ?? "None")")
        print("File exists: \(outputFileURL != nil ? FileManager.default.fileExists(atPath: outputFileURL!.path) : false)")
        print("-----------------------------------")
    }
    
    private func setupAudioEngine() {
        // Attach nodes that will be used
        _ = engine.inputNode // Ensure input node is available early
        engine.attach(systemAudioPlayerNode)
        
        // Initial connections (more connections might happen in startRecording)
        // We will connect mic and system audio source to the mixer later.
        
        // Prepare the engine but don't start it here
        engine.prepare()
        print("AVAudioEngine prepared.")
    }
    
    // MARK: - Screen Capture Setup & Control
    
    private func updateShareableContent() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            if let error = error {
                print("Error getting shareable content: \(error.localizedDescription)")
                // TODO: Update status message for UI
                self.statusMessage = "Error getting screen content: \(error.localizedDescription)"
                return
            }
            self.availableContent = content
            print("Shareable content updated.")
            // Optionally update UI if needed (e.g., to allow user selection)
        }
    }
    
    private func setupScreenCapture() {
        guard let availableContent = availableContent else {
            print("Error: Shareable content not available.")
            statusMessage = "Error: Screen content not found."
            return
        }
        
        // Configuration: Find the first display, or potentially an application window
        // For system audio, capturing a display is typical.
        guard let display = availableContent.displays.first else {
             print("Error: No display found for capture.")
             statusMessage = "Error: No display found."
             return
        }
        
        // Create a content filter to capture the chosen display (and exclude our app)
        // For system-wide audio, we typically capture a display.
        // Exclude the current app's windows to avoid potential feedback loops if playing audio.
        let excludedApps = availableContent.applications.filter { app in
            Bundle.main.bundleIdentifier == app.bundleIdentifier
        }
        self.filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        
        // Create the stream configuration
        let config = SCStreamConfiguration()
        config.width = 2 // Minimal width for audio-only
        config.height = 2 // Minimal height for audio-only
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // Low frame rate
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // Avoid capturing audio generated by this app
        config.sampleRate = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate) // Match engine's sample rate
        
        do {
            stream = SCStream(filter: filter!, configuration: config, delegate: self)
            // Add stream output for audio
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: serialQueue)
            print("SCStream initialized and output added.")
        } catch {
            print("Error initializing SCStream or adding output: \(error.localizedDescription)")
            statusMessage = "Error setting up screen capture: \(error.localizedDescription)"
        }
    }
    
    private func startScreenCapture() async {
        setupScreenCapture() // Ensure stream is configured
        
        guard let stream = stream else {
            print("SCStream not initialized, cannot start capture.")
            statusMessage = "Error: Screen capture not ready."
            return
        }
        
        do {
            try await stream.startCapture()
            print("SCStream capture started.")
        } catch {
            print("Error starting SCStream capture: \(error.localizedDescription)")
            // TODO: Handle error - update UI state, stop engine etc.
            statusMessage = "Error starting screen capture: \(error.localizedDescription)"
            stopRecording() // Stop everything if screen capture fails to start
        }
    }
    
    private func setupFileWritingTap() throws {
        let tapNode = mixer
        // --- Define Output Format --- 
        // Use a common format like linear PCM which is widely compatible within CAF
        // Or potentially AAC for compressed M4A (would require different AVAudioFile settings)
        // Let's stick with the mixer's output format initially for simplicity inside CAF.
        let format = tapNode.outputFormat(forBus: outputBus)
        
        // Create a unique temporary file URL using our helper method
        outputFileURL = createUniqueOutputURL()
        
        print("Setting up file writing tap. Output URL: \(outputFileURL!.path)")
        
        // Remove existing file if it exists (e.g., from a previous failed recording)
        if let url = outputFileURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        
        // Create the AVAudioFile
        outputFile = try AVAudioFile(forWriting: outputFileURL!, settings: format.settings)
        
        // Install the tap
        tapNode.installTap(onBus: outputBus, bufferSize: 4096, format: format) { [weak self] (buffer, time) in
            guard let self = self, let outputFile = self.outputFile else { return }
            
            do {
                // Write the buffer to the file
                try outputFile.write(from: buffer)
            } catch {
                print("Error writing audio buffer to file: \(error.localizedDescription)")
                // Consider stopping recording or setting an error state here
                self.statusMessage = "Error writing file: \(error.localizedDescription)"
                // Maybe call self.stopRecording() ? Depends on desired behavior
            }
        }
    }

    private func checkPermissions() {
        // ... mic and screen recording checks ...
    }
    
    // Required SCStreamDelegate method for handling stream errors/stop events
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("System audio stream stopped with error: \(error.localizedDescription)")
        // We should probably stop the recording if the system audio stream fails
        DispatchQueue.main.async {
            self.statusMessage = "System audio error: \(error.localizedDescription)"
            // Check if we are still recording, might have been stopped already
            if self.isRecording {
                self.stopRecording() 
            }
        }
    }
}

// MARK: - SCStreamOutput Delegate Methods (CMSampleBuffer Handling)

@available(macOS 12.3, *)
extension CombinedAudioEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only process audio buffers and ensure we're actually recording
        guard type == .audio, isRecording, engine.isRunning else { return }
        
        // Ensure the engine is running and we're expecting audio
        guard engine.isRunning else { return }
        
        // Convert CMSampleBuffer to AVAudioPCMBuffer
        // Get the format description from the CMSampleBuffer
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            print("Error getting audio format description from sample buffer")
            return
        }
        
        // Create an AVAudioFormat instance from the stream description
        // Explicitly cast channel count to AVAudioChannelCount (UInt32)
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: streamBasicDescription.mSampleRate,
                                              channels: AVAudioChannelCount(streamBasicDescription.mChannelsPerFrame)) else {
             print("Error creating AVAudioFormat from stream description")
             return
        }
        
        // Calculate frame length
        // Ensure frameLength is explicitly AVAudioFrameCount (UInt32)
        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        
        // Create an AVAudioPCMBuffer
        // Ensure frameCapacity is AVAudioFrameCount (UInt32)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameLength)) else {
            print("Error creating AVAudioPCMBuffer")
            return
        }
        pcmBuffer.frameLength = frameLength
        
        // Copy the audio data from CMSampleBuffer to AVAudioPCMBuffer
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                     at: 0,
                                                     frameCount: Int32(frameLength), // Explicit cast
                                                     into: pcmBuffer.mutableAudioBufferList)
        
        // Only schedule the buffer if we're actively recording
        if isRecording && engine.isRunning {
            // Schedule the buffer on the player node
            systemAudioPlayerNode.scheduleBuffer(pcmBuffer) {
                // Optional completion handler if needed
            }
            
            // Ensure the player node is playing to process scheduled buffers
            if !systemAudioPlayerNode.isPlaying && isRecording {
                systemAudioPlayerNode.play()
                print("Started System Audio Player Node.")
            }
        }
    }
}
