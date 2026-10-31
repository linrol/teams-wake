import Foundation
import AVFoundation
import Combine
import ScreenCaptureKit
import CoreGraphics
import FluidAudio

// MARK: - High-performance Audio Resampler (Any Rate/Channels -> 16000Hz Mono Float32)
public final class Mono16kResampler: @unchecked Sendable {
    public let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private var currentSampleRate: Double = 0

    public init() {}

    public func resample(floats: [Float], sampleRate: Double) -> [Float]? {
        guard !floats.isEmpty, sampleRate > 0 else { return nil }
        if sampleRate == 16000 {
            return floats
        }

        if converter == nil || currentSampleRate != sampleRate {
            guard let monoSource = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
            self.currentSampleRate = sampleRate
            self.converter = AVAudioConverter(from: monoSource, to: targetFormat)
        }
        guard let conv = converter else { return nil }

        let monoSource = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: monoSource, frameCapacity: AVAudioFrameCount(floats.count)) else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(floats.count)

        floats.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                inBuffer.floatChannelData?[0].update(from: base, count: floats.count)
            }
        }

        let outCapacity = AVAudioFrameCount(Double(floats.count) * (16000.0 / sampleRate) + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

        var error: NSError?
        var hasSupplied = false
        conv.convert(to: outBuffer, error: &error) { _, outStatus in
            if !hasSupplied {
                hasSupplied = true
                outStatus.pointee = .haveData
                return inBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error = error {
            NSLog("[Mono16kResampler] Conversion error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outBuffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(outBuffer.frameLength)))
    }
}

// MARK: - On-device CoreML SenseVoice Neural Inference Engine
public actor LocalSenseVoiceEngine {
    public static let shared = LocalSenseVoiceEngine()
    private var manager: SenseVoiceManager?
    private var isInitializing = false
    private var hasWarmedUp = false

    public func initializeIfNeeded(progressHandler: ProgressHandler? = nil) async throws {
        if manager != nil { return }
        while isInitializing {
            try await Task.sleep(nanoseconds: 50_000_000)
            if manager != nil { return }
        }
        isInitializing = true
        defer { isInitializing = false }

        NSLog("[LocalSenseVoiceEngine] Loading SenseVoice CoreML model...")
        let mgr = try await SenseVoiceManager.load(precision: .int8, progressHandler: progressHandler)
        self.manager = mgr
        NSLog("[LocalSenseVoiceEngine] 🚀 SenseVoice local neural engine loaded successfully!")

        // Muesli-style ANE warmup: compile Neural Engine computation graph with silent audio
        if !hasWarmedUp {
            NSLog("[LocalSenseVoiceEngine] Warming up Neural Engine (ANE) with silent buffer...")
            let silence = [Float](repeating: 0, count: 16_000)
            _ = try? await mgr.transcribe(audio: silence)
            hasWarmedUp = true
            NSLog("[LocalSenseVoiceEngine] ⚡️ ANE Warmup complete! Next inferences will be instant.")
        }
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let manager = manager else { return "" }
        guard samples.count >= 4800 else { return "" } // Minimum 300ms audio
        let result = try await manager.transcribeDetailed(audio: samples)

        // 1. Drop if classified as nospeech/silence
        if result.language == "nospeech" || result.tags.contains("nospeech") {
            return ""
        }

        let cleanText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Filter out known silence/hallucinated single-letter noise tokens
        let lower = cleanText.lowercased()
        let noiseTokens: Set<String> = ["i", "y", "a", "u", "e", "o", "uh", "um", "ah", "eh", "er", "mm", "hmm"]
        if noiseTokens.contains(lower) {
            return ""
        }

        // 3. Filter out short random symbols
        let hasChinese = cleanText.contains { $0.unicodeScalars.contains { (0x4E00...0x9FA5).contains($0.value) } }
        let allowedShortWords: Set<String> = ["ok", "hi", "no", "we", "he", "me", "go", "up", "in", "on"]
        if !hasChinese && cleanText.count <= 2 && !allowedShortWords.contains(lower) {
            return ""
        }

        return TranscriptionEngineArtifactsFilter.filter(cleanText)
    }
}

// MARK: - Transcription Artifacts & Control Tag Filter
public struct TranscriptionEngineArtifactsFilter {
    private static let artifactPatterns: [String] = [
        // Control tags: e.g. <|nospeech|>, <|laughter|>, <|applause|>, <|music|>, <|zh|>, etc.
        #"<\|[^|<>]*\|>"#,
        // Bracketed non-speech annotations: [laughter], [music], (applause), etc.
        #"(?i)\[\s*(?:blank[_\s-]*audio|no[_\s-]*speech|silence|inaudible|music|applause|laughter|screaming|cheering)\s*\]"#,
        #"(?i)\(\s*(?:blank[_\s-]*audio|no[_\s-]*speech|silence|inaudible|music|applause|laughter)\s*\)"#,
        // Special tokens
        #"(?i)<\s*(?:eou|eob|unk|blank|pad)\s*>"#
    ]

    private static let fillerTokens: Set<String> = [
        "uh", "um", "uhh", "umm", "err", "ah", "ahh", "hmm", "hm", "mm", "mmm"
    ]

    public static func filter(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Remove control tags and bracketed non-speech annotations
        for pattern in artifactPatterns {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // 2. Collapse redundant spaces
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Drop isolated filler tokens
        let lower = result.lowercased()
        if fillerTokens.contains(lower) {
            return ""
        }

        // 4. Drop if only punctuation characters left
        let strippedPunct = result.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        if strippedPunct.isEmpty {
            return ""
        }

        return result
    }
}

// MARK: - Audio Stream Transcriber (Low-Latency Adaptive VAD & Smart Pause Chunking)
public final class AudioStreamTranscriber: @unchecked Sendable {
    public let label: String
    public var onCommitSentence: (@Sendable (String) -> Void)?

    private var accumulatedSamples: [Float] = []
    private var lastSpeechTime: Date = Date.distantPast
    private var hasVoiceActivity: Bool = false
    private var silenceTimer: Timer?

    // Low-latency timing parameters (inspired by Muesli streaming ASR)
    private let silenceThreshold: TimeInterval = 0.45 // Fast punctuation/pause cut (down from 0.8s)
    private let shortPauseThreshold: TimeInterval = 0.25 // Quick pause cut when buffer is already long
    private let targetSegmentSamples: Int = 16000 * 3 // 3s target segment length
    private let maxContinuousSamples: Int = 16000 * 5 // 5s hard cap for continuous non-stop speech
    private let minSpeechSamples: Int = 4800 // 300ms minimum speech length
    private let voiceRmsThreshold: Float // Sensitivity threshold tuned for natural speech

    public private(set) var isRunning: Bool = false
    private let lock = NSLock()

    public init(label: String, rmsThreshold: Float = 0.012) {
        self.label = label
        self.voiceRmsThreshold = rmsThreshold
    }

    public func start() throws {
        stop()
        lock.lock()
        isRunning = true
        accumulatedSamples.removeAll()
        hasVoiceActivity = false
        lastSpeechTime = Date.distantPast
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.startSilenceWatcher()
        }
        NSLog("[Transcriber-\(label)] SenseVoice offline audio stream monitoring started")
    }

    public func stop() {
        lock.lock()
        isRunning = false
        accumulatedSamples.removeAll()
        hasVoiceActivity = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        lock.unlock()
        NSLog("[Transcriber-\(label)] SenseVoice offline audio stream monitoring stopped")
    }

    public func appendAudioSamples(_ floats: [Float]) {
        guard !floats.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        // Calculate RMS energy to detect voice activity
        var sumSquares: Float = 0
        for s in floats {
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(floats.count))

        if rms >= voiceRmsThreshold {
            lastSpeechTime = Date()
            hasVoiceActivity = true
        }

        if hasVoiceActivity || !accumulatedSamples.isEmpty {
            accumulatedSamples.append(contentsOf: floats)
            // Hard limit: if continuous non-stop talking reaches 5s, commit chunk immediately
            if accumulatedSamples.count >= maxContinuousSamples {
                commitAndTranscribeLocked()
            }
        }
    }

    private func startSilenceWatcher() {
        silenceTimer?.invalidate()
        // High responsiveness: 80ms poll interval
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            guard self.isRunning, self.hasVoiceActivity else {
                self.lock.unlock()
                return
            }
            let elapsedSilence = Date().timeIntervalSince(self.lastSpeechTime)
            let sampleCount = self.accumulatedSamples.count

            // 1. Natural sentence ending: >= 450ms silence and >= 300ms valid speech
            if elapsedSilence >= self.silenceThreshold && sampleCount >= self.minSpeechSamples {
                self.commitAndTranscribeLocked()
            }
            // 2. Continuous speech slicing: buffer >= 3s and minor pause >= 250ms
            else if sampleCount >= self.targetSegmentSamples && elapsedSilence >= self.shortPauseThreshold {
                self.commitAndTranscribeLocked()
            }
            // 3. Drop transient noise spike if silence exceeds 1.8s and speech too short
            else if elapsedSilence >= 1.8 && sampleCount < self.minSpeechSamples {
                self.accumulatedSamples.removeAll()
                self.hasVoiceActivity = false
            }
            self.lock.unlock()
        }
    }

    private func commitAndTranscribeLocked() {
        guard isRunning, !accumulatedSamples.isEmpty else { return }
        let chunk = accumulatedSamples
        accumulatedSamples.removeAll()
        hasVoiceActivity = false

        // Check average energy to silently drop floating noise (more sensitive for remote audio)
        var sumSq: Float = 0
        for s in chunk { sumSq += s * s }
        let chunkRms = sqrt(sumSq / Float(chunk.count))
        let minChunkRms: Float = (label == "Remote") ? 0.005 : 0.012
        guard chunkRms >= minChunkRms else { return }

        Task.detached(priority: .userInitiated) { [weak self, chunk, label = self.label] in
            do {
                let text = try await LocalSenseVoiceEngine.shared.transcribe(samples: chunk)
                if !text.isEmpty {
                    NSLog("[Transcriber-\(label)] 🎯 SenseVoice transcription result: '\(text)'")
                    self?.onCommitSentence?(text)
                }
            } catch {
                NSLog("[Transcriber-\(label)] Transcription error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 1. Remote Meeting Audio Interception (ScreenCaptureKit SCStream)
public final class RemoteScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let shared = RemoteScreenCaptureEngine()

    private var stream: SCStream?
    private let resampler = Mono16kResampler()
    private let processingQueue = DispatchQueue(label: "com.teams-wake.screen-audio-proc", qos: .userInteractive)
    public var onPCMSamples: (([Float]) -> Void)?
    public private(set) var isRunning: Bool = false
    private var packetCount: Int = 0

    private override init() {
        super.init()
    }

    public func start() async throws {
        guard !isRunning else { return }
        packetCount = 0

        // 1. ScreenCaptureKit permission check
        if !CGPreflightScreenCaptureAccess() {
            let requested = CGRequestScreenCaptureAccess()
            if !requested {
                throw NSError(
                    domain: "RemoteScreenCaptureEngine",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Screen & System Audio Recording permission is required. Please grant permission in System Settings -> Privacy & Security -> Screen & System Audio Recording."]
                )
            }
        }

        // 2. Fetch shareable displays
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = shareableContent.displays.first else {
            throw NSError(
                domain: "RemoteScreenCaptureEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No active display found to attach audio stream."]
            )
        }

        // 3. Content filter: capture full display audio, exclude self process to avoid audio loop
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // 4. Stream configuration for audio-only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        // Minimal video footprint (0% GPU/CPU overhead)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
        config.showsCursor = false
        config.queueDepth = 3

        // 5. Initialize and start stream
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
        try await newStream.startCapture()

        self.stream = newStream
        self.isRunning = true
        NSLog("[RemoteScreenCaptureEngine] 🚀 ScreenCaptureKit system audio capture started! (48kHz Mono, excludes self)")
    }

    public func stop() {
        guard isRunning || stream != nil else { return }
        isRunning = false
        let s = self.stream
        self.stream = nil
        if let s = s {
            Task {
                try? await s.stopCapture()
            }
        }
        NSLog("[RemoteScreenCaptureEngine] ScreenCaptureKit system audio capture stopped")
    }

    // MARK: - SCStreamOutput Protocol Conformance
    public nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, CMSampleBufferIsValid(sampleBuffer), self.isRunning else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }

        let sampleRate = asbd.mSampleRate
        var descCopy = asbd
        guard let audioFormat = AVAudioFormat(streamDescription: &descCopy) else { return }

        var monoSamples: [Float] = []

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: audioBufferList.unsafePointer) else {
                    return
                }

                let frameCount = Int(pcmBuffer.frameLength)
                guard frameCount > 0 else { return }

                if let floatChannelData = pcmBuffer.floatChannelData {
                    let channels = Int(pcmBuffer.format.channelCount)
                    if channels == 1 {
                        let ptr = floatChannelData[0]
                        monoSamples = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
                    } else if channels >= 2 {
                        let leftPtr = floatChannelData[0]
                        let rightPtr = floatChannelData[1]
                        monoSamples = (0..<frameCount).map { (leftPtr[$0] + rightPtr[$0]) * 0.5 }
                    }
                } else if let int16ChannelData = pcmBuffer.int16ChannelData {
                    let channels = Int(pcmBuffer.format.channelCount)
                    if channels == 1 {
                        let ptr = int16ChannelData[0]
                        monoSamples = (0..<frameCount).map { Float(ptr[$0]) / 32768.0 }
                    } else if channels >= 2 {
                        let leftPtr = int16ChannelData[0]
                        let rightPtr = int16ChannelData[1]
                        monoSamples = (0..<frameCount).map { (Float(leftPtr[$0]) + Float(rightPtr[$0])) * (0.5 / 32768.0) }
                    }
                }
            }
        } catch {
            return
        }

        guard !monoSamples.isEmpty else { return }

        self.packetCount += 1
        if self.packetCount % 50 == 0 {
            let sampleCount = min(monoSamples.count, 160)
            if sampleCount > 0 {
                let sumSquares = monoSamples[0..<sampleCount].reduce(Float(0)) { $0 + $1 * $1 }
                let rms = sqrt(sumSquares / Float(sampleCount))
                if rms > 0.003 {
                    NSLog("[RemoteScreenCaptureEngine] 🔊 Received remote audio signal (RMS: %.4f, samples: %d)", rms, monoSamples.count)
                }
            }
        }

        if let resampledFloats = self.resampler.resample(floats: monoSamples, sampleRate: sampleRate) {
            self.onPCMSamples?(resampledFloats)
        }
    }

    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[RemoteScreenCaptureEngine] ❌ Stream stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            AppState.shared.addLog(message: "ScreenCaptureKit stream error: \(error.localizedDescription)", type: .error)
        }
    }
}

