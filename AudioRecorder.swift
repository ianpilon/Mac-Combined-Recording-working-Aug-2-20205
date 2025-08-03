import AVFoundation
import Cocoa
import CoreAudio
import CoreMedia
import ScreenCaptureKit

// File logger for diagnostics
class FileLogger {
    static let shared = FileLogger()
    
    private var logFileURL: URL? = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("audio_recorder_log.txt")
    }()
    
    private init() {
        // Clear previous log file
        if let url = logFileURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        
        // Write header
        log("=== AUDIO RECORDER LOG ===\nStarted at \(Date())\n")
    }
    
    func log(_ message: String) {
        guard let url = logFileURL else { return }
        
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
    
    func getLogFilePath() -> String {
        return logFileURL?.path ?? "No log file available"
    }
}

enum AudioSource {
    case microphone
    case systemAudio
    case combined
}

class AudioRecorder: NSObject {
    // For combined recording mode
    private var combinedAudioEngine: CombinedAudioEngine?
    // Counter for audio samples
    private static var appendedSampleCount = 0
    
    // Counter for audio frames in ScreenCaptureKit
    private var audioFrameCounter = 0
    
    // Audio recording properties
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    
    // Audio capture components (used for both microphone and system audio recording)
    private var audioEngine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
    private var audioFile: AVAudioFile?
    
    // For direct audio and screen capture (CGDisplayStream approach - Legacy)
    private var displayStream: CGDisplayStream?
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var tempVideoURL: URL?
    private var tempAudioURL: URL?
    private var screenCaptureQueue = DispatchQueue(label: "com.display.stream")
    
    // For modern ScreenCaptureKit approach (macOS 13.0+)
    // We use a container class to avoid stored property availability issues
    private var screenCaptureManager: Any? = nil
    private var scOutputURL: URL?

    // Container class for macOS 13.0+ ScreenCaptureKit functionality
    @available(macOS 13.0, *)
    private class ScreenCaptureManager: NSObject, SCStreamDelegate {
        var stream: SCStream?
        var audioFile: AVAudioFile?
        var captureQueue = DispatchQueue(label: "com.screencapturekit.queue", qos: .userInitiated)
        
        // SCStreamDelegate implementation
        func stream(_ stream: SCStream, didStopWithError error: Error) {
            print("Stream stopped with error: \(error.localizedDescription)")
            FileLogger.shared.log("Stream stopped with error: \(error.localizedDescription)")
        }
    }
    
    // Previous implementation components (kept for reference)
    private var captureSession: AVCaptureSession?
    private var screenInput: AVCaptureScreenInput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var tempFileURL: URL?
    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var audioQueue = DispatchQueue(label: "audio.recording.queue")
    
    // Recording state
    private(set) var isRecording = false
    private(set) var isPlaying = false
    
    // Selected audio source
    private var selectedSource: AudioSource = .microphone
    
    // File URLs for recordings
    private var recordingURL: URL?
    private var micRecordingURL: URL
    private var systemAudioRecordingURL: URL
    private var combinedRecordingURL: URL
    
    // Completion handlers
    var recordingStateChanged: ((Bool) -> Void)?
    var playbackStateChanged: ((Bool) -> Void)?
    
