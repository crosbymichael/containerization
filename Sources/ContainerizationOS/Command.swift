//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import CShim
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
private let _kill = Darwin.kill
#elseif canImport(Musl)
import Musl
private let _kill = Musl.kill
#elseif canImport(Glibc)
import Glibc
private let _kill = Glibc.kill
#endif

/// A reference to a Linux network namespace for a child process to join.
///
/// The namespace is entered in the child between `fork` and `execve`, so the
/// calling process never changes its own namespace — a `setns` on the parent
/// would leak into every subsequent spawn.
public enum NetworkNamespaceRef: Sendable {
    /// An already-open file descriptor referring to a network namespace.
    /// The caller keeps ownership: it is neither duplicated nor closed.
    ///
    /// The fd must stay open for as long as this reference may be used to
    /// spawn. Closing it frees the number for reuse, and if an unrelated
    /// `open` recycles it onto *another* namespace fd the spawn joins the
    /// wrong namespace and reports success. Prefer `.path` for anything
    /// long-lived (a `VirtualMachineManager` that spawns per VM, say), where
    /// the fd is opened fresh for each spawn.
    case fd(Int32)
    /// A path to a network namespace, either `/proc/<pid>/ns/net` or a bind
    /// mount of one such as `/var/run/netns/<name>`. Opened before the spawn
    /// and closed again once it completes.
    case path(String)
}

extension NetworkNamespaceRef: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fd(let fd):
            return "fd \(fd)"
        case .path(let path):
            return path
        }
    }
}

/// Use a command to run an executable.
public struct Command: Sendable {
    /// Path to the executable binary.
    public var executable: String
    /// Arguments provided to the binary.
    public var arguments: [String]
    /// Environment variables for the process.
    public var environment: [String]
    /// The directory where the process should execute.
    public var directory: String?
    /// Additional files to pass to the process.
    public var extraFiles: [FileHandle]
    /// The standard input.
    public var stdin: FileHandle?
    /// The standard output.
    public var stdout: FileHandle?
    /// The standard error.
    public var stderr: FileHandle?

    private let state: State

    /// System level attributes to set on the process.
    public struct Attrs: Sendable {
        /// Set pgroup for the new process.
        public var setPGroup: Bool
        /// Make the new process group the foreground process group (requires setPGroup).
        public var setForegroundPGroup: Bool
        /// Inherit the real uid/gid of the parent.
        public var resetIDs: Bool
        /// Reset the child's signal handlers to the default.
        public var setSignalDefault: Bool
        /// The initial signal mask for the process.
        public var signalMask: UInt32
        /// Create a new session for the process.
        public var setsid: Bool
        /// Set the controlling terminal for the process to fd 0.
        public var setctty: Bool
        /// Set the process user ID.
        public var uid: UInt32?
        /// Set the process group ID.
        public var gid: UInt32?
        /// Signal to send when parent process dies (Linux only).
        public var pdeathSignal: Int32?
        /// Network namespace for the child to join before it execs (Linux
        /// only; setting it elsewhere throws `Error.networkNamespaceUnsupported`).
        /// Requires CAP_SYS_ADMIN, and is applied before `uid`/`gid` are
        /// dropped. If the namespace can't be joined the spawn fails rather
        /// than running the process in the caller's namespace.
        public var networkNamespace: NetworkNamespaceRef?

        public init(
            setPGroup: Bool = false,
            setForegroundPGroup: Bool = false,
            resetIDs: Bool = false,
            setSignalDefault: Bool = true,
            signalMask: UInt32 = 0,
            setsid: Bool = false,
            setctty: Bool = false,
            uid: UInt32? = nil,
            gid: UInt32? = nil,
            pdeathSignal: Int32? = nil,
            networkNamespace: NetworkNamespaceRef? = nil
        ) {
            self.setPGroup = setPGroup
            self.setForegroundPGroup = setForegroundPGroup
            self.resetIDs = resetIDs
            self.setSignalDefault = setSignalDefault
            self.signalMask = signalMask
            self.setsid = setsid
            self.setctty = setctty
            self.uid = uid
            self.gid = gid
            self.pdeathSignal = pdeathSignal
            self.networkNamespace = networkNamespace
        }
    }

    private final class State: Sendable {
        let pid: Atomic<pid_t> = Atomic(-1)
    }

    /// Attributes to set on the process.
    public var attrs = Attrs()

    /// System level process identifier.
    public var pid: Int32 { self.state.pid.load(ordering: .acquiring) }

    public init(
        _ executable: String,
        arguments: [String] = [],
        environment: [String] = environment(),
        directory: String? = nil,
        extraFiles: [FileHandle] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.extraFiles = extraFiles
        self.directory = directory
        self.state = State()
    }

    public static func environment() -> [String] {
        ProcessInfo.processInfo.environment
            .map { "\($0)=\($1)" }
    }
}

extension Command {
    public enum Error: Swift.Error, CustomStringConvertible {
        case processRunning
        case networkNamespaceUnsupported
        case invalidNetworkNamespaceFD(Int32)

        public var description: String {
            switch self {
            case .processRunning:
                return "the process is already running"
            case .networkNamespaceUnsupported:
                return "joining a network namespace is only supported on Linux"
            case .invalidNetworkNamespaceFD(let fd):
                return "\(fd) is not a valid network namespace file descriptor"
            }
        }
    }
}

extension Command {
    @discardableResult
    public func kill(_ signal: Int32) -> Int32? {
        let pid = self.pid
        guard pid > 0 else {
            return nil
        }
        return _kill(pid, signal)
    }
}

extension Command {
    /// Start the process.
    public func start() throws {
        guard self.pid == -1 else {
            throw Error.processRunning
        }
        let child = try execute()
        self.state.pid.store(child, ordering: .releasing)
    }

