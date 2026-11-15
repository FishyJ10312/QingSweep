import Foundation
import Darwin
struct StorageVolumeUsage: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    static func identity(for url: URL) -> String? {
        var status = statfs()
        guard url.withUnsafeFileSystemRepresentation({ statfs($0, &status) }) == 0 else { return nil }
        return withUnsafeBytes(of: status.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    static func collect(home: URL) -> [StorageVolumeUsage] {
        func plist(_ arguments: [String]) -> [String: Any]? {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil"); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        var status = statfs()
        guard home.withUnsafeFileSystemRepresentation({ statfs($0, &status) }) == 0 else { return [] }
        let mount = withUnsafeBytes(of: status.f_mntonname) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
        guard let device = plist(["info", "-plist", mount])?["DeviceIdentifier"] as? String,
              let containers = plist(["apfs", "list", "-plist"])?["Containers"] as? [[String: Any]],
              let volumes = containers.compactMap({ $0["Volumes"] as? [[String: Any]] }).first(where: { $0.contains { ($0["DeviceIdentifier"] as? String) == device } }) else { return [] }
        return volumes.compactMap { volume in
            guard let id = volume["DeviceIdentifier"] as? String, id != device,
                  let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value else { return nil }
            let role = (volume["Roles"] as? [String])?.first ?? ""
            return StorageVolumeUsage(id: id, title: ["System":"macOS 系统", "Preboot":"启动支持", "Recovery":"恢复系统", "VM":"内存交换"][role] ?? (volume["Name"] as? String ?? id), bytes: bytes)
        }
    }
}
