#!/usr/bin/env node
/* Generates the four eerie-stickman entity models as animated .glb files.
   Node-hierarchy rigs (no skinning) with idle / walk / attack clips baked as
   quaternion tracks, exported with three's GLTFExporter.

   Usage:  npm i three@0.128.0   (once, anywhere)
           node tools/gen_stickmen.js
   Writes: assets/models/entities/stickman_{tall,hound,crawler,drowned}.glb

   Conventions (match web/index.html ENTITY_MODELS): forward = -Z, Y-up,
   feet at y=0, real-world metres. */
'use strict';
const fs=require('fs'),path=require('path');
global.THREE=require('three');
require('three/examples/js/exporters/GLTFExporter.js');
/* GLTFExporter's binary path reads a Blob back through FileReader; Node has
   Blob but not FileReader, so give it the two methods the exporter calls. */
global.FileReader=class{
  readAsArrayBuffer(b){b.arrayBuffer().then(r=>{this.result=r;this.onloadend&&this.onloadend();});}
  readAsDataURL(b){b.arrayBuffer().then(r=>{
    this.result='data:application/octet-stream;base64,'+Buffer.from(r).toString('base64');
    this.onloadend&&this.onloadend();});}
};
global.window={FileReader:global.FileReader};   /* exporter reads it off window */

const T=global.THREE;
const OUT=path.join(__dirname,'..','assets','models','entities');

/* ---------- shared look ---------- */
const FLESH=()=>new T.MeshStandardMaterial({color:0x0b0b0e,roughness:0.92,metalness:0.05});
const GLOW=(hex)=>new T.MeshStandardMaterial({color:0x000000,emissive:hex,emissiveIntensity:2.2,roughness:0.4});

function limbSeg(name,len,r0,r1,mat){
  /* pivot group at the joint; cylinder hangs down -Y from it */
  const g=new T.Group();g.name=name;
  const geo=new T.CylinderGeometry(r1,r0,len,7,1);
  const m=new T.Mesh(geo,mat);m.position.y=-len/2;m.name=name+'_m';
  const j=new T.Mesh(new T.SphereGeometry(Math.max(r0*1.35,0.028),7,6),mat);j.name=name+'_j';
  g.add(m,j);
  return g;
}
function limbSegUp(name,len,r0,r1,mat){
  /* same, but the segment grows +Y from its pivot (spine, neck) */
  const g=new T.Group();g.name=name;
  const m=new T.Mesh(new T.CylinderGeometry(r1,r0,len,7,1),mat);
  m.position.y=len/2;m.name=name+'_m';
  const j=new T.Mesh(new T.SphereGeometry(Math.max(r0*1.35,0.028),7,6),mat);j.name=name+'_j';
  g.add(m,j);
  return g;
}
function ball(name,r,mat,sy){
  const m=new T.Mesh(new T.SphereGeometry(r,10,8),mat);
  m.name=name;if(sy)m.scale.y=sy;
  return m;
}

/* ---------- animation helpers ---------- */
const _e=new T.Euler(),_q=new T.Quaternion();
function qTrack(node,T_,fn,n){
  /* sample fn(phase 0..1) -> [rx,ry,rz] into a quaternion track */
  n=n||17;
  const times=[],vals=[];
  for(let i=0;i<=n;i++){
    const ph=i/n;times.push(ph*T_);
    const r=fn(ph);_e.set(r[0],r[1],r[2]);_q.setFromEuler(_e);
    vals.push(_q.x,_q.y,_q.z,_q.w);
  }
  return new T.QuaternionKeyframeTrack(node+'.quaternion',times,vals);
}
function vTrack(node,T_,fn,n){
  n=n||17;
  const times=[],vals=[];
  for(let i=0;i<=n;i++){
    const ph=i/n;times.push(ph*T_);
    const v=fn(ph);vals.push(v[0],v[1],v[2]);
  }
  return new T.VectorKeyframeTrack(node+'.position',times,vals);
}
const S=(ph,off)=>Math.sin((ph+(off||0))*Math.PI*2);

/* =========================================================
   BIPED STICKMAN (tall / crawler / drowned share this rig)
   ========================================================= */
