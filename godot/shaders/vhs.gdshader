// =====================================================================
// VHS composite-signal emulation — Godot 4 port of the web game's shader.
// Attach to a full-rect ColorRect on a CanvasLayer (layer above the world)
// with its material = a ShaderMaterial using this shader. Drive the uniforms
// from scripts/vhs_controller.gd.
//
// Models the analog chain: luma (Y) kept sharp with ring/overshoot; chroma
// (I/Q) band-limited + delayed to the right (the real source of VHS colour
// bleed); plus dot-crawl, tracking wobble, vertical roll, head-switch tear,
// tape dropout and per-field noise. All amounts scale from `intensity`.
// Bloom is intentionally omitted here — use a WorldEnvironment Glow instead
// (see godot/README.md), which is higher quality than a manual bright pass.
// =====================================================================
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec2  res       = vec2(1280.0, 720.0); // viewport size, set from script
uniform float intensity = 0.6;   // 0 clean · 0.6 vhs · 1.0 heavy
uniform float aspect43  = 0.0;   // 0 = 16:9, 1 = camcorder 4:3 pillarbox
uniform float sat       = 1.0;
uniform float dropout   = 0.0;   // pulse 0..1 for tape dropout dashes
uniform float ir        = 0.0;   // nightshot IR green
uniform float glitch    = 0.0;   // proximity/scare spikes
uniform float lowbatt   = 0.0;
uniform float heat      = 0.0;   // level-2 shimmer

float hash(vec2 p){p=fract(p*vec2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);}
float n2(vec2 p){
	vec2 i=floor(p);vec2 f=fract(p);f=f*f*(3.0-2.0*f);
	float a=hash(i);float b=hash(i+vec2(1.0,0.0));
	float c=hash(i+vec2(0.0,1.0));float d=hash(i+vec2(1.0,1.0));
	return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}
vec3  T(vec2 u){return texture(screen_tex,u).rgb;}
float LUM(vec3 c){return dot(c,vec3(0.299,0.587,0.114));}

