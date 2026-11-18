// Buscador M40 — buscador de archivos para todo el Mac (macOS 13+)
// Nota: sin @State/@Observable/#Preview: las Command Line Tools no traen el plugin de macros de SwiftUI.
import SwiftUI
import AppKit
import AVKit
import AVFoundation
import QuickLook
import QuickLookThumbnailing
import CoreServices
import Carbon.HIToolbox

// MARK: - Atajo global (⌘ + Espacio)

enum Atajo {
    static var ref: EventHotKeyRef?
    @discardableResult
    static func registrar() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Atajo.alternar() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D343042), id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
    static func campo(_ v: NSView) -> NSTextField? {
        if let t = v as? NSTextField, t.isEditable { return t }
        for s in v.subviews { if let r = campo(s) { return r } }
        return nil
    }
    static func alternar() {
        if NSApp.isActive, NSApp.keyWindow != nil { NSApp.hide(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeKey && $0.contentView != nil }) {
            w.makeKeyAndOrderFront(nil)
            if let c = w.contentView, let t = campo(c) { w.makeFirstResponder(t); t.selectText(nil) }
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}

// MARK: - Utilidades de bytes

enum F {
    static let dir: UInt8 = 1, muerto: UInt8 = 2, oculto: UInt8 = 4, sistema: UInt8 = 8, paquete: UInt8 = 16
}

@inline(__always) func minus(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }

func normalizarTexto(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}

/// Añade a `out` el nombre en minúsculas y sin tildes; devuelve cuántos bytes añadió.
func normalizarBytes(_ p: UnsafeBufferPointer<UInt8>, _ out: inout [UInt8]) -> Int {
    var ascii = true
    for b in p where b >= 0x80 { ascii = false; break }
    if ascii {
        for b in p { out.append(minus(b)) }
        return p.count
    }
    let u = Array(normalizarTexto(String(decoding: p, as: UTF8.self)).utf8)
    out.append(contentsOf: u)
    return u.count
}

/// Comodines * y ? sobre bytes; `pat` ya en minúsculas; `s` se compara sin distinguir mayúsculas ASCII.
func glob(_ pat: UnsafeBufferPointer<UInt8>, _ s: UnsafeBufferPointer<UInt8>) -> Bool {
    var p = 0, i = 0, star = -1, mark = 0
    while i < s.count {
        if p < pat.count && (pat[p] == 63 || pat[p] == minus(s[i])) { p += 1; i += 1 }
        else if p < pat.count && pat[p] == 42 { star = p; mark = i; p += 1 }
        else if star >= 0 { p = star + 1; mark += 1; i = mark }
        else { return false }
    }
    while p < pat.count && pat[p] == 42 { p += 1 }
    return p == pat.count
}

let categorias: [String: UInt8] = {
    var d: [String: UInt8] = [:]
    for e in ["wav", "mp3", "m4a", "ogg", "aif", "aiff", "flac", "aac", "wma", "opus"] { d[e] = 1 }
    for e in ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mts", "mxf", "wmv", "braw", "mpg"] { d[e] = 2 }
    for e in ["png", "jpg", "jpeg", "gif", "svg", "psd", "ai", "webp", "tif", "tiff", "heic", "cr2", "cr3", "arw", "nef", "dng", "raf", "bmp", "eps"] { d[e] = 3 }
    for e in ["pdf", "doc", "docx", "xls", "xlsx", "xlsm", "ppt", "pptx", "txt", "rtf", "csv", "pages", "numbers", "key", "md", "odt", "json", "xml", "html"] { d[e] = 4 }
    for e in ["zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "iso", "tgz", "bz2"] { d[e] = 5 }
    d["app"] = 6
    return d
}()

// MARK: - Exclusiones

struct Exclusiones {
    static let fijas = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/.vol"]
    static let defExcluir = """
    .DS_Store
    ._*
    ~$*
    *.tmp
    .Spotlight-V100
    .fseventsd
    .Trashes
    .DocumentRevisions-V100
    .TemporaryItems
    Caches
    node_modules
    .git
    /private/var/folders
    /private/var/vm
    /private/tmp
    """
    static let defNoEntrar = """
    *.app
    *.framework
    *.photoslibrary
    *.bundle
    *.plugin
    *.kext
    *.fcpbundle
    """
    var nombres: [[UInt8]] = []
    var rutas: [String] = []
    var paquetes: [[UInt8]] = []

    init(excluir: String, noEntrar: String) {
        for l in excluir.split(whereSeparator: \.isNewline) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("/") { rutas.append(t.hasSuffix("/") ? String(t.dropLast()) : t) }
            else { nombres.append(Array(normalizarTexto(t).utf8)) }
        }
        for l in noEntrar.split(whereSeparator: \.isNewline) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { paquetes.append(Array(normalizarTexto(t).utf8)) }
        }
    }

    func nombreExcluido(_ n: UnsafeBufferPointer<UInt8>) -> Bool {
        for p in nombres where p.withUnsafeBufferPointer({ glob($0, n) }) { return true }
        return false
    }
    func esPaquete(_ n: UnsafeBufferPointer<UInt8>) -> Bool {
        for p in paquetes where p.withUnsafeBufferPointer({ glob($0, n) }) { return true }
        return false
    }
    func rutaExcluida(_ r: String, raizEs: String) -> Bool {
        if raizEs == "/" { for f in Exclusiones.fijas where r == f || r.hasPrefix(f + "/") { return true } }
        for f in rutas where r == f || r.hasPrefix(f + "/") { return true }
        return false
    }
    /// Para eventos: ruta completa de un archivo cualquiera.
    func eventoExcluido(_ r: String) -> Bool {
        for f in rutas where r == f || r.hasPrefix(f + "/") { return true }
        if r.hasPrefix("/System/Volumes/") || r.hasPrefix("/dev/") { return true }
        for c in r.split(separator: "/") {
            var u = Array(c.utf8)
            if u.withUnsafeBufferPointer({ nombreExcluido($0) }) { return true }
            u.removeAll()
        }
        return false
    }
}

