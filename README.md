# Mac Combined Audio Recorder

A powerful macOS application that enables simultaneous recording of microphone input and system audio, built with SwiftUI and AVFoundation.

## Features

### 🎤 Multiple Recording Sources
- **Microphone Only**: Record audio from your microphone input
- **System Audio Only**: Capture audio playing through your Mac's speakers
- **Combined Recording**: Simultaneously record both microphone and system audio

### 🎵 Playback & Management
- Play back recorded audio directly in the app
- Save recordings in high-quality M4A format
- Real-time status updates during recording and playback

### 🔒 Privacy & Permissions
- Automatic permission handling for microphone access
- Screen recording permission management for system audio capture
- Clear user guidance for required permissions

## System Requirements

- **macOS 11.0+** (minimum)
- **macOS 12.3+** (recommended for combined recording features)
- **macOS 13.0+** (for enhanced system audio capture using ScreenCaptureKit)

## Technical Architecture

### Core Components

#### AudioRecorder.swift
The main audio recording engine that handles:
- AVFoundation-based microphone recording
- ScreenCaptureKit integration for system audio (macOS 13.0+)
- Legacy system audio recording for older macOS versions
- Audio file management and playback

#### CombinedAudioEngine.swift
Specialized engine for simultaneous microphone and system audio recording:
- AVAudioEngine-based audio mixing
- Real-time audio stream processing
- Feedback prevention during playback
- Advanced audio routing and node management

#### ContentView.swift
SwiftUI-based user interface providing:
- Intuitive recording source selection
- Real-time status display
- Recording, playback, and save controls
- Cross-version UI compatibility

### Audio Technologies Used

- **AVFoundation**: Core audio recording and playback
- **AVAudioEngine**: Real-time audio processing and mixing
- **ScreenCaptureKit**: Modern system audio capture (macOS 13.0+)
- **CoreAudio**: Low-level audio system integration
- **AVAssetWriter**: High-quality audio file encoding

## Installation & Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/ianpilon/Mac-Combined-Recording-working-Aug-2-20205.git
   ```

2. **Open in Xcode**:
   - Open `MacAudioRecorder.xcodeproj` in Xcode
   - Ensure you have Xcode 13.0+ installed

3. **Configure permissions**:
   - The app will automatically request microphone permissions
   - For system audio recording, you'll need to grant screen recording permission in:
     `System Settings > Privacy & Security > Screen Recording`

4. **Build and run**:
   - Select your target device
   - Press `Cmd+R` to build and run

## Usage

### Basic Recording
1. Launch the application
2. Select your desired recording source:
   - **Microphone Only**: For voice recordings
   - **System Audio Only**: For capturing computer audio
   - **Combined Recording**: For recording both simultaneously
3. Click the **Record** button to start recording
4. Click **Stop Recording** when finished
5. Use **Play** to preview your recording
6. Click **Save** to export the recording as an M4A file

### Advanced Features

#### Combined Recording
The combined recording feature allows you to:
- Record your voice commentary while capturing system audio
- Create tutorials with both narration and computer audio
- Record video calls with both participants' audio

#### System Audio Capture
- Requires screen recording permission (automatically prompted)
- Uses ScreenCaptureKit for high-quality capture on macOS 13.0+
- Falls back to legacy methods on older systems

## File Structure

```
MacAudioRecorder/
├── AudioRecorder.swift          # Core recording engine
├── CombinedAudioEngine.swift    # Combined recording engine
├── ContentView.swift            # Main UI
├── AudioRecorderApp.swift       # App entry point
├── AppDelegate.swift           # App lifecycle management
├── Info.plist                  # App configuration
└── MacAudioRecorder.xcodeproj  # Xcode project file
```

## Troubleshooting

### Common Issues

**"Screen recording permission required"**
- Go to `System Settings > Privacy & Security > Screen Recording`
- Enable permission for the Mac Audio Recorder app
- Restart the application

**"No audio input devices found"**
- Check that your microphone is connected and recognized by macOS
- Verify microphone permissions in `System Settings > Privacy & Security > Microphone`

**Recording quality issues**
- Ensure sufficient disk space for recordings
- Check audio input levels in System Preferences
- For system audio, verify the source application is producing audio

### Debug Logging
The app includes comprehensive logging for troubleshooting:
- Log files are saved to `~/Documents/audio_recorder_log.txt`
- Enable debug output in Console.app by filtering for "MacAudioRecorder"

## Development

### Building from Source
```bash
# Clone the repository
git clone https://github.com/ianpilon/Mac-Combined-Recording-working-Aug-2-20205.git

# Open in Xcode
open MacAudioRecorder.xcodeproj

# Build and run
# Press Cmd+R in Xcode
```

### Key Dependencies
- SwiftUI (UI framework)
- AVFoundation (Audio recording/playback)
- ScreenCaptureKit (System audio capture)
- CoreAudio (Low-level audio access)

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is available under the MIT License. See the LICENSE file for more details.

## Acknowledgments

- Built with Apple's AVFoundation and ScreenCaptureKit frameworks
- Designed for macOS with backwards compatibility in mind
- Optimized for professional audio recording workflows

---

**Note**: This application requires macOS-specific permissions and frameworks. It is designed specifically for macOS and will not run on other platforms.
