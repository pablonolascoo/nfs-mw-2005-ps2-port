# Cómo colaborar · How to contribute

> **ES** abajo · **EN** below

## Español
Gracias por querer ayudar. Este proyecto es abierto: cualquiera puede proponer cambios.
**Nada entra en `main` sin la revisión y aprobación del mantenedor** (@pablonolascoo).

### Pasos
1. Haz un *fork* y crea una rama: `git checkout -b mi-cambio`.
2. Lee [CONTEXT.md](CONTEXT.md) y el documento de `docs/es` del área que tocas.
3. Haz el cambio. Documenta en `docs/es` **y** `docs/en` lo que descubras o cambies.
4. Abre un *pull request* rellenando la plantilla. El mantenedor lo revisa.

### Reglas
- **Nunca subas datos del juego**: ISOs, archivos del disco, GLB/PNG convertidos, audio o vídeo de EA. Solo código, documentación y datos propios.
- **Estética y lógica original** siempre (ver las reglas de oro en [ROADMAP.md](ROADMAP.md)).
- Modelos, texturas y piezas nuevas deben ser **obra tuya** o con licencia libre compatible. Nada ripeado de otros juegos.
- Etiqueta los datos: [V] verificado en bytes, [D] decomp, [I] inferido, [H] hipótesis. No inventes offsets.
- Herramientas: **Bun** para JS/TS (`bun install`, `bun run`). Playwright con `npm`/`npx`. Motor nativo: Swift + Metal.
- Commits pequeños y claros, en español o inglés.

## English
Thanks for wanting to help. This project is open: anyone can propose changes.
**Nothing reaches `main` without review and approval by the maintainer** (@pablonolascoo).

### Steps
1. Fork the repo and create a branch: `git checkout -b my-change`.
2. Read [CONTEXT.md](CONTEXT.md) and the `docs/en` document for the area you touch.
3. Make the change. Document what you find or change in `docs/en` **and** `docs/es`.
4. Open a pull request using the template. The maintainer reviews it.

### Rules
- **Never upload game data**: ISOs, disc files, converted GLB/PNG, EA audio or video. Only code, docs and your own data.
- **Original look and logic**, always (see the golden rules in [ROADMAP.en.md](ROADMAP.en.md)).
- New models, textures and parts must be **your own work** or under a compatible free licence. Nothing ripped from other games.
- Tag facts: [V] verified on bytes, [D] decomp, [I] inferred, [H] hypothesis. Never invent offsets.
- Tools: **Bun** for JS/TS (`bun install`, `bun run`). Playwright with `npm`/`npx`. Native engine: Swift + Metal.
- Small, clear commits, in English or Spanish.