// MARK: - 2. Local Microphone Interception (AVAudioEngine inputNode.installTap)
public final class LocalMicAudioEngine: @unchecked Sendable {
    public static let shared = LocalMicAudioEngine()

    private let audioEngine = AVAudioEngine()
    private let resampler = Mono16kResampler()
    private let processingQueue = DispatchQueue(label: "com.teams-wake.local-mic-proc", qos: .userInteractive)
    public var onPCMSamples: (([Float]) -> Void)?
    public private(set) var isRunning: Bool = false
    private var packetCount: Int = 0
    private let lock = NSLock()

    private init() {
        // Automatically respond to audio hardware changes (e.g. AirPods connected/disconnected)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.restart()
        }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        packetCount = 0

        let inputNode = audioEngine.inputNode
        let bus: AVAudioNodeBus = 0
        let format = inputNode.outputFormat(forBus: bus)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "LocalMicAudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to obtain valid microphone hardware format"]
            )
        }

        NSLog("[LocalMicAudioEngine] Microphone hardware format: \(format.sampleRate)Hz, \(format.channelCount) channels")

        inputNode.removeTap(onBus: bus)
        inputNode.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] (buffer, _) in
            self?.handlePCMBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        self.isRunning = true
        NSLog("[LocalMicAudioEngine] 🚀 Local microphone AVAudioEngine capture started!")
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        NSLog("[LocalMicAudioEngine] Local microphone capture stopped")
    }

    public func restart() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        NSLog("[LocalMicAudioEngine] 🔄 Audio route configuration changed, restarting AVAudioEngine...")
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()

        do {
            let inputNode = audioEngine.inputNode
            let bus: AVAudioNodeBus = 0
            let format = inputNode.outputFormat(forBus: bus)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }

            inputNode.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] (buffer, _) in
                self?.handlePCMBuffer(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            NSLog("[LocalMicAudioEngine] 🚀 AVAudioEngine restarted successfully!")
        } catch {
            NSLog("[LocalMicAudioEngine] ❌ Failed to restart AVAudioEngine: \(error.localizedDescription)")
        }
    }

    private func handlePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        guard let floatChannelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        var monoSamples: [Float] = []

        if channels == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        } else if channels >= 2 {
            let leftPtr = floatChannelData[0]
            let rightPtr = floatChannelData[1]
            monoSamples = (0..<frameLength).map { (leftPtr[$0] + rightPtr[$0]) * 0.5 }
        }

        guard !monoSamples.isEmpty else { return }

        processingQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            self.packetCount += 1
            if self.packetCount % 50 == 0 {
                let sampleCount = min(monoSamples.count, 160)
                if sampleCount > 0 {
                    let sumSquares = monoSamples[0..<sampleCount].reduce(Float(0)) { $0 + $1 * $1 }
                    let rms = sqrt(sumSquares / Float(sampleCount))
                    if rms > 0.005 {
                        NSLog("[LocalMicAudioEngine] 🎤 Received microphone audio signal (RMS: %.4f, samples: %d)", rms, monoSamples.count)
                    }
                }
            }

            if let resampledFloats = self.resampler.resample(floats: monoSamples, sampleRate: sampleRate) {
                self.onPCMSamples?(resampledFloats)
            }
        }
    }
}

