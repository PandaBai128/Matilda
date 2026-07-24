//
//  StreamingMP3AudioPlayer.swift
//  leanring-buddy
//

import AudioToolbox
import Foundation

/// Incrementally parses MP3 bytes and feeds decoded packets to one Audio Queue.
/// A fresh parser is used for each synthesized sentence while the output queue
/// stays alive, preventing sentence downloads from blocking current playback.
nonisolated final class StreamingMP3AudioPlayer: @unchecked Sendable {
    enum PlayerError: LocalizedError {
        case audioFileStreamOpenFailed(OSStatus)
        case audioFileStreamParseFailed(OSStatus)
        case audioQueueCreationFailed(OSStatus)
        case audioQueueBufferAllocationFailed(OSStatus)
        case audioQueueEnqueueFailed(OSStatus)
        case audioOutputInterrupted

        var errorDescription: String? {
            switch self {
            case .audioFileStreamOpenFailed(let status):
                return "Couldn't open the streaming MP3 parser (\(status))."
            case .audioFileStreamParseFailed(let status):
                return "Couldn't parse streaming MP3 audio (\(status))."
            case .audioQueueCreationFailed(let status):
                return "Couldn't create the streaming audio queue (\(status))."
            case .audioQueueBufferAllocationFailed(let status):
                return "Couldn't allocate a streaming audio buffer (\(status))."
            case .audioQueueEnqueueFailed(let status):
                return "Couldn't enqueue streaming audio (\(status))."
            case .audioOutputInterrupted:
                return "Streaming audio output was interrupted."
            }
        }
    }

    private let stateLock = NSLock()
    private let playbackVolume: Float
    private let onPlaybackStarted: () -> Void
    private let onPlaybackFinished: () -> Void
    private let onFailure: (Error) -> Void
    private let cancellationCleanupHandler: () -> Void
    private let audioProcessingQueue = DispatchQueue(
        label: "com.nathan.clicky.streaming-audio-processing",
        qos: .userInitiated
    )
    private let audioQueueCallbackQueue = DispatchQueue(
        label: "com.nathan.clicky.streaming-audio-callbacks",
        qos: .userInitiated
    )

    private var audioFileStream: AudioFileStreamID?
    private var audioQueue: AudioQueueRef?
    private var pendingAudioQueueBufferCount = 0
    private var hasStartedPlayback = false
    private var isInputFinished = false
    private var isCancelled = false
    private var hasCompleted = false

    init(
        playbackVolume: Float = 1,
        onPlaybackStarted: @escaping () -> Void,
        onPlaybackFinished: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void,
        cancellationCleanupHandler: @escaping () -> Void = {}
    ) {
        self.playbackVolume = min(max(playbackVolume, 0), 1)
        self.onPlaybackStarted = onPlaybackStarted
        self.onPlaybackFinished = onPlaybackFinished
        self.onFailure = onFailure
        self.cancellationCleanupHandler = cancellationCleanupHandler
    }

    func beginSegment() async throws {
        try await withCheckedThrowingContinuation { continuation in
            audioProcessingQueue.async {
                do {
                    try self.beginSegmentSynchronously()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func beginSegmentSynchronously() throws {
        endSegmentSynchronously()

        stateLock.lock()
        let shouldCancel = isCancelled
        stateLock.unlock()
        guard !shouldCancel else { throw CancellationError() }

        var openedAudioFileStream: AudioFileStreamID?
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            streamingMP3PropertyListener,
            streamingMP3PacketListener,
            kAudioFileMP3Type,
            &openedAudioFileStream
        )
        guard status == noErr, let openedAudioFileStream else {
            throw PlayerError.audioFileStreamOpenFailed(status)
        }
        audioFileStream = openedAudioFileStream
    }

    func appendAudioBytes(_ audioData: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            audioProcessingQueue.async {
                do {
                    try self.appendAudioBytesSynchronously(audioData)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func appendAudioBytesSynchronously(_ audioData: Data) throws {
        guard !audioData.isEmpty, let audioFileStream else { return }

        stateLock.lock()
        let shouldCancel = isCancelled
        stateLock.unlock()
        guard !shouldCancel else { throw CancellationError() }

        let status = audioData.withUnsafeBytes { bytes in
            AudioFileStreamParseBytes(
                audioFileStream,
                UInt32(audioData.count),
                bytes.baseAddress,
                []
            )
        }
        guard status == noErr else {
            throw PlayerError.audioFileStreamParseFailed(status)
        }
    }

    func endSegment() async {
        await withCheckedContinuation { continuation in
            audioProcessingQueue.async {
                self.endSegmentSynchronously()
                continuation.resume()
            }
        }
    }

    private func endSegmentSynchronously() {
        guard let audioFileStream else { return }
        AudioFileStreamParseBytes(audioFileStream, 0, nil, [])
        AudioFileStreamClose(audioFileStream)
        self.audioFileStream = nil
    }

    func finishPlayback() {
        audioProcessingQueue.async {
            self.finishPlaybackSynchronously()
        }
    }

    private func finishPlaybackSynchronously() {
        endSegmentSynchronously()
        stateLock.lock()
        isInputFinished = true
        let shouldComplete = pendingAudioQueueBufferCount == 0
        stateLock.unlock()

        if shouldComplete {
            completePlaybackIfNeeded()
        }
    }

    func cancel() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            return
        }
        isCancelled = true
        stateLock.unlock()

        audioProcessingQueue.async {
            self.cancellationCleanupHandler()
            self.endSegmentSynchronously()
            self.disposeAudioQueue(immediately: true)
        }
    }

    func handleAudioOutputInterruption() {
        reportFailure(PlayerError.audioOutputInterrupted)
    }

    fileprivate func handleProperty(
        audioFileStream: AudioFileStreamID,
        propertyID: AudioFileStreamPropertyID
    ) {
        guard propertyID == kAudioFileStreamProperty_DataFormat else { return }

        stateLock.lock()
        let alreadyHasAudioQueue = audioQueue != nil
        stateLock.unlock()
        guard !alreadyHasAudioQueue else { return }

        var audioFormat = AudioStreamBasicDescription()
        var audioFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let propertyStatus = AudioFileStreamGetProperty(
            audioFileStream,
            kAudioFileStreamProperty_DataFormat,
            &audioFormatSize,
            &audioFormat
        )
        guard propertyStatus == noErr else {
            reportFailure(PlayerError.audioQueueCreationFailed(propertyStatus))
            return
        }

        var createdAudioQueue: AudioQueueRef?
        let queueStatus = AudioQueueNewOutputWithDispatchQueue(
            &createdAudioQueue,
            &audioFormat,
            0,
            audioQueueCallbackQueue
        ) { [weak self] _, _ in
            self?.audioQueueFinishedBuffer()
        }
        guard queueStatus == noErr, let createdAudioQueue else {
            reportFailure(PlayerError.audioQueueCreationFailed(queueStatus))
            return
        }

        AudioQueueSetParameter(createdAudioQueue, kAudioQueueParam_Volume, playbackVolume)
        stateLock.lock()
        audioQueue = createdAudioQueue
        stateLock.unlock()
    }

    fileprivate func handlePackets(
        numberBytes: UInt32,
        numberPackets: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        stateLock.lock()
        let currentAudioQueue = audioQueue
        let shouldIgnorePackets = isCancelled || hasCompleted
        stateLock.unlock()
        guard let currentAudioQueue, !shouldIgnorePackets else { return }

        var audioQueueBuffer: AudioQueueBufferRef?
        let allocationStatus = AudioQueueAllocateBufferWithPacketDescriptions(
            currentAudioQueue,
            numberBytes,
            packetDescriptions == nil ? 0 : numberPackets,
            &audioQueueBuffer
        )
        guard allocationStatus == noErr, let audioQueueBuffer else {
            reportFailure(PlayerError.audioQueueBufferAllocationFailed(allocationStatus))
            return
        }

        memcpy(audioQueueBuffer.pointee.mAudioData, inputData, Int(numberBytes))
        audioQueueBuffer.pointee.mAudioDataByteSize = numberBytes

        if let packetDescriptions,
           let destinationPacketDescriptions = audioQueueBuffer.pointee.mPacketDescriptions {
            destinationPacketDescriptions.initialize(from: packetDescriptions, count: Int(numberPackets))
            audioQueueBuffer.pointee.mPacketDescriptionCount = numberPackets
        } else {
            audioQueueBuffer.pointee.mPacketDescriptionCount = 0
        }

        let enqueueStatus = AudioQueueEnqueueBuffer(currentAudioQueue, audioQueueBuffer, 0, nil)
        guard enqueueStatus == noErr else {
            reportFailure(PlayerError.audioQueueEnqueueFailed(enqueueStatus))
            return
        }

        stateLock.lock()
        pendingAudioQueueBufferCount += 1
        let shouldNotifyPlaybackStarted = !hasStartedPlayback
        hasStartedPlayback = true
        stateLock.unlock()

        AudioQueueStart(currentAudioQueue, nil)
        if shouldNotifyPlaybackStarted {
            DispatchQueue.main.async { [onPlaybackStarted] in
                onPlaybackStarted()
            }
        }
    }

    private func audioQueueFinishedBuffer() {
        stateLock.lock()
        pendingAudioQueueBufferCount = max(0, pendingAudioQueueBufferCount - 1)
        let shouldComplete = isInputFinished && pendingAudioQueueBufferCount == 0
        stateLock.unlock()

        if shouldComplete {
            completePlaybackIfNeeded()
        }
    }

    private func completePlaybackIfNeeded() {
        stateLock.lock()
        guard !hasCompleted, !isCancelled else {
            stateLock.unlock()
            return
        }
        hasCompleted = true
        stateLock.unlock()

        audioProcessingQueue.async {
            self.disposeAudioQueue(immediately: false)
            DispatchQueue.main.async { [onPlaybackFinished = self.onPlaybackFinished] in
                onPlaybackFinished()
            }
        }
    }

    private func reportFailure(_ error: Error) {
        stateLock.lock()
        guard !hasCompleted, !isCancelled else {
            stateLock.unlock()
            return
        }
        hasCompleted = true
        stateLock.unlock()

        audioProcessingQueue.async {
            self.endSegmentSynchronously()
            self.disposeAudioQueue(immediately: true)
            DispatchQueue.main.async { [onFailure = self.onFailure] in
                onFailure(error)
            }
        }
    }

    private func disposeAudioQueue(immediately: Bool) {
        stateLock.lock()
        let currentAudioQueue = audioQueue
        audioQueue = nil
        pendingAudioQueueBufferCount = 0
        stateLock.unlock()

        if let currentAudioQueue {
            AudioQueueStop(currentAudioQueue, immediately)
            AudioQueueDispose(currentAudioQueue, immediately)
        }
    }
}

private nonisolated func streamingMP3PropertyListener(
    clientData: UnsafeMutableRawPointer,
    audioFileStream: AudioFileStreamID,
    propertyID: AudioFileStreamPropertyID,
    flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    let player = Unmanaged<StreamingMP3AudioPlayer>.fromOpaque(clientData).takeUnretainedValue()
    player.handleProperty(audioFileStream: audioFileStream, propertyID: propertyID)
}

private nonisolated func streamingMP3PacketListener(
    clientData: UnsafeMutableRawPointer,
    numberBytes: UInt32,
    numberPackets: UInt32,
    inputData: UnsafeRawPointer,
    packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    let player = Unmanaged<StreamingMP3AudioPlayer>.fromOpaque(clientData).takeUnretainedValue()
    player.handlePackets(
        numberBytes: numberBytes,
        numberPackets: numberPackets,
        inputData: inputData,
        packetDescriptions: packetDescriptions
    )
}
