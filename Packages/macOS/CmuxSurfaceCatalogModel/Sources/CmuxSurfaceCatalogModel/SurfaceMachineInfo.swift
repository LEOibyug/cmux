import Foundation

/// What a provider knows about its machine, for the tree header.
public struct SurfaceMachineInfo: Hashable, Codable, Sendable {
    public var id: SurfaceMachineID
    public var name: String
    /// The local or SSH host's operational status.
    public var status: String
    public var image: String?
    public var memoryMb: Int?
    public var diskMb: Int?
    public var linkState: SurfaceLinkState
    public var linkError: String?
    public var cpuPercent: Double?
    public var memoryUsedMb: Int?
    public var diskUsedMb: Int?
    /// Every cmux-tui workspace on the machine, in the daemon's order — including empty
    /// ones, which have no terminal to be derived from. nil when unknown (asleep, local).
    public var remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil
    /// The user-configured SSH route address; nil for the local machine.
    public var privateAddress: String? = nil
    public var portDiscoveryState: TuiPortDiscoveryState = .notRequested
    /// Host CPU count, when known.
    public var cpus: Int? = nil

    public init(
        id: SurfaceMachineID,
        name: String,
        status: String,
        image: String? = nil,
        memoryMb: Int? = nil,
        diskMb: Int? = nil,
        linkState: SurfaceLinkState,
        linkError: String? = nil,
        cpuPercent: Double? = nil,
        memoryUsedMb: Int? = nil,
        diskUsedMb: Int? = nil,
        remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil,
        privateAddress: String? = nil,
        portDiscoveryState: TuiPortDiscoveryState = .notRequested,
        cpus: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.image = image
        self.memoryMb = memoryMb
        self.diskMb = diskMb
        self.linkState = linkState
        self.linkError = linkError
        self.cpuPercent = cpuPercent
        self.memoryUsedMb = memoryUsedMb
        self.diskUsedMb = diskUsedMb
        self.remoteWorkspaces = remoteWorkspaces
        self.privateAddress = privateAddress
        self.portDiscoveryState = portDiscoveryState
        self.cpus = cpus
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, image, memoryMb, diskMb, linkState, linkError
        case cpuPercent, memoryUsedMb, diskUsedMb, remoteWorkspaces, privateAddress
        case portDiscoveryState, cpus
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SurfaceMachineID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        status = try values.decode(String.self, forKey: .status)
        image = try values.decodeIfPresent(String.self, forKey: .image)
        memoryMb = try values.decodeIfPresent(Int.self, forKey: .memoryMb)
        diskMb = try values.decodeIfPresent(Int.self, forKey: .diskMb)
        linkState = try values.decode(SurfaceLinkState.self, forKey: .linkState)
        linkError = try values.decodeIfPresent(String.self, forKey: .linkError)
        cpuPercent = try values.decodeIfPresent(Double.self, forKey: .cpuPercent)
        memoryUsedMb = try values.decodeIfPresent(Int.self, forKey: .memoryUsedMb)
        diskUsedMb = try values.decodeIfPresent(Int.self, forKey: .diskUsedMb)
        remoteWorkspaces = try values.decodeIfPresent([SurfaceRemoteWorkspace].self, forKey: .remoteWorkspaces)
        privateAddress = try values.decodeIfPresent(String.self, forKey: .privateAddress)
        portDiscoveryState = try values.decodeIfPresent(TuiPortDiscoveryState.self, forKey: .portDiscoveryState) ?? .notRequested
        cpus = try values.decodeIfPresent(Int.self, forKey: .cpus)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(image, forKey: .image)
        try values.encodeIfPresent(memoryMb, forKey: .memoryMb)
        try values.encodeIfPresent(diskMb, forKey: .diskMb)
        try values.encode(linkState, forKey: .linkState)
        try values.encodeIfPresent(linkError, forKey: .linkError)
        try values.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
        try values.encodeIfPresent(memoryUsedMb, forKey: .memoryUsedMb)
        try values.encodeIfPresent(diskUsedMb, forKey: .diskUsedMb)
        try values.encodeIfPresent(remoteWorkspaces, forKey: .remoteWorkspaces)
        try values.encodeIfPresent(privateAddress, forKey: .privateAddress)
        try values.encode(portDiscoveryState, forKey: .portDiscoveryState)
        try values.encodeIfPresent(cpus, forKey: .cpus)
    }
}

