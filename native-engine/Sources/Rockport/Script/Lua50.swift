// Intérprete de Lua 5.0 para los guiones de juego del disco (doc 26 §6). El juego compila sus manejadores de mensajes a
// bytecode de Lua 5.0 [V: «\x1bLua» 0x50, GAMEPLAY.BIN → scripts.json]; aquí se ejecutan tal cual, sin reescribirlos.
// Formato del disco [V]: little endian, int / size_t / Instruction de 4 B, campos OP 6 · A 8 · B 9 · C 9, lua_Number float
// de 4 B. Semántica de cada instrucción: lvm.c de Lua 5.0.2 (MAXSTACK 250, RK ≥ 250 = constante, FPF 32).
// Lo que no usan los guiones (metatablas, corrutinas, TFORLOOP) no está: si aparece, error claro en vez de seguir mal.
import Foundation

final class LuaTable {
    var hash: [LuaKey: LuaValue] = [:]
    /// Nombre que falta (tabla Game y globales): devuelve un sustituto que avisa en vez de romper el guion.
    var missing: ((String) -> LuaValue)?
    init() {}
    subscript(_ k: String) -> LuaValue {
        get { hash[.str(k)] ?? .nil }
        set { if case .nil = newValue { hash[.str(k)] = nil } else { hash[.str(k)] = newValue } }
    }
    func get(_ k: LuaValue) -> LuaValue {
        if let key = k.key, let v = hash[key] { return v }
        if let m = missing, case .str(let s) = k { return m(s) }
        return .nil
    }
    func set(_ k: LuaValue, _ v: LuaValue) {
        guard let key = k.key else { return }
        if case .nil = v { hash[key] = nil } else { hash[key] = v }
    }
}

/// Clave de tabla: cadenas, números y booleanos por valor; tablas y funciones por identidad.
enum LuaKey: Hashable { case str(String), num(Double), bool(Bool), obj(ObjectIdentifier) }

typealias LuaNative = ([LuaValue]) throws -> [LuaValue]
final class LuaNativeBox { let name: String; let fn: LuaNative; init(_ name: String, _ fn: @escaping LuaNative) { self.name = name; self.fn = fn } }
final class LuaBox { var v: LuaValue; init(_ v: LuaValue) { self.v = v } }
final class LuaClosure { let proto: LuaProto; var upvals: [LuaBox]; init(_ p: LuaProto, _ u: [LuaBox]) { proto = p; upvals = u } }

enum LuaValue {
    case `nil`, bool(Bool), num(Double), str(String), table(LuaTable), closure(LuaClosure), native(LuaNativeBox)
    var truthy: Bool { switch self { case .nil: false; case .bool(let b): b; default: true } }
    var key: LuaKey? {
        switch self {
        case .nil: nil
        case .bool(let b): .bool(b)
        case .num(let n): .num(n)
        case .str(let s): .str(s)
        case .table(let t): .obj(ObjectIdentifier(t))
        case .closure(let c): .obj(ObjectIdentifier(c))
        case .native(let n): .obj(ObjectIdentifier(n))
        }
    }
    var number: Double? { if case .num(let n) = self { return n }; if case .str(let s) = self { return Double(s) }; return nil }
    var string: String? { if case .str(let s) = self { return s }; if case .num(let n) = self { return LuaValue.format(n) }; return nil }
    var table: LuaTable? { if case .table(let t) = self { return t }; return nil }
    static func format(_ n: Double) -> String { n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n) }
    /// Igualdad de Lua: por valor (nil, booleanos, números, cadenas) o por identidad (tablas, funciones).
    static func rawEqual(_ a: LuaValue, _ b: LuaValue) -> Bool {
        switch (a, b) {
        case (.nil, .nil): true
        case (.bool(let x), .bool(let y)): x == y
        case (.num(let x), .num(let y)): x == y
        case (.str(let x), .str(let y)): x == y
        default: a.key != nil && a.key == b.key
        }
    }
    var debug: String {
        switch self {
        case .nil: "nil"
        case .bool(let b): String(b)
        case .num(let n): LuaValue.format(n)
        case .str(let s): "\"\(s)\""
        case .table(let t): (t["Name"].string).map { "<\($0)>" } ?? "<tabla>"
        case .closure: "<función>"
        case .native(let n): "<\(n.name)>"
        }
    }
}

struct LuaError: Error, CustomStringConvertible { let description: String }

/// Función compilada (Proto de Lua 5.0).
final class LuaProto {
    var source = "", nups = 0, nparams = 0, vararg = false, maxstack = 0
    var code: [UInt32] = [], consts: [LuaValue] = [], protos: [LuaProto] = []
}

