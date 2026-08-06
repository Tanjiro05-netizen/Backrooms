#if canImport(AVFoundation) && !os(Linux)
import Foundation
import AVFoundation
import BackroomsCore

/// Pumps `AudioMixer` into the output through a single `AVAudioSourceNode`.
///
/// One node, not a graph: the mixer already models the filters, envelopes and
/// panning itself, so there is nothing for `AVAudioEngine` to do beyond moving
/// samples. That is also what keeps the synth testable — every decision about
/// how a sound is shaped lives in `BackroomsCore`, and this file only has to be
/// correct about buffer plumbing.
public final class AudioHost {

    public let mixer: AudioMixer
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var left: [Float] = []
    private var right: [Float] = []
    /// The render callback runs on a realtime thread; this guards the handful of
    /// fields it shares with the game thread.
    private let lock = NSLock()
    public private(set) var isRunning = false

    public init(sampleRate: Double = 48_000) {
        mixer = AudioMixer(sampleRate: sampleRate)
    }

    public func start() throws {
        guard !isRunning else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: mixer.sampleRate, channels: 2)!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let self else {
                // No mixer means silence, not stale samples.
                for buffer in buffers {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }
            self.fill(buffers: buffers, frames: frames)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private func fill(buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lock.lock()
        if left.count < frames {
            left = [Float](repeating: 0, count: frames)
            right = [Float](repeating: 0, count: frames)
        }
        mixer.render(left: &left, right: &right, frames: frames)
        lock.unlock()

        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let source = channel == 0 ? left : right
            for i in 0..<frames { data[i] = source[i] }
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        isRunning = false
    }

    /// Triggering and parameter changes have to take the same lock the render
    /// callback does, or a voice can be appended mid-render.
    public func play(_ voice: Voice) {
        lock.lock(); mixer.play(voice); lock.unlock()
    }

    public func play(_ voices: [Voice]) {
        lock.lock(); mixer.play(voices); lock.unlock()
    }

    public func update(_ body: (AudioMixer) -> Void) {
        lock.lock(); body(mixer); lock.unlock()
    }
}
#endif