// MARK: - Índice

enum Orden { case nombre, ruta, tam, fecha }

struct Tok {
    var tipo: UInt8      // 0 contiene, 1 termina en, 2 comodín, 3 carpeta ancestro
    var bytes: [UInt8]
    var neg: Bool
}

struct Consulta {
    var toks: [Tok] = []
    var exts: [[UInt8]] = []
    var tipo = 0         // 0 todo, 1 carpetas, 2 audio, 3 video, 4 imagen, 5 documento, 6 comprimido, 7 app
    var ocultos = true
    var sistema = false
    var orden = Orden.nombre
    var asc = true
    var vacia: Bool { toks.isEmpty && exts.isEmpty && tipo == 0 }

    init(texto: String) {
        var partes: [String] = []
        var act = ""
        var comillas = false
        for ch in texto {
            if ch == "\"" { comillas.toggle(); continue }
            if ch == " " && !comillas { if !act.isEmpty { partes.append(act); act = "" }; continue }
            act.append(ch)
        }
        if !act.isEmpty { partes.append(act) }
        for var p in partes {
            var neg = false
            if p.hasPrefix("!") && p.count > 1 { neg = true; p.removeFirst() }
            let n = normalizarTexto(p)
            if n.hasPrefix("ext:") {
                for e in n.dropFirst(4).split(separator: ";") where !e.isEmpty { exts.append(Array(("." + String(e)).utf8)) }
                continue
            }
            if n.contains("/") {
                let s = n.replacingOccurrences(of: "/", with: "")
                if !s.isEmpty { toks.append(Tok(tipo: 3, bytes: Array(s.utf8), neg: neg)) }
            } else if n.contains("*") || n.contains("?") {
                toks.append(Tok(tipo: 2, bytes: Array(n.utf8), neg: neg))
            } else if n.hasPrefix(".") && n.count > 1 {
                toks.append(Tok(tipo: 1, bytes: Array(n.utf8), neg: neg))
            } else {
                toks.append(Tok(tipo: 0, bytes: Array(n.utf8), neg: neg))
            }
        }
    }
}

final class Indice {
    var parent = [Int32](), nOff = [UInt32](), nLen = [UInt16](), gOff = [UInt32](), gLen = [UInt16]()
    var tam = [Int64](), fecha = [Int32](), flags = [UInt8](), cat = [UInt8]()
    var blob = [UInt8](), norm = [UInt8]()
    var dirs = [UInt64: Int32]()
    var count: Int { parent.count }

    static func clave(_ par: Int32, _ n: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for b in n { h = (h ^ UInt64(b)) &* 1099511628211 }
        h ^= UInt64(UInt32(bitPattern: par)) &* 0x9E3779B97F4A7C15
        return h &* 1099511628211
    }

    @discardableResult
    func add(_ par: Int32, _ name: UnsafeBufferPointer<UInt8>, _ size: Int64, _ mt: Int32, _ fl: UInt8) -> Int32 {
        let i = Int32(parent.count)
        parent.append(par)
        nOff.append(UInt32(blob.count))
        nLen.append(UInt16(min(name.count, 60000)))
        blob.append(contentsOf: name)
        let g0 = norm.count
        gOff.append(UInt32(g0))
        let l = normalizarBytes(name, &norm)
        gLen.append(UInt16(min(l, 60000)))
        tam.append(size)
        fecha.append(mt)
        flags.append(fl)
        var c: UInt8 = 0
        if fl & F.dir == 0 || fl & F.paquete != 0 {
            var k = g0 + l - 1
            let lim = max(g0, g0 + l - 12)
            while k > lim && norm[k] != 46 { k -= 1 }
            if k > g0 && norm[k] == 46 {
                c = categorias[String(decoding: norm[(k + 1)..<(g0 + l)], as: UTF8.self)] ?? 0
            }
        }
        cat.append(c)
        if fl & F.dir != 0 { dirs[Indice.clave(par, name)] = i }
        return i
    }

    func nombre(_ i: Int) -> String {
        let o = Int(nOff[i])
        return String(decoding: blob[o..<(o + Int(nLen[i]))], as: UTF8.self)
    }

    func ruta(_ i: Int, _ cache: inout [Int32: String]) -> String {
        if i < 0 { return "" }
        if let c = cache[Int32(i)] { return c }
        let p = Int(parent[i])
        let n = nombre(i)
        let r: String
        if p < 0 { r = n } else {
            let pp = ruta(p, &cache)
            r = pp == "/" ? "/" + n : pp + "/" + n
        }
        if flags[i] & F.dir != 0 { cache[Int32(i)] = r }
        return r
    }

    /// Índice de una carpeta por su ruta completa.
    func buscarDir(_ ruta: String, raices: [(Int32, String)]) -> Int32? {
        var mejor: (Int32, String)? = nil
        for r in raices where ruta == r.1 || ruta.hasPrefix(r.1 == "/" ? "/" : r.1 + "/") {
            if mejor == nil || r.1.count > mejor!.1.count { mejor = r }
        }
        guard let (ri, rp) = mejor else { return nil }
        var cur = ri
        let resto = ruta.dropFirst(rp.count)
        for c in resto.split(separator: "/") {
            let u = Array(c.utf8)
            guard let s = u.withUnsafeBufferPointer({ dirs[Indice.clave(cur, $0)] }), flags[Int(s)] & F.muerto == 0 else { return nil }
            cur = s
        }
        return flags[Int(cur)] & F.muerto == 0 ? cur : nil
    }

    func propagarMuertos() {
        for i in 0..<count {
            let p = Int(parent[i])
            if p >= 0 && flags[p] & F.muerto != 0 { flags[i] |= F.muerto }
        }
    }

