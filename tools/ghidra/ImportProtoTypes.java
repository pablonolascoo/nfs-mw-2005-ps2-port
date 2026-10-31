// Importa las estructuras fiables del prototipo (TSV de tools/src/cli/ghidra-types.ts) y tipa «this» en los métodos de
// esas clases, para que el pseudocódigo diga mRaceBin en vez de *(param_1 + 0x18). Las no fiables no se tocan (doc 26 §5).
// Uso: -postScript ImportProtoTypes.java <proto-types.tsv>
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.HighFunctionDBUtil;
import ghidra.program.model.symbol.SourceType;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

public class ImportProtoTypes extends GhidraScript {
  static class F { int off; String type, name; }
  static class S { String name; int size; boolean ok; List<F> fields = new ArrayList<>(); List<F> bases = new ArrayList<>(); Set<String> statics = new HashSet<>(); }

  DataTypeManager dtm;
  CategoryPath cat = new CategoryPath("/NFSMW_proto");
  Map<String, Structure> made = new HashMap<>();

  DataType prim(String t) {
    switch (t) {
      case "int": case "long int": case "signed int": return IntegerDataType.dataType;
      case "unsigned int": case "long unsigned int": case "unsigned long": return UnsignedIntegerDataType.dataType;
      case "short int": case "short": return ShortDataType.dataType;
      case "short unsigned int": case "unsigned short": return UnsignedShortDataType.dataType;
      case "char": case "signed char": return CharDataType.dataType;
      case "unsigned char": return UnsignedCharDataType.dataType;
      case "bool": return BooleanDataType.dataType;
      case "float": return FloatDataType.dataType;
      case "double": return DoubleDataType.dataType;
      case "long long int": return LongLongDataType.dataType;
      case "long long unsigned int": return UnsignedLongLongDataType.dataType;
      case "void": return VoidDataType.dataType;
    }
    return null;
  }

  /** "GRaceBin*" / "float[10][16]" / "const char*" → tipo de Ghidra, o null si no se conoce con seguridad. */
  DataType resolve(String t) {
    t = t.replace("const ", "").replace("volatile ", "").trim();
    List<Integer> dims = new ArrayList<>();
    Matcher m = Pattern.compile("\\[(\\d+)\\]").matcher(t); while (m.find()) dims.add(Integer.parseInt(m.group(1)));
    t = t.replaceAll("\\[\\d+\\]", "").trim();
    int stars = 0; while (t.endsWith("*")) { stars++; t = t.substring(0, t.length() - 1).trim(); }
    DataType base = prim(t); if (base == null) base = made.get(t);
    DataType dt;
    if (stars > 0) { dt = base != null ? base : VoidDataType.dataType; for (int i = 0; i < stars; i++) dt = new PointerDataType(dt, 4, dtm); }
    else if (base == null || base instanceof VoidDataType) return null;
    else dt = base;
    for (int i = dims.size() - 1; i >= 0; i--) dt = new ArrayDataType(dt, dims.get(i), dt.getLength(), dtm);
    return dt;
  }

