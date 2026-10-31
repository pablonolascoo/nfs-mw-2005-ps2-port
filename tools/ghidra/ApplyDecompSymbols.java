// Pone los nombres de la decomp (config/<VERSION>/symbols.txt) en el programa: "nombre = 0xDIR; // type:func|object ..."
// Uso: -preScript ApplyDecompSymbols.java <symbols.txt>
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.SourceType;
import java.nio.file.*;
import java.util.regex.*;

public class ApplyDecompSymbols extends GhidraScript {
  @Override public void run() throws Exception {
    Pattern p = Pattern.compile("^(\\S+)\\s*=\\s*0x([0-9A-Fa-f]+);\\s*//\\s*type:(\\w+)");
    int funcs = 0, labels = 0;
    for (String line : Files.readAllLines(Paths.get(getScriptArgs()[0]))) {
      Matcher m = p.matcher(line.trim()); if (!m.find()) continue;
      Address a = toAddr(Long.parseLong(m.group(2), 16));
      if (currentProgram.getMemory().getBlock(a) == null) continue;
      try {
        if (m.group(3).equals("func")) {
          disassemble(a);
          var f = getFunctionAt(a); if (f == null) f = createFunction(a, m.group(1));
          if (f != null) { f.setName(m.group(1), SourceType.IMPORTED); funcs++; }
        } else { createLabel(a, m.group(1), true, SourceType.IMPORTED); labels++; }
      } catch (Exception e) { /* nombre duplicado o dirección sin código: se salta */ }
    }
    println("Nombres de la decomp: " + funcs + " funciones, " + labels + " datos");
  }
}