    func vivos() -> Int {
        var n = 0
        for f in flags where f & F.muerto == 0 { n += 1 }
        return n
    }

    func fusionar(_ o: Indice) {
        let base = Int32(count), bb = UInt32(blob.count), gb = UInt32(norm.count)
        parent.append(contentsOf: o.parent.map { $0 < 0 ? $0 : $0 + base })
        nOff.append(contentsOf: o.nOff.map { $0 + bb })
        nLen.append(contentsOf: o.nLen)
        gOff.append(contentsOf: o.gOff.map { $0 + gb })
        gLen.append(contentsOf: o.gLen)
        tam.append(contentsOf: o.tam)
        fecha.append(contentsOf: o.fecha)
        flags.append(contentsOf: o.flags)
        cat.append(contentsOf: o.cat)
        blob.append(contentsOf: o.blob)
        norm.append(contentsOf: o.norm)
        reconstruirDirs(desde: Int(base))
    }

    func reconstruirDirs(desde: Int) {
        blob.withUnsafeBufferPointer { bp in
            for i in desde..<count where flags[i] & F.dir != 0 && flags[i] & F.muerto == 0 {
                let o = Int(nOff[i])
                dirs[Indice.clave(parent[i], UnsafeBufferPointer(rebasing: bp[o..<(o + Int(nLen[i]))]))] = Int32(i)
            }
        }
    }

    // MARK: búsqueda

    func buscar(_ q: Consulta) -> [Int32] {
        let n = count
        if n == 0 || q.vacia { return [] }
        // copias en memoria propia para no tocar arrays Swift en el bucle caliente
        struct TP { var tipo: UInt8; var p: UnsafeMutablePointer<UInt8>; var n: Int; var neg: Bool; var anc: Int }
        var tps: [TP] = []
        var ancs: [[Bool]] = []
        for t in q.toks {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, t.bytes.count))
            for (k, b) in t.bytes.enumerated() { p[k] = b }
            var a = -1
            if t.tipo == 3 { ancs.append(ancestros(p, t.bytes.count)); a = ancs.count - 1 }
            tps.append(TP(tipo: t.tipo, p: p, n: t.bytes.count, neg: t.neg, anc: a))
        }
        var eps: [(UnsafeMutablePointer<UInt8>, Int)] = []
        for e in q.exts {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, e.count))
            for (k, b) in e.enumerated() { p[k] = b }
            eps.append((p, e.count))
        }
        defer {
            for t in tps { t.p.deallocate() }
            for e in eps { e.0.deallocate() }
        }
        let partes = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let paso = (n + partes - 1) / partes
        var trozos = [[Int32]](repeating: [], count: partes)
        let cerrojo = NSLock()
        let tipo = q.tipo, ocultos = q.ocultos, sistema = q.sistema
        norm.withUnsafeBufferPointer { np in
        gOff.withUnsafeBufferPointer { go in
        gLen.withUnsafeBufferPointer { gl in
        flags.withUnsafeBufferPointer { fl in
        cat.withUnsafeBufferPointer { ct in
            DispatchQueue.concurrentPerform(iterations: partes) { k in
                var loc = [Int32]()
                let a = k * paso, b = min(n, a + paso)
                if a < b {
                    for i in a..<b {
                        let f = fl[i]
                        if f & F.muerto != 0 { continue }
                        if !ocultos && f & F.oculto != 0 { continue }
                        if !sistema && f & F.sistema != 0 { continue }
                        if tipo == 1 { if f & F.dir == 0 { continue } }
                        else if tipo > 1 { if ct[i] != UInt8(tipo - 1) { continue } }
                        let s0 = np.baseAddress! + Int(go[i])
                        let sn = Int(gl[i])
                        var ok = true
                        for t in tps {
                            var m: Bool
                            switch t.tipo {
                            case 0: m = memmem(s0, sn, t.p, t.n) != nil
                            case 1:
                                // .ext: la extensión del nombre empieza por lo escrito (".pd" encuentra ".pdf")
                                var k = sn - 1
                                while k >= 0 && s0[k] != 46 { k -= 1 }
                                m = k >= 0 && sn - k >= t.n && memcmp(s0 + k, t.p, t.n) == 0
                            case 2: m = glob(UnsafeBufferPointer(start: t.p, count: t.n), UnsafeBufferPointer(start: s0, count: sn))
                            default: m = ancs[t.anc][i]
                            }
                            if m == t.neg { ok = false; break }
                        }
                        if ok && !eps.isEmpty {
                            ok = false
                            for e in eps where sn >= e.1 && memcmp(s0 + (sn - e.1), e.0, e.1) == 0 { ok = true; break }
                        }
                        if ok { loc.append(Int32(i)) }
                    }
                }
                cerrojo.lock(); trozos[k] = loc; cerrojo.unlock()
            }
        }}}}}
        var res = trozos.flatMap { $0 }
        if res.count <= 300_000 { ordenar(&res, q.orden, q.asc) }
        return res
    }

    /// a[i] = el propio elemento (si es carpeta) o alguna carpeta ancestro contiene el texto.
    func ancestros(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) -> [Bool] {
        var a = [Bool](repeating: false, count: count)
        norm.withUnsafeBufferPointer { np in
            for i in 0..<count {
                let par = Int(parent[i])
                var m = par >= 0 && a[par]
                if !m && flags[i] & F.dir != 0 {
                    m = memmem(np.baseAddress! + Int(gOff[i]), Int(gLen[i]), p, n) != nil
                }
                a[i] = m
            }
        }
        return a
    }

    func ordenar(_ r: inout [Int32], _ o: Orden, _ asc: Bool) {
        switch o {
        case .tam:
            r.sort { asc ? tam[Int($0)] < tam[Int($1)] : tam[Int($0)] > tam[Int($1)] }
        case .fecha:
            r.sort { asc ? fecha[Int($0)] < fecha[Int($1)] : fecha[Int($0)] > fecha[Int($1)] }
        case .nombre:
            norm.withUnsafeBufferPointer { np in
                r.sort { x, y in
                    let a = Int(x), b = Int(y)
                    let la = Int(gLen[a]), lb = Int(gLen[b])
                    let c = memcmp(np.baseAddress! + Int(gOff[a]), np.baseAddress! + Int(gOff[b]), min(la, lb))
                    let menor = c != 0 ? c < 0 : la < lb
                    return asc ? menor : !menor && !(c == 0 && la == lb)
                }
            }
        case .ruta:
            var cache: [Int32: String] = [:]
            var claves: [Int32: String] = [:]
            for i in r { claves[i] = ruta(Int(parent[Int(i)]), &cache) }
            r.sort { x, y in
                let a = claves[x] ?? "", b = claves[y] ?? ""
                return asc ? a < b : a > b
            }
        }
    }

    // MARK: caché en disco

    func guardar(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        func w<T>(_ a: [T]) { a.withUnsafeBytes { if let b = $0.baseAddress { fh.write(Data(bytes: b, count: $0.count)) } } }
        w([0x4D343042_55534331, UInt64(count), UInt64(blob.count), UInt64(norm.count)] as [UInt64])
        w(parent); w(nOff); w(nLen); w(gOff); w(gLen); w(tam); w(fecha); w(flags); w(cat); w(blob); w(norm)
        try? fh.close()
    }

    static func cargar(_ url: URL) -> Indice? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count >= 32 else { return nil }
        let ix = Indice()
        var bien = true
        d.withUnsafeBytes { raw in
            var cab = [UInt64](repeating: 0, count: 4)
            memcpy(&cab, raw.baseAddress!, 32)
            guard cab[0] == 0x4D343042_55534331 else { bien = false; return }
            let n = Int(cab[1]), nb = Int(cab[2]), ng = Int(cab[3])
            var off = 32
            func r<T>(_ c: Int) -> [T] {
                let bytes = c * MemoryLayout<T>.stride
                if off + bytes > raw.count { bien = false; return [] }
                let a = [T](unsafeUninitializedCapacity: c) { buf, k in
                    if c > 0 { memcpy(buf.baseAddress!, raw.baseAddress! + off, bytes) }
                    k = c
                }
                off += bytes
                return a
            }
            ix.parent = r(n); ix.nOff = r(n); ix.nLen = r(n); ix.gOff = r(n); ix.gLen = r(n)
            ix.tam = r(n); ix.fecha = r(n); ix.flags = r(n); ix.cat = r(n); ix.blob = r(nb); ix.norm = r(ng)
        }
        if !bien { return nil }
        ix.reconstruirDirs(desde: 0)
        return ix
    }
}

