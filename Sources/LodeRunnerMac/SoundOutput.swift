import AVFAudio

/// Small synthesized cues for the native prototype; gameplay timing stays in the core.
@MainActor
final class SoundOutput {
    enum Cue { case gold, dig, hole, death, levelClear }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var available = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            available = true
        } catch {
            available = false
        }
    }

    func play(_ cue: Cue) {
        guard available else { return }
        let notes: [(Double, Double)]
        switch cue {
        case .gold: notes = [(659, 0.055), (880, 0.07), (1175, 0.11)]
        case .dig: notes = [(220, 0.045)]
        case .hole: notes = [(330, 0.055), (196, 0.10)]
        case .death: notes = [(330, 0.11), (247, 0.11), (165, 0.20)]
        case .levelClear: notes = [(523, 0.09), (659, 0.09), (784, 0.09), (1047, 0.18)]
        }
        let frameCount = notes.reduce(0) { $0 + Int($1.1 * format.sampleRate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else { return }
        var frame = 0
        for (frequency, duration) in notes {
            let count = Int(duration * format.sampleRate)
            for sample in 0..<count {
                let time = Double(sample) / format.sampleRate
                let attack = min(1.0, Double(sample) / 120.0)
                let release = min(1.0, Double(count - sample) / 700.0)
                let square: Float = sin(2 * .pi * frequency * time) >= 0 ? 1 : -1
                channel[frame] = 0.085 * square * Float(attack * release)
                frame += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(frame)
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
    }
}
