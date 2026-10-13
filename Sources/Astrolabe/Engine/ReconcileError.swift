/// A child process failed: it exited non-zero, timed out, or couldn't be spawned.
public enum ReconcileError: Error, Sendable {
    case processFailed(path: String, arguments: [String], output: String)
}