// MARK: - Motor (escaneo, eventos, búsqueda)

struct Fila: Identifiable, Hashable {
    let id: Int32
    let nombre: String
    let carpeta: String
    let tam: Int64
    let fecha: Date
    let dir: Bool
    var ruta: String { carpeta.isEmpty ? nombre : (carpeta == "/" ? "/" + nombre : carpeta + "/" + nombre) }
    var url: URL { URL(fileURLWithPath: ruta) }
}

final class Motor {
    let iq = DispatchQueue(label: "m40.indice", qos: .userInitiated)
    let sq = DispatchQueue(label: "m40.escaneo", qos: .utility)
    var ix = Indice()
    var raices: [(Int32, String)] = []
    var excl = Exclusiones(excluir: Exclusiones.defExcluir, noEntrar: Exclusiones.defNoEntrar)
    var gen = 0
    var escaneando = false
    var pendientes: [String] = []
    var stream: FSEventStreamRef?
    var alCambiar: (() -> Void)?
    var alEstado: ((String, Int) -> Void)?
    static let sistemaTop: Set<String> = ["System", "usr", "bin", "sbin", "private", "cores", "opt", "etc", "var", "tmp"]

    var archivoCache: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BuscadorM40")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("indice.bin")
    }

    func estado(_ t: String, _ n: Int) { DispatchQueue.main.async { self.alEstado?(t, n) } }

    static func volumenes() -> [String] {
        var r = ["/"]
        let vs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? []
        for v in vs where v.path.hasPrefix("/Volumes/") {
            if (try? v.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false { continue }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: v.path)) != nil { continue }
            r.append(v.path)
        }
        return r
    }

    func calcularRaices(_ i: Indice) -> [(Int32, String)] {
        var r: [(Int32, String)] = []
        for k in 0..<i.count where i.parent[k] < 0 && i.flags[k] & F.muerto == 0 { r.append((Int32(k), i.nombre(k))) }
        return r
    }

    func arrancar() {
        iq.async { [self] in
            if let c = Indice.cargar(archivoCache) {
                ix = c
                raices = calcularRaices(c)
                estado("Índice anterior cargado; actualizando…", c.vivos())
                DispatchQueue.main.async { self.alCambiar?() }
            }
            iniciarEventos()
            reindexar()
        }
    }

    /// Recorre todo de nuevo en segundo plano y reemplaza el índice al terminar. Llamar en iq.
    func reindexar() {
        if escaneando { return }
        escaneando = true
        pendientes = []
        let ex = excl
        sq.async { [self] in
            let nuevo = Indice()
            let t0 = Date()
            for v in Motor.volumenes() {
                escanear(nuevo, ruta: v, padre: -1, nombreRaiz: Array(v.utf8), ex)
            }
            let seg = Int(Date().timeIntervalSince(t0))
            iq.async { [self] in
                ix = nuevo
                raices = calcularRaices(nuevo)
                escaneando = false
                let p = pendientes
                pendientes = []
                if !p.isEmpty { aplicar(p) }
                nuevo.guardar(archivoCache)
                estado("Índice al día (recorrido en \(seg) s)", nuevo.vivos())
                DispatchQueue.main.async { self.alCambiar?() }
            }
        }
    }

    /// Recorre `ruta` y añade todo a `i`. `padre` = -1 para una raíz.
    func escanear(_ i: Indice, ruta: String, padre: Int32, nombreRaiz: [UInt8], _ ex: Exclusiones) {
        guard let cp = strdup(ruta) else { return }
        defer { free(cp) }
        let argv: [UnsafeMutablePointer<CChar>?] = [cp, nil]
        guard let f = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(f) }
        let offNombre = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
        let raizEs = padre < 0 ? ruta : "/"
        let heredado: UInt8 = padre >= 0 ? (i.flags[Int(padre)] & (F.oculto | F.sistema)) : 0
        var cuenta = 0
        while let e = fts_read(f) {
            let info = Int32(e.pointee.fts_info)
            let nivel = Int(e.pointee.fts_level)
            let esDir = info == FTS_D
            if !(esDir || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT) { continue }
            let nb: UnsafeBufferPointer<UInt8>
            if nivel == 0 { nb = UnsafeBufferPointer(start: nil, count: 0) } else {
                let np = UnsafeRawPointer(e).advanced(by: offNombre).assumingMemoryBound(to: UInt8.self)
                nb = UnsafeBufferPointer(start: np, count: Int(e.pointee.fts_namelen))
            }
            let st = e.pointee.fts_statp.pointee
            let par: Int32 = nivel == 0 ? padre : Int32(truncatingIfNeeded: e.pointee.fts_parent.pointee.fts_number)
            var fl: UInt8 = nivel == 0 ? heredado : (i.flags[Int(par)] & (F.oculto | F.sistema))
            if nivel > 0 {
                if ex.nombreExcluido(nb) { if esDir { fts_set(f, e, FTS_SKIP) }; continue }
                if nb.count > 0 && nb[0] == 46 { fl |= F.oculto }
            }
            if st.st_flags & UInt32(UF_HIDDEN) != 0 && nivel > 0 { fl |= F.oculto }
            let mt = Int32(truncatingIfNeeded: st.st_mtimespec.tv_sec)
            if esDir {
                fl |= F.dir
                if nivel > 0 {
                    let r = String(cString: e.pointee.fts_path)
                    if ex.rutaExcluida(r, raizEs: raizEs) { fts_set(f, e, FTS_SKIP); continue }
                    if nivel == 1 && padre < 0 && ruta == "/" && Motor.sistemaTop.contains(String(decoding: nb, as: UTF8.self)) { fl |= F.sistema }
                    if ex.esPaquete(nb) { fl |= F.paquete; fts_set(f, e, FTS_SKIP) }
                }
                let idx: Int32
                if nivel == 0 { idx = nombreRaiz.withUnsafeBufferPointer { i.add(par, $0, 0, mt, fl) } }
                else { idx = i.add(par, nb, 0, mt, fl) }
                e.pointee.fts_number = Int(idx)
            } else {
                if nivel == 0 { nombreRaiz.withUnsafeBufferPointer { _ = i.add(par, $0, Int64(st.st_size), mt, fl) } }
                else { i.add(par, nb, Int64(st.st_size), mt, fl) }
            }
            cuenta += 1
            if padre < 0 && cuenta % 50_000 == 0 { estado("Indexando \(ruta)…", i.count) }
        }
    }

    // MARK: eventos en tiempo real

    func iniciarEventos() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let yo = Unmanaged<Motor>.fromOpaque(info).takeUnretainedValue()
            if let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] { yo.eventos(arr) }
        }
        let fl = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, ["/"] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, fl) else { return }
        FSEventStreamSetDispatchQueue(s, iq)
        FSEventStreamStart(s)
        stream = s
    }

    /// Llega en iq.
    func eventos(_ rutas: [String]) {
        if escaneando { if pendientes.count < 200_000 { pendientes.append(contentsOf: rutas) } }
        if aplicar(rutas) { DispatchQueue.main.async { self.alCambiar?() } }
    }

    @discardableResult
    func aplicar(_ rutas: [String]) -> Bool {
        var carpetas = Set<String>()
        for var r in rutas {
            if r.hasPrefix("/System/Volumes/Data/") { r = String(r.dropFirst("/System/Volumes/Data".count)) }
            if r.count > 1 && r.hasSuffix("/") { r.removeLast() }
            if excl.eventoExcluido(r) { continue }
            let p = (r as NSString).deletingLastPathComponent
            if !p.isEmpty { carpetas.insert(p) }
        }
        if carpetas.isEmpty { return false }
        var objetivo: [Int32: String] = [:]
        for c in carpetas { if let i = ix.buscarDir(c, raices: raices) { objetivo[i] = c } }
        if objetivo.isEmpty { return false }
        var marca = [Bool](repeating: false, count: ix.count)
        for k in objetivo.keys { marca[Int(k)] = true }
        var hijos: [Int32: [Int32]] = [:]
        for i in 0..<ix.count {
            let p = Int(ix.parent[i])
            if p >= 0 && marca[p] && ix.flags[i] & F.muerto == 0 { hijos[Int32(p), default: []].append(Int32(i)) }
        }
        var hayMuertos = false
        var cambio = false
        for (d, dp) in objetivo {
            if ix.flags[Int(d)] & F.paquete != 0 { continue }
            guard let nombres = try? FileManager.default.contentsOfDirectory(atPath: dp) else { continue }
            var existentes: [String: Int32] = [:]
            for h in hijos[d] ?? [] { existentes[ix.nombre(Int(h))] = h }
            let heredado = ix.flags[Int(d)] & (F.oculto | F.sistema)
            for n in nombres {
                let completo = dp == "/" ? "/" + n : dp + "/" + n
                var st = stat()
                if lstat(completo, &st) != 0 { continue }
                let esDir = (st.st_mode & S_IFMT) == S_IFDIR
                let mt = Int32(truncatingIfNeeded: st.st_mtimespec.tv_sec)
                if let e = existentes.removeValue(forKey: n) {
                    let k = Int(e)
                    if !esDir && (ix.tam[k] != Int64(st.st_size) || ix.fecha[k] != mt) {
                        ix.tam[k] = Int64(st.st_size); ix.fecha[k] = mt; cambio = true
                    }
                    continue
                }
                let u = Array(n.utf8)
                if u.withUnsafeBufferPointer({ excl.nombreExcluido($0) }) { continue }
                cambio = true
                if esDir {
                    if excl.rutaExcluida(completo, raizEs: "/") { continue }
                    if u.withUnsafeBufferPointer({ excl.esPaquete($0) }) {
                        var fl = heredado | F.dir | F.paquete
                        if u.first == 46 || st.st_flags & UInt32(UF_HIDDEN) != 0 { fl |= F.oculto }
                        u.withUnsafeBufferPointer { _ = ix.add(d, $0, 0, mt, fl) }
                    } else {
                        let antes = ix.count
                        escanear(ix, ruta: completo, padre: d, nombreRaiz: u, excl)
                        if ix.count > antes && (u.first == 46 || st.st_flags & UInt32(UF_HIDDEN) != 0) {
                            for k in antes..<ix.count { ix.flags[k] |= F.oculto }
                        }
                    }
                } else {
                    var fl = heredado
                    if u.first == 46 || st.st_flags & UInt32(UF_HIDDEN) != 0 { fl |= F.oculto }
                    u.withUnsafeBufferPointer { _ = ix.add(d, $0, Int64(st.st_size), mt, fl) }
                }
            }
            for (_, e) in existentes { ix.flags[Int(e)] |= F.muerto; hayMuertos = true; cambio = true }
        }
        if hayMuertos { ix.propagarMuertos() }
        return cambio
    }

    func volumenMontado(_ ruta: String) {
        let ex = excl
        sq.async { [self] in
            let tmp = Indice()
            estado("Indexando \(ruta)…", 0)
            escanear(tmp, ruta: ruta, padre: -1, nombreRaiz: Array(ruta.utf8), ex)
            iq.async { [self] in
                if raices.contains(where: { $0.1 == ruta }) { return }
                ix.fusionar(tmp)
                raices = calcularRaices(ix)
                estado("Disco añadido: \(ruta)", ix.vivos())
                DispatchQueue.main.async { self.alCambiar?() }
            }
        }
    }

    func volumenDesmontado(_ ruta: String) {
        iq.async { [self] in
            guard let r = raices.first(where: { $0.1 == ruta }) else { return }
            ix.flags[Int(r.0)] |= F.muerto
            ix.propagarMuertos()
            raices = calcularRaices(ix)
            estado("Disco retirado: \(ruta)", ix.vivos())
            DispatchQueue.main.async { self.alCambiar?() }
        }
    }

    func buscar(_ q: Consulta, _ g: Int, _ listo: @escaping (Int, [Fila], Int) -> Void) {
        gen = g
        iq.async { [self] in
            if g != gen { return }
            let ids = ix.buscar(q)
            var cache: [Int32: String] = [:]
            var filas: [Fila] = []
            filas.reserveCapacity(min(ids.count, 3000))
            for id in ids.prefix(3000) {
                let k = Int(id)
                filas.append(Fila(id: id, nombre: ix.nombre(k), carpeta: ix.ruta(Int(ix.parent[k]), &cache), tam: ix.tam[k],
                                  fecha: Date(timeIntervalSince1970: TimeInterval(ix.fecha[k])), dir: ix.flags[k] & F.dir != 0))
            }
            let total = ids.count
            DispatchQueue.main.async { listo(g, filas, total) }
        }
    }

    func guardarAhora() { iq.sync { if !escaneando && ix.count > 0 { ix.guardar(archivoCache) } } }
}