// MARK: - Audio Listening Mode
public enum AudioListenMode: String, CaseIterable, Identifiable {
    case remoteOnly = "remote"      // Remote meeting audio
    case localOnly = "local"        // Local microphone audio
    case bidirectional = "both"     // Both remote and local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .remoteOnly:
            return "Remote Only"
        case .localOnly:
            return "Local Mic"
        case .bidirectional:
            return "Both"
        }
    }

    public var runningStatusText: String {
        switch self {
        case .remoteOnly:
            return "Listening to remote audio (ScreenCaptureKit)"
        case .localOnly:
            return "Listening to local microphone (Noise filtered)"
        case .bidirectional:
            return "Listening both sides (ScreenCaptureKit + Mic)"
        }
    }

    public var tipText: String {
        switch self {
        case .remoteOnly:
            return "Captures incoming meeting audio via ScreenCaptureKit without using microphone"
        case .localOnly:
            return "Captures local microphone speech with noise suppression"
        case .bidirectional:
            return "Simultaneously captures and transcribes both participants"
        }
    }
}

// MARK: - 3. Unified Audio Capture Manager (Direct to Activity Logs)
@MainActor
public final class NativeAudioCaptureManager: ObservableObject {
    public static let shared = NativeAudioCaptureManager()

    @Published public private(set) var isRunning: Bool = false
    @Published public var listenMode: AudioListenMode = .bidirectional
    @Published public var errorMessage: String? = nil