enum Lua50 {
    /// Lee un chunk binario de Lua 5.0 con la cabecera del disco.
    static func load(_ data: Data) throws -> LuaProto {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1b, b[1] == 0x4c, b[2] == 0x75, b[3] == 0x61, b[4] == 0x50 else { throw LuaError(description: "no es bytecode de Lua 5.0") }
        let numSize = Int(b[13])
        var p = 14 + numSize
        func need(_ n: Int) throws { if p + n > b.count { throw LuaError(description: "bytecode truncado") } }
        func int() throws -> Int { try need(4); let v = Int32(bitPattern: UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24); p += 4; return Int(v) }
        func u32() throws -> UInt32 { try need(4); let v = UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24; p += 4; return v }
        func str() throws -> String { let n = Int(try u32()); if n == 0 { return "" }; try need(n); let s = String(decoding: b[p..<(p + n - 1)], as: UTF8.self); p += n; return s }
        func num() throws -> Double {
            try need(numSize)
            defer { p += numSize }
            if numSize == 4 { return Double(Float(bitPattern: UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24)) }
            var bits: UInt64 = 0; for i in 0..<8 { bits |= UInt64(b[p + i]) << (8 * i) }; return Double(bitPattern: bits)
        }
        func fn(_ parent: String) throws -> LuaProto {
            let f = LuaProto()
            let s = try str(); f.source = s.isEmpty ? parent : s
            _ = try int()                                    // línea
            try need(4); f.nups = Int(b[p]); f.nparams = Int(b[p + 1]); f.vararg = b[p + 2] != 0; f.maxstack = Int(b[p + 3]); p += 4
            p += try int() * 4                               // líneas
            for _ in 0..<(try int()) { _ = try str(); p += 8 }   // variables locales
            for _ in 0..<(try int()) { _ = try str() }       // nombres de upvalues
            for _ in 0..<(try int()) {
                try need(1); let t = b[p]; p += 1
                switch t {
                case 0: f.consts.append(.nil)
                case 1: try need(1); f.consts.append(.bool(b[p] != 0)); p += 1
                case 3: f.consts.append(.num(try num()))
                case 4: f.consts.append(.str(try str()))
                default: throw LuaError(description: "constante de tipo \(t)")
                }
            }
            for _ in 0..<(try int()) { f.protos.append(try fn(f.source)) }
            for _ in 0..<(try int()) { f.code.append(try u32()) }
            return f
        }
        return try fn("?")
    }
}

/// Estado global y ejecución.
final class LuaVM {
    let globals = LuaTable()
    /// Tope de instrucciones por llamada (un guion no debería pasar de unos miles): evita colgar el juego.
    var budget = 200_000

    func register(_ name: String, in table: LuaTable? = nil, _ fn: @escaping LuaNative) {
        (table ?? globals)[name] = .native(LuaNativeBox(name, fn))
    }

    /// Ejecuta el chunk principal (define las funciones globales del guion).
    func run(_ proto: LuaProto) throws { _ = try call(.closure(LuaClosure(proto, [])), []) }

    func call(_ f: LuaValue, _ args: [LuaValue]) throws -> [LuaValue] {
        switch f {
        case .native(let n): return try n.fn(args)
        case .closure(let c): return try execute(c, args)
        default: throw LuaError(description: "llamada a un valor que no es función (\(f.debug))")
        }
    }

    private func arith(_ op: Int, _ a: LuaValue, _ b: LuaValue) throws -> LuaValue {
        guard let x = a.number, let y = b.number else { throw LuaError(description: "aritmética con \(a.debug) y \(b.debug)") }
        switch op {
        case 12: return .num(x + y)
        case 13: return .num(x - y)
        case 14: return .num(x * y)
        case 15: return .num(x / y)
        default: return .num(pow(x, y))
        }
    }

    private func less(_ a: LuaValue, _ b: LuaValue, orEqual: Bool) throws -> Bool {
        if case .num(let x) = a, case .num(let y) = b { return orEqual ? x <= y : x < y }
        if case .str(let x) = a, case .str(let y) = b { return orEqual ? x <= y : x < y }
        throw LuaError(description: "comparación de \(a.debug) con \(b.debug)")
    }

