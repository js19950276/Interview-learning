import Observation

@MainActor
@Observable
final class MotionPreferences {
    var isSoundEnabled = true
    var isHapticsEnabled = true
    var reduceMotion = false
    var colorAssistEnabled = true
}
