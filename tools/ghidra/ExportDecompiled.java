// Exporta el pseudocódigo de cada función, agrupado por el archivo original que indica symbols.txt ("// Speed/.../x.cpp").
// Uso: -postScript ExportDecompiled.java <symbols.txt> <carpeta de salida>
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

public class ExportDecompiled extends GhidraScript {
  @Override public void run() throws Exception {
    String[] args = getScriptArgs();
    Path out = Paths.get(args[1]); Files.createDirectories(out);
    Map<Long, String> fileOf = new HashMap<>();
    Pattern sym = Pattern.compile("^(\\S+)\\s*=\\s*0x([0-9A-Fa-f]+);\\s*//\\s*type:func");
    String cur = "_sin_archivo";
    for (String line : Files.readAllLines(Paths.get(args[0]))) {
      String t = line.trim();
      if (t.startsWith("// ") && (t.endsWith(".cpp") || t.endsWith(".c") || t.endsWith(".s"))) { cur = t.substring(3); continue; }
      Matcher m = sym.matcher(t); if (m.find()) fileOf.put(Long.parseLong(m.group(2), 16), cur);
    }
    DecompInterface d = new DecompInterface(); d.openProgram(currentProgram);
    Map<String, StringBuilder> files = new TreeMap<>();
    int ok = 0, fail = 0;
    for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
      if (monitor.isCancelled()) break;
      String file = fileOf.getOrDefault(f.getEntryPoint().getOffset(), "_sin_archivo");
      DecompileResults r = d.decompileFunction(f, 60, monitor);
      StringBuilder sb = files.computeIfAbsent(file, k -> new StringBuilder("// " + k + "\n\n"));
      sb.append("// ").append(f.getName()).append(" @ ").append(f.getEntryPoint()).append("\n");
      if (r != null && r.decompileCompleted()) { sb.append(r.getDecompiledFunction().getC()).append("\n"); ok++; }
      else { sb.append("// (no se pudo descompilar)\n\n"); fail++; }
    }
    for (var e : files.entrySet()) {
      Path p = out.resolve(e.getKey().replace('\\', '/') + ".c"); Files.createDirectories(p.getParent());
      Files.writeString(p, e.getValue());
    }
    println("Pseudocódigo: " + ok + " funciones, " + fail + " fallidas, " + files.size() + " archivos en " + out);
  }
}