    private func execute(_ cl: LuaClosure, _ args: [LuaValue]) throws -> [LuaValue] {
        let f = cl.proto
        var R = [LuaValue](repeating: .nil, count: max(f.maxstack, 2) + 260)
        for i in 0..<min(f.nparams, args.count) { R[i] = args[i] }
        var top = f.nparams
        var pc = 0
        @inline(__always) func RK(_ x: Int) -> LuaValue { x >= 250 ? f.consts[x - 250] : R[x] }
        func K(_ i: Int) throws -> LuaValue { guard i < f.consts.count else { throw LuaError(description: "constante \(i) fuera de rango") }; return f.consts[i] }
        while pc < f.code.count {
            budget -= 1
            if budget < 0 { throw LuaError(description: "guion demasiado largo (¿bucle infinito?)") }
            let i = f.code[pc]; pc += 1
            let op = Int(i & 0x3f), c = Int((i >> 6) & 0x1ff), b = Int((i >> 15) & 0x1ff), a = Int(i >> 24)
            let bx = Int((i >> 6) & 0x3ffff), sbx = bx - 131071
            switch op {
            case 0: R[a] = R[b]                                                    // MOVE
            case 1: R[a] = try K(bx)                                               // LOADK
            case 2: R[a] = .bool(b != 0); if c != 0 { pc += 1 }                    // LOADBOOL
            case 3: for r in a...max(a, b) { R[r] = .nil }                          // LOADNIL
            case 4: R[a] = b < cl.upvals.count ? cl.upvals[b].v : .nil             // GETUPVAL
            case 5: R[a] = globals.get(try K(bx))                                  // GETGLOBAL
            case 6:                                                                // GETTABLE
                guard let t = R[b].table else { throw LuaError(description: "índice \(RK(c).debug) sobre \(R[b].debug)") }
                R[a] = t.get(RK(c))
            case 7: globals.set(try K(bx), R[a])                                   // SETGLOBAL
            case 8: if b < cl.upvals.count { cl.upvals[b].v = R[a] }               // SETUPVAL
            case 9:                                                                // SETTABLE
                guard let t = R[a].table else { throw LuaError(description: "asignación en \(R[a].debug)") }
                t.set(RK(b), RK(c))
            case 10: R[a] = .table(LuaTable())                                     // NEWTABLE
            case 11:                                                               // SELF
                let o = R[b]; R[a + 1] = o
                guard let t = o.table else { throw LuaError(description: "método \(RK(c).debug) sobre \(o.debug)") }
                R[a] = t.get(RK(c))
            case 12, 13, 14, 15, 16: R[a] = try arith(op, RK(b), RK(c))            // ADD SUB MUL DIV POW
            case 17: guard let n = R[b].number else { throw LuaError(description: "UNM") }; R[a] = .num(-n)
            case 18: R[a] = .bool(!R[b].truthy)                                    // NOT
            case 19:                                                               // CONCAT
                var s = ""; for r in b...c { guard let p = R[r].string else { throw LuaError(description: "concatenar \(R[r].debug)") }; s += p }
                R[a] = .str(s)
            case 20: pc += sbx                                                     // JMP
            case 21: if LuaValue.rawEqual(RK(b), RK(c)) != (a != 0) { pc += 1 }    // EQ
            case 22: if try less(RK(b), RK(c), orEqual: false) != (a != 0) { pc += 1 }   // LT
            case 23: if try less(RK(b), RK(c), orEqual: true) != (a != 0) { pc += 1 }    // LE
            case 24: if R[b].truthy == (c != 0) { R[a] = R[b] } else { pc += 1 }   // TEST
            case 25, 26:                                                           // CALL, TAILCALL
                let n = b != 0 ? b - 1 : top - a - 1
                let res = try call(R[a], Array(R[(a + 1)..<(a + 1 + max(0, n))]))
                if op == 26 { return res }
                if c != 0 { for k in 0..<(c - 1) { R[a + k] = k < res.count ? res[k] : .nil } }
                else { for (k, v) in res.enumerated() { R[a + k] = v }; top = a + res.count }
            case 27:                                                               // RETURN
                let n = b != 0 ? b - 1 : top - a
                return n > 0 ? Array(R[a..<(a + n)]) : []
            case 28:                                                               // FORLOOP
                guard let v = R[a].number, let lim = R[a + 1].number, let st = R[a + 2].number else { throw LuaError(description: "for sin números") }
                let nv = v + st; R[a] = .num(nv)
                if st > 0 ? nv <= lim : nv >= lim { pc += sbx }
            case 31, 32:                                                           // SETLIST, SETLISTO
                guard let t = R[a].table else { throw LuaError(description: "SETLIST") }
                let n = op == 32 ? top - a - 1 : (bx % 32) + 1
                let base = bx - bx % 32
                for k in 1...max(1, n) where k <= n { t.set(.num(Double(base + k)), R[a + k]) }
            case 33: break                                                         // CLOSE
            case 34:                                                               // CLOSURE
                let p = f.protos[bx]
                var ups: [LuaBox] = []
                for _ in 0..<p.nups {
                    let ins = f.code[pc]; pc += 1
                    let pb = Int((ins >> 15) & 0x1ff)
                    ups.append((ins & 0x3f) == 4 ? (pb < cl.upvals.count ? cl.upvals[pb] : LuaBox(.nil)) : LuaBox(R[pb]))
                }
                R[a] = .closure(LuaClosure(p, ups))
            default: throw LuaError(description: "instrucción \(op) no soportada")
            }
        }
        return []
    }
}
