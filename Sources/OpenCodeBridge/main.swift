import Darwin
import Foundation

// Codenotch OpenCode blocking bridge.
//
// The OpenCode plugin runs inside Node. CodeIsland already proved that using a
// tiny native POSIX helper is the reliable way to hold a Unix-socket request
// open for minutes while the user answers a permission/question in a macOS
// NWConnection server. Keep this helper deliberately narrow: one stdin JSON
// request in, one socket round-trip, one stdout JSON response out.

signal(SIGPIPE, SIG_IGN)

let socketPath = "/tmp/codenotch-(getuid()).sock"

func connectSocket(_ path: String, timeoutMs: Int32 = 3_000) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var noSigPipe: Int32 = 1
    setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let maxPath = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxPath else {
        close(fd)
        return nil
    }

    withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
        path.withCString { source in
            _ = strcpy(pointer, source)
        }
    }

    let originalFlags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 && errno != EINPROGRESS {
        close(fd)
        return nil
    }

    if result != 0 {
        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, timeoutMs) > 0 else {
            close(fd)
            return nil
        }

        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
        guard socketError == 0 else {
            close(fd)
            return nil
        }
    }

    _ = fcntl(fd, F_SETFL, originalFlags)
    return fd
}

func sendAll(_ fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { bytes -> Bool in
        guard let base = bytes.baseAddress else { return true }

        var sent = 0
        while sent < bytes.count {
            let count = send(fd, base + sent, bytes.count - sent, 0)
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            if count == 0 { return false }
            sent += count
        }
        return true
    }
}

func receiveLine(_ fd: Int32) -> Data? {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while response.count <= 1_048_576 {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if count == 0 { break }

        response.append(contentsOf: buffer[..<count])
        if let newline = response.firstIndex(of: 0x0A) {
            return Data(response[..<newline])
        }
    }

    return response.isEmpty ? nil : response
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty,
      let fd = connectSocket(socketPath)
else {
    exit(1)
}
defer { close(fd) }

var framed = input
if framed.last != 0x0A {
    framed.append(0x0A)
}

guard sendAll(fd, data: framed) else {
    exit(1)
}

// The request is line-framed, so Codenotch can process it immediately. The
// write half-close matches CodeIsland's proven native helper behaviour and
// makes the request lifecycle explicit without closing the read half.
shutdown(fd, SHUT_WR)

guard let response = receiveLine(fd), !response.isEmpty else {
    exit(1)
}

FileHandle.standardOutput.write(response)
