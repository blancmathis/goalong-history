import AVFoundation
import Foundation
import OndeDSP

/// The sole device-audio boundary. Created by Play; no input, permission,
/// observer or timer. The DSP owner outlives this graph and its render callback.
final class AmbianceAudioOutput {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var player: AVAudioPlayerNode?
    private var file: AVAudioFile?
    private var finish: (() -> Void)?
    private var looping = false
    private var stopped = false

    init(core: OpaquePointer) {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let node = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else {
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }
            // No allocation, lock, actor hop or mutable Swift state here.
            onde_dsp_render(core, left.assumingMemoryBound(to: Float.self),
                            right.assumingMemoryBound(to: Float.self), count)
            return noErr
        }
        self.engine = engine; source = node
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    init(fileURL: URL, looping: Bool, finish: @escaping () -> Void) throws {
        // scheduleFile streams through the player's bounded disk buffers. No
        // read(into:) of the entire file, decoded array or copied personal file.
        let file = try AVAudioFile(forReading: fileURL)
        guard file.length > 0 else { throw AmbianceError.unavailable }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player; self.file = file
        self.looping = looping; self.finish = finish
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    }

    var running: Bool { engine?.isRunning == true && !stopped }
    var volume: Double = 1 {
        didSet { engine?.mainMixerNode.outputVolume = Float(AmbianceSettings.clamp(volume)) }
    }
    func start(volume: Double) throws {
        guard let engine, !stopped, engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            throw AmbianceError.unavailable
        }
        self.volume = volume
        if player != nil { scheduleFile() }
        engine.prepare()
        try engine.start()
        player?.play()
    }
    private func scheduleFile() {
        guard let player, let file, !stopped else { return }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                if self.looping { self.scheduleFile() }
                else { self.finish?() }
            }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; finish = nil
        // stop synchronizes rendering before the runtime frees the DSP/mappings.
        engine?.stop(); player?.stop()
        if let source { engine?.detach(source) }
        if let player { engine?.detach(player) }
        source = nil; player = nil; file = nil; engine = nil
    }
    deinit { stop() }
}