    override init() {
        // Set up recording file URLs in the Documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.micRecordingURL = documentsPath.appendingPathComponent("mic_recording.m4a")
        self.systemAudioRecordingURL = documentsPath.appendingPathComponent("system_audio_recording.m4a")
        self.combinedRecordingURL = documentsPath.appendingPathComponent("combined_recording.caf")
        
        // Default to microphone recording URL
        self.recordingURL = self.micRecordingURL
        
        super.init()
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { micPermission in
            // Check screen recording permission (for system audio)
            DispatchQueue.main.async {
                // Check for screen recording permission which is required for system audio
                if !CGPreflightScreenCaptureAccess() {
                    // Try to request permission directly
                    _ = CGRequestScreenCaptureAccess()
                    
                    // Show alert explaining screen recording permission requirements
                    let alert = NSAlert()
                    alert.messageText = "Screen Recording Permission Required"
                    alert.informativeText = "To capture system audio, this app needs screen recording permission. Please open System Settings and grant this app access to screen recording."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Later")
                    
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                
                // We'll proceed regardless of screen recording permission status
                // The user can grant it when they try to record system audio
                completion(micPermission)
            }
        }
    }
    
    func setAudioSource(_ source: AudioSource) {
        // Stop any ongoing recording when switching sources
        if isRecording {
            stopRecording()
        }
        
        // If previously in combined mode and switching away, clean up the engine
        if selectedSource == .combined && source != .combined {
            if #available(macOS 12.3, *) {
                // Stop and release the combined audio engine
                if let engine = combinedAudioEngine, engine.isRecording {
                    engine.stopRecording()
                }
                combinedAudioEngine = nil
                print("Cleaned up combined audio engine")
            }
        }
        
        // Update the source
        selectedSource = source
        FileLogger.shared.log("Audio source set to: \(source)")
        
        // Initialize combinedAudioEngine if combined mode is selected
        if source == .combined {
            if #available(macOS 12.3, *) {
                if combinedAudioEngine == nil {
                    print("Creating new CombinedAudioEngine")
                    combinedAudioEngine = CombinedAudioEngine()
                }
            } else {
                print("Combined recording requires macOS 12.3 or later")
            }
        }
    }
    
    func startRecording() -> Bool {
        // Print diagnostics before starting
        print("Start recording requested for source: \(selectedSource)")
        printDiagnostics()
        
        if isRecording {
            print("Already recording")
            return false
        }
        
        // First, attempt to get screen capture access if needed
        if selectedSource == .systemAudio || selectedSource == .combined {
            if !CGPreflightScreenCaptureAccess() {
                print("Requesting screen capture access")
                _ = CGRequestScreenCaptureAccess()
            }
        }
        
        // Set the recording URL based on selected source
        NSLog("🟡 SELECTED SOURCE IS: \(selectedSource)")
        print("🟡 SELECTED SOURCE IS: \(selectedSource)")
        
        switch selectedSource {
        case .microphone:
            NSLog("🟡 STARTING MICROPHONE RECORDING")
            print("🟡 STARTING MICROPHONE RECORDING")
            recordingURL = micRecordingURL
            return startMicrophoneRecording()
        case .systemAudio:
            NSLog("🟡 STARTING SYSTEM AUDIO RECORDING")
            print("🟡 STARTING SYSTEM AUDIO RECORDING")
            recordingURL = systemAudioRecordingURL
            return startSystemAudioRecording()
        case .combined:
            NSLog("🟡 STARTING COMBINED RECORDING")
            print("🟡 STARTING COMBINED RECORDING")
            return startCombinedRecording()
        }
    }
    
    // MARK: - Diagnostics
    
    func printDiagnostics() {
        print("\n=== AUDIO RECORDER DIAGNOSTICS ===")
        print("Selected audio source: \(selectedSource)")
        print("Is recording: \(isRecording)")
        print("Is playing: \(isPlaying)")
        print("Recording URL: \(recordingURL?.path ?? "Not set")")
        print("File exists: \(recordingURL != nil ? FileManager.default.fileExists(atPath: recordingURL!.path) : false)")
        
        // Combined audio specific diagnostics
        if selectedSource == .combined {
            if #available(macOS 12.3, *) {
                if let engine = combinedAudioEngine {
                    print("\n=== COMBINED AUDIO ENGINE DIAGNOSTICS ===")
                    print("Engine initialized: Yes")
                    print("Engine recording: \(engine.isRecording)")
                    print("Engine completed URL: \(engine.completedRecordingURL?.path ?? "None")")
                    engine.printDiagnostics() // Use the engine's own diagnostics
                } else {
                    print("Combined audio engine not initialized")
                }
            } else {
                print("Combined audio requires macOS 12.3+, current OS not compatible")
            }
        }
        print("===================================\n")
    }
    
    private func startMicrophoneRecording() -> Bool {
        do {
            // Set up recording settings for microphone
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            // Create audio recorder
            guard let url = recordingURL else {
                print("No recording URL available")
                return false
            }
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()
            
            // Start recording
            if audioRecorder?.record() == true {
                isRecording = true
                recordingStateChanged?(true)
                return true
            }
        } catch {
            print("Error starting microphone recording: \(error)")
        }
        
        return false
    }
    
    // Note: This requires additional work and a different approach to make it function
    // We're currently exploring a better solution for system audio recording
    private func startSystemAudioRecording() -> Bool {
        FileLogger.shared.log("\n=== SYSTEM AUDIO RECORDING DEBUG ===")
        
        // Check if ScreenCaptureKit is available (macOS 13.0+)
        if #available(macOS 13.0, *) {
            return startSystemAudioRecordingWithScreenCaptureKit()
        } else {
            // Fall back to legacy method for older macOS versions
            FileLogger.shared.log("Using legacy system audio recording method (macOS < 13.0)")
            print("Using legacy system audio recording method (macOS < 13.0)")
            return startLegacySystemAudioRecording()
        }
    }
    
    private func startCombinedRecording() -> Bool {
        NSLog("🔴 COMBINED RECORDING ATTEMPT STARTED")
        print("🔴 COMBINED RECORDING ATTEMPT STARTED")
        
        if #available(macOS 12.3, *) {
            guard let combinedEngine = combinedAudioEngine else {
                NSLog("🔴 COMBINED ENGINE NOT INITIALIZED")
                print("🔴 COMBINED ENGINE NOT INITIALIZED")
                return false
            }
            
            NSLog("🔴 COMBINED ENGINE FOUND, CHECKING PERMISSIONS")
            print("🔴 COMBINED ENGINE FOUND, CHECKING PERMISSIONS")
            
            // Check for permissions
            let micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let screenPermission = CGPreflightScreenCaptureAccess()
            
            if !micPermission {
                NSLog("🔴 MICROPHONE PERMISSION DENIED")
                print("🔴 MICROPHONE PERMISSION DENIED")
                return false
            }
            
            if !screenPermission {
                NSLog("🔴 SCREEN CAPTURE PERMISSION DENIED")
                print("🔴 SCREEN CAPTURE PERMISSION DENIED")
                return false
            }
            
            NSLog("🔴 PERMISSIONS OK, STARTING RECORDING")
            print("🔴 PERMISSIONS OK, STARTING RECORDING")
            
            if !combinedEngine.isRecording {
                // DON'T set recordingURL here - let engine manage it
                // recordingURL = combinedRecordingURL  // ← REMOVED
                
                // Start the engine recording
                NSLog("🔴 CALLING ENGINE.STARTRECORDING()")
                print("🔴 CALLING ENGINE.STARTRECORDING()")
                combinedEngine.startRecording()
                
                NSLog("🔴 ENGINE STARTED, UPDATING STATE")
                print("🔴 ENGINE STARTED, UPDATING STATE")
                isRecording = true
                recordingStateChanged?(true)
                return true
            } else {
                print("Combined recording is already in progress")
                return false
            }
        } else {
            print("Combined recording requires macOS 12.3 or later")
            return false
        }
    }
    
    @available(macOS 13.0, *)
    private func startSystemAudioRecordingWithScreenCaptureKit() -> Bool {
        FileLogger.shared.log("Starting system audio recording with ScreenCaptureKit")
        print("\n=== SYSTEM AUDIO RECORDING DEBUG ===")
        print("Starting system audio recording with ScreenCaptureKit")
        
        // Check and request permission with better handling
        let hasPermission = CGPreflightScreenCaptureAccess()
        FileLogger.shared.log("Initial screen recording permission status: \(hasPermission)")
        
        if !hasPermission {
            FileLogger.shared.log("Screen recording permission not granted - requesting access")
            print("Screen recording permission not granted - requesting access")
            
            // Request permission (this displays system dialog)
            CGRequestScreenCaptureAccess()
            
            // Show additional instructions
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText = "MacAudioRecorder needs screen recording permission to capture system audio. Please grant this permission in System Settings > Privacy & Security > Screen Recording."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                
                self.recordingStateChanged?(false)
            }
            return false
        }
        
        FileLogger.shared.log("Screen recording permission verified")
        print("Screen recording permission verified")
        
        // Create temp path for audio output with unique timestamp and UUID for conflict avoidance
        let tempDir = FileManager.default.temporaryDirectory
        let uniqueID = UUID().uuidString.prefix(8)
        let timestamp = Int(Date().timeIntervalSince1970)
        scOutputURL = tempDir.appendingPathComponent("system_audio_\(timestamp)_\(uniqueID).m4a")
        
        guard let outputURL = scOutputURL else {
            print("ERROR: Could not create output URL")
            return false
        }
        
        // Set recording state
        isRecording = true
        recordingURL = systemAudioRecordingURL  // Final output after processing
        
        // Create the ScreenCaptureManager
        let manager = ScreenCaptureManager()
        screenCaptureManager = manager
        
        // Set up ScreenCaptureKit recording (using async/await)
        Task {
            do {
                // Get available content to capture - this is critical for ScreenCaptureKit
                let availableContent = try await SCShareableContent.current
                
                // Log what displays are available to help with debugging
                FileLogger.shared.log("Available displays for capture: \(availableContent.displays.count)")
                for (index, display) in availableContent.displays.enumerated() {
                    FileLogger.shared.log("   Display \(index): \(display.width)x\(display.height)")
                }
                
                // Select the first available display for capture
                guard let mainDisplay = availableContent.displays.first else {
                    print("ERROR: No display available for capture")
                    FileLogger.shared.log("ERROR: No display available for capture")
                    self.stopRecording() // Clean up if we can't proceed
                    return
                }
                
                // Log selected display details
                FileLogger.shared.log("Selected display for capture: \(mainDisplay.width)x\(mainDisplay.height)")
                
                // Get running applications that we might want to exclude
                let runningApps = availableContent.applications
                FileLogger.shared.log("Number of available applications: \(runningApps.count)")
                
                // Create a list of apps to exclude (optional - we're not excluding any here)
                let excludedApps: [SCRunningApplication] = []
                
                // Configure content filter with the display we want to capture
                // We're not excluding any apps, as that might affect audio capture
                let filter = SCContentFilter(display: mainDisplay, excludingApplications: excludedApps, exceptingWindows: [])
                
                // Configure stream with minimal video, focused on audio
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true         // Enable audio capture
                configuration.excludesCurrentProcessAudio = true  // Don't record our own app's audio
                
                // Set audio-specific settings to match our file format
                configuration.sampleRate = 44100
                configuration.channelCount = 2
                
                // Minimal video settings (must be at least 2x2 to avoid API errors)
                configuration.width = 2                    // Minimal video capture (2x2 pixels)
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 FPS (standard)
                
                // Set up audio file for writing
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                
                do {
                    manager.audioFile = try AVAudioFile(forWriting: outputURL, settings: audioSettings)
                    FileLogger.shared.log("Created audio file at: \(outputURL.path)")
                } catch {
                    FileLogger.shared.log("ERROR creating audio file: \(error.localizedDescription)")
                    print("ERROR creating audio file: \(error.localizedDescription)")
                    self.stopRecording()
                    return
                }
                
                // Create the stream with our manager as the delegate
                let stream = SCStream(filter: filter, configuration: configuration, delegate: manager)
                manager.stream = stream
                
                // Add stream output handler for audio
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: manager.captureQueue)
                
                // Start capturing with better error handling
                do {
                    try await stream.startCapture()
                    
                    // Successfully started capture
                    FileLogger.shared.log("Successfully started ScreenCaptureKit recording to: \(outputURL.path)")
                    print("Successfully started ScreenCaptureKit recording")
                } catch {
                    // Log detailed error information
                    let errorDetail = "ERROR starting ScreenCaptureKit recording: \(error.localizedDescription)"
                    if let nsError = error as NSError? {
                        FileLogger.shared.log("\(errorDetail) - Domain: \(nsError.domain), Code: \(nsError.code)")
                        print("\(errorDetail) - Domain: \(nsError.domain), Code: \(nsError.code)")
                        
                        if nsError.domain == "CoreGraphicsErrorDomain" && nsError.code == 1003 {
                            FileLogger.shared.log("This appears to be a stream initialization error. Likely causes: permissions, resource contention, or system restrictions.")
                            print("This appears to be a stream initialization error. Likely causes: permissions, resource contention, or system restrictions.")
                        }
                    } else {
                        FileLogger.shared.log(errorDetail)
                        print(errorDetail)
                    }
                    
                    // Clean up resources
                    manager.stream = nil
                    manager.audioFile = nil
                    self.stopRecording()
                    return
                }
                
                // Notify UI that recording has started
                DispatchQueue.main.async {
                    self.recordingStateChanged?(true)
                }
            } catch {
                FileLogger.shared.log("ERROR starting ScreenCaptureKit recording: \(error.localizedDescription)")
                print("ERROR starting ScreenCaptureKit recording: \(error.localizedDescription)")
                
                // Clean up on error
                DispatchQueue.main.async {
                    self.stopRecording()
                }
            }
        }
        
        return true
    }
    
    private func startLegacySystemAudioRecording() -> Bool {
        FileLogger.shared.log("Starting system audio recording with CGDisplayStream + AVAudioEngine approach")
        print("Starting system audio recording with CGDisplayStream + AVAudioEngine approach")
        
        // First, ensure screen recording permission is granted (still required)
        if !CGPreflightScreenCaptureAccess() {
            FileLogger.shared.log("CRITICAL ERROR: Screen recording permission is required")
            print("CRITICAL ERROR: Screen recording permission is required")
            DispatchQueue.main.async {
                self.recordingStateChanged?(false)
            }
            return false
        }
        FileLogger.shared.log("Screen recording permission verified")
        print("Screen recording permission verified")
        
        // Create temp paths for audio and video components
        let tempDir = FileManager.default.temporaryDirectory
        tempAudioURL = tempDir.appendingPathComponent("temp_audio_\(Date().timeIntervalSince1970).m4a")
        tempVideoURL = tempDir.appendingPathComponent("temp_video_\(Date().timeIntervalSince1970).mp4")
        
        // Setup in two steps
        if !setupAudioCapture() || !setupScreenCapture() {
            cleanupRecording()
            return false
        }
        
        // Set recording state
        isRecording = true
        recordingURL = systemAudioRecordingURL  // Final output after processing
        recordingStateChanged?(true)
        print("System audio recording started successfully")
        
        return true
    }
    
    private func setupAudioCapture() -> Bool {
        // Initialize Audio Engine
        audioEngine = AVAudioEngine()
        mixerNode = AVAudioMixerNode()
        
        guard let audioEngine = audioEngine, let mixerNode = mixerNode, let tempAudioURL = tempAudioURL else {
            print("ERROR: Failed to create audio components")
            return false
        }
        
        print("Setting up audio capture to: \(tempAudioURL.path)")
        
        // Try to delete existing audio file if it exists
        if FileManager.default.fileExists(atPath: tempAudioURL.path) {
            do {
                try FileManager.default.removeItem(at: tempAudioURL)
            } catch {
                print("Warning: Could not delete existing temp audio file: \(error)")
            }
        }
        
        // Configure the audio engine
        do {
            // Get output node (system audio)
            let outputNode = audioEngine.outputNode
            
            // Attach mixer node
            audioEngine.attach(mixerNode)
            
            // Setup recording format
            let recordingFormat = outputNode.outputFormat(forBus: 0)
            print("Recording format: \(recordingFormat.description)")
            
            // Create audio file for writing
            let recordingSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: recordingFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            audioFile = try AVAudioFile(forWriting: tempAudioURL, 
                                        settings: recordingSettings)
            
            // IMPORTANT: For system audio, tap the output node directly instead of trying to connect it
            outputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
                guard let self = self, let audioFile = self.audioFile else { return }
                
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    print("Error writing audio buffer: \(error.localizedDescription)")
                }
            }
            
            // Start audio engine
            try audioEngine.start()
            print("Audio engine started successfully")
            return true
        } catch {
            print("Error setting up audio capture: \(error.localizedDescription)")
            return false
        }
    }
    
    private func setupScreenCapture() -> Bool {
        guard let tempVideoURL = tempVideoURL else {
            print("ERROR: No video URL available")
            return false
        }
        
        print("Setting up screen capture to: \(tempVideoURL.path)")
        
        // Delete existing video file if it exists
        if FileManager.default.fileExists(atPath: tempVideoURL.path) {
            do {
                try FileManager.default.removeItem(at: tempVideoURL)
            } catch {
                print("Warning: Could not delete existing temp video file: \(error)")
            }
        }
        
        do {
            // Setup asset writer for video
            videoWriter = try AVAssetWriter(outputURL: tempVideoURL, fileType: .mp4)
            
            // Screen dimensions
            let displayID = CGMainDisplayID()
            let width = CGDisplayPixelsWide(displayID)
            let height = CGDisplayPixelsHigh(displayID)
            
            // Use lower resolution and frame rate to minimize resource usage
            // We're only capturing system audio, so the video quality is not important
            let scaleFactor = 0.25 // 25% of screen size
            let outputWidth = Int(Double(width) * scaleFactor)
            let outputHeight = Int(Double(height) * scaleFactor)
            
            // Video settings (low quality, audio is what matters)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1000000, // Low bitrate
                    AVVideoMaxKeyFrameIntervalKey: 30, // Keyframe every 1 second at 30fps
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
                ]
            ]
            
            // Create writer input
            videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoWriterInput?.expectsMediaDataInRealTime = true
            
            // Create pixel buffer adaptor
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight
            ]
            
            guard let videoWriterInput = videoWriterInput else {
                print("ERROR: Could not create video writer input")
                return false
            }
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoWriterInput,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
            
            // Add input to writer
            if let videoWriter = videoWriter, videoWriter.canAdd(videoWriterInput) {
                videoWriter.add(videoWriterInput)
            } else {
                print("ERROR: Cannot add video input to writer")
                return false
            }
            
            // Start the asset writer
            if let videoWriter = videoWriter, videoWriter.startWriting() {
                videoWriter.startSession(atSourceTime: CMTime.zero)
                recordingStartTime = CMClockGetTime(CMClockGetHostTimeClock())
                print("Started video asset writer")
            } else {
                print("ERROR: Cannot start video writer")
                return false
            }
            
            // Set up display stream
            displayStream = CGDisplayStream(
                dispatchQueueDisplay: displayID,
                outputWidth: Int(outputWidth),
                outputHeight: Int(outputHeight),
                pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                properties: nil,
                queue: screenCaptureQueue,
                handler: { [weak self] status, displayTime, frameBuffer, sourceRect in
                    guard let self = self,
                          let frameBuffer = frameBuffer,
                          status == .frameComplete,
                          let recordingStartTime = self.recordingStartTime,
                          let videoWriterInput = self.videoWriterInput,
                          let pixelBufferAdaptor = self.pixelBufferAdaptor else {
                        return
                    }
                    
                    if videoWriterInput.isReadyForMoreMediaData {
                        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())
                        let presentationTime = CMTimeSubtract(currentTime, recordingStartTime)
                        
                        // Write frame to video - force cast IOSurfaceRef to CVPixelBuffer
                        let pixelBuffer = frameBuffer as! CVPixelBuffer
                        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                    }
                }
            )
            
            // Start the display stream
            displayStream?.start()
            print("Started display stream")
            return true
        } catch {
            print("Error setting up screen capture: \(error.localizedDescription)")
            return false
        }
    }
    
    // Note: This combined recording capability was previously implemented here,
    // but has now been replaced by the implementation above that uses CombinedAudioEngine
    
    // This method is no longer used in our simplified implementation
    // but kept as a placeholder for future enhancements
    private func createSystemAudioNode() -> AVAudioNode? {
        return nil
    }
    
    func stopRecording() {
        if isRecording {
            // Stop based on which recording method is active
            switch selectedSource {
            case .microphone:
                // Stop microphone recording
                audioRecorder?.stop()
                isRecording = false
                recordingStateChanged?(false)
                
            case .systemAudio:
                // Stop system audio recording with our new approach
                stopSystemAudioRecording()
                
            case .combined:
                // Stop combined recording mode
                if #available(macOS 12.3, *) {
                    guard let engine = combinedAudioEngine else {
                        print("Combined audio engine not available")
                        isRecording = false
                        recordingStateChanged?(false)
                        return
                    }
                    
                    // Stop the recording
                    engine.stopRecording()
                    
                    // Sync the URL immediately after stopping
                    NSLog("🔴 SYNCING COMPLETED URL FROM ENGINE")
                    print("🔴 SYNCING COMPLETED URL FROM ENGINE")
                    
                    if let completedURL = engine.completedRecordingURL {
                        recordingURL = completedURL
                        NSLog("🔴 ✅ SYNCED recordingURL TO: \(completedURL.path)")
                        print("🔴 ✅ SYNCED recordingURL TO: \(completedURL.path)")
                    } else {
                        NSLog("🔴 ❌ WARNING: NO COMPLETED URL FROM ENGINE")
                        print("🔴 ❌ WARNING: NO COMPLETED URL FROM ENGINE")
                    }
                    
                    isRecording = false
                    recordingStateChanged?(false)
                }
            }
        }
    }
    
    private func stopSystemAudioRecording() {
        print("Stopping system audio recording")
        FileLogger.shared.log("Stopping system audio recording")

        // For the ScreenCaptureKit implementation (macOS 13.0+)
        if #available(macOS 13.0, *) {
            if let manager = screenCaptureManager as? ScreenCaptureManager {
                stopSystemAudioRecordingWithScreenCaptureKit(manager: manager)
                return // Exit early since we're handling the new implementation
            }
        }
        
        // LEGACY IMPLEMENTATION (for older macOS versions)
        // Stop the display stream
        displayStream?.stop()
        print("Stopped display stream")
        
        // Stop and cleanup audio recording
        if let engine = audioEngine, let mixerNode = mixerNode {
            // Remove tap
            mixerNode.removeTap(onBus: 0)
            
            // Stop the engine
            engine.stop()
            print("Stopped audio engine")
        }
        
        // Finalize video recording
        videoWriterInput?.markAsFinished()
        
        // Capture audio and video URLs before cleanup
        let finalAudioURL = tempAudioURL
        let finalVideoURL = tempVideoURL
        
        videoWriter?.finishWriting { [weak self] in
            guard let self = self else { return }
            
            print("Finished writing video file")
            
            // Extract and process audio
            if let audioURL = finalAudioURL, let videoURL = finalVideoURL,
               FileManager.default.fileExists(atPath: audioURL.path) {
                
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
                    if let size = attributes[.size] as? NSNumber {
                        print("Temp audio file size: \(size.intValue) bytes")
                        
                        if size.intValue > 1000 {
                            // We have good audio data, copy to final destination
                            try FileManager.default.copyItem(at: audioURL, to: self.systemAudioRecordingURL)
                            print("Audio file copied to final destination: \(self.systemAudioRecordingURL.path)")
                            
                            let finalAttributes = try FileManager.default.attributesOfItem(atPath: self.systemAudioRecordingURL.path)
                            if let finalSize = finalAttributes[.size] as? NSNumber {
                                print("Final recording size: \(finalSize.intValue) bytes")
                            }
                        } else {
                            print("WARNING: Audio file is suspiciously small, may not contain audio")
                        }
                    }
                } catch {
                    print("Error processing audio file: \(error.localizedDescription)")
                }
                
                // Cleanup temporary files
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: videoURL)
            } else {
                print("WARNING: Temp audio file not found")
            }
            
            // Always update recording state on main thread
            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingStateChanged?(false)
            }
        }
    }
    
    @available(macOS 13.0, *)
    private func stopSystemAudioRecordingWithScreenCaptureKit(manager: ScreenCaptureManager) {
        // Capture local reference to the stream before clearing the manager
        guard let stream = manager.stream else {
            print("No active stream to stop")
            return
        }
        
        // Clear references immediately to prevent redundant stop attempts
        manager.stream = nil
        
        Task {
            do {
                // Stop the screen capture stream with direct reference
                try await stream.stopCapture()
                FileLogger.shared.log("Stopped ScreenCaptureKit capture")
                print("Stopped ScreenCaptureKit capture")
                
                // Close audio file
                manager.audioFile = nil
                manager.stream = nil
                screenCaptureManager = nil
                
                // Process the recorded file
                if let outputURL = scOutputURL, FileManager.default.fileExists(atPath: outputURL.path) {
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                        if let size = attributes[.size] as? NSNumber {
                            print("Recorded audio file size: \(size.intValue) bytes")
                            
                            if size.intValue > 1000 {  // Make sure we have actual data
                                // Handle potential duplicate files by creating a unique destination name if needed
                                let destinationURL = systemAudioRecordingURL
                                
                                // Remove destination file if it already exists
                                if FileManager.default.fileExists(atPath: destinationURL.path) {
                                    do {
                                        try FileManager.default.removeItem(at: destinationURL)
                                        print("Removed existing file at destination")
                                    } catch {
                                        print("Failed to remove existing file: \(error.localizedDescription)")
                                        // Create alternative filename with timestamp
                                        let timestamp = Int(Date().timeIntervalSince1970)
                                        let alternateURL = destinationURL.deletingLastPathComponent()
                                            .appendingPathComponent("system_audio_\(timestamp).m4a")
                                        systemAudioRecordingURL = alternateURL
                                    }
                                }
                                
                                // Copy to final destination
                                try FileManager.default.copyItem(at: outputURL, to: systemAudioRecordingURL)
                                print("Successfully saved system audio recording to: \(systemAudioRecordingURL.path)")
                                FileLogger.shared.log("Saved system audio to: \(systemAudioRecordingURL.path)")
                                
                                // Ensure UI updates
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self else { return }
                                    self.isRecording = false
                                    self.recordingStateChanged?(false)
                                }
                            } else {
                                print("WARNING: Recorded file is too small, likely empty")
                                FileLogger.shared.log("WARNING: Recorded file is too small, likely empty")
                            }
                        }
                    } catch {
                        print("Error processing recorded file: \(error.localizedDescription)")
                        FileLogger.shared.log("Error processing recorded file: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("Error stopping capture: \(error.localizedDescription)")
                FileLogger.shared.log("Error stopping capture: \(error.localizedDescription)")
            }
        }
    }
    
    private func cleanupRecording() {
        // ScreenCaptureKit cleanup (modern implementation)
        if #available(macOS 13.0, *), let manager = screenCaptureManager as? ScreenCaptureManager {
            // Capture the stream before nulling the references
            if let stream = manager.stream {
                // Clear the reference before attempting to stop
                // to prevent duplicate stop attempts
                manager.stream = nil
                
                Task {
                    do {
                        try await stream.stopCapture()
                        print("Stopped ScreenCaptureKit during cleanup")
                    } catch {
                        print("Error stopping ScreenCaptureKit during cleanup: \(error.localizedDescription)")
                    }
                }
            }
            screenCaptureManager = nil
        }
        
        // Remove temp file from ScreenCaptureKit
        if let outputURL = scOutputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
            print("Removed temp ScreenCaptureKit audio file")
        }
        scOutputURL = nil
        
        // Legacy implementation cleanup
        // Stop all recording components
        displayStream?.stop()
        
        if let mixerNode = mixerNode {
            mixerNode.removeTap(onBus: 0)
        }
        
        audioEngine?.stop()
        audioFile = nil
        
        videoWriterInput?.markAsFinished()
        
        // Remove temp files
        if let audioURL = tempAudioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        if let videoURL = tempVideoURL, FileManager.default.fileExists(atPath: videoURL.path) {
            try? FileManager.default.removeItem(at: videoURL)
        }
        
        // Reset components
        displayStream = nil
        audioEngine = nil
        mixerNode = nil
        videoWriter = nil
        videoWriterInput = nil
        pixelBufferAdaptor = nil
        recordingStartTime = nil
        tempVideoURL = nil
        tempAudioURL = nil
    }
    
    private func cleanupEngine() {
        // This is now a wrapper for cleanupRecording to maintain API compatibility
        cleanupRecording()
    }
    
    private func cleanupCaptureSession() {
        // Stop recording if in progress
        if let output = movieOutput, output.isRecording {
            output.stopRecording()
        }
        
        // Stop the session
        captureSession?.stopRunning()
        
        // Clear references for capture components
        movieOutput = nil
        audioOutput = nil
        screenInput = nil
        captureSession = nil
        
        // Clear references for audio writer components
        audioWriter = nil
        audioWriterInput = nil
        
        // Note: We don't clear tempFileURL here as it might still be needed for extraction
    }
    
    func startPlayback() -> Bool {
        if isPlaying {
            print("Already playing")
            return false
        }
        
        FileLogger.shared.log("\n=== PLAYBACK DEBUG ===")
        FileLogger.shared.log("Attempting to play: \(recordingURL?.path ?? "No recording URL")")
        print("\n=== PLAYBACK DEBUG ===")
        print("Attempting to play: \(recordingURL?.path ?? "No recording URL")")
        
        // Special handling for combined recordings
        if selectedSource == .combined {
            if #available(macOS 12.3, *), let engine = combinedAudioEngine {
                NSLog("🟢 USING COMBINED ENGINE FOR PLAYBACK")
                print("🟢 USING COMBINED ENGINE FOR PLAYBACK")
                
                // Ensure URL is synced before playback
                if let engineURL = engine.completedRecordingURL {
                    recordingURL = engineURL
                    NSLog("🟢 ✅ SYNCED URL FOR PLAYBACK: \(engineURL.path)")
                    print("🟢 ✅ SYNCED URL FOR PLAYBACK: \(engineURL.path)")
                }
                
                let success = engine.playLastRecording()
                if success {
                    isPlaying = true
                    playbackStateChanged?(true)
                }
                return success
            } else {
                print("Combined audio engine not available for playback")
                // Fall back to regular playback
            }
        }
        
        // Standard playback for microphone and system audio recordings
        guard let url = recordingURL else {
            print("❌ ERROR: No recording URL available")
            return false
        }
        
        // First check if the file exists at the recording URL
        if !FileManager.default.fileExists(atPath: url.path) {
            print("❌ ERROR: No recording found at \(url.path)")
            return false
        }
        
        // Check file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber {
                print("File size: \(size.intValue) bytes")
                if size.intValue < 1000 {
                    print("WARNING: File is suspiciously small, may not contain audio")
                }
            }
        } catch {
            print("Error checking file size: \(error)")
        }
        
        do {
            // Create audio player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            // Start playback
            if audioPlayer?.play() == true {
                isPlaying = true
                playbackStateChanged?(true)
                return true
            } else {
                print("Failed to start playback")
            }
        } catch {
            print("Error starting playback: \(error)")
        }
        
        return false
    }
    
    func stopPlayback() {
        if !isPlaying {
            return
        }
        
        // Handle combined recording playback
        if selectedSource == .combined {
            if #available(macOS 12.3, *), let engine = combinedAudioEngine {
                // Stop the engine playback
                // Note: The engine doesn't have a specific stopPlayback method,
                // but stopping the engine will stop any ongoing playback
                if engine.isRunning {
                    engine.stop()
                }
            }
        } else if let player = audioPlayer {
            // Standard audio player stop
            player.stop()
        }
        
        // Update state regardless of playback method
        isPlaying = false
        playbackStateChanged?(false)
    }
    
    func saveRecording(to url: URL, completion: @escaping (Bool) -> Void) {
        do {
            guard let sourceURL = recordingURL else {
                print("No recording URL available to save")
                completion(false)
                return
            }
            
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                // Save diagnostic log alongside the recording
                FileLogger.shared.log("Saving recording from \(sourceURL.path) to \(url.path)")
                
                // Copy the recording to the destination
                try FileManager.default.copyItem(at: sourceURL, to: url)
                
                // Also save the log file for diagnostics
                let logDestination = url.deletingLastPathComponent().appendingPathComponent("audio_recording_log.txt")
                let logURL = URL(string: FileLogger.shared.getLogFilePath())
                if let logURL = logURL, FileManager.default.fileExists(atPath: logURL.path) {
                    try FileManager.default.copyItem(at: logURL, to: logDestination)
                    FileLogger.shared.log("Log saved to: \(logDestination.path)")
                    print("Diagnostic log saved to: \(logDestination.path)")
                }
                
                completion(true)
            } else {
                FileLogger.shared.log("No recording found to save at \(sourceURL.path)")
                print("No recording found to save at \(sourceURL.path)")
                completion(false)
            }
        } catch {
            FileLogger.shared.log("Error saving recording: \(error)")
            print("Error saving recording: \(error)")
            completion(false)
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Only mark as finished if not using capture session
        if captureSession == nil {
            self.isRecording = false
            self.recordingStateChanged?(false)
        }
        
        if !flag {
            print("Recording failed")
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording error: \(error)")
        }
        
        // Only mark as finished if not using capture session
        if captureSession == nil {
            self.isRecording = false
            self.recordingStateChanged?(false)
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension AudioRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        FileLogger.shared.log("\n=== CAPTURE DELEGATE CALLBACK ===")
        FileLogger.shared.log("didFinishRecordingTo: \(outputFileURL.path)")
        print("\n=== CAPTURE DELEGATE CALLBACK ===")
        print("didFinishRecordingTo: \(outputFileURL.path)")
        
        // Handle any errors
        if let error = error {
            print("CRITICAL ERROR: Screen recording error: \(error.localizedDescription)")
            self.isRecording = false
            self.recordingStateChanged?(false)
            return
        }
        print("No errors reported in recording callback")
        
        // Verify the file exists and has content
        let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
        print("Output file exists: \(fileExists)")
        
        if fileExists {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: outputFileURL.path)
                if let size = attributes[.size] as? NSNumber {
                    print("File size: \(size.intValue) bytes")
                }
            } catch {
                print("Error checking file size: \(error)")
            }
        }
        
        // Process the recorded file - extract audio for system audio recordings
        print("Proceeding to extract audio from screen recording")
        extractAudioFromScreenRecording(outputFileURL)
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    // We're now using AVCaptureMovieFileOutput instead of processing audio samples directly
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            print("WARNING: Dropped audio sample buffer")
            FileLogger.shared.log("WARNING: Dropped audio sample buffer")
        }
    }
}
    