    /// Wait for the process to exit and return the exit status.
    @discardableResult
    public func wait() throws -> Int32 {
        var rus = rusage()
        var ws = Int32()

        let pid = self.pid
        guard pid > 0 else {
            return -1
        }

        let result = wait4(pid, &ws, 0, &rus)
        guard result == pid else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return Self.toExitStatus(ws)
    }

    private func execute() throws -> pid_t {
        var attrs = exec_command_attrs()
        exec_command_attrs_init(&attrs)

        let set = try createFileset()
        defer {
            for nullHandle in set.nullHandles {
                try? nullHandle.close()
            }
        }
        var fds = [Int32](repeating: 0, count: set.handles.count)
        for (i, handle) in set.handles.enumerated() {
            fds[i] = handle.fileDescriptor
        }

        attrs.setsid = self.attrs.setsid ? 1 : 0
        attrs.setctty = self.attrs.setctty ? 1 : 0
        attrs.setpgid = self.attrs.setPGroup ? 1 : 0
        attrs.setfgpgrp = self.attrs.setForegroundPGroup ? 1 : 0

        var cwdPath: UnsafeMutablePointer<CChar>?
        if let chdir = self.directory {
            cwdPath = strdup(chdir)
        }
        defer {
            if let cwdPath {
                free(cwdPath)
            }
        }

        if let uid = self.attrs.uid {
            attrs.uid = uid
        }
        if let gid = self.attrs.gid {
            attrs.gid = gid
        }

        if let pdeathSignal = self.attrs.pdeathSignal {
            attrs.pdeathSignal = pdeathSignal
        }

        // The child joins the network namespace itself, between fork and exec,
        // so this process stays in its own namespace. A path is opened here in
        // the parent and closed once the spawn returns; an fd is passed
        // through untouched and remains the caller's to close. O_CLOEXEC is
        // correct either way: the fd is only used before execve.
        #if os(Linux)
        var openedNamespaceFD: Int32?
        defer {
            if let openedNamespaceFD {
                close(openedNamespaceFD)
            }
        }
        if let namespace = self.attrs.networkNamespace {
            switch namespace {
            case .fd(let fd):
                // A negative fd is the C layer's "no namespace" sentinel, and
                // -1 is exactly what a failed open() hands back. Accepting it
                // would spawn in the caller's namespace and say nothing —
                // the silent misconfiguration this option exists to prevent.
                guard fd >= 0 else {
                    throw Error.invalidNetworkNamespaceFD(fd)
                }
                attrs.netns_fd = fd
            case .path(let path):
                let fd = open(path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else {
                    throw POSIXError.fromErrno()
                }
                openedNamespaceFD = fd
                attrs.netns_fd = fd
            }
        }
        #else
        guard self.attrs.networkNamespace == nil else {
            throw Error.networkNamespaceUnsupported
        }
        #endif

        var pid: pid_t = 0
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for arg in argv where arg != nil {
                free(arg)
            }
        }

        let env = environment.map { strdup($0) } + [nil]
        defer {
            for e in env where e != nil {
                free(e)
            }
        }

        let result = fds.withUnsafeBufferPointer { file_handles in
            exec_command(
                &pid,
                argv[0],
                &argv,
                env,
                file_handles.baseAddress!, Int32(file_handles.count),
                cwdPath ?? nil,
                &attrs)
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        return pid
    }

    /// Create a posix_spawn file actions set of fds to pass to the new process
    private func createFileset() throws -> (nullHandles: [FileHandle], handles: [FileHandle]) {
        // grab dev null handles for different purposes
        let nullRead = try openDevNull(flags: O_RDONLY)
        let nullWrite = try openDevNull(flags: O_WRONLY)
        var files = [FileHandle]()
        files.append(stdin ?? nullRead)
        files.append(stdout ?? nullWrite)
        files.append(stderr ?? nullWrite)
        files.append(contentsOf: extraFiles)
        return (nullHandles: [nullRead, nullWrite], handles: files)
    }

    /// Returns a file handle to /dev/null with the specified flags.
    private func openDevNull(flags: Int32) throws -> FileHandle {
        let fd = open("/dev/null", flags, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }
}

extension Command {
    private static let signalOffset: Int32 = 128

    private static let shift: Int32 = 8
    private static let mask: Int32 = 0x7F
    private static let stopped: Int32 = 0x7F
    private static let exited: Int32 = 0x00

    static func signaled(_ ws: Int32) -> Bool {
        ws & mask != stopped && ws & mask != exited
    }

    static func exited(_ ws: Int32) -> Bool {
        ws & mask == exited
    }

    static func exitStatus(_ ws: Int32) -> Int32 {
        let r: Int32
        #if os(Linux)
        r = ws >> shift & 0xFF
        #else
        r = ws >> shift
        #endif
        return r
    }

    public static func toExitStatus(_ ws: Int32) -> Int32 {
        if signaled(ws) {
            // We use the offset as that is how existing container
            // runtimes minic bash for the status when signaled.
            return Int32(Self.signalOffset + ws & mask)
        }
        if exited(ws) {
            return exitStatus(ws)
        }
        return ws
    }

}

private func WIFEXITED(_ status: Int32) -> Bool {
    _WSTATUS(status) == 0
}

private func _WSTATUS(_ status: Int32) -> Int32 {
    status & 0x7f
}

private func WIFSIGNALED(_ status: Int32) -> Bool {
    (_WSTATUS(status) != 0) && (_WSTATUS(status) != 0x7f)
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func WTERMSIG(_ status: Int32) -> Int32 {
    status & 0x7f
}
