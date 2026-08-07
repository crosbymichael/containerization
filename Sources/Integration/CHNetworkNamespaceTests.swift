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

import Containerization
import ContainerizationExtras
import ContainerizationOS
import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

extension IntegrationSuite {
    /// cloud-hypervisor is told its tap by *name*, and resolves that name in
    /// whichever network namespace it happens to be running in. `TUNSETIFF` on
    /// a name that doesn't exist there **creates** a tap rather than failing,
    /// so a VMM spawned outside the namespace that owns the tap gets a fresh,
    /// unattached device: the guest NIC comes up, carries no traffic, and
    /// nothing logs an error. `CHProcess` therefore spawns the VMM inside the
    /// namespace its taps live in.
    ///
    /// The two assertions here are deliberately different in kind:
    ///
    ///   * The gateway address exists *only* on the in-namespace tap, so a
    ///     successful ping can't be faked by the host kernel answering ARP for
    ///     a locally-configured address (which is what makes an ARP-level
    ///     check useless here — see `net.ipv4.conf.all.arp_ignore`).
    ///   * No device of the tap's name may appear in the host namespace. This
    ///     is the assertion that catches a regression: the duplicate is what
    ///     cloud-hypervisor creates when it is in the wrong namespace, and the
    ///     real tap being present in the pod namespace proves nothing, since
    ///     we put it there ourselves.
    func testCHProcessNetworkNamespace() async throws {
        let id = "test-ch-netns"
        let tap = "cz-nstest0"
        let gateway = "10.211.99.1"
        let guestAddress = "10.211.99.2/24"

        guard let unshare = Self.hostTool("unshare"),
            let nsenter = Self.hostTool("nsenter"),
            let ip = Self.hostTool("ip")
        else {
            throw SkipTest(reason: "network namespace test needs unshare, nsenter and ip installed")
        }
        guard !Self.hostInterfaceExists(tap) else {
            throw SkipTest(reason: "\(tap) already exists in the host network namespace; refusing to touch a device this test did not create")
        }

        // A namespace parked on a sleeping process. It lives exactly as long
        // as that process, so terminating it is the entire teardown, and the
        // tap inside it goes with it. A SIGKILLed suite orphans the sleep
        // rather than reaping it, which is why it's short-lived: the leak
        // expires on its own instead of wedging later runs.
        let parked = try Self.parkNetworkNamespace(unshare: unshare)
        defer { Self.terminate(parked) }
        let nsPath = "/proc/\(parked.pid)/ns/net"

        // Leave the tap the way a CNI plugin would: created and up inside the
        // namespace, with the gateway address on it. A failure here is the
        // environment saying it can't host this test (no /dev/net/tun, no
        // CAP_NET_ADMIN) — `ip` isn't the code under test — so it's a skip,
        // with the command's stderr attached.
        do {
            try Self.runHostCommand(nsenter, ["--net=\(nsPath)", ip, "tuntap", "add", "dev", tap, "mode", "tap"])
            try Self.runHostCommand(nsenter, ["--net=\(nsPath)", ip, "addr", "add", "\(gateway)/24", "dev", tap])
            try Self.runHostCommand(nsenter, ["--net=\(nsPath)", ip, "link", "set", tap, "up"])
        } catch {
            throw SkipTest(reason: "could not prepare tap \(tap) inside \(nsPath): \(error)")
        }

        let bs = try await bootstrap(id, networkNamespace: .path(nsPath))
        let interface = TAPInterface(
            tapName: tap,
            ipv4Address: try CIDRv4(guestAddress),
            ipv4Gateway: try IPv4Address(gateway)
        )

        let container = try LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm) { config in
            config.process.arguments = ["sleep", "100"]
            config.interfaces = [interface]
            config.bootLog = bs.bootLog
        }

