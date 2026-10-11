// Capa de la red de carreteras (map-data/<ID>/roads.json, ver docs/es/09-red-de-carreteras.md).
// Cada tramo es una Bézier cúbica [inicio, inicio+tiradorInicial, fin+tiradorFinal, fin] en mundo (Z arriba).
// Se dibujan el eje (color según el tipo de tramo) y los bordes de la calzada según el perfil de carriles del nodo.
import * as THREE from "three";

interface RoadNode { i: number; p: [number, number, number]; profile: number; segments: number[] }
interface RoadSegment { i: number; nodes: [number, number]; length: number; road: number; flagNames: string[]; startControl: number[]; endControl: number[] }
interface RoadProfile { i: number; numZones: number; middleZone: number; lanes: { type: number; width: number; offset: number }[] }
export interface RoadsFile { nodes: RoadNode[]; segments: RoadSegment[]; profiles: RoadProfile[]; stats?: Record<string, unknown> }

export const ROAD_COLORS = { normal: 0x3ddc84, sentidoUnico: 0xffb21a, sinTrafico: 0x8a8f98, cruce: 0x4aa8ff, borde: 0xf2f2f2 } as const;

const LIFT = 0.35; // por encima del asfalto para que no parpadee

/** Mitad del ancho a cada lado del eje: [izquierda, derecha] en metros. */
function halfWidths(p: RoadProfile | undefined): [number, number] {
  if (!p || !p.lanes.length) return [4, 4];
  let l = 0, r = 0;
  p.lanes.forEach((ln, k) => { const edge = Math.abs(ln.offset) + Math.abs(ln.width) / 2; if (k < p.middleZone) l = Math.max(l, edge); else r = Math.max(r, edge); });
  return [l || r, r || l];
}

export function buildRoads(data: RoadsFile): THREE.Group {
  const group = new THREE.Group(); group.name = "Carreteras";
  const axis: number[] = [], axisCol: number[] = [], edges: number[] = [];
  const col = new THREE.Color(), a = new THREE.Vector3(), b = new THREE.Vector3(), c1 = new THREE.Vector3(), c2 = new THREE.Vector3();
  const curve = new THREE.CubicBezierCurve3(a, c1, c2, b);
  const tan = new THREE.Vector3(), side = new THREE.Vector3(), up = new THREE.Vector3(0, 0, 1);
  for (const s of data.segments) {
    const n0 = data.nodes[s.nodes[0]], n1 = data.nodes[s.nodes[1]]; if (!n0 || !n1) continue;
    a.set(...n0.p); b.set(...n1.p);
    c1.set(a.x + s.startControl[0], a.y + s.startControl[1], a.z + s.startControl[2]);
    c2.set(b.x + s.endControl[0], b.y + s.endControl[1], b.z + s.endControl[2]);
    const f = s.flagNames;
    col.setHex(f.includes("oneWay") ? ROAD_COLORS.sentidoUnico : f.includes("noTraffic") ? ROAD_COLORS.sinTrafico : s.road < 0 ? ROAD_COLORS.cruce : ROAD_COLORS.normal);
    const steps = Math.max(2, Math.min(24, Math.ceil(s.length / 6)));
    const [hl0, hr0] = halfWidths(data.profiles[n0.profile]), [hl1, hr1] = halfWidths(data.profiles[n1.profile]);
    let prev: THREE.Vector3 | null = null, prevL: THREE.Vector3 | null = null, prevR: THREE.Vector3 | null = null;
    for (let k = 0; k <= steps; k++) {
      const t = k / steps, p = curve.getPoint(t).setZ(curve.getPoint(t).z + LIFT);
      curve.getTangent(t, tan); side.crossVectors(up, tan).normalize();
      const hl = hl0 + (hl1 - hl0) * t, hr = hr0 + (hr1 - hr0) * t;
      const L = p.clone().addScaledVector(side, hl), R = p.clone().addScaledVector(side, -hr);
      if (prev && prevL && prevR) {
        axis.push(prev.x, prev.y, prev.z, p.x, p.y, p.z); axisCol.push(col.r, col.g, col.b, col.r, col.g, col.b);
        if (s.road >= 0) edges.push(prevL.x, prevL.y, prevL.z, L.x, L.y, L.z, prevR.x, prevR.y, prevR.z, R.x, R.y, R.z);
      }
      prev = p; prevL = L; prevR = R;
    }
  }
  const g1 = new THREE.BufferGeometry();
  g1.setAttribute("position", new THREE.Float32BufferAttribute(axis, 3)); g1.setAttribute("color", new THREE.Float32BufferAttribute(axisCol, 3));
  const axisLines = new THREE.LineSegments(g1, new THREE.LineBasicMaterial({ vertexColors: true, depthTest: true, transparent: true, opacity: 0.95 }));
  axisLines.name = "Ejes"; axisLines.renderOrder = 5;
  const g2 = new THREE.BufferGeometry(); g2.setAttribute("position", new THREE.Float32BufferAttribute(edges, 3));
  const edgeLines = new THREE.LineSegments(g2, new THREE.LineBasicMaterial({ color: ROAD_COLORS.borde, transparent: true, opacity: 0.35 }));
  edgeLines.name = "Bordes"; edgeLines.renderOrder = 5;
  // Nodos: puntos pequeños (decisiones y cruces)
  const pts = new Float32Array(data.nodes.length * 3);
  data.nodes.forEach((n, k) => { pts[k * 3] = n.p[0]; pts[k * 3 + 1] = n.p[1]; pts[k * 3 + 2] = n.p[2] + LIFT; });
  const g3 = new THREE.BufferGeometry(); g3.setAttribute("position", new THREE.BufferAttribute(pts, 3));
  const nodes = new THREE.Points(g3, new THREE.PointsMaterial({ color: 0xffffff, size: 3, sizeAttenuation: false }));
  nodes.name = "Nodos";
  group.add(edgeLines, axisLines, nodes);
  group.userData = { Capa: "Red de carreteras", Nodos: data.nodes.length, Tramos: data.segments.length };
  return group;
}
