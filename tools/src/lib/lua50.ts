// Lua 5.0 (bytecode «\x1bLua» versión 0x50) de los scripts de juego de NFS MW PS2: messagehandler.bytecode de
// GAMEPLAY.BIN (Attrib::Blob comprimido con HUFF) [V]. Cabecera del disco: little endian, int/size_t/Instruction de
// 4 bytes, campos de instrucción OP=6 A=8 B=9 C=9 y lua_Number de 4 bytes (float) [V].
// Lee la función principal y sus funciones anidadas, y desensambla (sin descompilar) con nombres de registro y constantes.

export interface LuaFunc {
  source: string; line: number; nups: number; nparams: number; vararg: number; maxstack: number;
  code: number[]; consts: (string | number | boolean | null)[]; protos: LuaFunc[]; locals: string[]; upvalues: string[];
}

const OPS = ["MOVE", "LOADK", "LOADBOOL", "LOADNIL", "GETUPVAL", "GETGLOBAL", "GETTABLE", "SETGLOBAL", "SETUPVAL", "SETTABLE",
  "NEWTABLE", "SELF", "ADD", "SUB", "MUL", "DIV", "POW", "UNM", "NOT", "CONCAT", "JMP", "EQ", "LT", "LE", "TEST", "CALL",
  "TAILCALL", "RETURN", "FORLOOP", "TFORLOOP", "TFORPREP", "SETLIST", "SETLISTO", "CLOSE", "CLOSURE"];

export function parseLua50(buf: Uint8Array): LuaFunc {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  if (buf[0] !== 0x1b || String.fromCharCode(buf[1], buf[2], buf[3]) !== "Lua" || buf[4] !== 0x50) throw new Error("No es bytecode de Lua 5.0");
  const numSize = buf[13];
  let p = 14 + numSize;   // cabecera (14 B) + número de prueba
  const int = () => { const v = dv.getInt32(p, true); p += 4; return v; };
  const str = () => { const n = dv.getUint32(p, true); p += 4; if (n === 0) return ""; const s = new TextDecoder("latin1").decode(buf.subarray(p, p + n - 1)); p += n; return s; };
  const num = () => { const v = numSize === 4 ? dv.getFloat32(p, true) : dv.getFloat64(p, true); p += numSize; return +v.toPrecision(7); };
  const func = (parentSource: string): LuaFunc => {
    const source = str() || parentSource;
    const line = int(), nups = buf[p++], nparams = buf[p++], vararg = buf[p++], maxstack = buf[p++];
    const nli = int(); p += nli * 4;   // líneas
    const nloc = int(); const locals: string[] = [];
    for (let i = 0; i < nloc; i++) { locals.push(str()); p += 8; }
    const nupv = int(); const upvalues: string[] = []; for (let i = 0; i < nupv; i++) upvalues.push(str());
    const nk = int(); const consts: LuaFunc["consts"] = [];
    for (let i = 0; i < nk; i++) { const t = buf[p++]; consts.push(t === 3 ? num() : t === 4 ? str() : t === 1 ? buf[p++] !== 0 : null); }
    const np = int(); const protos: LuaFunc[] = []; for (let i = 0; i < np; i++) protos.push(func(source));
    const nc = int(); const code: number[] = []; for (let i = 0; i < nc; i++) code.push(int() >>> 0);
    return { source, line, nups, nparams, vararg, maxstack, code, consts, protos, locals, upvalues };
  };
  return func("?");
}

/** Desensamblado legible: «CALL R1 2 1  ; NIS_Play(…)»; las constantes van entre comillas. */
export function disasmLua50(f: LuaFunc, indent = ""): string {
  const K = (i: number) => JSON.stringify(f.consts[i]);
  const RK = (x: number) => x >= 250 ? K(x - 250) : `R${x}`;
  const out: string[] = [`${indent}function (params ${f.nparams}${f.vararg ? ", …" : ""}; ${f.code.length} instrucciones)`];
  f.code.forEach((ins, pc) => {
    const op = ins & 0x3f, c = (ins >>> 6) & 0x1ff, b = (ins >>> 15) & 0x1ff, a = ins >>> 24, bx = (ins >>> 6) & 0x3ffff, sbx = bx - 131071;
    const name = OPS[op] ?? `OP${op}`;
    let txt: string;
    switch (name) {
      case "LOADK": txt = `R${a} = ${K(bx)}`; break;
      case "GETGLOBAL": txt = `R${a} = ${f.consts[bx]}`; break;
      case "SETGLOBAL": txt = `${f.consts[bx]} = R${a}`; break;
      case "GETTABLE": txt = `R${a} = R${b}[${RK(c)}]`; break;
      case "SETTABLE": txt = `R${a}[${RK(b)}] = ${RK(c)}`; break;
      case "SELF": txt = `R${a + 1} = R${b}; R${a} = R${b}[${RK(c)}]`; break;
      case "MOVE": txt = `R${a} = R${b}`; break;
      case "LOADBOOL": txt = `R${a} = ${!!b}${c ? "; salta" : ""}`; break;
      case "LOADNIL": txt = `R${a}..R${b} = nil`; break;
      case "GETUPVAL": txt = `R${a} = U${b}`; break;
      case "CALL": case "TAILCALL": txt = `R${a}(${b ? `${b - 1} args` : "…"}) → ${c ? `${c - 1} res` : "…"}`; break;
      case "RETURN": txt = `return ${b ? `${b - 1} valores` : "…"}`; break;
      case "JMP": txt = `→ ${pc + 1 + sbx}`; break;
      case "EQ": case "LT": case "LE": txt = `si (${RK(b)} ${name === "EQ" ? "==" : name === "LT" ? "<" : "<="} ${RK(c)}) ~= ${a} salta`; break;
      case "TEST": txt = `si R${b} ~= ${c} salta; si no R${a} = R${b}`; break;
      case "ADD": case "SUB": case "MUL": case "DIV": txt = `R${a} = ${RK(b)} ${{ ADD: "+", SUB: "-", MUL: "*", DIV: "/" }[name]} ${RK(c)}`; break;
      case "NOT": txt = `R${a} = not R${b}`; break;
      case "CLOSURE": txt = `R${a} = función ${bx}`; break;
      default: txt = `A=${a} B=${b} C=${c}`;
    }
    out.push(`${indent}  ${String(pc).padStart(3)}  ${name.padEnd(9)} ${txt}`);
  });
  f.protos.forEach((q, i) => { out.push(`${indent}  -- función ${i}`); out.push(disasmLua50(q, indent + "    ")); });
  return out.join("\n");
}

