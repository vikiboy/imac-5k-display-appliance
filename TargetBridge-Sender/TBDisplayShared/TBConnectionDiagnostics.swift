import Foundation
import Darwin
import Network
import os
import SystemConfiguration

enum TBConnectionPathPreference: String, CaseIterable {
    case automatic
    case wired
    case thunderbolt
    case usb
    case ethernet
    case wifi

    static func parse(_ value: String?) -> TBConnectionPathPreference? {
        guard let value else { return nil }
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "") {
        case "auto", "automatic", "automatico", "best", "alwaysavailable", "sempredisponibile": return .automatic
        case "wired", "cable", "cabled", "cableonly", "solocavo", "onlycable": return .wired
        case "tb", "thunderbolt", "thunderboltbridge", "bridge": return .thunderbolt
        case "usb", "usb4", "usbc", "directusb": return .usb
        case "ethernet", "eth", "lan": return .ethernet
        case "wifi", "wireless", "wlan": return .wifi
        default: return nil
        }
    }

    func allows(_ kind: TBConnectionPathKind) -> Bool {
        switch self {
        case .automatic:
            return true
        case .wired:
            return kind != .wifi
        case .thunderbolt, .usb, .ethernet, .wifi:
            return kind.rawValue == rawValue
        }
    }
}

enum TBConnectionPathKind: String, CaseIterable {
    case thunderbolt
    case usb
    case ethernet
    case wifi

    var transportKind: TBTransportKind {
        self == .thunderbolt ? .thunderboltBridge : .networkLink
    }

    fileprivate var tieBreakPriority: Int {
        switch self {
        case .thunderbolt: return 4
        case .usb: return 3
        case .ethernet: return 2
        case .wifi: return 1
        }
    }
}

struct TBConnectionCandidate: Hashable {
    let kind: TBConnectionPathKind
    let localInterfaceName: String
    let localIP: String
    let receiverIP: String
    /// The receiver TXT-record field that supplied `receiverIP`. A `nil`
    /// value means the address came from a generic Bonjour resolution rather
    /// than a transport-specific advertisement.
    let advertisedReceiverPath: TBConnectionPathKind?

    init(
        kind: TBConnectionPathKind,
        localInterfaceName: String,
        localIP: String,
        receiverIP: String,
        advertisedReceiverPath: TBConnectionPathKind? = nil
    ) {
        self.kind = kind
        self.localInterfaceName = localInterfaceName
        self.localIP = localIP
        self.receiverIP = receiverIP
        self.advertisedReceiverPath = advertisedReceiverPath
    }

    var transportKind: TBTransportKind { kind.transportKind }
    var id: String {
        "\(kind.rawValue)|\(localInterfaceName)|\(localIP)|\(receiverIP)|\(advertisedReceiverPath?.rawValue ?? "resolved")"
    }
}

struct TBConnectionMeasurement: Equatable {
    let candidate: TBConnectionCandidate
    let throughputGbps: Double
    let connectLatencyMilliseconds: Double
}

enum TBConnectionProbeError: LocalizedError {
    case invalidAddress(String)
    case interfaceUnavailable(String)
    case socketFailure(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let value): return "Invalid IPv4 address: \(value)"
        case .interfaceUnavailable(let value): return "Interface unavailable: \(value)"
        case .socketFailure(let value): return value
        case .timeout: return "Connection-path probe timed out"
        }
    }
}

/// Unified-logging entry points for the sender. `log stream --predicate
/// 'subsystem == "com.vikiboy.imac5kdisplay.sender"'` (or Console.app) shows the
/// connection lifecycle without attaching a debugger.
enum TBLog {
    static let connection = Logger(subsystem: "com.vikiboy.imac5kdisplay.sender", category: "connection")
}

/// Pure helpers for deciding how to dial a receiver and for composing
/// actionable connection-failure details. Kept free of session state so the
/// unit-test bundle can exercise them without hardware.
enum TBConnectionDiagnostics {

    private struct ReceiverEndpoint {
        let ip: String
        let advertisedPath: TBConnectionPathKind?
    }

    /// A local IPv4 interface as (name, ip) — the test-injectable slice of
    /// what `getifaddrs` reports.
    struct LocalInterface: Equatable {
        let name: String
        let ip: String

