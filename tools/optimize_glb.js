#!/usr/bin/env node
/* Optimizes a .glb for phone delivery: welds/dedupes, simplifies the mesh,
   resizes oversized textures and re-encodes them, then prunes what's unused.
   Authored models routinely ship with 4K PBR maps and million-triangle
   sculpts — that is fine for a render farm and fatal for a WebView on an
   iPhone (four 4096² maps alone cost ~270 MB of GPU memory uncompressed).

   Usage:
     node tools/optimize_glb.js <in.glb> <out.glb> [--tex 1024] [--ratio 0.25]

   Requires (install anywhere, then run with NODE_PATH set):
     npm i @gltf-transform/core @gltf-transform/functions @gltf-transform/extensions sharp
*/
'use strict';
const fs = require('fs');
const path = require('path');
const { NodeIO } = require('@gltf-transform/core');
const { ALL_EXTENSIONS } = require('@gltf-transform/extensions');
const {
  dedup, prune, weld, simplify, textureCompress, resample, flatten, join,
} = require('@gltf-transform/functions');

async function main() {
  const [inFile, outFile] = process.argv.slice(2).filter(a => !a.startsWith('--'));
  if (!inFile || !outFile) {
    console.error('usage: optimize_glb.js <in.glb> <out.glb> [--tex N] [--ratio R]');
    process.exit(1);
  }
  const argOf = (name, dflt) => {
    const i = process.argv.indexOf(name);
    return i >= 0 && process.argv[i + 1] ? Number(process.argv[i + 1]) : dflt;
  };
  const texMax = argOf('--tex', 1024);
  const ratio = argOf('--ratio', 0.25);

  const sharp = require('sharp');
  const { MeshoptSimplifier } = await import('meshoptimizer').catch(() => ({}));

  const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
  const doc = await io.read(inFile);
  const before = fs.statSync(inFile).size;

  const countTris = (d) => d.getRoot().listMeshes()
    .flatMap(m => m.listPrimitives())
    .reduce((s, p) => s + (p.getIndices()
      ? p.getIndices().getCount() / 3
      : (p.getAttribute('POSITION') ? p.getAttribute('POSITION').getCount() / 3 : 0)), 0);
  const trisBefore = Math.round(countTris(doc));

  const transforms = [
    dedup(),
    flatten(),
    join(),
    weld(),
    resample(),
  ];
  if (MeshoptSimplifier) {
    transforms.push(simplify({ simplifier: MeshoptSimplifier, ratio, error: 0.01 }));
  }
  transforms.push(
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [texMax, texMax], quality: 85 }),
    prune(),
  );

  await doc.transform(...transforms);

  await io.write(outFile, doc);
  const after = fs.statSync(outFile).size;
  const trisAfter = Math.round(countTris(doc));
  const mb = (b) => (b / 1048576).toFixed(1) + ' MB';
  console.log(`${path.basename(inFile)} -> ${path.basename(outFile)}`);
  console.log(`  size      ${mb(before)}  ->  ${mb(after)}   (${(100 * after / before).toFixed(1)}%)`);
  console.log(`  triangles ${trisBefore.toLocaleString()}  ->  ${trisAfter.toLocaleString()}`);
  console.log(`  textures  capped at ${texMax}px, webp q85`);
}

main().catch(e => { console.error(e); process.exit(1); });