// MARK: - Audio Extraction
extension AudioRecorder {
    private func extractAudioFromScreenRecording(_ videoURL: URL) {
        FileLogger.shared.log("\n=== AUDIO EXTRACTION PROCESS ===")
        FileLogger.shared.log("Creating asset from: \(videoURL.path)")
        print("\n=== AUDIO EXTRACTION PROCESS ===")
        print("Creating asset from: \(videoURL.path)")
        
        // Create an asset from the screen recording
        let asset = AVAsset(url: videoURL)
        
        // Print asset duration
        let duration = CMTimeGetSeconds(asset.duration)
        print("Asset duration: \(duration) seconds")
        
        // List all tracks in the asset
        print("Asset tracks:")
        for track in asset.tracks {
            print("- Track ID: \(track.trackID), type: \(track.mediaType.rawValue), format: \(track.formatDescriptions)")
        }
        
        // Check if it has an audio track
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            print("CRITICAL ERROR: No audio track found in the screen recording!")
            print("This likely means no system audio was captured.")
            isRecording = false
            recordingStateChanged?(false)
            return
        }
        print("Found audio track: \(audioTrack.trackID)")
        print("Audio format descriptions: \(audioTrack.formatDescriptions)")
        print("Audio track duration: \(CMTimeGetSeconds(audioTrack.timeRange.duration)) seconds")
        