// MARK: - Modelo de la ventana

final class Caja<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}

final class Modelo: ObservableObject {
    let motor = Motor()
    @Published var query = "" { didSet { buscar() } }
    @Published var tipo = 0 { didSet { buscar() } }
    @Published var ocultos = UserDefaults.standard.object(forKey: "ocultos") as? Bool ?? true { didSet { UserDefaults.standard.set(ocultos, forKey: "ocultos"); buscar() } }
    @Published var sistema = UserDefaults.standard.bool(forKey: "sistema") { didSet { UserDefaults.standard.set(sistema, forKey: "sistema"); buscar() } }
    @Published var orden: [KeyPathComparator<Fila>] = [KeyPathComparator(\Fila.nombre)] { didSet { buscar() } }
    @Published var filas: [Fila] = []
    @Published var total = 0
    @Published var sel = Set<Int32>()
    @Published var estado = "Preparando…"
    @Published var indexados = 0
    @Published var ql: URL?
    @Published var ajustes = false
    @Published var confirmar = false
    @Published var exclTxt = UserDefaults.standard.string(forKey: "excluir") ?? Exclusiones.defExcluir
    @Published var paqTxt = UserDefaults.standard.string(forKey: "noEntrar") ?? Exclusiones.defNoEntrar
    @Published var alInicio = FileManager.default.fileExists(atPath: Modelo.agente.path)
    var aBorrar: [Fila] = []
    var gen = 0
    var ultimoRefresco = Date.distantPast
    var refrescoPendiente = false

