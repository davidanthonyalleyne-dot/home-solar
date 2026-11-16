import SwiftUI
import UniformTypeIdentifiers

// Settings, Export data: the data behind Solar as an Excel workbook (or CSV), for a date range,
// by day or by month, with the groups of columns you pick. Made on the device from the same
// decrypted data the screens use; nothing is sent anywhere until you share or save the file.

struct ExportOptions {
    enum Range: String, CaseIterable, Identifiable { case thisMonth = "This month", lastMonth = "Last month", thisYear = "This year",
                                                          lastYear = "Last year", last12 = "Last 12 months", all = "Everything", custom = "Custom"
        var id: String { rawValue } }
    enum By: String, CaseIterable, Identifiable { case day = "Day", month = "Month"; var id: String { rawValue } }
    enum Format: String, CaseIterable, Identifiable { case xlsx = "Excel", csv = "CSV"; var id: String { rawValue } }

    var range: Range = .thisYear
    var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var to = Date()
    var by: By = .day
    var format: Format = .xlsx
    var solar = true, grid = true, money = true, weather = false, heating = false
}

/// One column: its heading, how wide, whether it's a date, and its value for a row key (a day or a month)
private struct Col {
    let name: String
    var width: Double = 14
    var decimals = 1
    let value: (String) -> Any?
}

enum Exporter {
    /// "2026-11" moved by n months
    static func shift(_ ym: String, _ n: Int) -> String {
        let y = Int(ym.prefix(4)) ?? 2026, m = Int(ym.suffix(2)) ?? 1
        let t = y * 12 + (m - 1) + n
        return String(format: "%04d-%02d", t / 12, t % 12 + 1)
    }
    static func span(_ o: ExportOptions, db: SolarDB) -> (String, String) {
        let today = SK.day(Date()), ym = String(today.prefix(7)), y = Int(today.prefix(4)) ?? 2026
        let lastYm = Exporter.shift(ym, -1)
        switch o.range {
        case .thisMonth: return (ym + "-01", today)
        case .lastMonth: return (lastYm + "-01", "\(lastYm)-\(String(format: "%02d", MonthMath.daysIn(lastYm)))")
        case .thisYear: return ("\(y)-01-01", today)
        case .lastYear: return ("\(y - 1)-01-01", "\(y - 1)-12-31")
        case .last12: return (Exporter.shift(ym, -11) + "-01", today)
        case .all: return (db.months.first.map { $0 + "-01" } ?? "2023-01-01", today)
        case .custom:
            let a = SK.day(min(o.from, o.to)), b = SK.day(max(o.from, o.to))
            return (a, b)
        }
    }

    private static func days(_ a: String, _ b: String) -> [String] {
        guard var t = SK.date(a), let end = SK.date(b) else { return [] }
        var out: [String] = []
        var cal = Calendar(identifier: .gregorian); cal.timeZone = SolarConfig.tz
        while t <= end, out.count < 5000 { out.append(SK.day(t)); t = cal.date(byAdding: .day, value: 1, to: t)! }
        return out
    }

