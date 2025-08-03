import Cocoa
import UniformTypeIdentifiers

class MainViewController: NSViewController {
    
    // Audio recorder instance
    private let audioRecorder = AudioRecorder()
    
    // UI elements
    private var recordButton: NSButton!
    private var playButton: NSButton!
    private var saveButton: NSButton!
    private var statusLabel: NSTextField!
    
    override func loadView() {
        // Create the main view
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = view
        
        setupUI()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set up observers for recording/playback state changes
        audioRecorder.recordingStateChanged = { [weak self] isRecording in
            DispatchQueue.main.async {
                self?.updateUI()
            }
        }
        
        audioRecorder.playbackStateChanged = { [weak self] isPlaying in
            DispatchQueue.main.async {
                self?.updateUI()
            }
        }
    }
    
    private func setupUI() {
        // Record button
        recordButton = NSButton(frame: NSRect(x: 20, y: 200, width: 120, height: 30))
        recordButton.title = "Record"
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        view.addSubview(recordButton)
        
        // Play button
        playButton = NSButton(frame: NSRect(x: 150, y: 200, width: 120, height: 30))
        playButton.title = "Play"
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.isEnabled = false
        view.addSubview(playButton)
        
        // Save button
        saveButton = NSButton(frame: NSRect(x: 280, y: 200, width: 120, height: 30))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveRecording)
        saveButton.isEnabled = false
        view.addSubview(saveButton)
        
        // Status label
        statusLabel = NSTextField(frame: NSRect(x: 20, y: 150, width: 440, height: 20))
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = NSColor.clear
        statusLabel.stringValue = "Ready to record"
        statusLabel.alignment = .center
        view.addSubview(statusLabel)
    }
    
    @objc private func toggleRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
        } else {
            // Request permission if needed
            audioRecorder.requestPermission { [weak self] granted in
                if granted {
                    _ = self?.audioRecorder.startRecording()
                } else {
                    self?.statusLabel.stringValue = "Microphone access denied"
                }
            }
        }
        updateUI()
    }
    
    @objc private func togglePlayback() {
        if audioRecorder.isPlaying {
            audioRecorder.stopPlayback()
        } else {
            _ = audioRecorder.startPlayback()
        }
        updateUI()
    }
    
    @objc private func saveRecording() {
        // Create save panel
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "m4a")!]
        savePanel.nameFieldStringValue = "recording.m4a"
        savePanel.message = "Save your recording"
        savePanel.begin { [weak self] result in
            if result == .OK, let url = savePanel.url {
                self?.audioRecorder.saveRecording(to: url) { success in
                    DispatchQueue.main.async {
                        if success {
                            self?.statusLabel.stringValue = "Recording saved successfully"
                        } else {
                            self?.statusLabel.stringValue = "Failed to save recording"
                        }
                    }
                }
            }
        }
    }
    
    private func updateUI() {
        if audioRecorder.isRecording {
            recordButton.title = "Stop Recording"
            playButton.isEnabled = false
            saveButton.isEnabled = false
            statusLabel.stringValue = "Recording..."
        } else if audioRecorder.isPlaying {
            recordButton.isEnabled = false
            playButton.title = "Stop Playback"
            saveButton.isEnabled = false
            statusLabel.stringValue = "Playing..."
        } else {
            recordButton.title = "Record"
            recordButton.isEnabled = true
            playButton.title = "Play"
            playButton.isEnabled = true
            saveButton.isEnabled = true
            statusLabel.stringValue = "Ready"
        }
    }
}