  @Override public void run() throws Exception {
    dtm = currentProgram.getDataTypeManager();
    Map<String, S> all = new LinkedHashMap<>(); S cur = null;
    for (String line : Files.readAllLines(Paths.get(getScriptArgs()[0]))) {
      String[] p = line.split("\t");
      switch (p[0]) {
        case "S": cur = new S(); cur.name = p[1]; cur.size = Integer.parseInt(p[2]); cur.ok = p[3].equals("1"); all.put(cur.name, cur); break;
        case "F": case "B": { F f = new F(); f.off = Integer.parseInt(p[1]); f.type = p[2]; f.name = p.length > 3 ? p[3] : "base_" + p[2]; (p[0].equals("F") ? cur.fields : cur.bases).add(f); break; }
        case "M": cur.statics.add(p[1]); break;
      }
    }
    // 1. Todas las fiables, vacías y con su tamaño
    for (S s : all.values()) if (s.ok && s.size > 0) {
      Structure st = new StructureDataType(cat, s.name, s.size, dtm);
      made.put(s.name, (Structure) dtm.addDataType(st, DataTypeConflictHandler.REPLACE_HANDLER));
    }
    // 2. Bases y campos (cada campo ocupa hasta el siguiente; si el tipo no cabe o no se conoce, se deja sin definir)
    int fields = 0;
    for (S s : all.values()) {
      Structure st = made.get(s.name); if (st == null) continue;
      for (F b : s.bases) { Structure bs = made.get(b.type); if (bs != null && b.off + bs.getLength() <= s.size) try { st.replaceAtOffset(b.off, bs, bs.getLength(), "base_" + b.type, null); } catch (Exception e) {} }
      List<F> fs = new ArrayList<>(s.fields); fs.sort(Comparator.comparingInt(x -> x.off));
      for (int i = 0; i < fs.size(); i++) {
        F f = fs.get(i); int room = (i + 1 < fs.size() ? fs.get(i + 1).off : s.size) - f.off;
        if (room <= 0 || f.off >= s.size) continue;
        DataType dt = resolve(f.type);
        try {
          if (dt != null && dt.getLength() > 0 && dt.getLength() <= room) st.replaceAtOffset(f.off, dt, dt.getLength(), f.name, null);
          else st.replaceAtOffset(f.off, new ArrayDataType(Undefined1DataType.dataType, room, 1), room, f.name, f.type);
          fields++;
        } catch (Exception e) { /* solapado con una base: se respeta la base */ }
      }
    }
    println("Tipos del prototipo: " + made.size() + " estructuras fiables, " + fields + " campos");

    // 3. «this» en los métodos (no estáticos) de clases fiables. Nombre GNU v2: metodo__[C]<clase>…, __<clase>… (constructor), _$_<clase> (destructor)
    Pattern cls = Pattern.compile("^(?:C)?(\\d+)");
    DecompInterface d = new DecompInterface(); d.openProgram(currentProgram);
    int typed = 0;
    for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
      if (monitor.isCancelled()) break;
      String n = f.getName(), method, rest;
      if (n.startsWith("_$_")) { method = "~"; rest = n.substring(3); }
      else { int k = n.indexOf("__", n.startsWith("__") ? 0 : 1); if (k < 0) continue; method = n.substring(0, k); rest = n.substring(k + 2); }
      String className = null;
      if (rest.startsWith("Q") && rest.length() > 2 && Character.isDigit(rest.charAt(1))) {   // Q23Sim5Param → Param (último nivel)
        int q = rest.charAt(1) - '0', pos = 2; String last = null;
        for (int i = 0; i < q; i++) { Matcher mm = Pattern.compile("^(\\d+)").matcher(rest.substring(pos)); if (!mm.find()) break; int len = Integer.parseInt(mm.group(1)); pos += mm.group(1).length(); if (pos + len > rest.length()) break; last = rest.substring(pos, pos + len); pos += len; }
        className = last;
      } else {
        Matcher mm = cls.matcher(rest); if (mm.find()) { int len = Integer.parseInt(mm.group(1)), pos = mm.end(); if (pos + len <= rest.length()) className = rest.substring(pos, pos + len); }
      }
      if (className == null) continue;
      Structure st = made.get(className); S s = all.get(className);
      if (st == null || s == null || s.statics.contains(method)) continue;
      try {
        if (f.getParameterCount() == 0) {
          DecompileResults r = d.decompileFunction(f, 30, monitor);
          if (r == null || r.getHighFunction() == null) continue;
          HighFunctionDBUtil.commitParamsToDatabase(r.getHighFunction(), true, HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.ANALYSIS);
        }
        if (f.getParameterCount() == 0) continue;
        Parameter p0 = f.getParameter(0);
        p0.setDataType(new PointerDataType(st, 4, dtm), SourceType.USER_DEFINED);
        p0.setName("this", SourceType.USER_DEFINED);
        typed++;
      } catch (Exception e) { /* firma bloqueada: se deja */ }
    }
    println("Métodos con «this» tipado: " + typed);
  }
}
