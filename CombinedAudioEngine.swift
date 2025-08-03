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
    
    // --- Connection State Tracking (CRASH FIX) ---
    private var micInputDisconnected: Bool = false
    private var systemAudioDisconnected: Bool = false
    
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
            
            // CRITICAL: Only disconnect inputs if we're not actively recording
            // (This prevents feedback during playback while preserving recording capability)
            if engine.isRunning && !isRecording {
                // Disconnect microphone input from mixer (prevents feedback)
                engine.disconnectNodeInput(mixer, bus: 0)
                micInputDisconnected = true
                print("🔇 Disconnected microphone input to prevent feedback")
                
                // Disconnect system audio player from mixer (prevents interference)
                engine.disconnectNodeOutput(systemAudioPlayerNode)
                systemAudioDisconnected = true
                print("🔇 Disconnected system audio player to prevent interference")
            } else if isRecording {
                micInputDisconnected = false
                systemAudioDisconnected = false
                print("⚠️ Recording in progress - keeping audio connections intact")
            }
            
            // Create a dedicated player node for playback
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            
            // Get the file
            let audioFile = try AVAudioFile(forReading: fileURL)
            print("🎵 Playing file: \(fileURL.path)")
            
            // Connect player DIRECTLY to output (bypass mixer to avoid feedback)
            engine.connect(playerNode, to: engine.outputNode, format: audioFile.processingFormat)
            print("🔌 Connected player directly to output (isolated path)")
            
            // Start the engine if needed
            if !engine.isRunning {
                try engine.start()
                print("🎵 Started engine for playback")
            }
            
            // Schedule the file for playback
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    
                    strongSelf.statusMessage = "Playback finished"
                    print("🎵 Playback finished")
                    
                    // SAFE CLEANUP: Use try-catch to prevent crashes
                    strongSelf.safeCleanupPlayback(playerNode: playerNode)
                }
            }
            
            // Start playback
            playerNode.play()
            statusMessage = "Playing recording..."
            print("🎵 Started isolated playback (no feedback)")
            return true
        } catch {
            statusMessage = "Error playing recording: \(error.localizedDescription)"
            print("❌ Error playing combined recording: \(error.localizedDescription)")
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
        
        // Clear any previous audio data FIRST
        clearScheduledBuffers()
        
        // Setup audio engine with proper connections
        setupAudioEngine()
        
        // Reset audio nodes to ensure clean state
        resetAudioNodes()
        
        // Start screen capture stream
        Task(priority: .userInitiated) {
            await startScreenCapture()
        }
        
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
        
        // Stop engine but DON'T reset it - keep the audio graph intact
        if engine.isRunning {
            engine.stop()
            print("Engine stopped (graph preserved)")
        }
        
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
    
    // Clears all scheduled audio buffers from the system audio player node
    private func clearScheduledBuffers() {
        print("Clearing scheduled audio buffers...")
        
        // Stop the player node
        if systemAudioPlayerNode.isPlaying {
            systemAudioPlayerNode.stop()
        }
        
        // Reset clears all scheduled buffers
        systemAudioPlayerNode.reset()
        
        print("All scheduled buffers cleared")
    }
    
    // Resets audio nodes to clean state
    private func resetAudioNodes() {
        print("Resetting audio nodes...")
        
        if engine.isRunning {
            // Stop the player node completely
            if systemAudioPlayerNode.isPlaying {
                systemAudioPlayerNode.stop()
                print("Stopped system audio player node")
            }
            
            // Disconnect from audio graph
            engine.disconnectNodeOutput(systemAudioPlayerNode)
            print("Disconnected system audio player node")
            
            // Reset the node to clear any scheduled buffers
            systemAudioPlayerNode.reset()
            print("Reset system audio player node (cleared buffers)")
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
    
    // Safely reconnects audio sources after playback to restore recording capability
    private func reconnectAudioSources() {
        print("🔌 Safely reconnecting audio sources for future recording...")
        
        guard engine.isRunning else {
            print("⚠️ Engine not running, skipping reconnection")
            return
        }
        
        // CRASH FIX: Only reconnect what we actually disconnected
        if !micInputDisconnected && !systemAudioDisconnected {
            print("✅ No disconnections made - skipping reconnection")
            return
        }
        
        do {
            // Only reconnect microphone if we disconnected it
            if micInputDisconnected {
                let inputNode = engine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                engine.connect(inputNode, to: mixer, format: inputFormat)
                micInputDisconnected = false
                print("🎤 Reconnected microphone input to mixer")
            }
            
            // Only reconnect system audio player if we disconnected it
            if systemAudioDisconnected {
                // CRITICAL: Use the SAME sample rate as the engine
                let engineSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
                let systemAudioFormat = AVAudioFormat(standardFormatWithSampleRate: engineSampleRate, channels: 2)!
                engine.connect(systemAudioPlayerNode, to: mixer, format: systemAudioFormat)
                systemAudioDisconnected = false
                print("🔊 Reconnected system audio player to mixer (\(engineSampleRate)Hz)")
            }
            
            print("✅ Audio sources safely reconnected - ready for recording")
        } catch {
            print("❌ Error reconnecting audio sources: \(error.localizedDescription)")
            // Reset state and fallback to full setup
            micInputDisconnected = false
            systemAudioDisconnected = false
            setupAudioEngine()
        }
    }
    
    // MINIMAL cleanup to isolate crash cause
    private func safeCleanupPlayback(playerNode: AVAudioPlayerNode) {
        print("🧹 MINIMAL cleanup - isolating crash cause...")
        
        // STEP 1: Just update status - NO audio operations
        print("✅ Playback cleanup completed (minimal)")
        
        // TODO: Add operations one by one to find crash point
    }
    
    private func setupAudioEngine() {
        print("Setting up audio engine...")
        
        // Clean shutdown if running
        if engine.isRunning {
            engine.stop()
            print("Stopped running engine")
        }
        
        // Detach all custom nodes to ensure clean state
        if engine.attachedNodes.contains(systemAudioPlayerNode) {
            engine.detach(systemAudioPlayerNode)
            print("Detached system audio player node")
        }
        
        // Reattach system audio player node
        engine.attach(systemAudioPlayerNode)
        print("Reattached system audio player node")
        
        // Rebuild microphone input connection
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        engine.connect(inputNode, to: mixer, format: inputFormat)
        print("🎤 Connected microphone input to mixer (Format: \(inputFormat))")
        
        // Connect system audio player to mixer
        // CRITICAL: Use the SAME sample rate as the engine to prevent speed mismatch
        let engineSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let systemAudioFormat = AVAudioFormat(standardFormatWithSampleRate: engineSampleRate, channels: 2)!
        engine.connect(systemAudioPlayerNode, to: mixer, format: systemAudioFormat)
        print("🔊 Connected system audio player to mixer (Format: \(systemAudioFormat))")
        print("⚙️ SAMPLE RATE SYNC: Engine=\(engineSampleRate)Hz, SystemAudio=\(systemAudioFormat.sampleRate)Hz")
        
        // Prepare engine for recording
        engine.prepare()
        print("⚙️ Audio engine prepared and ready")
        
        // Enhanced diagnostics
        print("🔍 AUDIO GRAPH DIAGNOSTICS:")
        print("  - Input Node: \(inputNode)")
        print("  - System Audio Player: \(systemAudioPlayerNode)")
        print("  - Mixer: \(mixer)")
        print("  - Mixer Input Count: \(mixer.numberOfInputs)")
        print("  - Engine Attached Nodes: \(engine.attachedNodes.count)")
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
