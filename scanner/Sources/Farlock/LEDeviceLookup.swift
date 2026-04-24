// LEDeviceLookup — resolve CBPeripheral.identifier UUIDs to static MAC
// addresses and cached device names by reading macOS's Bluetooth databases.
//
// Adapted from BLEUnlock's LEDeviceInfo.swift / BLE.swift (MIT © 2019-2022
// Takeshi Sone). BLE peripherals on iOS and recent macOS rotate their
// advertised MAC addresses every ~15 minutes for privacy, so the
// CBPeripheral.identifier UUID is the only persistent handle a scanner
// observes. Apple keeps a mapping from that UUID back to the device's real
// ("resolved") MAC address in two places:
//
//   1. /Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db
//      /Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db
//      SQLite databases introduced in macOS Monterey. Most useful because the
//      `PairedDevices` table has a `ResolvedAddress` column.
//
//   2. /Library/Preferences/com.apple.Bluetooth.plist
//      The older `CoreBluetoothCache` dictionary. Still populated on recent
//      macOS as a fallback.
//
// On Ventura+ these paths often require Full Disk Access. If opening fails
// we log once and return nil — the scanner still emits UUID + name + rssi and
// the Lua side can keep matching on those.

import Foundation
import SQLite3

struct LEDeviceInfo {
    var name: String?
    var macAddr: String?
}

final class LEDeviceLookup {
    private var pairedDb: OpaquePointer?
    private var otherDb: OpaquePointer?
    private var legacyPlist: NSDictionary?
    private var openLogged = false

    private let pairedPath = "/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db"
    private let otherPath  = "/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db"
    private let legacyPlistPath = "/Library/Preferences/com.apple.Bluetooth.plist"

    // Tiny cache so we don't hit SQLite on every snapshot tick. UUIDs are
    // stable per-Mac so the first hit is forever correct; if the device is
    // re-paired its UUID would typically change and we'd look up the new one.
    private var cache: [String: LEDeviceInfo] = [:]

    init() {
        open()
    }

    deinit {
        if let db = pairedDb { sqlite3_close(db) }
        if let db = otherDb  { sqlite3_close(db) }
    }

    private func open() {
        if sqlite3_open_v2(pairedPath, &pairedDb, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            pairedDb = nil
        }
        if sqlite3_open_v2(otherPath,  &otherDb,  SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            otherDb = nil
        }
        legacyPlist = NSDictionary(contentsOfFile: legacyPlistPath)

        if !openLogged {
            openLogged = true
            let parts = [
                "paired.db=\(pairedDb != nil ? "ok" : "unavailable")",
                "other.db=\(otherDb  != nil ? "ok" : "unavailable")",
                "legacy.plist=\(legacyPlist != nil ? "ok" : "unavailable")",
            ].joined(separator: " ")
            FileHandle.standardError.write(Data("LEDeviceLookup: \(parts)\n".utf8))
            if pairedDb == nil && otherDb == nil && legacyPlist == nil {
                FileHandle.standardError.write(Data(
                    "LEDeviceLookup: all sources unavailable — static MAC resolution disabled. Grant Full Disk Access to this binary to enable.\n".utf8))
            }
        }
    }

    func lookup(uuid: String) -> LEDeviceInfo? {
        if let hit = cache[uuid] { return hit.macAddr == nil && hit.name == nil ? nil : hit }
        let result = queryPaired(uuid: uuid)
            ?? queryOther(uuid: uuid)
            ?? queryLegacy(uuid: uuid)
        cache[uuid] = result ?? LEDeviceInfo(name: nil, macAddr: nil)
        return result
    }

    // MARK: SQLite

    private func queryPaired(uuid: String) -> LEDeviceInfo? {
        return querySqlite(
            db: pairedDb,
            sql: "SELECT Name, Address, ResolvedAddress FROM PairedDevices WHERE Uuid = ?",
            uuid: uuid,
            hasResolved: true
        )
    }

    private func queryOther(uuid: String) -> LEDeviceInfo? {
        return querySqlite(
            db: otherDb,
            sql: "SELECT Name, Address FROM OtherDevices WHERE Uuid = ?",
            uuid: uuid,
            hasResolved: false
        )
    }

    private func querySqlite(
        db: OpaquePointer?,
        sql: String,
        uuid: String,
        hasResolved: Bool
    ) -> LEDeviceInfo? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        // SQLITE_TRANSIENT — have SQLite copy the string.
        let SQLITE_TRANSIENT = unsafeBitCast(
            OpaquePointer(bitPattern: -1)!,
            to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
        )
        _ = sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let name = readString(stmt: stmt, col: 0)
        let rawAddress = readString(stmt: stmt, col: 1)
        let resolved = hasResolved ? readString(stmt: stmt, col: 2) : nil
        let mac = parseMacAddress(resolved ?? rawAddress)
        guard name != nil || mac != nil else { return nil }
        return LEDeviceInfo(name: name, macAddr: mac)
    }

    private func readString(stmt: OpaquePointer?, col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) == SQLITE_TEXT,
              let ptr = sqlite3_column_text(stmt, col) else {
            return nil
        }
        let s = String(cString: ptr).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    // MARK: Legacy plist

    private func queryLegacy(uuid: String) -> LEDeviceInfo? {
        guard let plist = legacyPlist else { return nil }
        guard let cbCache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
        guard let entry = cbCache[uuid] as? NSDictionary else { return nil }
        let mac = entry["DeviceAddress"] as? String
        var name: String?
        // Name lookup traverses DeviceCache keyed by MAC.
        if let mac = mac,
           let devCache = plist["DeviceCache"] as? NSDictionary,
           let devEntry = devCache[mac] as? NSDictionary,
           let raw = devEntry["Name"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            name = trimmed.isEmpty ? nil : trimmed
        }
        guard name != nil || mac != nil else { return nil }
        return LEDeviceInfo(name: name, macAddr: mac)
    }

    // MARK: Helpers

    // Apple stores addresses as "Public XX:XX:..." or "Random XX:XX:...". The
    // second component is the MAC. Also accept bare "XX:XX:..." strings.
    private func parseMacAddress(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return raw
    }
}
