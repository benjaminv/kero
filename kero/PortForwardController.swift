//
//  PortForwardController.swift
//  kero
//

import Combine
import Foundation

/// The local forwards open for one remote connection.
///
/// A remote listening port is only reachable from the Mac once ssh forwards it
/// to a loopback port here, so "Open port" on a remote session becomes forward
/// first, then open. Forwarding is never automatic: something has to ask.
///
/// Ports are numbered as `Int` throughout, matching `RemoteConnection.forward`
/// and `WorkspacePort.port`, so no conversion is needed anywhere along the way.
@MainActor
final class PortForwardController: ObservableObject {
    private let connection: RemoteConnection

    /// Remote port to the loopback port it is reachable on.
    @Published private(set) var localPortsByRemote: [Int: Int] = [:]

    /// Forwards being opened right now, so two callers asking for the same
    /// remote port at once wait on one request and get one local port.
    private var pending: [Int: Task<Int, Error>] = [:]
    private var stateObserver: AnyCancellable?

    init(connection: RemoteConnection) {
        self.connection = connection
        // Forwards live inside the ssh connection, so a drop takes them with
        // it. Nothing needs cancelling; the table just stops being true.
        stateObserver = connection.$state
            .filter { $0 == .disconnected }
            .sink { [weak self] _ in self?.forgetAll() }
    }

    // MARK: - Forwarding

    /// The loopback port `remotePort` is reachable on, forwarding it first if
    /// it is not already. Asking twice returns the same port.
    func forward(remotePort: Int) async throws -> Int {
        if let existing = localPortsByRemote[remotePort] { return existing }
        if let running = pending[remotePort] { return try await running.value }

        let task = Task { [connection] in
            try await connection.forward(remotePort: remotePort)
        }
        pending[remotePort] = task
        defer { pending[remotePort] = nil }

        let localPort = try await task.value
        // A disconnect while the request was in flight makes the forward moot.
        guard connection.state == .connected else {
            throw RemoteConnectionError.notConnected
        }
        localPortsByRemote[remotePort] = localPort
        return localPort
    }

    func localPort(forRemote remotePort: Int) -> Int? {
        localPortsByRemote[remotePort]
    }

    func cancel(remotePort: Int) async {
        pending[remotePort]?.cancel()
        pending[remotePort] = nil
        guard let localPort = localPortsByRemote.removeValue(forKey: remotePort) else {
            return
        }
        await connection.cancelForward(localPort: localPort, remotePort: remotePort)
    }

    func cancelAll() async {
        let open = localPortsByRemote
        forgetAll()
        for (remotePort, localPort) in open {
            await connection.cancelForward(localPort: localPort, remotePort: remotePort)
        }
    }

    private func forgetAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        localPortsByRemote.removeAll()
    }
}
