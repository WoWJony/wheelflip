import Foundation

/// Wait for the current instance to exit, then reopen it through LaunchServices.
/// Paths travel as positional arguments: shell syntax in a filename stays data.
enum PermissionRelauncher {
    static func makeProcess(
        bundleURL: URL,
        parentPID: Int32,
        launchCommand: [String] = ["/usr/bin/open"]
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            while kill -0 "$1" 2>/dev/null; do
                /bin/sleep 0.2
            done
            bundle_path="$2"
            shift 2
            exec "$@" "$bundle_path" --args --permission-recheck
            """,
            "wheelflip-relaunch",
            String(parentPID),
            bundleURL.path,
        ] + launchCommand
        return process
    }
}
