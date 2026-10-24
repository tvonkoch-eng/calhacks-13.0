// The live page served by LiveServer. Plain HTML + JS, no build step, no dependencies.
let livePage = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>assist · live</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0b0d10;--panel:#13161b;--line:#22262e;--text:#e7e9ee;--dim:#8a909c;--faint:#596070;
--accent:#7cc4ff;--good:#5fd38d;--bad:#ff6b6b;--warn:#f5c26b;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,sans-serif}
header{display:flex;align-items:center;gap:16px;padding:14px 22px;border-bottom:1px solid var(--line)}
header h1{font-size:14px;font-weight:600;margin:0;letter-spacing:.02em}
.dot{width:8px;height:8px;border-radius:50%;background:var(--faint)}.dot.on{background:var(--good);box-shadow:0 0 10px var(--good)}
#status{color:var(--dim);font-size:13px}
.meter{flex:0 0 120px;height:4px;background:var(--line);border-radius:2px;overflow:hidden}.meter i{display:block;height:100%;width:0;background:var(--accent);transition:width .08s}
.stats{margin-left:auto;display:flex;gap:22px;font-size:12px;color:var(--dim)}.stats b{display:block;color:var(--text);font:600 18px var(--mono)}
main{display:grid;grid-template-columns:minmax(380px,1fr) minmax(420px,1.25fr);gap:0;height:calc(100vh - 61px)}
section{overflow:auto;padding:20px 22px}section+section{border-left:1px solid var(--line)}
h2{font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:var(--faint);font-weight:600;margin:0 0 10px}
.lens{position:relative;height:190px;border-radius:22px;background:radial-gradient(120% 140% at 30% 0%,#1b2330,#0d1016);border:1px solid #263142;display:flex;flex-direction:column;justify-content:center;padding:26px 30px;margin-bottom:24px;overflow:hidden}
.lens .head{font-size:30px;font-weight:600;letter-spacing:-.01em;min-height:40px;transition:opacity .15s}
.lens .echo{color:var(--dim);font-size:14px;margin-top:8px;min-height:20px}
.lens .tag{position:absolute;top:14px;right:18px;font:11px var(--mono);color:var(--faint)}
.lens.idle .head{color:var(--faint);font-weight:400;font-size:18px}
.lens.thinking .head{color:var(--accent)}
.heard{font-size:20px;line-height:1.4;min-height:60px;margin-bottom:24px}.heard .past{color:var(--faint)}.heard .live{color:var(--text)}
.log{font:12px/1.6 var(--mono);color:var(--dim)}.log div{white-space:pre-wrap;word-break:break-word}
.log .k{display:inline-block;width:86px;color:var(--faint)}.log .t{color:var(--faint);display:inline-block;width:62px}
.k-fire{color:var(--warn)!important}.k-token,.k-answer{color:var(--good)!important}.k-lens{color:var(--accent)!important}.k-error{color:var(--bad)!important}.k-personal,.k-incomplete,.k-abandon,.k-carry{color:#c7a2ff!important}.k-final{color:var(--text)!important}
.card{border:1px solid var(--line);background:var(--panel);border-radius:14px;padding:14px 16px;margin-bottom:10px}
.card .said{font-size:15px}.card .what{margin-top:6px;display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}
.card .ans{font-weight:600}.pill{font:11px var(--mono);padding:2px 7px;border-radius:999px;border:1px solid var(--line);color:var(--dim)}
.pill.good{color:var(--good);border-color:#244b35}.pill.bad{color:var(--bad);border-color:#5a2a2a}.pill.warn{color:var(--warn);border-color:#55452a}
.judge{margin-top:10px;padding-top:10px;border-top:1px dashed var(--line);display:flex;gap:10px;align-items:baseline;color:var(--dim);font-size:13px}
.score{font:600 15px var(--mono);min-width:28px}.s5,.s4{color:var(--good)}.s3{color:var(--warn)}.s2,.s1{color:var(--bad)}
.empty{color:var(--faint)}
</style></head><body>
<header><span class="dot" id="dot"></span><h1>assist · live</h1><span id="status">connecting…</span><div class="meter"><i id="lvl"></i></div>
<div class="stats"><div>sentences<b id="sN">0</b></div><div>avg grade<b id="sAvg">–</b></div><div>missed<b id="sMiss">0</b></div><div>wrong<b id="sWrong">0</b></div><div>median 1st token<b id="sTok">–</b></div><div>median lead<b id="sLead">–</b></div></div></header>
<main>
<section>
<h2>Lens</h2>
<div class="lens idle" id="lens"><span class="tag" id="lensTag"></span><div class="head" id="lensHead">waiting for a question</div><div class="echo" id="lensEcho"></div></div>
<h2>Hearing</h2><div class="heard" id="heard"><span class="empty">say something…</span></div>
<h2>Pipeline</h2><div class="log" id="log"></div>
</section>
<section><h2>Sentences, graded</h2><div id="cards"><div class="empty">Each sentence you finish shows up here with what the assistant did and a grade from a second model.</div></div></section>
</main>
<script>
const $=id=>document.getElementById(id);
const turns=new Map(), sentences=[];
let past=[];
function esc(s){return String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}
function med(a){if(!a.length)return null;a=[...a].sort((x,y)=>x-y);return a[Math.floor(a.length/2)]}
function stats(){
  const g=sentences.filter(s=>s.verdict);$("sN").textContent=sentences.length;
  $("sAvg").textContent=g.length?(g.reduce((a,s)=>a+s.verdict.score,0)/g.length).toFixed(1):"–";
  $("sMiss").textContent=g.filter(s=>s.outcome==="missed").length;
  $("sWrong").textContent=g.filter(s=>s.outcome==="wrong answer"||s.outcome==="should have stayed quiet").length;
  const done=[...turns.values()].filter(t=>t.state==="done");
  const tok=med(done.map(t=>t.firstTokenMs).filter(x=>x!=null)),lead=med(done.map(t=>t.lead).filter(x=>x!=null));
  $("sTok").textContent=tok==null?"–":Math.round(tok)+"ms";$("sLead").textContent=lead==null?"–":(lead>=0?"+":"")+lead.toFixed(2)+"s";
}
function render(){
  const box=$("cards");if(!sentences.length)return;
  box.innerHTML=sentences.slice().reverse().map(s=>{
    const t=s.turn&&turns.get(s.turn);let what;
    if(t&&(t.state==="done"||t.state==="answering")){
      const lead=t.lead==null?"":`<span class="pill ${t.lead>=0?"good":"warn"}">${t.lead>=0?"+":""}${t.lead.toFixed(2)}s lead</span>`;
      const tok=t.firstTokenMs==null?"":`<span class="pill">${t.firstTokenMs===0?"local":Math.round(t.firstTokenMs)+"ms 1st token"}</span>`;
      what=`<span class="ans">→ ${esc(t.answer)}</span>${tok}${lead}${t.fires>1?`<span class="pill">${t.fires} tries</span>`:""}`;
    }else what=`<span class="empty">${esc(s.did)}</span>`;
    const asked=t&&t.question?`<div class="empty" style="font-size:12px;margin-top:4px">asked the model: “${esc(t.question)}”</div>`:"";
    let j=`<div class="judge"><span class="empty">grading…</span></div>`;
    if(s.verdict){const v=s.verdict,cls=s.outcome==="answered"||s.outcome==="correctly quiet"?"good":s.outcome==="missed"?"warn":"bad";
      j=`<div class="judge"><span class="score s${v.score}">${v.score}/5</span><span class="pill ${cls}">${esc(s.outcome)}</span>${v.heard_right?"":'<span class="pill warn">misheard</span>'}<span>${esc(v.note)}${v.better_answer&&s.outcome!=="answered"&&s.outcome!=="correctly quiet"?` · ideal: <b style="color:var(--text)">${esc(v.better_answer)}</b>`:""}</span></div>`}
    else if(s.error) j=`<div class="judge"><span class="pill bad">grader failed</span>${esc(s.error)}</div>`;
    return `<div class="card"><div class="said">“${esc(s.text)}”</div>${asked}<div class="what">${what}</div>${j}</div>`}).join("");
}
function log(e){const d=document.createElement("div");d.innerHTML=`<span class="t">${e.t.toFixed(2)}</span><span class="k k-${e.kind}">${e.kind.toUpperCase()}</span>${esc(e.msg)}`;const L=$("log");L.prepend(d);while(L.childNodes.length>300)L.lastChild.remove()}
const es=new EventSource("/events");
es.onopen=()=>{$("dot").classList.add("on")};es.onerror=()=>{$("dot").classList.remove("on");$("status").textContent="disconnected (assist stopped?)"};
es.onmessage=m=>{const e=JSON.parse(m.data);
  switch(e.type){
  case "status":$("status").textContent=e.text;break;
  case "level":$("lvl").style.width=Math.round(e.v*100)+"%";break;
  case "log":if(e.kind!=="hear")log(e);if(e.kind==="final"){past.push(e.msg.replace(/^"|"$/g,""));past=past.slice(-2)}break;
  case "transcript":$("heard").innerHTML=`<span class="past">${esc(past.join(" "))} </span><span class="live">${esc(e.text)}</span>`;break;
  case "lens":{const L=$("lens");if(!e.card){L.className="lens idle";$("lensHead").textContent="waiting for a question";$("lensEcho").textContent="";$("lensTag").textContent=""}
    else{L.className="lens"+(e.card.thinking?" thinking":"");$("lensHead").textContent=e.card.headline;$("lensEcho").textContent=e.card.echo;$("lensTag").textContent=e.card.thinking?"streaming":"✓"}break}
  case "turns":for(const t of e.turns)turns.set(t.id,t);render();stats();break;
  case "sentence":sentences.push(e);render();stats();break;
  case "verdict":{const s=sentences.find(x=>x.sid===e.sid);if(s){s.verdict=e.verdict;s.outcome=e.outcome;s.error=e.error}render();stats();break}
  }};
</script></body></html>
"""#