function biped(cfg){
  const mat=FLESH();
  const root=new T.Group();root.name='root';
  const pelvis=new T.Group();pelvis.name='pelvis';pelvis.position.y=cfg.hip;root.add(pelvis);
  const hipBall=ball('hip_b',cfg.rTorso*1.5,mat);pelvis.add(hipBall);
  const spine=limbSegUp('spine',cfg.spineLen,cfg.rTorso,cfg.rTorso*1.12,mat);
  pelvis.add(spine);
  const chest=new T.Group();chest.name='chest';chest.position.y=cfg.spineLen;spine.add(chest);
  chest.add(ball('chest_b',cfg.rTorso*1.5,mat));
  const neck=limbSegUp('neck',cfg.neckLen,cfg.rTorso*0.5,cfg.rTorso*0.55,mat);
  chest.add(neck);
  const head=new T.Group();head.name='head';head.position.y=cfg.neckLen;neck.add(head);
  head.add(ball('skull',cfg.headR,mat,1.28));
  if(cfg.grin){                     /* faint hanging grin — the Level 0 signature.
       Too wide, too dim, slightly crooked: a smear of light, not a smiley. */
    const gm=new T.MeshStandardMaterial({color:0x000000,emissive:0xffe9b0,
      emissiveIntensity:1.1,roughness:0.4});
    const g=new T.Mesh(new T.TorusGeometry(cfg.headR*0.74,0.009,5,16,2.6),gm);
    g.name='grin';g.position.set(0,-cfg.headR*0.30,-cfg.headR*0.82);
    g.rotation.z=Math.PI+0.5*(Math.PI-2.6)+0.13;g.rotation.x=-0.15;
    head.add(g);
  }
  if(cfg.eyes){
    for(const s of [-1,1]){
      const em=new T.MeshStandardMaterial({color:0x000000,emissive:cfg.eyes,
        emissiveIntensity:1.5,roughness:0.4});
      const e=new T.Mesh(new T.SphereGeometry(0.016,6,5),em);
      e.name='eye'+(s<0?'L':'R');
      e.position.set(s*cfg.headR*0.38,cfg.headR*0.20,-cfg.headR*0.84);
      head.add(e);
    }
  }
  const mk=(side)=>{
    const s=side==='L'?-1:1;
    const sh=new T.Group();sh.name='arm'+side;sh.position.set(s*cfg.shoulderW,-0.02,0);   /* chest is already at the spine top */
    const up=limbSeg('armU'+side,cfg.armU,0.034,0.030,mat);sh.add(up);
    const el=new T.Group();el.name='armL'+side;el.position.y=-cfg.armU;up.add(el);
    const lo=limbSeg('armF'+side,cfg.armL,0.030,0.024,mat);el.add(lo);
    const hand=ball('hand'+side,0.045,mat,1.5);hand.position.y=-cfg.armL;lo.add(hand);
    chest.add(sh);
    const hp=new T.Group();hp.name='leg'+side;hp.position.set(s*cfg.hipW,0,0);
    const th=limbSeg('legU'+side,cfg.legU,0.042,0.036,mat);hp.add(th);
    const kn=new T.Group();kn.name='knee'+side;kn.position.y=-cfg.legU;th.add(kn);
    const sn=limbSeg('legL'+side,cfg.legL,0.036,0.028,mat);kn.add(sn);
    const ft=new T.Mesh(new T.BoxGeometry(0.075,0.035,0.19),mat);
    ft.name='foot'+side;ft.position.set(0,-cfg.legL,-0.045);sn.add(ft);
    pelvis.add(hp);
  };
  mk('L');mk('R');
  return root;
}

