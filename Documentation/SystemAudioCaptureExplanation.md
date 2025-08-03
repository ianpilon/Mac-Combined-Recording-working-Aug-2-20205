# Explaining System Audio Capture on macOS using ScreenCaptureKit

This document details the process used by the MacAudioRecorder application to capture system audio on macOS 13.0 and later, primarily leveraging the `ScreenCaptureKit` framework. This method requires obtaining Screen Recording permissions from the user.

## Core Approach: ScreenCaptureKit

`ScreenCaptureKit` is designed for screen recording but can be configured to capture system audio alongside video. The key is to configure the video capture minimally while enabling audio.

## Prerequisites

1.  **macOS Version**: 13.0 or later.
2.  **Screen Recording Permission**: The user must grant this permission via System Settings > Privacy & Security > Screen Recording.

## Setup and Configuration Steps

The setup involves configuring and starting an `SCStream`:

1.  **Check/Request Permissions**:
    *   Verify existing permission using `CGPreflightScreenCaptureAccess()`.
    *   If not granted, request it using `CGRequestScreenCaptureAccess()`. Guide the user to System Settings if needed.

2.  **Identify Content**: Use `SCShareableContent.current` to get a list of available displays.

3.  **Create Content Filter**: Instantiate an `SCContentFilter` targeting a specific display (e.g., the first available one). Importantly, do *not* exclude any applications if the goal is to capture all system audio.
    ```swift
    // Assuming 'mainDisplay' is an SCDisplay obtained from SCShareableContent
    let filter = SCContentFilter(display: mainDisplay, excludingApplications: [], exceptingWindows: [])
    ```

4.  **Configure Stream (`SCStreamConfiguration`)**:
    *   Enable audio capture: `configuration.capturesAudio = true`
    *   Exclude the app's own audio: `configuration.excludesCurrentProcessAudio = true`
    *   Set desired audio parameters: `configuration.sampleRate = 44100`, `configuration.channelCount = 2`
    *   **Crucially, configure minimal video**: `ScreenCaptureKit` requires video configuration. Use the smallest possible dimensions (2x2 pixels) to minimize overhead.
        ```swift
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 44100
        configuration.channelCount = 2
        
        // Minimal video settings
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30) // e.g., 30 FPS
        ```

5.  **Prepare Output File**: Create the final `AVAudioFile` where the processed audio will be stored. Use desired settings (e.g., AAC format).
    ```swift
    let outputURL = /* URL for the final recording */
    let audioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 2,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
    let finalAudioFile = try AVAudioFile(forWriting: outputURL, settings: audioSettings)
    ```

6.  **Create `SCStream`**: Initialize the stream with the filter, configuration, and a delegate object (`SCStreamDelegate`) to handle lifecycle events.
    ```swift
    // Assuming 'delegate' conforms to SCStreamDelegate
    let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    ```

7.  **Register Audio Output Handler**: Add an object conforming to `SCStreamOutput` to handle incoming audio sample buffers. This is often the main `AudioRecorder` class itself.
    ```swift
    // Assuming 'self' conforms to SCStreamOutput and 'captureQueue' is a DispatchQueue
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
    ```

8.  **Start Capture**: Begin the asynchronous capture process.
    ```swift
    Task {
        try await stream.startCapture()
        // Recording has started
    }
    ```

## Handling Audio Data (`SCStreamOutput` Delegate)

The most complex part is processing the raw audio data received in the `stream(_:didOutputSampleBuffer:ofType:)` delegate method. The raw data comes as `CMSampleBuffer` objects.

Directly writing these `CMSampleBuffer` objects to the final `AVAudioFile` can be problematic due to format complexities. This application uses an intermediate temporary file approach for *each buffer*:

1.  **Receive Buffer**: The delegate method receives an audio `CMSampleBuffer`.
2.  **Create Temporary File**: A unique temporary file URL is generated (e.g., in `FileManager.default.temporaryDirectory`).
3.  **Setup `AVAssetWriter`**: An `AVAssetWriter` and `AVAssetWriterInput` are configured for this *temporary* file, using the desired final audio format (e.g., AAC).
4.  **Write Single Buffer**: The *incoming `CMSampleBuffer`* is appended to the temporary file's `AVAssetWriterInput`.
5.  **Finalize Temporary File**: Writing to the `AVAssetWriter` is immediately started and finished (`assetWriter.startWriting()`, `assetWriter.startSession(...)`, `writerInput.append(sampleBuffer)`, `writerInput.markAsFinished()`, `assetWriter.finishWriting { ... }`).
6.  **Read Temporary File**: Inside the `finishWriting` completion handler:
    *   The temporary file is opened for reading using `AVAudioFile(forReading:)`.
    *   Its entire content is read into an `AVAudioPCMBuffer`.
7.  **Write to Final File**: The `AVAudioPCMBuffer` (now correctly formatted) is written to the main, persistent `AVAudioFile` created during setup (`finalAudioFile.write(from: buffer)`).
8.  **Cleanup**: The temporary file is deleted.

```swift
// Inside stream(_:didOutputSampleBuffer:ofType:)

guard type == .audio, let finalAudioFile = /* reference to the main AVAudioFile */ else { return }

do {
    // Create a temporary file URL
    let tempAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_audio_\(UUID().uuidString).m4a")
    
    // Setup an asset writer for the temporary file
    let assetWriter = try AVAssetWriter(outputURL: tempAudioURL, fileType: .m4a)
    let audioSettings: [String: Any] = [/* ... your desired AAC settings ... */]
    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    writerInput.expectsMediaDataInRealTime = true // Important for live capture
    
    if assetWriter.canAdd(writerInput) {
        assetWriter.add(writerInput)
    } else {
        // Handle error: cannot add input
        return
    }
    
    // Start writing and finish asynchronously
    assetWriter.startWriting()
    assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) // Use buffer timestamp
    
    if writerInput.isReadyForMoreMediaData {
        writerInput.append(sampleBuffer)
    }
    
    writerInput.markAsFinished()
    assetWriter.finishWriting {
        // Writing to temp file complete, now read it back
        do {
            let tempAudioFile = try AVAudioFile(forReading: tempAudioURL)
            let format = tempAudioFile.processingFormat
            
            // Create buffer for the entire temp file content
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tempAudioFile.length)) else {
                print("Could not create buffer from temp file")
                try? FileManager.default.removeItem(at: tempAudioURL)
                return
            }
            
            // Read temp file into buffer
            try tempAudioFile.read(into: buffer)
            
            // --- CRITICAL STEP: Write the processed buffer to the FINAL audio file ---
            try finalAudioFile.write(from: buffer)
            
            // Clean up the temporary file
            try? FileManager.default.removeItem(at: tempAudioURL)
            
        } catch {
            print("Error processing temp audio file: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempAudioURL)
        }
    }
} catch {
    print("Error setting up asset writer for temp file: \(error.localizedDescription)")
}
```

This intermediate step ensures that the data written to the final `AVAudioFile` is correctly encoded and formatted as `AVAudioPCMBuffer` data, sidestepping potential issues with directly handling the raw `CMSampleBuffer` format for persistent AAC file writing.

## Stopping the Recording

1.  Call `stream.stopCapture()`.
2.  Ensure the final `AVAudioFile` is properly closed or finalized (often implicitly handled when the `AVAudioFile` object goes out of scope or is set to `nil`).
3.  Clean up references to the `SCStream`, `AVAudioFile`, and delegate objects.

## Legacy Approach (macOS < 13.0)

For older macOS versions, `ScreenCaptureKit` is unavailable. Alternative methods often involve:

*   `CGDisplayStream` (less common for audio).
*   Third-party kernel extensions or virtual audio drivers (like BlackHole or the now-deprecated Soundflower), which create virtual audio devices that can be recorded using standard `AVFoundation` APIs.
*   These methods are generally more complex to set up and may require separate installation steps for the user.

This application appears to have a `startLegacySystemAudioRecording` function as a fallback, but its specific implementation wasn't detailed in this analysis.
