import Foundation
import NetFS

/// Wraps `NetFSMountURLSync` so the UI can call it as an async function.
/// Used when a pasted path resolves under `/Volumes/DimensionHub` but the
/// share isn't currently mounted — we try to bring it up before erroring.
///
/// Credentials come from the Keychain entry the operator created the first
/// time they connected to the share via Finder. We deliberately do not
/// prompt for username/password from inside the app: a Finder "Connect to
/// Server" once-per-Mac is the supported setup, and an in-app prompt
/// would only confuse things if it diverged.
enum NetFSMounter {

    enum MountError: Error {
        /// Result code from `NetFSMountURLSync` when it returned non-zero.
        /// 0 is success; any other value bubbles up so the caller can log.
        case nonZero(Int32)
    }

    /// Mount `smb://dim-svr/DimensionHub` if `/Volumes/DimensionHub` isn't
    /// already mounted. No-op when it is. Runs the blocking sync call on
    /// a utility queue so the main actor stays responsive while the
    /// network handshake completes.
    static func ensureCanonicalShareMounted() async throws {
        let mountPoint = "/Volumes/" + PathNormaliser.canonicalShare
        if FileManager.default.fileExists(atPath: mountPoint) { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let url = PathNormaliser.canonicalServerURL as CFURL
                var mounted: Unmanaged<CFArray>?
                let result = NetFSMountURLSync(
                    url,
                    nil,           // mount path: default /Volumes
                    nil,           // user: prompt or use Keychain
                    nil,           // password: use Keychain
                    nil,           // open options
                    nil,           // mount options
                    &mounted       // output: list of mounted URLs (we ignore beyond release)
                )
                mounted?.release()
                if result == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MountError.nonZero(result))
                }
            }
        }
    }
}