    /// The sheets: name, columns, row keys
    private static func sheets(_ o: ExportOptions, db: SolarDB) -> [(String, [Col], [String])] {
        let (a, b) = span(o, db: db)
        let ds = days(a, b)
        var dayCache: [String: SolarDB.Day] = [:]
        for m in Set(ds.map { String($0.prefix(7)) }) { for r in db.monthDays(m) { dayCache[r.d] = r } }
        var clim: [String: ClimDay] = [:]
        if o.heating { for y in db.climYears { for c in db.climateData(y).days { clim[c.d] = c } } }

        if o.by == .day {
            var cols = [Col(name: "Date", width: 12) { $0 }]
            if o.solar { cols.append(Col(name: "Solar generated (kWh)", width: 20) { dayCache[$0]?.prod }) }
            if o.grid {
                cols += [Col(name: "Bought from the grid (kWh)", width: 24) { dayCache[$0]?.imp },
                         Col(name: "Sent to the grid (kWh)", width: 21) { dayCache[$0]?.exp },
                         Col(name: "Solar used at home (kWh)", width: 23) { dayCache[$0]?.selfUse },
                         Col(name: "Home used in total (kWh)", width: 23) { dayCache[$0]?.home }]
            }
            if o.weather {
                cols += [Col(name: "High (°C)", width: 10) { db.w($0, 0) }, Col(name: "Low (°C)", width: 10) { db.w($0, 1) },
                         Col(name: "Conditions", width: 18) { d in db.w(d, 2).map { describe(iInt($0)) } },
                         Col(name: "Sunshine (h)", width: 12) { db.w($0, 3) },
                         Col(name: "Sunlight (MJ/m²)", width: 16, decimals: 2) { db.w($0, 4) },
                         Col(name: "Snow (cm)", width: 10) { db.w($0, 5) }]
            }
            if o.heating {
                cols += [Col(name: "Heat pump (h)", width: 13) { clim[$0]?.heat }, Col(name: "Backup heat (h)", width: 15) { clim[$0]?.aux },
                         Col(name: "Cooling (h)", width: 11) { clim[$0]?.cool }, Col(name: "Thermostat set (°C)", width: 18) { clim[$0]?.set },
                         Col(name: "Indoor (°C)", width: 11) { clim[$0]?.inside }, Col(name: "Outdoor (°C)", width: 12) { clim[$0]?.out }]
            }
            var out: [(String, [Col], [String])] = [("Days", cols, ds)]
            if o.money { out.append(("Months", moneyCols(db), monthsIn(ds))) }
            return out
        }

        // by month: daily figures added up, money from the bills
        let ms = monthsIn(ds)
        func sum(_ m: String, _ f: (String) -> Double?) -> Double? {
            let v = ds.filter { $0.hasPrefix(m) }.compactMap(f)
            return v.isEmpty ? nil : v.reduce(0, +)
        }
        func avg(_ m: String, _ f: (String) -> Double?) -> Double? {
            let v = ds.filter { $0.hasPrefix(m) }.compactMap(f)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        var cols = [Col(name: "Month", width: 10) { $0 }]
        if o.solar { cols.append(Col(name: "Solar generated (kWh)", width: 20) { m in sum(m) { dayCache[$0]?.prod } }) }
        if o.grid {
            cols += [Col(name: "Bought from the grid (kWh)", width: 24) { m in sum(m) { dayCache[$0]?.imp } },
                     Col(name: "Sent to the grid (kWh)", width: 21) { m in sum(m) { dayCache[$0]?.exp } },
                     Col(name: "Solar used at home (kWh)", width: 23) { m in sum(m) { dayCache[$0]?.selfUse } },
                     Col(name: "Home used in total (kWh)", width: 23) { m in sum(m) { dayCache[$0]?.home } }]
        }
        if o.money { cols += Array(moneyCols(db).dropFirst()) }
        if o.weather {
            cols += [Col(name: "Average high (°C)", width: 16) { m in avg(m) { db.w($0, 0) } },
                     Col(name: "Average low (°C)", width: 16) { m in avg(m) { db.w($0, 1) } },
                     Col(name: "Sunshine (h)", width: 12, decimals: 0) { m in sum(m) { db.w($0, 3) } },
                     Col(name: "Snow (cm)", width: 10) { m in sum(m) { db.w($0, 5) } }]
        }
        if o.heating {
            cols += [Col(name: "Heat pump (h)", width: 13, decimals: 0) { m in sum(m) { clim[$0]?.heat } },
                     Col(name: "Backup heat (h)", width: 15, decimals: 0) { m in sum(m) { clim[$0]?.aux } },
                     Col(name: "Cooling (h)", width: 11, decimals: 0) { m in sum(m) { clim[$0]?.cool } },
                     Col(name: "Average outdoor (°C)", width: 19) { m in avg(m) { clim[$0]?.out } }]
        }
        return [("Months", cols, ms)]
    }

    private static func monthsIn(_ ds: [String]) -> [String] {
        var seen = Set<String>(); return ds.map { String($0.prefix(7)) }.filter { seen.insert($0).inserted }
    }

    private static func moneyCols(_ db: SolarDB) -> [Col] {
        [Col(name: "Month", width: 10) { $0 },
         Col(name: "Paid to Toronto Hydro ($)", width: 23, decimals: 2) { db.num($0, "grid") },
         Col(name: "Saved by solar ($)", width: 17, decimals: 2) { db.num($0, "saved") },
         Col(name: "Without solar ($)", width: 16, decimals: 2) { db.num($0, "without") },
         Col(name: "Credits for power sent back ($)", width: 28, decimals: 2) { db.num($0, "credits") },
         Col(name: "Price per kWh bought ($)", width: 22, decimals: 4) { db.num($0, "buyRate") },
         Col(name: "From", width: 10) { m in (db.money[m]?["gridSource"] as? String).map { $0 == "bill" ? "Bill" : "Estimate" } }]
    }

    /// Writes the file to a temporary folder and returns its address, with how many rows went in.
    static func make(_ o: ExportOptions, db: SolarDB) throws -> (URL, Int) {
        let sh = sheets(o, db: db)
        let (a, b) = span(o, db: db)
        let name = "Solar \(a) to \(b)" + (o.by == .month ? " by month" : "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = sh.first?.2.count ?? 0
        if o.format == .csv {
            let (_, cols, keys) = sh[0]
            var lines = [cols.map { csv($0.name) }.joined(separator: ",")]
            for k in keys { lines.append(cols.map { csv(text($0.value(k), $0.decimals)) }.joined(separator: ",")) }
            let url = dir.appendingPathComponent(name + ".csv")
            try (lines.joined(separator: "\r\n") + "\r\n").data(using: .utf8)!.write(to: url)
            return (url, rows)
        }
        let url = dir.appendingPathComponent(name + ".xlsx")
        try XLSX.workbook(sh.map { s in (s.0, s.1.map { ($0.name, $0.width, $0.decimals) },
                                         s.2.map { k in s.1.map { $0.value(k) } }) }).write(to: url)
        return (url, rows)
    }

    private static func text(_ v: Any?, _ dec: Int) -> String {
        switch v {
        case let d as Double: return String(format: "%.\(dec)f", d)
        case let s as String: return s
        case nil: return ""
        default: return "\(v!)"
        }
    }
    private static func csv(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

// MARK: - A small .xlsx writer

/// An Excel workbook is a zip of XML files. This writes the few it needs: one sheet per table,
/// a bold frozen header row, real dates, and numbers kept as numbers.
enum XLSX {
    static func workbook(_ sheets: [(name: String, cols: [(String, Double, Int)], rows: [[Any?]])]) -> Data {
        var files: [(String, Data)] = []
        let x = { (s: String) in Data(s.utf8) }
        files.append(("[Content_Types].xml", x("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())</Types>
        """)))
        files.append(("_rels/.rels", x("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)))
        files.append(("xl/workbook.xml", x("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheets.enumerated().map { "<sheet name=\"\(esc($1.name))\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined())</sheets></workbook>
        """)))
        files.append(("xl/_rels/workbook.xml.rels", x("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())<Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)))
        // styles: 0 plain, 1 bold header, 2 date, 3..6 numbers with 0, 1, 2, 4 decimals
        files.append(("xl/styles.xml", x("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="4"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="0.0"/><numFmt numFmtId="166" formatCode="0.00"/><numFmt numFmtId="167" formatCode="0.0000"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"><alignment wrapText="1" vertical="top"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs></styleSheet>
        """)))
        for (i, s) in sheets.enumerated() {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
            xml += "<cols>" + s.cols.enumerated().map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\($1.1)\" customWidth=\"1\"/>" }.joined() + "</cols><sheetData>"
            xml += "<row r=\"1\">" + s.cols.enumerated().map { "<c r=\"\(ref($0, 1))\" t=\"inlineStr\" s=\"1\"><is><t>\(esc($1.0))</t></is></c>" }.joined() + "</row>"
            for (r, row) in s.rows.enumerated() {
                xml += "<row r=\"\(r + 2)\">"
                for (c, v) in row.enumerated() {
                    let at = ref(c, r + 2)
                    switch v {
                    case let d as Double where d.isFinite:
                        let style = [0: 3, 1: 4, 2: 5, 4: 6][s.cols[c].2] ?? 4
                        xml += "<c r=\"\(at)\" s=\"\(style)\"><v>\(d)</v></c>"
                    case let t as String:
                        if let serial = serial(t) { xml += "<c r=\"\(at)\" s=\"2\"><v>\(serial)</v></c>" }
                        else { xml += "<c r=\"\(at)\" t=\"inlineStr\"><is><t>\(esc(t))</t></is></c>" }
                    default: break
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            files.append(("xl/worksheets/sheet\(i + 1).xml", Data(xml.utf8)))
        }
        return Zip.store(files)
    }

    /// "2026-11-15" as an Excel date number (days since 1899-12-30); months ("2026-11") stay text
    private static func serial(_ s: String) -> Int? {
        guard s.count == 10, let n = SK.dayNum(s), let base = SK.dayNum("1899-12-30") else { return nil }
        return n - base
    }
    private static func ref(_ col: Int, _ row: Int) -> String {
        var c = col, s = ""
        repeat { s = String(UnicodeScalar(65 + c % 26)!) + s; c = c / 26 - 1 } while c >= 0
        return s + "\(row)"
    }
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A zip with stored (uncompressed) entries, which is all Excel needs
enum Zip {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
    static func store(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), off = UInt32(out.count)
            u32(0x04034b50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out); u16(n.count, &out); u16(0, &out)
            out.append(n); out.append(data)
            u32(0x02014b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central); u16(0, &central); u16(0x21, &central)
            u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central); u16(n.count, &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(off, &central)
            central.append(n)
        }
        let cdOff = UInt32(out.count)
        out.append(central)
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(cdOff, &out); u16(0, &out)
        return out
    }
}

// MARK: - The page

struct ExportPage: View {
    let json: [String: Any]
    @State private var o = ExportOptions()
    @State private var file: URL?
    @State private var rows = 0
    @State private var err: String?

    var body: some View {
        let db = SolarDB(json)
        Section {
            Picker("Dates", selection: $o.range) { ForEach(ExportOptions.Range.allCases) { Text($0.rawValue).tag($0) } }
            if o.range == .custom {
                DatePicker("From", selection: $o.from, displayedComponents: .date)
                DatePicker("To", selection: $o.to, displayedComponents: .date)
            }
            Picker("One row per", selection: $o.by) { ForEach(ExportOptions.By.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
        } header: { Text("Range") } footer: {
            let (a, b) = Exporter.span(o, db: db)
            Text("\(MonthMath.date(a, "MMM d, yyyy")) to \(MonthMath.date(b, "MMM d, yyyy"))")
        }
        Section {
            Toggle("Solar generated", isOn: $o.solar)
            Toggle("Grid: bought, sent back, used at home", isOn: $o.grid)
            Toggle("Bills and savings", isOn: $o.money)
            Toggle("Weather", isOn: $o.weather)
            Toggle("Heating and cooling", isOn: $o.heating).disabled(!db.hasClimate)
        } header: { Text("Columns") } footer: {
            Text(o.by == .day && o.money ? "Bills are monthly, so with one row per day they go on a second sheet." : "Heating needs the ecobee files added in Settings.")
        }
        .tint(SK.sunColor)
        Section {
            Picker("Format", selection: $o.format) { ForEach(ExportOptions.Format.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            Button("Make the spreadsheet") { make(db) }
            if let file {
                ShareLink(item: file) {
                    Label("Share or save \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            if let err { Text(err).foregroundStyle(.red) }
            else if file != nil { Text("\(rows) rows. Save to Files, AirDrop it, or open it in Excel or Numbers.") }
            else { Text("Made here on the \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"); it isn't sent anywhere until you share it.") }
        }
        .onChange(of: o.range) { _, _ in file = nil }
        .onChange(of: o.by) { _, _ in file = nil }
        .onChange(of: o.format) { _, _ in file = nil }
    }

    func make(_ db: SolarDB) {
        err = nil; file = nil
        do { let (url, n) = try Exporter.make(o, db: db); file = url; rows = n }
        catch { err = "Couldn't make it: \(error.localizedDescription)" }
    }
}
