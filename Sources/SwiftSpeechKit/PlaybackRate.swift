/// Shared playback-rate policy: the supported range, the discrete choices a
/// UI can offer, and a clamp. Used by every player and by any speech engine
/// that honors a user-selected rate.
public enum PlaybackRate {
    public static let minimum: Float = 0.75
    public static let maximum: Float = 2
    public static let choices: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    public static func normalized(_ value: Float) -> Float {
        min(max(value, minimum), maximum)
    }
}