function bipedClips(cfg){
  const A=cfg.stride,Aa=cfg.armSwing,hun=cfg.hunch,W=cfg.walkT;
  const tracks=(T_,f)=>[
    qTrack('legL',T_,ph=>[f.leg(ph,0),0,0]),
    qTrack('legR',T_,ph=>[f.leg(ph,0.5),0,0]),
    qTrack('kneeL',T_,ph=>[f.knee(ph,0),0,0]),
    qTrack('kneeR',T_,ph=>[f.knee(ph,0.5),0,0]),
    qTrack('armL',T_,ph=>[f.arm(ph,0.5),0,cfg.armFlare]),
    qTrack('armR',T_,ph=>[f.arm(ph,0),0,-cfg.armFlare]),
    qTrack('armLL',T_,ph=>[f.elbow(ph,0.5),0,0]),
    qTrack('armLR',T_,ph=>[f.elbow(ph,0),0,0]),
    qTrack('spine',T_,ph=>[hun+f.hunchOsc(ph),f.sway(ph),0]),
    qTrack('neck',T_,ph=>[cfg.neckPitch,0,0]),
    qTrack('head',T_,ph=>[f.headX(ph),f.headY(ph),cfg.headTilt]),
    vTrack('pelvis',T_,ph=>[0,cfg.hip+f.bob(ph),0])
  ];
  const walk=new T.AnimationClip('walk',W,tracks(W,{
    leg:(p,o)=>S(p,o)*A,
    knee:(p,o)=>Math.max(0,S(p,o+0.25))*A*1.5,
    arm:(p,o)=>S(p,o)*Aa,
    elbow:(p,o)=>cfg.elbowBase+Math.max(0,S(p,o+0.2))*Aa*0.7,
    hunchOsc:p=>S(p,0)*0.02,
    sway:p=>S(p,0.25)*cfg.sway,
    headX:p=>cfg.headPitch+S(p*2,0)*0.03,
    headY:p=>S(p,0.4)*0.10,
    bob:p=>Math.abs(S(p,0.25))*-cfg.bob
  }));
  const I=3.2;
  const idle=new T.AnimationClip('idle',I,tracks(I,{
    leg:()=>0,knee:()=>0.06,
    arm:(p,o)=>S(p,o)*0.03,
    elbow:()=>cfg.elbowBase*0.7,
    hunchOsc:p=>S(p,0)*0.025,
    sway:p=>S(p,0)*0.02,
    /* two sharp head jerks baked into the loop — it keeps *noticing* you */
    headX:p=>cfg.headPitch+(p>0.31&&p<0.36?0.22:0)*Math.sin((p-0.31)*62.8),
    headY:p=>(p>0.62&&p<0.70?0.55:0)*Math.sin((p-0.62)*39.3)+S(p,0)*0.03,
    bob:p=>S(p,0)*-0.006
  }));
  const K=0.55;
  const atk=new T.AnimationClip('attack',K,tracks(K,{
    leg:(p,o)=>S(p,o)*A*1.2,
    knee:(p,o)=>Math.max(0,S(p,o+0.25))*A*1.8,
    arm:p=>-1.9-Math.min(1,p*3)*0.4,        /* both arms thrown forward-up */
    elbow:()=>-0.5,
    hunchOsc:p=>0.25*Math.min(1,p*2.5),
    sway:p=>S(p*2,0)*0.06,
    headX:()=>cfg.headPitch-0.30,
    headY:p=>S(p*4,0)*0.16,
    bob:p=>-0.05*Math.min(1,p*3)
  }));
  return [idle,walk,atk];
}

/* =========================================================
   QUADRUPED STICKMAN (the hound slot — runs on all fours)
   ========================================================= */
function quad(cfg){
  const mat=FLESH();
  const root=new T.Group();root.name='root';
  const body=new T.Group();body.name='body';body.position.y=cfg.hip;root.add(body);
  const spineGeo=new T.CylinderGeometry(0.05,0.058,cfg.bodyLen,7,1);
  const sp=new T.Mesh(spineGeo,mat);sp.rotation.x=Math.PI/2;sp.name='torso';
  body.add(sp);
  body.add(ball('hip_b',0.085,mat));
  const chestB=ball('chest_b',0.09,mat);chestB.position.z=-cfg.bodyLen/2;body.add(chestB);
  const tailB=ball('tail_b',0.06,mat);tailB.position.z=cfg.bodyLen/2;body.add(tailB);
  const neck=new T.Group();neck.name='neck';neck.position.set(0,0.04,-cfg.bodyLen/2-0.02);
  const nk=limbSeg('neckSeg',0.30,0.035,0.03,mat);nk.rotation.x=2.35;neck.add(nk);
  body.add(neck);
  const head=new T.Group();head.name='head';
  head.position.set(0,0.22,-cfg.bodyLen/2-0.22);
  head.add(ball('skull',0.115,mat,1.2));
  if(cfg.eyes)for(const s of [-1,1]){
    const e=new T.Mesh(new T.SphereGeometry(0.02,6,5),GLOW(cfg.eyes));
    e.position.set(s*0.05,0.02,-0.095);e.name='eye'+(s<0?'L':'R');head.add(e);
  }
  body.add(head);
  const mkLeg=(name,x,z)=>{
    const hp=new T.Group();hp.name=name;hp.position.set(x,0,z);
    const up=limbSeg(name+'U',cfg.legU,0.036,0.03,mat);hp.add(up);
    const kn=new T.Group();kn.name=name+'K';kn.position.y=-cfg.legU;up.add(kn);
    const lo=limbSeg(name+'L',cfg.legL,0.03,0.022,mat);kn.add(lo);
    const ft=ball(name+'F',0.045,mat,0.7);ft.position.y=-cfg.legL;lo.add(ft);
    body.add(hp);
  };
  mkLeg('legFL',-cfg.width,-cfg.bodyLen/2+0.06);
  mkLeg('legFR', cfg.width,-cfg.bodyLen/2+0.06);
  mkLeg('legBL',-cfg.width, cfg.bodyLen/2-0.06);
  mkLeg('legBR', cfg.width, cfg.bodyLen/2-0.06);
  return root;
}
function quadClips(cfg){
  const A=cfg.stride,W=cfg.walkT;
  const leg=(T_,name,off,amp)=>[
    qTrack(name,T_,ph=>[S(ph,off)*amp,0,0]),
    qTrack(name+'K',T_,ph=>[Math.max(0,S(ph,off+0.25))*amp*1.6,0,0])
  ];
  const tracks=(T_,amp,headF)=>[
    ...leg(T_,'legFL',0.0,amp),...leg(T_,'legBR',0.05,amp),
    ...leg(T_,'legFR',0.5,amp),...leg(T_,'legBL',0.55,amp),
    qTrack('body',T_,ph=>[S(ph*2,0)*0.03*(amp/A||0),S(ph,0.25)*0.05*(amp/A||0),0]),
    qTrack('head',T_,headF),
    vTrack('body',T_,ph=>[0,cfg.hip+Math.abs(S(ph,0.25))*-0.03*(amp/A||0),0])
  ];
  const walk=new T.AnimationClip('walk',W,tracks(W,A,
    ph=>[S(ph*2,0)*0.05,S(ph,0.3)*0.12,S(ph,0.1)*0.06]));
  const idle=new T.AnimationClip('idle',3.0,tracks(3.0,0.02,
    ph=>[(ph>0.4&&ph<0.47?0.3:0)*Math.sin((ph-0.4)*44.9),
         (ph>0.7&&ph<0.78?0.7:0)*Math.sin((ph-0.7)*39.3)+S(ph,0)*0.05,S(ph,0.5)*0.05]));
  const atk=new T.AnimationClip('attack',0.5,tracks(0.5,A*1.4,
    ph=>[-0.35,S(ph*4,0)*0.2,0]));
  return [idle,walk,atk];
}

