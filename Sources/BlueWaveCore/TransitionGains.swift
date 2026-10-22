import Foundation

public enum TransitionGains {
    public static func at(progress: Double, volume: Double) -> (outgoing: Float, incoming: Float) {
        let t = progress.isFinite ? min(1, max(0, progress)) : 0
        let v = volume.isFinite ? min(1, max(0, volume)) : 0
        return (Float((1 - t) * v), Float(t * v))
    }
}
