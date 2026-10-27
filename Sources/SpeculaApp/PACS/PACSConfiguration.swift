import Foundation
import DICOMCore
import DICOMNet

/// Which peers the listener admits (RadiAnt "Accept connections").
enum AcceptConnections: Int, Codable, Identifiable {
    case definedHostsOnly = 0, localNetwork = 1, all = 2, thisComputer = 3
    var id: Int { rawValue }
    static let allCases: [AcceptConnections] = [.thisComputer, .definedHostsOnly, .localNetwork, .all]
    var title: String {
        switch self {
        case .thisComputer: return "This computer only"
        case .definedHostsOnly: return "Defined PACS hosts only"
        case .localNetwork: return "Local network"
        case .all: return "All IPs (local and Internet)"
        }
    }
}

enum WildcardMode: Int, Codable, CaseIterable, Identifiable {
    case none = 0, leading = 1, trailing = 2, both = 3
    var id: Int { rawValue }
    var title: String { ["None", "Leading", "Trailing", "Both"][rawValue] }
}

/// Specific Character Set used for queries.
enum QueryCharacterSet: String, Codable, CaseIterable, Identifiable {
    case automatic = "", latin1 = "ISO_IR 100", latin2 = "ISO_IR 101", cyrillic = "ISO_IR 144", greek = "ISO_IR 126", utf8 = "ISO_IR 192"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Default"
        case .latin1: return "Latin-1 (ISO_IR 100)"
        case .latin2: return "Latin-2 (ISO_IR 101)"
        case .cyrillic: return "Cyrillic (ISO_IR 144)"
        case .greek: return "Greek (ISO_IR 126)"
        case .utf8: return "Unicode UTF-8 (ISO_IR 192)"
        }
    }
    var encoding: String.Encoding {
        switch self {
        case .automatic, .utf8: return .utf8
        case .latin1: return .isoLatin1
        case .latin2: return .isoLatin2
        case .cyrillic: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatinCyrillic.rawValue)))
        case .greek: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatinGreek.rawValue)))
        }
    }
}

/// Saved search filters (RadiAnt "PACS search presets").
struct PACSSearchPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var datePreset: DatePreset
    var modalities: [String]
    var nodeIDs: [UUID]
}

/// PACS settings (mirrors RadiAnt pacs.xml and its advanced settings).
struct PACSConfiguration: Codable, Equatable {
    var aeTitle = "SPECULA"
    var listenerPort = 11112
    var nodes: [DICOMNode] = []
    var timeout = 30.0
    var queryTimeout = 30.0
    var maxActiveDownloads = 3
    var preferredTransferSyntax = ""
    var acceptAllContexts = false
    var retrieveProtocol = RetrieveProtocol.cMove
    var proposedTransferSyntaxes = ProposedTransferSyntaxes.all
    var acceptConnections = AcceptConnections.localNetwork
    var pauseListenerOnLock = false
    var characterSet = QueryCharacterSet.automatic
    var forceCharacterSet = false
    var wildcards = WildcardMode.trailing
    var spacesToCarets = true
    var nonASCIIToWildcards = false
    var importToLibrary = true
    var presets: [PACSSearchPreset] = []
    var selectedNodeIDs: [UUID] = []

    init() {}

    /// Missing keys keep their defaults, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PACSConfiguration()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        aeTitle = v(.aeTitle, d.aeTitle)
        listenerPort = v(.listenerPort, d.listenerPort)
        timeout = v(.timeout, d.timeout)
        queryTimeout = v(.queryTimeout, d.queryTimeout)
        maxActiveDownloads = v(.maxActiveDownloads, d.maxActiveDownloads)
        preferredTransferSyntax = v(.preferredTransferSyntax, d.preferredTransferSyntax)
        acceptAllContexts = v(.acceptAllContexts, d.acceptAllContexts)
        retrieveProtocol = v(.retrieveProtocol, d.retrieveProtocol)
        proposedTransferSyntaxes = v(.proposedTransferSyntaxes, d.proposedTransferSyntaxes)
        acceptConnections = v(.acceptConnections, d.acceptConnections)
        pauseListenerOnLock = v(.pauseListenerOnLock, d.pauseListenerOnLock)
        characterSet = v(.characterSet, d.characterSet)
        forceCharacterSet = v(.forceCharacterSet, d.forceCharacterSet)
        wildcards = v(.wildcards, d.wildcards)
        spacesToCarets = v(.spacesToCarets, d.spacesToCarets)
        nonASCIIToWildcards = v(.nonASCIIToWildcards, d.nonASCIIToWildcards)
        importToLibrary = v(.importToLibrary, d.importToLibrary)
        nodes = v(.nodes, d.nodes)
        presets = v(.presets, d.presets)
        selectedNodeIDs = v(.selectedNodeIDs, d.selectedNodeIDs)
    }

    static let key = "pacsConfiguration"

    static func load() -> PACSConfiguration {
        guard let d = UserDefaults.standard.data(forKey: key), let c = try? JSONDecoder().decode(PACSConfiguration.self, from: d) else { return PACSConfiguration() }
        return c
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }

    /// Transfer syntaxes offered in the "Preferred transfer syntax" picker.
    static let preferredChoices: [(String, String)] = [
        ("", "Default (first proposed)"),
        (TransferSyntax.explicitVRLittleEndian.uid, "Explicit VR Little Endian"),
        (TransferSyntax.implicitVRLittleEndian.uid, "Implicit VR Little Endian"),
        (TransferSyntax.jpegLosslessSV1.uid, "JPEG Lossless"),
        (TransferSyntax.jpegLSLossless.uid, "JPEG-LS Lossless"),
        (TransferSyntax.jpeg2000Lossless.uid, "JPEG 2000 Lossless"),
        (TransferSyntax.rleLossless.uid, "RLE Lossless"),
        (TransferSyntax.jpeg2000.uid, "JPEG 2000"),
        (TransferSyntax.jpegBaseline.uid, "JPEG Baseline"),
    ]

    func validate(node n: DICOMNode, ignoring id: UUID?) -> String? {
        if n.description.trimmingCharacters(in: .whitespaces).isEmpty { return "Please enter host description." }
        if n.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Please enter host address." }
        if !(1...65535).contains(n.port) { return "Please enter valid port." }
        if !Self.validAE(n.aeTitle) { return "Please enter valid AE title (1-16 characters)." }
        let others = nodes.filter { $0.id != id }
        if others.contains(where: { $0.host.lowercased() == n.host.lowercased() && $0.aeTitle == n.aeTitle }) { return "A host with the same IP address and AE title already exists." }
        if others.contains(where: { $0.description == n.description }) { return "A host with the same description already exists." }
        return nil
    }

    static func validAE(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (1...16).contains(t.count) && t.allSatisfy { $0.isASCII && $0 != "\\" && !$0.isNewline }
    }
}

