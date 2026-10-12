// Archivos de texto incrustados con `import x from "…" with { type: "text" }`.
declare module "*.list" { const text: string; export default text; }
declare module "*.txt" { const text: string; export default text; }
