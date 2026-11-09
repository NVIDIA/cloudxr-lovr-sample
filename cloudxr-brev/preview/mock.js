const versions={runtime:['6.2.3','6.2.1','6.2.0','6.0.5','6.0.4','6.0.2'],js:['6.2.0','6.1.0'],framework:['6.2.0','6.1.0','6.0.4','6.0.3','6.0.2']};
let process={mode:'webxr',runtime:'6.2.3',js:'6.2.0',framework:'6.2.0',endpoint:'203.0.113.10',state:'ready',apple_profile:'apple-vision-pro',device_profile:'auto-webrtc'},timers=[];
let network={settings:{deployment_mode:'direct',stun_mode:'local',public_ip:'',stun_ip:'',stun_port:3478,media_port:47998},current:{deployment_mode:'direct',public_ip:'203.0.113.10',media_port:47998,enable_ice:null},local_stun_running:false};
const output={stun:'Mock STUN log: no network traffic is generated.\n',combined:`CloudXR Experiences preview initialized
CloudXR Experiences: reusing cached WebXR flavor
INFO [print_end_user_started_information] The NVIDIA CloudXR Runtime service has started.
INFO [nv_cxr_service_start] Runtime is now running and accepting connections
`,proxy:`Brev Secure Link: HTTPS 443 -> HTTP 8080
HAProxy signaling route: /signal -> localhost:49100
`,ui:`CloudXR Experiences HTTP backend listening on 127.0.0.1:8081
GET /api/status 200
`};
const inventory={driver_version:'580.173.02',gpus:[{index:0,name:'NVIDIA L40S',memory_mib:46068,nvenc:true}],blockers:[],runnable:true,versions};
const status=()=>({inventory,process,ports:{native:48010},network}),reply=(value,ok=true)=>({ok,statusText:ok?'OK':'Mock request failed',json:async()=>value});
const append=(source,line)=>{output[source]+=`${line}\n`},later=(delay,state,line,source='combined')=>timers.push(setTimeout(()=>{process={...process,state};append(source,line)},delay));
window.fetch=async(input,options={})=>{
  let url=new URL(input,location.href),path=url.pathname;
  if(path==='/api/status')return reply(status());
  if(path==='/api/logs')return reply({sources:[{id:'combined',name:'Build + CloudXR server'},{id:'proxy',name:'Brev Secure Link proxy'},{id:'ui',name:'Chooser + WebXR service'},{id:'stun',name:'Local STUN address mapping'}]});
  if(path==='/api/log'){let id=url.searchParams.get('id')||'combined',text=output[id]||'',offset=Number(url.searchParams.get('offset')||0);return reply({text:text.slice(offset),offset:text.length,size:text.length})}
  if(path==='/api/start'){
    timers.forEach(clearTimeout);timers=[];let form=new URLSearchParams(options.body),mode=form.get('mode'),runtime=form.get('runtime'),js=form.get('js'),framework=form.get('framework');
    if(!['webxr','apple'].includes(mode))return reply({error:'Unknown mock client mode'},false);
    let apple_profile=form.get('apple_profile')||process.apple_profile||'apple-vision-pro';
    if(!['apple-vision-pro','ipad-pro'].includes(apple_profile))return reply({error:'Unknown mock Apple profile'},false);
    let settings={...network.settings};for(let key of Object.keys(settings))if(form.has(key))settings[key]=form.get(key);
    if(!['direct','cloud'].includes(settings.deployment_mode))return reply({error:'Unknown mock deployment mode'},false);
    let cloud=settings.deployment_mode==='cloud',local=cloud&&settings.stun_mode==='local';
    network={settings,current:{...settings,public_ip:settings.public_ip||'203.0.113.10',media_port:Number(settings.media_port),stun_ip:local?'127.0.0.1':cloud?settings.stun_ip:'',stun_port:cloud?Number(settings.stun_port):0,enable_ice:cloud?true:null},local_stun_running:local};
    process={mode,runtime,js,framework,apple_profile,device_profile:mode==='apple'?apple_profile:'auto-webrtc',endpoint:network.current.public_ip,state:'queued'};append('combined',`CloudXR Experiences: queued ${mode} flavor with Runtime ${runtime}`);
    later(700,'syncing','CloudXR Experiences: fetching the latest cloudxr-lovr-sample main');later(1700,'building',`CloudXR Experiences: building Runtime ${runtime}`);later(3000,'starting','Starting LÖVR in headless mode');later(4500,'ready','INFO [nv_cxr_service_start] Runtime is now running and accepting connections');
    if(mode==='webxr')append('proxy','Routing same-origin /signal WebSockets to Runtime port 49100');
    return reply({message:`Mock ${mode} deployment started`});
  }
  if(path==='/api/stop'){timers.forEach(clearTimeout);timers=[];process={...process,state:'stopped'};network.local_stun_running=false;append('combined','CloudXR Experiences: flavor stopped');return reply({message:'Mock flavor stopped'})}
  return reply({error:`Unsupported mock request: ${path}`},false);
};
addEventListener('DOMContentLoaded',()=>{let banner=document.createElement('div');banner.textContent='INTERACTIVE MOCK · No Brev VM, build, or GPU workload is running';banner.style.cssText='padding:9px 5vw;background:#26380d;color:#b7e36f;font-size:12px;font-weight:bold;letter-spacing:.08em';document.body.insertBefore(banner,document.querySelector('main'))});
addEventListener('click',event=>{if(event.target.closest('a[href="/webxr/"]')){event.preventDefault();document.getElementById('message').textContent='Mock preview: no CloudXR stream is running.'}});