/** Lectura simplificada: sigue los registros en el código lineal y escribe las llamadas y asignaciones como Lua
 *  («Game.SetTimer("fade", 2)»), con los saltos como «si … → pc». No es un descompilador completo (bucles y
 *  expresiones anidadas salen como registros), pero basta para leer los guiones de juego. */
export function pseudoLua50(f: LuaFunc, indent = ""): string {
  const K = (i: number) => { const k = f.consts[i]; return typeof k === "string" ? JSON.stringify(k) : String(k); };
  const R: string[] = [];
  const reg = (i: number) => R[i] ?? (i < f.nparams ? ["self", "msg", "state"][i] ?? `p${i}` : `r${i}`);
  const RK = (x: number) => x >= 250 ? K(x - 250) : reg(x);
  const field = (base: string, key: string) => /^"[A-Za-z_]\w*"$/.test(key) ? `${base}.${key.slice(1, -1)}` : `${base}[${key}]`;
  const out: string[] = [];
  f.code.forEach((ins, pc) => {
    const op = OPS[ins & 0x3f], c = (ins >>> 6) & 0x1ff, b = (ins >>> 15) & 0x1ff, a = ins >>> 24, bx = (ins >>> 6) & 0x3ffff, sbx = bx - 131071;
    const line = (s: string) => out.push(`${indent}${String(pc).padStart(3)}  ${s}`);
    switch (op) {
      case "MOVE": R[a] = reg(b); break;
      case "LOADK": R[a] = K(bx); break;
      case "LOADBOOL": R[a] = b ? "true" : "false"; break;
      case "LOADNIL": for (let i = a; i <= b; i++) R[i] = "nil"; break;
      case "GETUPVAL": R[a] = f.upvalues[b] ?? `up${b}`; break;
      case "GETGLOBAL": R[a] = String(f.consts[bx]); break;
      case "GETTABLE": R[a] = field(reg(b), RK(c)); break;
      case "SELF": { const o = reg(b); R[a + 1] = o; R[a] = `${o}:${String(RK(c)).replace(/"/g, "")}`; break; }
      case "SETGLOBAL": line(`${f.consts[bx]} = ${reg(a)}`); break;
      case "SETTABLE": line(`${field(reg(a), RK(b))} = ${RK(c)}`); break;
      case "NEWTABLE": R[a] = "{}"; break;
      case "ADD": case "SUB": case "MUL": case "DIV": R[a] = `(${RK(b)} ${{ ADD: "+", SUB: "-", MUL: "*", DIV: "/" }[op]} ${RK(c)})`; break;
      case "UNM": R[a] = `-${reg(b)}`; break;
      case "NOT": R[a] = `not ${reg(b)}`; break;
      case "CONCAT": R[a] = Array.from({ length: c - b + 1 }, (_, i) => reg(b + i)).join(" .. "); break;
      case "EQ": case "LT": case "LE": line(`si no (${RK(b)} ${op === "EQ" ? (a ? "~=" : "==") : op === "LT" ? (a ? ">=" : "<") : (a ? ">" : "<=")} ${RK(c)}) → ${pc + 2}`); break;
      case "TEST": line(`si ${c ? "no " : ""}${reg(b)} → ${pc + 2}`); R[a] = reg(b); break;
      case "JMP": line(`→ ${pc + 1 + sbx}`); break;
      case "CALL": case "TAILCALL": {
        const isSelf = reg(a).includes(":");
        const args = Array.from({ length: b ? b - 1 : 0 }, (_, i) => reg(a + 1 + i)).slice(isSelf ? 1 : 0);
        const call = `${reg(a)}(${args.join(", ")})`;
        if (c === 1) line(call); else { R[a] = call; if (c > 2) for (let i = 1; i < c - 1; i++) R[a + i] = `${call}[${i + 1}]`; }
        break;
      }
      case "RETURN": line(b > 1 ? `return ${Array.from({ length: b - 1 }, (_, i) => reg(a + i)).join(", ")}` : "return"); break;
      case "CLOSURE": R[a] = `función${bx}`; break;
      default: line(`${op} A=${a} B=${b} C=${c}`);
    }
  });
  f.protos.forEach((q, i) => { out.push(`${indent}-- función${i}(${["self", "msg", "state"].slice(0, q.nparams).join(", ")})`); out.push(pseudoLua50(q, indent + "    ")); });
  return out.join("\n");
}
