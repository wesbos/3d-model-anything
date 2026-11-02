// Imported first by export.ts: procedural textures that call Math.random() must come out identical on every run.
let state = 0x2f6e2b1;
Math.random = () => {
  state = (state + 0x6d2b79f5) | 0; // mulberry32
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