    private var remoteTranscriber: AudioStreamTranscriber?
    private var localTranscriber: AudioStreamTranscriber?

    private init() {}

    public func toggleCapture() {
        if isRunning {
            stopCapture()
        } else {
            startCapture()
        }
    }

private final class DownloadProgressThrottler: @unchecked Sendable {
    private var lastLogTime = Date.distantPast
    private let interval: TimeInterval = 10.0
    private let lock = NSLock()

    func report(progress: DownloadProgress) {
        lock.lock()
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastLogTime) >= interval
        if shouldLog {
            lastLogTime = now
        }
        lock.unlock()

        if shouldLog {
            let pct = min(max(Int(progress.fractionCompleted * 100), 0), 100)
            Task { @MainActor in
                AppState.shared.addLog(message: "Downloading SenseVoice model: \(pct)%", type: .info)
            }
        }
    }
}

    public func startCapture() {
        guard !isRunning else { return }
        errorMessage = nil

        AppState.shared.addLog(message: "Initializing SenseVoice local neural engine...", type: .info)

        Task {
            do {
                let throttler = DownloadProgressThrottler()
                // 1. Initialize SenseVoice CoreML model on-device
                try await LocalSenseVoiceEngine.shared.initializeIfNeeded { progress in
                    throttler.report(progress: progress)
                }

                let shouldCaptureRemote = (self.listenMode == .remoteOnly || self.listenMode == .bidirectional)
                let shouldCaptureLocal = (self.listenMode == .localOnly || self.listenMode == .bidirectional)

                // 2. Start remote audio stream and transcription pipeline (ScreenCaptureKit)
                if shouldCaptureRemote {
                    if !CGPreflightScreenCaptureAccess() {
                        AppState.shared.addLog(message: "Requesting Screen & System Audio Recording permission...", type: .warning)
                        _ = CGRequestScreenCaptureAccess()
                    }

                    let remoteTrans = AudioStreamTranscriber(label: "Remote", rmsThreshold: 0.008)
                    remoteTrans.onCommitSentence = { sentence in
                        Task { @MainActor in
                            AppState.shared.addLog(message: "[Remote]: \(sentence)", type: .info)
                        }
                    }
                    try remoteTrans.start()
                    self.remoteTranscriber = remoteTrans

                    RemoteScreenCaptureEngine.shared.onPCMSamples = { [weak remoteTrans] samples in
                        remoteTrans?.appendAudioSamples(samples)
                    }
                    try await RemoteScreenCaptureEngine.shared.start()
                }

                // 3. Start local microphone tap and transcription pipeline (HAL Mic)
                if shouldCaptureLocal {
                    do {
                        let localTrans = AudioStreamTranscriber(label: "Local", rmsThreshold: 0.016)
                        localTrans.onCommitSentence = { sentence in
                            Task { @MainActor in
                                AppState.shared.addLog(message: "[Local]: \(sentence)", type: .success)
                            }
                        }
                        try localTrans.start()
                        self.localTranscriber = localTrans

                        LocalMicAudioEngine.shared.onPCMSamples = { [weak localTrans] samples in
                            localTrans?.appendAudioSamples(samples)
                        }
                        try LocalMicAudioEngine.shared.start()
                    } catch {
                        NSLog("[NativeAudioCaptureManager] Microphone start skipped: \(error.localizedDescription)")
                        if self.listenMode == .localOnly {
                            throw error
                        }
                    }
                }

                self.isRunning = true

                switch self.listenMode {
                case .bidirectional:
                    AppState.shared.addLog(message: "🚀 Bidirectional SenseVoice offline audio monitor started! (ScreenCaptureKit + Local Mic)", type: .success)
                case .remoteOnly:
                    AppState.shared.addLog(message: "🚀 Remote SenseVoice offline audio monitor started! (ScreenCaptureKit)", type: .success)
                case .localOnly:
                    AppState.shared.addLog(message: "🚀 Local SenseVoice offline audio monitor started! (Microphone)", type: .success)
                }
            } catch {
                let err = "Failed to start: \(error.localizedDescription)"
                self.errorMessage = err
                AppState.shared.addLog(message: err, type: .error)
                self.stopCapture()
            }
        }
    }

    public func stopCapture() {
        RemoteScreenCaptureEngine.shared.stop()
        RemoteScreenCaptureEngine.shared.onPCMSamples = nil
        remoteTranscriber?.stop()
        remoteTranscriber = nil

        LocalMicAudioEngine.shared.stop()
        LocalMicAudioEngine.shared.onPCMSamples = nil
        localTranscriber?.stop()
        localTranscriber = nil

        isRunning = false
        AppState.shared.addLog(message: "Audio capture stopped", type: .warning)
    }
}
