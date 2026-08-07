//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import Testing

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

@testable import ContainerizationOS

/// Coverage for `Command.Attrs.networkNamespace`.
///
/// The tests that need a real namespace carry `.enabled(if:)` so an
/// environment that can't host them reports them as *skipped*. They must not
/// return early and read as passed: this whole change exists because a silent
/// success is worse than a loud failure, and that applies to its own tests.
@Suite("Command network namespace")
struct CommandNetworkNamespaceTests {
    // MARK: - Happy paths

    @Test(
        "child joins a network namespace given by path",
        .enabled(if: CommandNetworkNamespaceTests.canUseNetworkNamespaces, "needs CAP_SYS_ADMIN to create a network namespace")
    )
    func childJoinsNamespaceByPath() throws {
        let sleepBinary = try #require(Self.sleepBinary)
        let parked = try #require(Self.parkNamespace())
        defer { Self.terminate(parked) }

        let target = try Self.namespace(ofPID: parked.pid)
        let ours = try Self.ownNamespace()

        var child = Command(sleepBinary, arguments: [Self.parkSeconds])
        child.attrs.networkNamespace = .path("/proc/\(parked.pid)/ns/net")
        try child.start()
        defer { Self.terminate(child) }

        let joined = try Self.namespace(ofPID: child.pid)
        #expect(joined == target)
        #expect(joined != ours)
    }

    @Test(
        "child joins a network namespace given by fd",
        .enabled(if: CommandNetworkNamespaceTests.canUseNetworkNamespaces, "needs CAP_SYS_ADMIN to create a network namespace")
    )
    func childJoinsNamespaceByFD() throws {
        let sleepBinary = try #require(Self.sleepBinary)
        let parked = try #require(Self.parkNamespace())
        defer { Self.terminate(parked) }

        let target = try Self.namespace(ofPID: parked.pid)
        let ours = try Self.ownNamespace()

        let nsFD = open("/proc/\(parked.pid)/ns/net", O_RDONLY | O_CLOEXEC)
        try #require(nsFD >= 0)
        defer { close(nsFD) }

        var child = Command(sleepBinary, arguments: [Self.parkSeconds])
        child.attrs.networkNamespace = .fd(nsFD)
        try child.start()
        defer { Self.terminate(child) }

        let joined = try Self.namespace(ofPID: child.pid)
        #expect(joined == target)
        #expect(joined != ours)
    }

    /// The child's fd shuffle relocates the sync pipe to `max(handles)+1` and
    /// then `dup2()`s the handles onto `0..<handleCount`, either of which can
    /// land on the namespace fd and silently replace it before `execve`. This
    /// pins `setns` ahead of the shuffle: move it back below and this fails.
    @Test(
        "namespace fd survives the child fd table shuffle",
        .enabled(if: CommandNetworkNamespaceTests.canUseNetworkNamespaces, "needs CAP_SYS_ADMIN to create a network namespace")
    )
    func namespaceFDSurvivesFDShuffle() throws {
        let sleepBinary = try #require(Self.sleepBinary)
        let parked = try #require(Self.parkNamespace())
        defer { Self.terminate(parked) }

        let target = try Self.namespace(ofPID: parked.pid)

        let nsFD = open("/proc/\(parked.pid)/ns/net", O_RDONLY | O_CLOEXEC)
        try #require(nsFD >= 0)
        defer { close(nsFD) }

        // Enough extra files that the child's final fd table (stdin, stdout,
        // stderr + extras) extends past nsFD and therefore dup2()s over it.
        var extras: [FileHandle] = []
        defer { for extra in extras { try? extra.close() } }
        for _ in 0..<max(nsFD, 1) {
            let fd = open("/dev/null", O_RDONLY)
            try #require(fd >= 0)
            extras.append(FileHandle(fileDescriptor: fd, closeOnDealloc: false))
        }

        var child = Command(sleepBinary, arguments: [Self.parkSeconds], extraFiles: extras)
        child.attrs.networkNamespace = .fd(nsFD)
        try child.start()
        defer { Self.terminate(child) }

        let joined = try Self.namespace(ofPID: child.pid)
        #expect(joined == target)
    }

    @Test("no namespace attribute leaves the child in the parent namespace")
    func defaultKeepsParentNamespace() throws {
        let sleepBinary = try #require(Self.sleepBinary)

        let child = Command(sleepBinary, arguments: [Self.parkSeconds])
        try child.start()
        defer { Self.terminate(child) }

        let joined = try Self.namespace(ofPID: child.pid)
        let ours = try Self.ownNamespace()
        #expect(joined == ours)
    }

    // MARK: - Failure paths
    //
    // These need no privileges: they assert that a namespace we can't join
    // fails the spawn outright rather than running the process in ours.