        do {
            // Create an export session to extract just the audio
            let composition = AVMutableComposition()
            
            // Create an audio track in the composition
            let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            
            // Add the audio from the screen recording to the composition
            try compositionAudioTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: audioTrack,
                at: .zero
            )
            
            // Configure export
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                print("Could not create export session")
                self.isRecording = false
                self.recordingStateChanged?(false)
                return
            }
            
            exportSession.outputURL = recordingURL
            exportSession.outputFileType = .m4a
            
            // Export the audio
            print("Starting async export to: \(recordingURL?.path ?? "unknown")")
            exportSession.exportAsynchronously { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    FileLogger.shared.log("\n=== EXPORT COMPLETION ===")
                    print("\n=== EXPORT COMPLETION ===")
                    // Check export status
                    switch exportSession.status {
                    case .completed:
                        print("✅ Audio extraction completed successfully")
                        // Verify the file exists after export
                        if let url = self.recordingURL, FileManager.default.fileExists(atPath: url.path) {
                            print("✅ Recording saved to: \(url.path)")
                            
                            // Get file size
                            do {
                                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                                if let size = attributes[.size] as? NSNumber {
                                    print("Final file size: \(size.intValue) bytes")
                                    if size.intValue < 1000 {
                                        print("WARNING: File is suspiciously small, may not contain audio")
                                    }
                                }
                            } catch {
                                print("Error checking final file size: \(error)")
                            }
                        } else {
                            print("❌ ERROR: Export completed but file not found at destination")
                        }
                    case .failed:
                        print("❌ Export failed: \(exportSession.error?.localizedDescription ?? "unknown error")")
                    case .cancelled:
                        print("❌ Export cancelled")
                    default:
                        print("⚠️ Export ended with status: \(exportSession.status.rawValue)")
                    }
                    
                    // Clean up the temp video file
                    do {
                        if FileManager.default.fileExists(atPath: videoURL.path) {
                            try FileManager.default.removeItem(at: videoURL)
                        }
                    } catch {
                        print("Error removing temp file: \(error)")
                    }
                    
                    // Update state
                    self.isRecording = false
                    self.recordingStateChanged?(false)
                    
                    // Clean up capture session
                    self.cleanupCaptureSession()
                }
            }
        } catch {
            print("Error extracting audio: \(error)")
            self.isRecording = false
            self.recordingStateChanged?(false)
        }
    }
}