    static var agente: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/co.m40producciones.buscador.plist")
    }

    init() {
        motor.excl = Exclusiones(excluir: exclTxt, noEntrar: paqTxt)
        motor.alEstado = { [weak self] t, n in self?.estado = t; self?.indexados = n }
        motor.alCambiar = { [weak self] in self?.refrescar() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            if let u = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.motor.volumenMontado(u.path) }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            if let u = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.motor.volumenDesmontado(u.path) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.motor.guardarAhora()
        }
        if !Atajo.registrar() { estado = "No se pudo registrar ⌘ + Espacio (otra app lo está usando)" }
        motor.arrancar()
    }

    /// Los cambios del disco llegan a ráfagas: como mucho un refresco cada 2 s.
    func refrescar() {
        let espera = 2.0 - Date().timeIntervalSince(ultimoRefresco)
        if espera <= 0 { ultimoRefresco = Date(); buscar() }
        else if !refrescoPendiente {
            refrescoPendiente = true
            DispatchQueue.main.asyncAfter(deadline: .now() + espera) { [weak self] in
                self?.refrescoPendiente = false
                self?.ultimoRefresco = Date()
                self?.buscar()
            }
        }
    }

    func buscar() {
        gen += 1
        var q = Consulta(texto: query)
        q.tipo = tipo
        q.ocultos = ocultos
        q.sistema = sistema
        if let c = orden.first {
            q.asc = c.order == .forward
            if c.keyPath == (\Fila.carpeta as PartialKeyPath<Fila>) { q.orden = .ruta }
            else if c.keyPath == (\Fila.tam as PartialKeyPath<Fila>) { q.orden = .tam }
            else if c.keyPath == (\Fila.fecha as PartialKeyPath<Fila>) { q.orden = .fecha }
            else { q.orden = .nombre }
        }
        if q.vacia { filas = []; total = 0; return }
        motor.buscar(q, gen) { [weak self] g, f, t in
            guard let self, g == self.gen else { return }
            self.filas = f
            self.total = t
            let ids = Set(f.map { $0.id })
            if !self.sel.isSubset(of: ids) { self.sel = self.sel.intersection(ids) }
        }
    }

    func elegidas(_ ids: Set<Int32>) -> [Fila] { filas.filter { ids.contains($0.id) } }

    func abrir(_ ids: Set<Int32>) { for f in elegidas(ids).prefix(20) { NSWorkspace.shared.open(f.url) } }
    func mostrar(_ ids: Set<Int32>) {
        let u = elegidas(ids).prefix(50).map { $0.url }
        if !u.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(u)) }
    }
    func copiar(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    func pedirBorrado(_ ids: Set<Int32>) {
        aBorrar = elegidas(ids)
        if !aBorrar.isEmpty { confirmar = true }
    }
    func borrar() {
        var fallos = 0
        var rutas: [String] = []
        for f in aBorrar {
            do { try FileManager.default.trashItem(at: f.url, resultingItemURL: nil); rutas.append(f.ruta) } catch { fallos += 1 }
        }
        aBorrar = []
        if fallos > 0 { estado = "No se pudieron mover \(fallos) elemento(s) a la papelera (protegidos o sin permiso)" }
        if !rutas.isEmpty { motor.iq.async { self.motor.eventos(rutas) } }
    }

    func aplicarAjustes() {
        UserDefaults.standard.set(exclTxt, forKey: "excluir")
        UserDefaults.standard.set(paqTxt, forKey: "noEntrar")
        let e = Exclusiones(excluir: exclTxt, noEntrar: paqTxt)
        motor.iq.async { self.motor.excl = e; self.motor.reindexar() }
    }

    func ponerAlInicio(_ si: Bool) {
        let a = Modelo.agente
        if si {
            let d: [String: Any] = ["Label": "co.m40producciones.buscador", "RunAtLoad": true,
                                    "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath]]
            try? FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
            (d as NSDictionary).write(to: a, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: a)
        }
        alInicio = FileManager.default.fileExists(atPath: a.path)
    }
}

// MARK: - Vistas

enum Miniaturas {
    static let cache = NSCache<NSString, NSImage>()
    static func pedir(_ url: URL, lado: CGFloat, _ listo: @escaping (NSImage?) -> Void) {
        let k = url.path as NSString
        if let i = cache.object(forKey: k) { listo(i); return }
        let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: lado, height: lado), scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: r) { rep, _ in
            let img = rep?.nsImage
            if let img { cache.setObject(img, forKey: k) }
            DispatchQueue.main.async { listo(img) }
        }
    }
}