    @Test("a missing namespace path fails the spawn")
    func missingNamespacePathFailsSpawn() throws {
        let sleepBinary = try #require(Self.sleepBinary)

        // Rejected in the parent by open(), before any fork.
        var child = Command(sleepBinary, arguments: ["1"])
        child.attrs.networkNamespace = .path("/proc/self/ns/net-does-not-exist")

        Self.expectSpawnFailure(child, code: .ENOENT)
    }

    /// A valid fd that isn't a namespace: `setns` rejects it in the child, and
    /// the errno has to survive the trip back through the sync pipe.
    @Test("a namespace fd that is not a namespace fails the spawn")
    func invalidNamespaceFDFailsSpawn() throws {
        let sleepBinary = try #require(Self.sleepBinary)

        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }

        var child = Command(sleepBinary, arguments: ["1"])
        child.attrs.networkNamespace = .fd(fd)

        Self.expectSpawnFailure(child, code: .EINVAL)
    }

    /// An fd number that was never opened. Deliberately a number far above
    /// anything the process could have open, rather than a just-closed fd:
    /// `createFileset()` opens two `/dev/null` handles before the namespace fd
    /// is consumed, so a recently freed number gets recycled and the test
    /// would quietly become another EINVAL case.
    @Test("an unopened namespace fd fails the spawn")
    func unopenedNamespaceFDFailsSpawn() throws {
        let sleepBinary = try #require(Self.sleepBinary)

        var child = Command(sleepBinary, arguments: ["1"])
        child.attrs.networkNamespace = .fd(1_000_000)

        Self.expectSpawnFailure(child, code: .EBADF)
    }

    /// `-1` is the C layer's "no namespace" sentinel and exactly what a failed
    /// `open()` returns, so it must be rejected rather than quietly spawning
    /// in the caller's namespace.
    @Test("a negative namespace fd is rejected before spawning")
    func negativeNamespaceFDRejected() throws {
        let sleepBinary = try #require(Self.sleepBinary)

        var child = Command(sleepBinary, arguments: ["1"])
        child.attrs.networkNamespace = .fd(-1)

        #expect(throws: Command.Error.self) {
            try child.start()
        }
        #expect(child.pid == -1)
    }

    // MARK: - Helpers

    /// Whether this environment can create and join a network namespace.
    ///
    /// `setns(CLONE_NEWNET)` needs CAP_SYS_ADMIN in both the caller's own user
    /// namespace and the one owning the target, so an unprivileged run can
    /// neither create the namespace nor join it — an `unshare --user` detour
    /// doesn't help, because the first of those two checks still fails.
    /// `make linux-test` grants the capability; elsewhere the tests that need
    /// it are reported as skipped.
    static let canUseNetworkNamespaces: Bool = {
        guard let parked = parkNamespace() else { return false }
        terminate(parked)
        return true
    }()

    /// How long parked helper processes live. Short enough that a suite killed
    /// with SIGKILL — which orphans them, since nothing sets a parent-death
    /// signal — leaks a namespace for seconds rather than minutes.
    private static let parkSeconds = "120"

    private static let sleepBinary = resolve(["/bin/sleep", "/usr/bin/sleep"])
    private static let unshareBinary = resolve(["/usr/bin/unshare", "/bin/unshare"])

    private static func resolve(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Park a process in a fresh network namespace and return it. The
    /// namespace lives exactly as long as that process, so terminating it is
    /// the whole teardown — nothing persists between runs.
    ///
    /// Returns nil when the namespace could not be created: `unshare` is
    /// missing, or we lack CAP_SYS_ADMIN.
    static func parkNamespace() -> Command? {
        guard let unshare = unshareBinary, let sleepBinary else { return nil }

        let parked = Command(unshare, arguments: ["--net", "--", sleepBinary, parkSeconds])
        guard (try? parked.start()) != nil else { return nil }

        // `unshare` calls unshare(2) after fork and before exec, so for a
        // moment the child is still in our namespace. Poll for the namespace
        // to actually differ rather than sleeping a fixed amount.
        guard let ours = try? ownNamespace() else {
            terminate(parked)
            return nil
        }
        for _ in 0..<200 {
            if let theirs = try? namespace(ofPID: parked.pid), theirs != ours {
                return parked
            }
            usleep(10_000)
        }

        terminate(parked)
        return nil
    }

    /// Assert that `start()` failed with a specific errno and that nothing was
    /// spawned. The exact code matters: it distinguishes "setns rejected this"
    /// from "setns was never reached".
    private static func expectSpawnFailure(_ command: Command, code: POSIXErrorCode) {
        do {
            try command.start()
            Issue.record("spawn should have failed with \(code)")
            terminate(command)
        } catch let error as POSIXError {
            #expect(error.code == code)
        } catch {
            Issue.record("expected POSIXError(\(code)), got \(error)")
        }
        #expect(command.pid == -1)
    }

    private static func namespace(ofPID pid: Int32) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/ns/net")
    }

    private static func ownNamespace() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/ns/net")
    }

    private static func terminate(_ command: Command) {
        command.kill(SIGKILL)
        _ = try? command.wait()
    }
}

#endif