// MARK: - SCStreamOutput
@available(macOS 13.0, *)
extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // We only care about audio samples
        guard type == .audio, 
              let manager = screenCaptureManager as? ScreenCaptureManager,
              let audioFile = manager.audioFile else { return }
        
        // Process audio sample buffer - use direct writing method for maximum compatibility
        do {
            // We need to convert CMSampleBuffer to AVAudioPCMBuffer first
            if let formatDescription = sampleBuffer.formatDescription {
                // Get format from the CMSampleBuffer
                let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
                
                // Create buffer with the proper capacity
                let frameCapacity = AVAudioFrameCount(sampleBuffer.numSamples)
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                    print("Failed to create PCM buffer")
                    return
                }
                
                // Set the frame length to match sample count
                pcmBuffer.frameLength = frameCapacity
                
                // Use Apple's recommended approach with CMSampleBuffer
                // Instead of trying to manually copy audio data, we'll take a different approach
                
                // Create a new asset writer to directly write the CMSampleBuffer
                let tempAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_audio_\(UUID().uuidString).m4a")
                
                // Setup an asset writer for direct CMSampleBuffer writing
                let assetWriter = try AVAssetWriter(outputURL: tempAudioURL, fileType: .m4a)
                
                // Configure the audio input
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                
                let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                writerInput.expectsMediaDataInRealTime = true
                
                // Add the input to the writer
                if assetWriter.canAdd(writerInput) {
                    assetWriter.add(writerInput)
                }
                
                // Start the asset writer
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: CMTime.zero)
                
                // Write the sample buffer
                if writerInput.isReadyForMoreMediaData {
                    writerInput.append(sampleBuffer)
                }
                
                // Finish writing
                writerInput.markAsFinished()
                assetWriter.finishWriting {
                    // Now that we have the audio in the temp file, use AVAudioFile to process it
                    do {
                        // Open the temp file and read its format
                        let tempAudioFile = try AVAudioFile(forReading: tempAudioURL)
                        let format = tempAudioFile.processingFormat
                        
                        // Create a buffer large enough for the entire file
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tempAudioFile.length)) else {
                            print("Could not create buffer")
                            return
                        }
                        
                        // Read the file into the buffer
                        try tempAudioFile.read(into: buffer)
                        
                        // Write the buffer to our recording file
                        try audioFile.write(from: buffer)
                    
                        
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: tempAudioURL)
                        
                        // Log success - use explicit self to avoid capture semantics warning
                        self.audioFrameCounter += 1
                        if self.audioFrameCounter <= 5 {
                            print("Successfully wrote audio frame \(self.audioFrameCounter)")
                            FileLogger.shared.log("Successfully wrote audio frame \(self.audioFrameCounter)")
                        }
                    } catch {
                        print("Error processing temp audio file: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("Error writing audio sample: \(error.localizedDescription)")
            FileLogger.shared.log("Error writing audio sample: \(error.localizedDescription)")
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.isPlaying = false
        self.playbackStateChanged?(false)
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print("Playback error: \(error)")
        }
        isPlaying = false
        playbackStateChanged?(false)
    }
}