struct Miniatura: View {
    let url: URL
    @StateObject private var img = Caja<NSImage?>(nil)
    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let i = img.v { Image(nsImage: i).resizable().scaledToFit() }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 96, height: 96) }
        }
        .onAppear {
            let c = img
            Miniaturas.pedir(url, lado: 640) { c.v = $0 }
        }
    }
}

struct Reproductor: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.player = player
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

let fmtFecha: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

func fmtTam(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

struct Panel: View {
    @EnvironmentObject var m: Modelo
    let f: Fila
    @StateObject private var player = Caja<AVPlayer?>(nil)

    var esMedio: Bool {
        let c = categorias[f.url.pathExtension.lowercased()] ?? 0
        return !f.dir && (c == 1 || c == 2)
    }

    var contenido: some View {
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: f.ruta)) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(items.count) elementos dentro").font(.caption.bold())
            ForEach(Array(items.prefix(11)), id: \.self) { n in
                Text(n).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            if items.count > 11 { Text("…").font(.caption).foregroundColor(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.05))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if esMedio, let p = player.v { Reproductor(player: p) } else if f.dir && f.url.pathExtension.isEmpty { contenido } else { Miniatura(url: f.url) }
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(f.nombre).font(.headline).textSelection(.enabled)
                Text(f.carpeta).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text((f.dir ? "Carpeta" : fmtTam(f.tam)) + "  ·  " + fmtFecha.string(from: f.fecha)).font(.caption)
                HStack {
                    Button("Abrir") { m.abrir([f.id]) }
                    Button("Mostrar en Finder") { m.mostrar([f.id]) }
                }
                HStack {
                    Button("Copiar ruta") { m.copiar(f.ruta) }
                    Button("Vista rápida") { m.ql = f.url }
                }
                Button("Mover a la papelera") { m.pedirBorrado([f.id]) }
            }
            .padding(12)
        }
        .onAppear {
            if esMedio {
                let p = AVPlayer(url: f.url)
                player.v = p
                p.play()
            }
        }
        .onDisappear { player.v?.pause() }
    }
}

