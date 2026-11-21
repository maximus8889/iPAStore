import UIKit
import AudioToolbox

protocol IPAFeedbackOption: Identifiable, Equatable {
    var title: String { get }
    var symbol: String { get }
}

@MainActor enum IPAFeedback {
    enum Sound: String, CaseIterable, IPAFeedbackOption {
        case chime, bell, drop, off
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var symbol: String { self == .off ? "speaker.slash" : "speaker.wave.2" }
        var resource: String? {
            switch self {
            case .chime: "Success"
            case .bell: "SuccessBell"
            case .drop: "SuccessDrop"
            case .off: nil
            }
        }
        static var selected: Self {
            UserDefaults.standard.string(forKey: "IPASuccessSound").flatMap(Self.init(rawValue:))
                ?? (UserDefaults.standard.object(forKey: "IPASoundsEnabled") as? Bool == false ? .off : .chime)
        }
    }
    enum Haptic: String, CaseIterable, IPAFeedbackOption {
        case soft, crisp, subtle, off
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var symbol: String { self == .off ? "iphone.slash" : "waveform.path" }
        static var selected: Self {
            UserDefaults.standard.string(forKey: "IPAHapticStyle").flatMap(Self.init(rawValue:))
                ?? (UserDefaults.standard.object(forKey: "IPAHapticsEnabled") as? Bool == false ? .off : .soft)
        }
    }
    private static let lift = UIImpactFeedbackGenerator(style: .soft)
    private static let settle = UIImpactFeedbackGenerator(style: .rigid)
    private static let confirmation = UINotificationFeedbackGenerator()
    private static let accentImpact = UIImpactFeedbackGenerator(style: .heavy)
    private static var launchTail: Task<Void, Never>?
    private static var sounds: [Sound: SystemSoundID] = [:]
    private static var lastSuccess: TimeInterval = -.infinity
    static func appWillOpen() {
        launchTail?.cancel()
        guard UIApplication.shared.applicationState == .active, Haptic.selected != .off else { return }
        // A soft lift followed by a lighter, crisp landing. UIKit owns the
        // actuator; no engine/audio-session startup delays the app launch.
        if Haptic.selected != .soft { preview(Haptic.selected); return }
        settle.prepare()
        lift.impactOccurred(intensity: 0.58)
        launchTail = Task {
            do { try await Task.sleep(for: .milliseconds(55)) } catch { return }
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active, Haptic.selected == .soft else { return }
            settle.impactOccurred(intensity: 0.28)
        }
    }
    static func accentChanged() {
        guard UIApplication.shared.applicationState == .active, Haptic.selected != .off else { return }
        accentImpact.impactOccurred(intensity: 0.9)
    }

    static func confirmationHaptic() {
        preview(Haptic.selected)
    }
    static func preview(_ haptic: Haptic) {
        guard UIApplication.shared.applicationState == .active else { return }
        switch haptic {
        case .soft: confirmation.notificationOccurred(.success)
        case .crisp: settle.impactOccurred(intensity: 0.8)
        case .subtle: lift.impactOccurred(intensity: 0.4)
        case .off: break
        }
    }
    static func success() {
        guard UIApplication.shared.applicationState == .active else { return }
        // Coalesce simultaneous successful operations rather than stack tones.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSuccess >= 0.38 else { return }
        lastSuccess = now
        launchTail?.cancel()
        confirmationHaptic()
        preview(Sound.selected)
    }

    static func preview(_ sound: Sound) {
        guard UIApplication.shared.applicationState == .active, let resource = sound.resource else { return }
        if sounds[sound] == nil, let url = Bundle.main.url(forResource: resource, withExtension: "wav") {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError { sounds[sound] = id }
        }
        if let id = sounds[sound] { AudioServicesPlaySystemSound(id) }
    }
}