        init(name: String, ip: String) {
            self.name = name
            self.ip = ip
        }
    }

    /// Returns the name of the local interface that owns `localIP`, if any.
    static func interfaceName(forLocalIP localIP: String, in interfaces: [LocalInterface]) -> String? {
        guard !localIP.isEmpty else { return nil }
        return interfaces.first(where: { $0.ip == localIP })?.name
    }

    /// Direct Mac-to-Mac USB connections are exposed by macOS as USB-NCM
    /// Ethernet interfaces (normally enX) with an IPv4 link-local address.
    /// Keep bridgeX reserved for the Thunderbolt Bridge transport.
    static func isDirectLinkInterface(name: String, ip: String) -> Bool {
        guard name.hasPrefix("en") || name.hasPrefix("eth") else { return false }
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]),
              octets.dropFirst(2).allSatisfy({ component in
                  guard let value = Int(component) else { return false }
                  return (0...255).contains(value)
              })
        else {
            return false
        }
        return first == 169 && second == 254
    }

    static func isIPv4LinkLocal(_ ip: String) -> Bool {
        let octets = ipv4Octets(ip)
        return octets?.count == 4 && octets?[0] == 169 && octets?[1] == 254
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        guard let octets = ipv4Octets(ip) else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func ipv4Octets(_ ip: String) -> [Int]? {
        let components = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    /// Maps BSD interface names to their physical role using SystemConfiguration.
    /// This avoids assuming that Wi-Fi is always en0/en1, which changes between Macs.
    static func hardwarePathKinds() -> [String: TBConnectionPathKind] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: TBConnectionPathKind] = [:]
        for interface in all {
            guard let bsdNameValue = SCNetworkInterfaceGetBSDName(interface),
                  let type = SCNetworkInterfaceGetInterfaceType(interface)
            else { continue }
            let bsdName = bsdNameValue as String
            if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) {
                result[bsdName] = .wifi
            } else if CFEqual(type, kSCNetworkInterfaceTypeEthernet) {
                result[bsdName] = .ethernet
            }
        }
        return result
    }

    static func pathKind(
        for interface: LocalInterface,
        hardwareKinds: [String: TBConnectionPathKind]
    ) -> TBConnectionPathKind? {
        if interface.name.hasPrefix("bridge"), isIPv4LinkLocal(interface.ip) {
            return .thunderbolt
        }
        if isDirectLinkInterface(name: interface.name, ip: interface.ip) {
            return .usb
        }
        if hardwareKinds[interface.name] == .wifi, isPrivateIPv4(interface.ip) {
            return .wifi
        }
        if hardwareKinds[interface.name] == .ethernet, isPrivateIPv4(interface.ip) {
            return .ethernet
        }
        // Some third-party USB Ethernet adapters are absent from the SC inventory.
        if (interface.name.hasPrefix("en") || interface.name.hasPrefix("eth")), isPrivateIPv4(interface.ip) {
            return .ethernet
        }
        return nil
    }

    /// Builds every plausible local/remote pair. Real probing decides which pair
    /// is alive; a cable type is never presumed to be faster merely from its name.
    static func connectionCandidates(
        receiver: TBDiscoveredReceiver,
        interfaces: [LocalInterface],
        hardwareKinds: [String: TBConnectionPathKind]
    ) -> [TBConnectionCandidate] {
        // Preserve the receiver's transport-specific TXT metadata instead of
        // flattening every address into one pool. In particular, both
        // Thunderbolt Bridge and USB-NCM commonly use 169.254/16, so address
        // shape alone cannot distinguish them.
        let receiverEndpoints = uniqueReceiverEndpoints([
            ReceiverEndpoint(ip: receiver.thunderboltIP, advertisedPath: .thunderbolt),
            ReceiverEndpoint(ip: receiver.usbIP, advertisedPath: .usb),
            ReceiverEndpoint(ip: receiver.ethernetIP, advertisedPath: .ethernet),
            ReceiverEndpoint(ip: receiver.wifiIP, advertisedPath: .wifi),
            ReceiverEndpoint(ip: receiver.networkIP, advertisedPath: nil),
            ReceiverEndpoint(ip: receiver.preferredIP, advertisedPath: nil),
        ] + receiver.resolvedIPv4Addresses.map {
            ReceiverEndpoint(ip: $0, advertisedPath: nil)
        })

        var candidates: [TBConnectionCandidate] = []
        var seen = Set<String>()
        for interface in interfaces {
            guard let kind = pathKind(for: interface, hardwareKinds: hardwareKinds) else { continue }
            let explicitEndpoints = receiverEndpoints.filter { $0.advertisedPath == kind }
            let genericEndpoints = receiverEndpoints.filter { $0.advertisedPath == nil }

            let addressPool: [ReceiverEndpoint]
            if kind == .thunderbolt || kind == .usb {
                // Do not cross-pollinate the other direct transport's
                // advertised link-local endpoint. Generic resolved addresses
                // remain useful to automatic probing for older receivers.
                addressPool = explicitEndpoints + genericEndpoints.filter { isIPv4LinkLocal($0.ip) }
            } else {
                let privateEndpoints = genericEndpoints.filter { isPrivateIPv4($0.ip) }
                let sameSubnet = privateEndpoints.filter { likelySameIPv4Subnet(interface.ip, $0.ip) }
                // Prefer a same-/24 endpoint. If Bonjour only exposes a different
                // subnet, retain it as a probe candidate so routed LANs still work.
                addressPool = explicitEndpoints + (sameSubnet.isEmpty ? privateEndpoints : sameSubnet)
            }

            for endpoint in addressPool where endpoint.ip != interface.ip {
                let candidate = TBConnectionCandidate(
                    kind: kind,
                    localInterfaceName: interface.name,
                    localIP: interface.ip,
                    receiverIP: endpoint.ip,
                    advertisedReceiverPath: endpoint.advertisedPath
                )
                if seen.insert(candidate.id).inserted {
                    candidates.append(candidate)
                }
            }
        }

        return candidates.sorted(by: candidateComesBefore)
    }

    /// Selects a fixed user-requested route without inferring a Thunderbolt
    /// endpoint from a generic link-local address. A pinned Thunderbolt route
    /// is valid only when the local interface is bridge0 and the remote address
    /// came from the receiver's `tbIP` advertisement. If either fact is absent,
    /// selection fails closed and the automation retry waits for fresh metadata.
    static func selectPinnedCandidate(
        _ candidates: [TBConnectionCandidate],
        preference: TBConnectionPathPreference
    ) -> TBConnectionCandidate? {
        guard preference != .automatic, preference != .wired else { return nil }

        var eligible = candidates.filter { preference.allows($0.kind) }
        if preference == .thunderbolt {
            eligible = eligible.filter {
                $0.kind == .thunderbolt
                    && $0.localInterfaceName == "bridge0"
                    && $0.advertisedReceiverPath == .thunderbolt
            }
        }
        return eligible.sorted(by: candidateComesBefore).first
    }

    static func selectBestMeasurement(
        _ measurements: [TBConnectionMeasurement],
        preference: TBConnectionPathPreference
    ) -> TBConnectionMeasurement? {
        let eligible: [TBConnectionMeasurement]
        eligible = measurements.filter { preference.allows($0.candidate.kind) }
        guard let fastest = eligible.max(by: { $0.throughputGbps < $1.throughputGbps }) else { return nil }

        // Results within 10% are effectively tied for a short startup probe.
        // In that narrow band prefer lower latency, then the more direct medium.
        let competitive = eligible.filter {
            $0.throughputGbps >= fastest.throughputGbps * 0.90
        }
        return competitive.sorted {
            let latencyDifference = abs($0.connectLatencyMilliseconds - $1.connectLatencyMilliseconds)
            if latencyDifference > 0.25 {
                return $0.connectLatencyMilliseconds < $1.connectLatencyMilliseconds
            }
            if $0.candidate.kind.tieBreakPriority != $1.candidate.kind.tieBreakPriority {
                return $0.candidate.kind.tieBreakPriority > $1.candidate.kind.tieBreakPriority
            }
            return $0.throughputGbps > $1.throughputGbps
        }.first
    }

    /// Sends a bounded stream of protocol-valid TEST_DATA packets through one
    /// explicitly bound interface. The receiver already discards this packet
    /// type, so the probe measures the real path without starting video capture.
    static func probe(
        _ candidate: TBConnectionCandidate,
        port: UInt16 = TBMonitorProtocol.port,
        payloadBytes: Int = 16 * 1024 * 1024,
        timeout: TimeInterval = 3.0
    ) throws -> TBConnectionMeasurement {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw socketError("socket") }
        defer { Darwin.close(fd) }

        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw socketError("setsockopt(SO_NOSIGPIPE)")
        }

        let interfaceIndex = if_nametoindex(candidate.localInterfaceName)
        guard interfaceIndex != 0 else { throw TBConnectionProbeError.interfaceUnavailable(candidate.localInterfaceName) }
        var boundIndex = interfaceIndex
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIndex, socklen_t(MemoryLayout.size(ofValue: boundIndex))) == 0 else {
            throw socketError("setsockopt(IP_BOUND_IF)")
        }

        var localAddress = try socketAddress(ip: candidate.localIP, port: 0)
        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw socketError("bind") }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw socketError("fcntl")
        }

        var remoteAddress = try socketAddress(ip: candidate.receiverIP, port: port)
        let connectStarted = DispatchTime.now().uptimeNanoseconds
        let connectResult = withUnsafePointer(to: &remoteAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else { throw socketError("connect") }
            try waitForSocket(fd, events: Int16(POLLOUT), timeout: timeout)
            var socketStatus: Int32 = 0
            var socketStatusLength = socklen_t(MemoryLayout.size(ofValue: socketStatus))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketStatus, &socketStatusLength) == 0 else {
                throw socketError("getsockopt(SO_ERROR)")
            }
            guard socketStatus == 0 else {
                throw TBConnectionProbeError.socketFailure("connect: \(String(cString: strerror(socketStatus)))")
            }
        }
        let connectedAt = DispatchTime.now().uptimeNanoseconds

        let chunkBytes = min(256 * 1024, max(1, payloadBytes))
        let payload = Data(repeating: 0xA5, count: chunkBytes)
        let fullPacket = TBMonitorProtocol.makePacket(type: .testData, payload: payload)
        let sendStarted = DispatchTime.now().uptimeNanoseconds
        let deadline = sendStarted + UInt64(timeout * 1_000_000_000)
        var sentPayloadBytes = 0

        while sentPayloadBytes < payloadBytes {
            let remaining = payloadBytes - sentPayloadBytes
            let packet = remaining >= chunkBytes
                ? fullPacket
                : TBMonitorProtocol.makePacket(type: .testData, payload: Data(repeating: 0xA5, count: remaining))
            try sendAll(packet, socket: fd, deadline: deadline)
            sentPayloadBytes += min(chunkBytes, remaining)
        }
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        let sendSeconds = max(Double(finishedAt - sendStarted) / 1_000_000_000.0, 0.000_001)
        let throughput = (Double(sentPayloadBytes) * 8.0) / 1_000_000_000.0 / sendSeconds
        let latency = Double(connectedAt - connectStarted) / 1_000_000.0
        return TBConnectionMeasurement(
            candidate: candidate,
            throughputGbps: throughput,
            connectLatencyMilliseconds: latency
        )
    }

    private static func uniqueReceiverEndpoints(_ values: [ReceiverEndpoint]) -> [ReceiverEndpoint] {
        var result: [ReceiverEndpoint] = []
        var seen = Set<String>()
        for value in values where ipv4Octets(value.ip) != nil && seen.insert(value.ip).inserted {
            result.append(value)
        }
        return result
    }

    private static func candidateComesBefore(
        _ lhs: TBConnectionCandidate,
        _ rhs: TBConnectionCandidate
    ) -> Bool {
        if lhs.kind.tieBreakPriority != rhs.kind.tieBreakPriority {
            return lhs.kind.tieBreakPriority > rhs.kind.tieBreakPriority
        }
        let lhsIsExplicitMatch = lhs.advertisedReceiverPath == lhs.kind
        let rhsIsExplicitMatch = rhs.advertisedReceiverPath == rhs.kind
        if lhsIsExplicitMatch != rhsIsExplicitMatch {
            return lhsIsExplicitMatch
        }
        if lhs.localInterfaceName != rhs.localInterfaceName {
            return lhs.localInterfaceName < rhs.localInterfaceName
        }
        if lhs.localIP != rhs.localIP {
            return lhs.localIP < rhs.localIP
        }
        if lhs.receiverIP != rhs.receiverIP {
            return lhs.receiverIP < rhs.receiverIP
        }
        return (lhs.advertisedReceiverPath?.rawValue ?? "")
            < (rhs.advertisedReceiverPath?.rawValue ?? "")
    }

    private static func likelySameIPv4Subnet(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = ipv4Octets(lhs), let right = ipv4Octets(rhs) else { return false }
        return left[0] == right[0] && left[1] == right[1] && left[2] == right[2]
    }

    private static func socketAddress(ip: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw TBConnectionProbeError.invalidAddress(ip)
        }
        return address
    }

    private static func waitForSocket(_ fd: Int32, events: Int16, timeout: TimeInterval) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1000.0, Double(Int32.max))))
        while true {
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard (descriptor.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) == 0 else {
                    throw TBConnectionProbeError.socketFailure("socket became unavailable")
                }
                return
            }
            if result == 0 { throw TBConnectionProbeError.timeout }
            if errno != EINTR { throw socketError("poll") }
        }
    }

    private static func sendAll(_ data: Data, socket fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadline {
                    throw TBConnectionProbeError.timeout
                }
                let sent = Darwin.send(fd, baseAddress.advanced(by: offset), buffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let waitStarted = DispatchTime.now().uptimeNanoseconds
                    guard waitStarted < deadline else { throw TBConnectionProbeError.timeout }
                    let remainingSeconds = Double(deadline - waitStarted) / 1_000_000_000.0
                    try waitForSocket(fd, events: Int16(POLLOUT), timeout: max(0.001, remainingSeconds))
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    throw socketError("send")
                }
            }
        }
    }

    private static func socketError(_ operation: String) -> TBConnectionProbeError {
        TBConnectionProbeError.socketFailure("\(operation): \(String(cString: strerror(errno)))")
    }

    /// For a link-local (`169.254.x`) receiver reached through bridgeX,
    /// returns `"<ip>%<interface>"` so the Thunderbolt dial is scoped to the
    /// interface that owns `localIP`. Direct USB-NCM enX links remain
    /// unscoped: macOS installs a host route for the USB peer and Network.framework
    /// does not reliably accept an IPv4 `%enX` zone suffix.
    ///
    /// Why: macOS keeps a single routing-table entry for all of
    /// 169.254.0.0/16, pointing at the primary interface (usually Wi-Fi). A
    /// Thunderbolt Bridge peer is only reachable on the bridge interface, so
    /// an unscoped dial to its self-assigned link-local address leaves via the
    /// wrong interface and times out — with both Macs configured correctly.
    /// A scoped address routes on the named interface regardless of the table.
    static func scopedReceiverHost(
        receiverIP: String,
        localIP: String,
        interfaces: [LocalInterface]
    ) -> String {
        guard receiverIP.hasPrefix("169.254."), !receiverIP.contains("%") else { return receiverIP }
        guard let name = interfaceName(forLocalIP: localIP, in: interfaces) else { return receiverIP }
        guard name.hasPrefix("bridge") else { return receiverIP }
        return "\(receiverIP)%\(name)"
    }

    /// Human-readable context for a failed or timed-out connect attempt:
    /// where we dialed, from which address/interface, over which transport,
    /// and the last state reported by the network stack.
    static func failureDetail(
        receiverHost: String,
        port: UInt16,
        localIP: String,
        interfaceName: String?,
        transport: String,
        lastNetworkState: String?
    ) -> String {
        var detail = "dialed \(receiverHost):\(port) from \(localIP)"
        if let interfaceName, !interfaceName.isEmpty {
            detail += " (\(interfaceName))"
        }
        detail += " [\(transport)]"
        if let lastNetworkState, !lastNetworkState.isEmpty {
            detail += " — last network state: \(lastNetworkState)"
        }
        return detail
    }

    /// Snapshot of the machine's up, non-loopback IPv4 interfaces.
    static func currentIPv4Interfaces() -> [LocalInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [LocalInterface] = []
        var pointer = ifaddr
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let sa = iface.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            interfaces.append(LocalInterface(name: String(cString: iface.pointee.ifa_name), ip: String(cString: buffer)))
        }
        return interfaces
    }
}