/// Date filter presets of the PACS search (RadiAnt strings 20037-20061).
enum DatePreset: String, Codable, CaseIterable, Identifiable {
    case all = "All dates", todayAM = "Today before noon", todayPM = "Today after noon", today = "Today", yesterday = "Yesterday"
    case dayBeforeYesterday = "Day before yesterday", last30min = "Last 30 minutes", last1h = "Last 1 hour", last2h = "Last 2 hours"
    case last3h = "Last 3 hours", last6h = "Last 6 hours", last8h = "Last 8 hours", last12h = "Last 12 hours", last24h = "Last 24 hours"
    case last2d = "Last 2 days", lastWeek = "Last week", last2w = "Last 2 weeks", lastMonth = "Last month", last3m = "Last 3 months"
    case last6m = "Last 6 months", lastYear = "Last year", thisWeek = "This week", thisMonth = "This month", thisYear = "This year"
    case custom = "Custom date range"
    var id: String { rawValue }

    /// Menu groups, separated by dividers.
    static let groups: [[DatePreset]] = [
        [.all], [.todayAM, .todayPM, .today, .yesterday, .dayBeforeYesterday],
        [.last30min, .last1h, .last2h, .last3h, .last6h, .last8h, .last12h, .last24h],
        [.last2d, .lastWeek, .last2w, .lastMonth, .last3m, .last6m, .lastYear],
        [.thisWeek, .thisMonth, .thisYear], [.custom],
    ]

    /// The [from, to] interval, or nil for no date restriction.
    func interval(now: Date = Date(), custom: (Date, Date)? = nil) -> (Date, Date)? {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: now)
        let eod = cal.date(byAdding: DateComponents(day: 1, second: -1), to: sod)!
        func hours(_ h: Double) -> (Date, Date) { (now.addingTimeInterval(-h * 3600), now) }
        func days(_ d: Int) -> (Date, Date) { (cal.date(byAdding: .day, value: -d, to: sod)!, eod) }
        switch self {
        case .all: return nil
        case .todayAM: return (sod, sod.addingTimeInterval(12 * 3600 - 1))
        case .todayPM: return (sod.addingTimeInterval(12 * 3600), eod)
        case .today: return (sod, eod)
        case .yesterday: let y = cal.date(byAdding: .day, value: -1, to: sod)!; return (y, sod.addingTimeInterval(-1))
        case .dayBeforeYesterday: let y = cal.date(byAdding: .day, value: -2, to: sod)!; return (y, cal.date(byAdding: .day, value: -1, to: sod)!.addingTimeInterval(-1))
        case .last30min: return hours(0.5)
        case .last1h: return hours(1)
        case .last2h: return hours(2)
        case .last3h: return hours(3)
        case .last6h: return hours(6)
        case .last8h: return hours(8)
        case .last12h: return hours(12)
        case .last24h: return hours(24)
        case .last2d: return days(1)
        case .lastWeek: return days(6)
        case .last2w: return days(13)
        case .lastMonth: return (cal.date(byAdding: .month, value: -1, to: sod)!, eod)
        case .last3m: return (cal.date(byAdding: .month, value: -3, to: sod)!, eod)
        case .last6m: return (cal.date(byAdding: .month, value: -6, to: sod)!, eod)
        case .lastYear: return (cal.date(byAdding: .year, value: -1, to: sod)!, eod)
        case .thisWeek: return (cal.dateInterval(of: .weekOfYear, for: now)!.start, eod)
        case .thisMonth: return (cal.dateInterval(of: .month, for: now)!.start, eod)
        case .thisYear: return (cal.dateInterval(of: .year, for: now)!.start, eod)
        case .custom:
            guard let c = custom else { return nil }
            return (cal.startOfDay(for: min(c.0, c.1)), cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: max(c.0, c.1)))!)
        }
    }
}