void fragment(){
	float V  = clamp(intensity,0.0,1.0);
	float tt = mod(TIME,60.0);
	float G  = glitch;

	// 4:3 pillarbox
	vec2 sUv = UV;
	float scrAsp = res.x/max(1.0,res.y);
	float winW = mix(1.0, min(1.0,(4.0/3.0)/scrAsp), aspect43);
	float x0 = (1.0-winW)*0.5;
	float inWin = step(x0,sUv.x)*step(sUv.x,1.0-x0);
	sUv.x = (sUv.x-x0)/winW;

	// lens barrel
	vec2 cc = sUv-0.5;
	float r2 = dot(cc,cc);
	vec2 uv = 0.5+cc*(1.0+(0.045+0.03*V)*r2+0.04*r2*r2);

	// heat shimmer
	uv.x += sin(uv.y*70.0+tt*9.0)*0.0016*heat;
	uv.y += sin(uv.x*50.0-tt*7.0)*0.0010*heat;

	// vertical hold roll
	float rollGate = step(0.993-glitch*0.03, hash(vec2(floor(tt*2.5),7.0)));
	uv.y = fract(uv.y + rollGate*(n2(vec2(tt*6.0,0.0))*0.6));

	// tracking band + jitter
	float bandPos = fract(tt*0.11+0.3);
	float band = smoothstep(0.08,0.0,abs(uv.y-bandPos));
	float trackAmt = band*(0.004+0.05*G+0.05*lowbatt*step(0.93,hash(vec2(floor(tt*2.0),3.0))));
	uv.x += (n2(vec2(uv.y*140.0,tt*28.0))-0.5)*trackAmt*8.0*(0.4+V);
	uv.x += (hash(vec2(floor(uv.y*res.y),floor(tt*60.0)))-0.5)*(0.0009+G*0.012)*(0.4+V);

	// head-switch tear (bottom)
	float hb = 0.05+0.02*V;
	float hsw = smoothstep(hb,0.0,sUv.y);
	uv.x += hsw*(n2(vec2(tt*40.0,sUv.y*420.0))-0.5)*0.28*(0.4+V);

	// luma with ringing
	float px = 1.0/res.x;
	float Y  = LUM(T(uv));
	float Yl = LUM(T(uv-vec2(px*2.0,0.0)));
	float Yr = LUM(T(uv+vec2(px*2.0,0.0)));
	Y += (Y-(Yl+Yr)*0.5)*(0.35+0.55*V);

	// chroma band-limited + delayed
	float cw = (1.5+9.0*V)*px;
	float cd = (2.0+7.0*V)*px;
	vec2 cuv = uv-vec2(cd,0.0);
	vec3 ca = T(cuv)*0.24;
	ca += T(cuv-vec2(cw,0.0))*0.20;      ca += T(cuv+vec2(cw,0.0))*0.14;
	ca += T(cuv-vec2(cw*2.0,0.0))*0.16;  ca += T(cuv+vec2(cw*2.0,0.0))*0.08;
	ca += T(cuv-vec2(cw*3.5,0.0))*0.12;  ca += T(cuv+vec2(cw*3.5,0.0))*0.06;
	float I = dot(ca,vec3(0.596,-0.274,-0.322));
	float Q = dot(ca,vec3(0.211,-0.523, 0.312));

	// dot crawl + chroma noise
	float field = floor(tt*50.0);
	float dc = sin((uv.x*res.x+uv.y*res.y*2.0+field)*1.5708)*0.5;
	float cEdge = clamp(abs(I)+abs(Q),0.0,1.0);
	I += dc*cEdge*0.10*V; Q -= dc*cEdge*0.10*V;
	float cn = hash(vec2(floor(uv.x*res.x*0.5),floor(uv.y*res.y*0.5)+field))-0.5;
	I += cn*0.05*V; Q += cn*0.05*V;
	I *= sat; Q *= sat;

	// YIQ -> RGB
	vec3 col = vec3(Y+0.956*I+0.621*Q, Y-0.272*I-0.647*Q, Y-1.106*I+1.703*Q);

	// grade
	col = col*0.97+0.03;
	col = pow(max(col,vec3(0.0)),vec3(0.94));
	col *= mix(vec3(1.0),vec3(1.05,1.0,0.90),0.5+0.5*V);
	float lum = LUM(col);
	col = mix(vec3(lum),col,mix(1.0,0.86,V));

	// IR nightshot
	vec3 irc = vec3(0.20,1.0,0.28)*(lum*1.7+0.05);
	col = mix(col,irc,ir);

	// scanlines + interlace
	float sl = 1.0-(0.10+0.05*V)*(0.5+0.5*sin(uv.y*res.y*3.14159));
	float inter = 1.0-0.045*V*step(0.5,fract(uv.y*res.y*0.5+field*0.5));
	col *= sl*inter;

	// luma noise
	float g0 = hash(uv*res+vec2(tt*97.0,tt*61.0));
	col += (g0-0.5)*(0.025+0.04*V+ir*0.07+G*0.10+lowbatt*0.05);

	// tape dropout dashes
	float ln = floor(uv.y*res.y);
	float dRow = step(0.975-dropout*0.12, hash(vec2(ln,floor(tt*15.0))));
	float dSeg = step(0.62, hash(vec2(floor(uv.x*48.0),ln+floor(tt*15.0))));
	col += dRow*dSeg*(0.22+0.4*dropout)*(0.3+V);

	// head-switch static
	col = mix(col,vec3(g0*0.9),hsw*(0.35+0.35*V));

	// vignette + bars
	float vig = smoothstep(0.95,0.28,r2);
	col *= mix(0.30,1.0,vig);
	if(uv.x<0.0||uv.x>1.0||uv.y<0.0||uv.y>1.0) col = vec3(0.0);
	col *= inWin;

	COLOR = vec4(col,1.0);
}
