import CoreAudio
import AudioToolbox
import Foundation

enum TapError: LocalizedError {
    case createTap(OSStatus), createAggregate(OSStatus), createIOProc(OSStatus), start(OSStatus)
    var errorDescription: String? {
        switch self {
        case .createTap(let s): return "Kunne ikke koble til appens lyd (\(s)). Sjekk at Lydpanel har lov til lydopptak i Personvern og sikkerhet."
        case .createAggregate(let s): return "Kunne ikke lage lydruting (\(s))."
        case .createIOProc(let s): return "Kunne ikke starte lydbehandling (\(s))."
        case .start(let s): return "Kunne ikke starte lyden (\(s))."
        }
    }
}

/// Fanger lyden fra én app med en Core Audio process tap (macOS 14.2+),
/// demper originalen og spiller den av på nytt med valgt volum.
/// Lages bare når appen ikke står på 100 % — ellers går lyden urørt.
final class AppTap {
    let processIDs: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// [0] = målvolum, [1] = nåværende (for myk overgang uten klikk), [2] = antall kanaler i tappen.
    private let state: UnsafeMutablePointer<Float>

    init(processIDs: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processIDs = processIDs
        self.outputUID = outputUID
        state = .allocate(capacity: 3)
        state[0] = gain
        state[1] = 1
        state[2] = 2

        do { try start() } catch { teardown(); state.deallocate(); throw error }
    }

    deinit {
        teardown()
        state.deallocate()
    }

    func setGain(_ gain: Float) { state[0] = gain }

    private func start() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processIDs)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "Lydpanel"

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.createTap(err) }

        let format = getValue(tapID, address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
        if format.mChannelsPerFrame > 0 { state[2] = Float(format.mChannelsPerFrame) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lydpanel",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { throw TapError.createAggregate(err) }

        let state = self.state
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, state: state)
        }
        guard err == noErr else { throw TapError.createIOProc(err) }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw TapError.start(err) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Kjører på lydtråden: ingen allokering, ingen låser.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: UnsafeMutablePointer<Float>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var totalIn = 0
        for b in inList { totalIn += Int(b.mNumberChannels) }
        // Tappens kanaler ligger sist i inndataene (etter eventuell mikrofon på utgangsenheten).
        let tapChannels = min(max(1, Int(state[2])), totalIn)
        let srcBase = totalIn - tapChannels

        let target = state[0]
        let startGain = state[1]
        var outBase = 0

        for ob in outList {
            let outChannels = max(1, Int(ob.mNumberChannels))
            defer { outBase += outChannels }
            guard let raw = ob.mData else { continue }
            memset(raw, 0, Int(ob.mDataByteSize))
            guard tapChannels > 0 else { continue }
            let od = raw.assumingMemoryBound(to: Float.self)
            let outFrames = Int(ob.mDataByteSize) / (4 * outChannels)

            for ch in 0..<outChannels {
                let src = srcBase + (outBase + ch) % tapChannels
                var acc = 0
                var found = false
                var srcBuffer = AudioBuffer()
                var srcChannel = 0
                for ib in inList {
                    let n = Int(ib.mNumberChannels)
                    if src < acc + n { srcBuffer = ib; srcChannel = src - acc; found = true; break }
                    acc += n
                }
                guard found, let sraw = srcBuffer.mData else { continue }
                let sd = sraw.assumingMemoryBound(to: Float.self)
                let srcChannels = max(1, Int(srcBuffer.mNumberChannels))
                let frames = min(outFrames, Int(srcBuffer.mDataByteSize) / (4 * srcChannels))
                guard frames > 0 else { continue }
                let step = (target - startGain) / Float(frames)
                var g = startGain
                for f in 0..<frames {
                    od[f * outChannels + ch] = sd[f * srcChannels + srcChannel] * g
                    g += step
                }
            }
        }
        state[1] = target
    }
}