/* ---------- variants: one locomotion style per floor ---------- */
(async()=>{
  fs.mkdirSync(OUT,{recursive:true});
  const jobs=[
    ['stickman_tall',  ()=>{const cfg={hip:1.42,spineLen:0.78,neckLen:0.16,headR:0.14,rTorso:0.05,
        shoulderW:0.24,hipW:0.11,armU:0.62,armL:0.60,legU:0.74,legL:0.68,grin:true,
        hunch:0.14,neckPitch:0.10,headPitch:-0.16,headTilt:0.06,armFlare:0.10,
        elbowBase:0.12,stride:0.52,armSwing:0.30,sway:0.05,bob:0.045,walkT:1.15};
      return {root:biped(cfg),clips:bipedClips(cfg)};}],
    ['stickman_hound', ()=>{const cfg={hip:0.78,bodyLen:0.95,width:0.16,legU:0.44,legL:0.40,
        stride:0.75,walkT:0.55,eyes:0xcfd8ff};
      return {root:quad(cfg),clips:quadClips(cfg)};}],
    ['stickman_crawler',()=>{const cfg={hip:0.92,spineLen:0.70,neckLen:0.14,headR:0.13,rTorso:0.046,
        shoulderW:0.22,hipW:0.11,armU:0.58,armL:0.55,legU:0.50,legL:0.44,eyes:0xffb489,
        hunch:1.25,neckPitch:-1.35,headPitch:-0.25,headTilt:0.0,armFlare:0.16,
        elbowBase:0.05,stride:0.62,armSwing:0.62,sway:0.10,bob:0.05,walkT:0.72};
      return {root:biped(cfg),clips:bipedClips(cfg)};}],
    ['stickman_drowned',()=>{const cfg={hip:1.30,spineLen:0.72,neckLen:0.15,headR:0.14,rTorso:0.05,
        shoulderW:0.23,hipW:0.11,armU:0.58,armL:0.58,legU:0.68,legL:0.62,eyes:0x9adfcf,
        hunch:0.34,neckPitch:0.18,headPitch:-0.05,headTilt:0.42,armFlare:0.05,
        elbowBase:0.06,stride:0.38,armSwing:0.07,sway:0.09,bob:0.03,walkT:1.5};
      return {root:biped(cfg),clips:bipedClips(cfg)};}]
  ];
  for(const [name,make] of jobs){
    const {root,clips}=make();
    const scene=new T.Scene();scene.add(root);
    const ab=await new Promise((res,rej)=>{
      try{
        new T.GLTFExporter().parse(scene,res,{binary:true,animations:clips});
      }catch(e){rej(e);}
    });
    const f=path.join(OUT,name+'.glb');
    fs.writeFileSync(f,Buffer.from(ab));
    console.log('wrote',f,(fs.statSync(f).size/1024).toFixed(1)+'kB',
      'clips:',clips.map(c=>c.name+'('+c.duration.toFixed(2)+'s)').join(' '));
  }
})().catch(e=>{console.error(e);process.exit(1);});
