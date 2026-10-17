import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine
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

        return cleanText
    }
}

// MARK: - Audio Stream Transcriber (VAD Energy Detection + 800ms Smart Pause Chunking)
public final class AudioStreamTranscriber: @unchecked Sendable {
    public let label: String
    public var onCommitSentence: (@Sendable (String) -> Void)?

    private var accumulatedSamples: [Float] = []
    private var lastSpeechTime: Date = Date.distantPast
    private var hasVoiceActivity: Bool = false
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 0.8
    private let voiceRmsThreshold: Float = 0.018 // Raised threshold to filter electromagnetic/board floor noise

    public private(set) var isRunning: Bool = false
    private let lock = NSLock()

    public init(label: String) {
        self.label = label
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
            // Prevent single sentence from being too long (e.g. force cut at 15s)
            if accumulatedSamples.count >= 16000 * 15 {
                commitAndTranscribe()
            }
        }
    }

    private func startSilenceWatcher() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            guard self.isRunning, self.hasVoiceActivity else {
                self.lock.unlock()
                return
            }
            let elapsed = Date().timeIntervalSince(self.lastSpeechTime)
            let sampleCount = self.accumulatedSamples.count
            self.lock.unlock()

            // Commit on 800ms silence and >= 0.4s (6400 samples) speech
            if elapsed >= self.silenceThreshold && sampleCount >= 6400 {
                self.commitAndTranscribe()
            } else if elapsed >= 2.5 && sampleCount < 6400 {
                // If noise and silent for > 2.5s, reset buffer
                self.lock.lock()
                self.accumulatedSamples.removeAll()
                self.hasVoiceActivity = false
                self.lock.unlock()
            }
        }
    }

    private func commitAndTranscribe() {
        lock.lock()
        guard isRunning, !accumulatedSamples.isEmpty else {
            lock.unlock()
            return
        }
        let chunk = accumulatedSamples
        accumulatedSamples.removeAll()
        hasVoiceActivity = false
        lock.unlock()

        // Check average energy to silently drop floating noise (RMS < 0.015)
        var sumSq: Float = 0
        for s in chunk { sumSq += s * s }
        let chunkRms = sqrt(sumSq / Float(chunk.count))
        guard chunkRms >= 0.015 else { return }

        Task.detached { [weak self, chunk, label = self.label] in
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

// MARK: - 1. Remote Process Tap Audio Interception (CATapDescription + AudioHardwareCreateProcessTap)
public final class RemoteProcessTapEngine: @unchecked Sendable {
    public static let shared = RemoteProcessTapEngine()

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFormat: AVAudioFormat?
    private var packetCount: Int = 0
    private let resampler = Mono16kResampler()
    public var onPCMSamples: (([Float]) -> Void)?
    public private(set) var isRunning: Bool = false

    private init() {}

    private func getMyProcessAudioObjectID() -> AudioObjectID? {
        var translateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var targetObjID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translateAddr,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &targetObjID
        )
        return (status == noErr && targetObjID != kAudioObjectUnknown) ? targetObjID : nil
    }

    private func getDefaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultOutputID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultOutputID)
        guard status == noErr, defaultOutputID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &outputUID) { ptr in
            AudioObjectGetPropertyData(defaultOutputID, &uidAddr, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr else { return nil }
        return outputUID as String
    }

    public func start() throws {
        guard !isRunning else { return }
        packetCount = 0

        // 1. Exclude self process
        var excludeProcesses: [AudioObjectID] = []
        if let myObjID = getMyProcessAudioObjectID() {
            excludeProcesses.append(myObjID)
        }

        // 2. Create mono global tap
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excludeProcesses)
        description.uuid = UUID()
        description.name = "TeamsWake Remote Process Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else {
            throw NSError(domain: "RemoteProcessTapEngine", code: Int(tapStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create CoreAudio Process Tap (Status: \(tapStatus))"])
        }
        self.tapID = newTapID

        // 3. Get physical output device UID for clock anchor
        guard let outputUID = getDefaultOutputDeviceUID() else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = 0
            throw NSError(domain: "RemoteProcessTapEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get default output device UID as clock anchor"])
        }

        // 4. Create aggregate virtual device
        let aggregateUID = UUID().uuidString
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TeamsWake Remote Aggregate Stream",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newAggregateDeviceID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = 0
            throw NSError(domain: "RemoteProcessTapEngine", code: Int(aggStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device (Status: \(aggStatus))"])
        }
        self.aggregateDeviceID = newAggregateDeviceID

        // 5. Get tap stream format
        var streamFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(newTapID, &propertyAddress, 0, nil, &propertySize, &streamFormat)
        if formatStatus == noErr, let format = AVAudioFormat(streamDescription: &streamFormat) {
            self.audioFormat = format
        } else {
            self.audioFormat = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)
        }

        // 6. Register IOProc callback
        let ioProc: AudioDeviceIOProc = { (deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
            guard let clientData = inClientData else { return noErr }
            let engine = Unmanaged<RemoteProcessTapEngine>.fromOpaque(clientData).takeUnretainedValue()
            engine.handleIOData(inInputData: inInputData)
            return noErr
        }

        var newIOProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(newAggregateDeviceID, ioProc, Unmanaged.passUnretained(self).toOpaque(), &newIOProcID)
        guard procStatus == noErr, let validProcID = newIOProcID else {
            stop()
            throw NSError(domain: "RemoteProcessTapEngine", code: Int(procStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create IOProc"])
        }
        self.ioProcID = validProcID

        // 7. Start aggregate device
        let startStatus = AudioDeviceStart(newAggregateDeviceID, validProcID)
        guard startStatus == noErr else {
            stop()
            throw NSError(domain: "RemoteProcessTapEngine", code: Int(startStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to start audio device capture"])
        }

        self.isRunning = true
        NSLog("[RemoteProcessTapEngine] 🚀 Remote audio CoreAudio Process Tap started! Format: \(self.audioFormat?.sampleRate ?? 0)Hz")
    }

    public func stop() {
        guard isRunning || tapID != 0 || aggregateDeviceID != 0 else { return }
        isRunning = false

        if let p = ioProcID, aggregateDeviceID != 0 {
            AudioDeviceStop(aggregateDeviceID, p)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, p)
            ioProcID = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        NSLog("[RemoteProcessTapEngine] Remote audio capture stopped")
    }

    private func handleIOData(inInputData: UnsafePointer<AudioBufferList>) {
        guard isRunning else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first, let rawData = first.mData else { return }

        let sampleRate = self.audioFormat?.sampleRate ?? 44100
        let channels = Int(self.audioFormat?.channelCount ?? 1)
        var monoSamples: [Float] = []

        if abl.count >= 2 {
            let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            if let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                monoSamples = (0..<frameCount).map { (leftPtr[$0] + rightPtr[$0]) * 0.5 }
            } else {
                monoSamples = Array(UnsafeBufferPointer(start: leftPtr, count: frameCount))
            }
        } else if channels == 2 {
            let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * 2)
            guard frameCount > 0 else { return }
            let ptr = rawData.assumingMemoryBound(to: Float.self)
            monoSamples = (0..<frameCount).map { (ptr[$0 * 2] + ptr[$0 * 2 + 1]) * 0.5 }
        } else {
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { return }
            let ptr = rawData.assumingMemoryBound(to: Float.self)
            monoSamples = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
        }

        packetCount += 1
        if packetCount % 50 == 0 {
            let sampleCount = min(monoSamples.count, 160)
            if sampleCount > 0 {
                let sumSquares = monoSamples[0..<sampleCount].reduce(Float(0)) { $0 + $1 * $1 }
                let rms = sqrt(sumSquares / Float(sampleCount))
                if rms > 0.005 {
                    NSLog("[RemoteProcessTapEngine] 🔊 Received remote audio signal (RMS: %.4f, samples: %d)", rms, monoSamples.count)
                }
            }
        }

        if let resampledFloats = resampler.resample(floats: monoSamples, sampleRate: sampleRate) {
            onPCMSamples?(resampledFloats)
        }
    }
}

// MARK: - 2. Local Microphone Interception (CoreAudio HAL Input Device IOProc)
public final class LocalMicHalEngine: @unchecked Sendable {
    public static let shared = LocalMicHalEngine()

    private var inputDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFormat: AVAudioFormat?
    private var packetCount: Int = 0
    private let resampler = Mono16kResampler()
    public var onPCMSamples: (([Float]) -> Void)?
    public private(set) var isRunning: Bool = false

    private init() {}

    public func start() throws {
        guard !isRunning else { return }
        packetCount = 0

        // 1. Get default input device ID (Microphone / AirPods Mic)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let devStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        guard devStatus == noErr, devID != 0 else {
            throw NSError(domain: "LocalMicHalEngine", code: Int(devStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to get default microphone input device"])
        }
        self.inputDeviceID = devID

        // 2. Read hardware stream format
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(devID, &formatAddr, 0, nil, &formatSize, &asbd)
        if fmtStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) {
            self.audioFormat = format
            NSLog("[LocalMicHalEngine] Microphone hardware format: \(format.sampleRate)Hz, \(format.channelCount) channels")
        } else {
            self.audioFormat = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)
        }

        // 3. Attach AudioDeviceIOProc callback on input device
        let ioProc: AudioDeviceIOProc = { (deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
            guard let clientData = inClientData else { return noErr }
            let engine = Unmanaged<LocalMicHalEngine>.fromOpaque(clientData).takeUnretainedValue()
            engine.handleIOData(inInputData: inInputData)
            return noErr
        }

        var newIOProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(devID, ioProc, Unmanaged.passUnretained(self).toOpaque(), &newIOProcID)
        guard procStatus == noErr, let validProcID = newIOProcID else {
            throw NSError(domain: "LocalMicHalEngine", code: Int(procStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create microphone HAL IOProc"])
        }
        self.ioProcID = validProcID

        // 4. Start hardware capture
        let startStatus = AudioDeviceStart(devID, validProcID)
        guard startStatus == noErr else {
            stop()
            throw NSError(domain: "LocalMicHalEngine", code: Int(startStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to start microphone hardware capture"])
        }

        self.isRunning = true
        NSLog("[LocalMicHalEngine] 🚀 Local microphone CoreAudio HAL capture started!")
    }

    public func stop() {
        guard isRunning || inputDeviceID != 0 else { return }
        isRunning = false

        if let p = ioProcID, inputDeviceID != 0 {
            AudioDeviceStop(inputDeviceID, p)
            AudioDeviceDestroyIOProcID(inputDeviceID, p)
            ioProcID = nil
        }
        inputDeviceID = 0
        NSLog("[LocalMicHalEngine] Local microphone capture stopped")
    }

    private func handleIOData(inInputData: UnsafePointer<AudioBufferList>) {
        guard isRunning else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first, let rawData = first.mData else { return }

        let sampleRate = self.audioFormat?.sampleRate ?? 44100
        let channels = Int(self.audioFormat?.channelCount ?? 1)
        var monoSamples: [Float] = []

        if abl.count >= 2 {
            let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            if let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                monoSamples = (0..<frameCount).map { (leftPtr[$0] + rightPtr[$0]) * 0.5 }
            } else {
                monoSamples = Array(UnsafeBufferPointer(start: leftPtr, count: frameCount))
            }
        } else if channels == 2 {
            let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * 2)
            guard frameCount > 0 else { return }
            let ptr = rawData.assumingMemoryBound(to: Float.self)
            monoSamples = (0..<frameCount).map { (ptr[$0 * 2] + ptr[$0 * 2 + 1]) * 0.5 }
        } else {
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { return }
            let ptr = rawData.assumingMemoryBound(to: Float.self)
            monoSamples = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
        }

        packetCount += 1
        if packetCount % 50 == 0 {
            let sampleCount = min(monoSamples.count, 160)
            if sampleCount > 0 {
                let sumSquares = monoSamples[0..<sampleCount].reduce(Float(0)) { $0 + $1 * $1 }
                let rms = sqrt(sumSquares / Float(sampleCount))
                if rms > 0.005 {
                    NSLog("[LocalMicHalEngine] 🎤 Received microphone audio signal (RMS: %.4f, samples: %d)", rms, monoSamples.count)
                }
            }
        }

        if let resampledFloats = resampler.resample(floats: monoSamples, sampleRate: sampleRate) {
            onPCMSamples?(resampledFloats)
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
            return "Listening to remote audio (Process Tap)"
        case .localOnly:
            return "Listening to local microphone (Noise filtered)"
        case .bidirectional:
            return "Listening both sides (Remote + Mic)"
        }
    }

    public var tipText: String {
        switch self {
        case .remoteOnly:
            return "Captures incoming meeting audio without using microphone"
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
    @Published public var remoteLanguage: String = "zh-CN"
    @Published public var localLanguage: String = "zh-CN"
    @Published public var errorMessage: String? = nil

    /// Backward compatibility property
    public var captureLocalMic: Bool {
        get { listenMode == .bidirectional || listenMode == .localOnly }
        set { listenMode = newValue ? .bidirectional : .remoteOnly }
    }

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

                // 2. Start remote audio tap and transcription pipeline (Process Tap)
                if shouldCaptureRemote {
                    let remoteTrans = AudioStreamTranscriber(label: "Remote")
                    remoteTrans.onCommitSentence = { sentence in
                        Task { @MainActor in
                            AppState.shared.addLog(message: "[Remote]: \(sentence)", type: .info)
                        }
                    }
                    try remoteTrans.start()
                    self.remoteTranscriber = remoteTrans

                    RemoteProcessTapEngine.shared.onPCMSamples = { [weak remoteTrans] samples in
                        remoteTrans?.appendAudioSamples(samples)
                    }
                    try RemoteProcessTapEngine.shared.start()
                }

                // 3. Start local microphone tap and transcription pipeline (HAL Mic)
                if shouldCaptureLocal {
                    do {
                        let localTrans = AudioStreamTranscriber(label: "Local")
                        localTrans.onCommitSentence = { sentence in
                            Task { @MainActor in
                                AppState.shared.addLog(message: "[Local]: \(sentence)", type: .success)
                            }
                        }
                        try localTrans.start()
                        self.localTranscriber = localTrans

                        LocalMicHalEngine.shared.onPCMSamples = { [weak localTrans] samples in
                            localTrans?.appendAudioSamples(samples)
                        }
                        try LocalMicHalEngine.shared.start()
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
                    AppState.shared.addLog(message: "🚀 Bidirectional SenseVoice offline audio monitor started! (Remote Tap + Local Mic)", type: .success)
                case .remoteOnly:
                    AppState.shared.addLog(message: "🚀 Remote SenseVoice offline audio monitor started! (Process Tap)", type: .success)
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
        RemoteProcessTapEngine.shared.stop()
        RemoteProcessTapEngine.shared.onPCMSamples = nil
        remoteTranscriber?.stop()
        remoteTranscriber = nil

        LocalMicHalEngine.shared.stop()
        LocalMicHalEngine.shared.onPCMSamples = nil
        localTranscriber?.stop()
        localTranscriber = nil

        isRunning = false
        AppState.shared.addLog(message: "Audio capture stopped", type: .warning)
    }
}