        // `create()` is inside the do/catch: it boots the VM, so a failure
        // partway through can leave a cloud-hypervisor process holding the
        // namespace open past our own teardown.
        do {
            try await container.create()
            try await container.start()

            guard !Self.hostInterfaceExists(tap) else {
                throw IntegrationError.assert(
                    msg: "\(tap) appeared in the host network namespace: cloud-hypervisor created its own tap instead of joining \(nsPath)"
                )
            }

            let stdoutBuffer = BufferWriter()
            let stderrBuffer = BufferWriter()
            let exec = try await container.exec("ping-gateway") { config in
                config.arguments = ["ping", "-c", "2", "-W", "2", gateway]
                config.stdout = stdoutBuffer
                config.stderr = stderrBuffer
            }
            try await exec.start()
            let status = try await exec.wait()
            try await exec.delete()

            guard status.exitCode == 0 else {
                let output = String(data: stdoutBuffer.data + stderrBuffer.data, encoding: .utf8) ?? "<non-utf8>"
                throw IntegrationError.assert(
                    msg: "guest could not reach \(gateway) (in-namespace tap address), status \(status): \(output)"
                )
            }

            try await container.stop()
        } catch {
            try? await container.stop()
            throw error
        }
    }

    // MARK: - Helpers

    private static func hostTool(_ name: String) -> String? {
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func hostInterfaceExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/sys/class/net/\(name)")
    }

    /// Park a sleeping process in a fresh network namespace. Throws `SkipTest`
    /// when the namespace can't be created: that needs CAP_SYS_ADMIN, which
    /// `make linux-integration` grants via `--cap-add` but a bare run of the
    /// suite in an unprivileged container won't have.
    private static func parkNetworkNamespace(unshare: String) throws -> Command {
        guard let sleepBinary = hostTool("sleep") else {
            throw SkipTest(reason: "no sleep binary to park a network namespace on")
        }

        // Short-lived on purpose: if the suite is SIGKILLed this process is
        // orphaned rather than reaped, and its namespace (plus the tap inside)
        // lives until it exits.
        let parked = Command(unshare, arguments: ["--net", "--", sleepBinary, "300"])
        try parked.start()

        // `unshare` calls unshare(2) after fork and before exec, so for a
        // moment the child is still in our namespace. Wait for the namespace
        // to actually differ instead of sleeping a fixed amount.
        let ours = try? namespaceLink(pid: -1)
        for _ in 0..<200 {
            if let theirs = try? namespaceLink(pid: parked.pid), theirs != ours {
                return parked
            }
            usleep(10_000)
        }

        terminate(parked)
        throw SkipTest(reason: "could not create a network namespace (needs CAP_SYS_ADMIN)")
    }

    /// The target of `/proc/<pid>/ns/net`; `pid` of -1 means this process.
    private static func namespaceLink(pid: Int32) throws -> String {
        let who = pid < 0 ? "self" : "\(pid)"
        return try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(who)/ns/net")
    }

    private static func terminate(_ command: Command) {
        command.kill(SIGKILL)
        _ = try? command.wait()
    }

    /// Run a host command to completion, throwing with its stderr when it
    /// fails. Used for the `ip`/`nsenter` plumbing this test needs; failures
    /// are reported as skips because they mean the environment can't host the
    /// test (no `/dev/net/tun`, no capabilities), not that the code is wrong.
    private static func runHostCommand(_ binary: String, _ arguments: [String]) throws {
        let errPath = Self.testDir.appendingPathComponent("hostcmd-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: errPath.path, contents: nil),
            let errHandle = FileHandle(forWritingAtPath: errPath.path)
        else {
            throw IntegrationError.assert(msg: "could not create \(errPath.path)")
        }
        defer {
            try? errHandle.close()
            try? FileManager.default.removeItem(at: errPath)
        }

        var command = Command(binary, arguments: arguments)
        command.stderr = errHandle
        try command.start()
        let status = try command.wait()

        guard status == 0 else {
            let stderr = (try? String(contentsOf: errPath, encoding: .utf8)) ?? ""
            let line = ([binary] + arguments).joined(separator: " ")
            throw IntegrationError.assert(
                msg: "`\(line)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
}

#endif