struct Ajustes: View {
    @EnvironmentObject var m: Modelo
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ajustes").font(.title3.bold())
            Toggle("Abrir al iniciar sesión", isOn: Binding(get: { m.alInicio }, set: { m.ponerAlInicio($0) }))
            Text("No indexar (uno por línea; admite * y ?; las líneas que empiezan por / son carpetas completas)").font(.caption)
            TextEditor(text: $m.exclTxt).font(.system(.body, design: .monospaced)).frame(height: 170).border(Color.white.opacity(0.15))
            Text("Mostrar pero no entrar (paquetes como apps y bibliotecas)").font(.caption)
            TextEditor(text: $m.paqTxt).font(.system(.body, design: .monospaced)).frame(height: 100).border(Color.white.opacity(0.15))
            HStack {
                Button("Guardar y volver a indexar") { m.aplicarAjustes(); m.ajustes = false }
                Button("Restaurar valores") { m.exclTxt = Exclusiones.defExcluir; m.paqTxt = Exclusiones.defNoEntrar }
                Spacer()
                Button("Acceso total al disco…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
                }
                Button("Cerrar") { m.ajustes = false }
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}

struct Principal: View {
    @EnvironmentObject var m: Modelo
    static let tipos = ["Todo", "Carpetas", "Audio", "Video", "Imagen", "Documento", "Comprimido", "App"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Buscar en todo el Mac: letras, .ext, comodines *  ?, !excluir, carpeta/", text: $m.query)
                        .textFieldStyle(.plain).font(.title3)
                    if !m.query.isEmpty {
                        Button { m.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    Button { m.ajustes = true } label: { Image(systemName: "gearshape") }.help("Ajustes")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                HStack(spacing: 6) {
                    ForEach(0..<Principal.tipos.count, id: \.self) { k in
                        Button { m.tipo = k } label: {
                            Text(Principal.tipos[k]).font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(m.tipo == k ? Color.accentColor : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Toggle("Ocultos", isOn: $m.ocultos).toggleStyle(.checkbox)
                    Toggle("Sistema", isOn: $m.sistema).toggleStyle(.checkbox)
                }
            }
            .padding(10)
            Divider()
            HStack(spacing: 0) {
                tabla
                Divider()
                Group {
                    if let id = m.sel.first, m.sel.count == 1, let f = m.filas.first(where: { $0.id == id }) {
                        Panel(f: f).id(f.ruta)
                    } else {
                        Text(m.sel.count > 1 ? "\(m.sel.count) elementos seleccionados" : "Selecciona un resultado")
                            .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 320)
            }
            Divider()
            HStack {
                Text(m.total > m.filas.count ? "Mostrando \(m.filas.count) de \(m.total) resultados" : "\(m.total) resultados")
                Spacer()
                Text("\(m.indexados) elementos indexados  ·  \(m.estado)").lineLimit(1)
            }
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .sheet(isPresented: $m.ajustes) { Ajustes().environmentObject(m) }
        .quickLookPreview($m.ql)
        .alert("¿Mover \(m.aBorrar.count) elemento(s) a la papelera?", isPresented: $m.confirmar) {
            Button("Mover a la papelera", role: .destructive) { m.borrar() }
            Button("Cancelar", role: .cancel) { m.aBorrar = [] }
        } message: {
            Text(m.aBorrar.prefix(5).map { $0.nombre }.joined(separator: "\n"))
        }
    }

    var tabla: some View {
        Table(of: Fila.self, selection: $m.sel, sortOrder: $m.orden) {
            TableColumn("Nombre", value: \.nombre) { f in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.ruta)).resizable().frame(width: 16, height: 16)
                    Text(f.nombre).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Ruta", value: \.carpeta) { f in
                Text(f.carpeta).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 160, ideal: 360)
            TableColumn("Tamaño", value: \.tam) { f in
                Text(f.dir ? "—" : fmtTam(f.tam)).foregroundColor(.secondary)
            }
            .width(80)
            TableColumn("Modificado", value: \.fecha) { f in
                Text(fmtFecha.string(from: f.fecha)).foregroundColor(.secondary)
            }
            .width(150)
        } rows: {
            ForEach(m.filas) { f in
                TableRow(f).itemProvider { NSItemProvider(object: f.url as NSURL) }
            }
        }
        .contextMenu(forSelectionType: Int32.self) { ids in
            if !ids.isEmpty {
                Button("Abrir") { m.abrir(ids) }
                Button("Mostrar en Finder") { m.mostrar(ids) }
                Button("Vista rápida") { m.ql = m.elegidas(ids).first?.url }
                Divider()
                Button("Copiar ruta") { m.copiar(m.elegidas(ids).map { $0.ruta }.joined(separator: "\n")) }
                Button("Copiar nombre") { m.copiar(m.elegidas(ids).map { $0.nombre }.joined(separator: "\n")) }
                Divider()
                Button("Mover a la papelera") { m.pedirBorrado(ids) }
            }
        } primaryAction: { ids in
            m.abrir(ids)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main
struct BuscadorApp: App {
    @StateObject private var m = Modelo()
    var body: some Scene {
        WindowGroup("Buscador M40") {
            Principal()
                .environmentObject(m)
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandMenu("Resultado") {
                Button("Vista rápida") { m.ql = m.elegidas(m.sel).first?.url }.keyboardShortcut("y")
                Button("Mostrar en Finder") { m.mostrar(m.sel) }.keyboardShortcut(.return, modifiers: .command)
                Button("Copiar ruta") { m.copiar(m.elegidas(m.sel).map { $0.ruta }.joined(separator: "\n")) }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Mover a la papelera") { m.pedirBorrado(m.sel) }.keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}
