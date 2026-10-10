// 把 zhejiuqu-pwa 打包成一个自包含的单文件离线版（图标/清单全部内嵌，双击即用）
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, 'zhejiuqu-pwa');
let html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');

const b64 = f => 'data:image/png;base64,' + fs.readFileSync(path.join(dir, f)).toString('base64');
const i192 = b64('icons/icon-192.png');
const i512 = b64('icons/icon-512.png');
const i180 = b64('icons/apple-touch-icon.png');

const manifest = {
  name: '这就去 · AI 监工', short_name: '这就去',
  description: 'AI 监工：用你顶不住的身份，催你把该干的事干完',
  start_url: './index.html', scope: './', display: 'standalone',
  orientation: 'portrait', background_color: '#FFFFFF', theme_color: '#FF9500', lang: 'zh-CN',
  icons: [
    { src: i192, sizes: '192x192', type: 'image/png', purpose: 'any' },
    { src: i512, sizes: '512x512', type: 'image/png', purpose: 'any' },
    { src: i512, sizes: '512x512', type: 'image/png', purpose: 'maskable' }
  ]
};

// 1. 清单改为运行时 blob 注入（file:// 下不能用外部 manifest 文件）
html = html.replace('<link rel="manifest" href="manifest.json">', '');
// 2. 图标全部内联
html = html.replace(
  '<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">',
  `<link rel="apple-touch-icon" href="${i180}">\n<link rel="icon" type="image/png" href="${i192}">`
);
// 3. 去掉 Service Worker（本地文件无法注册），改为运行时注入 manifest
const swLine = "if('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(()=>{});";
if (!html.includes(swLine)) throw new Error('找不到 SW 注册行');
html = html.replace(swLine,
  `window.__OFFLINE__=true;document.title='这就去 · AI 监工（离线版）';\n` +
  `try{const _m=${JSON.stringify(manifest)};` +
  `const _l=document.createElement('link');_l.rel='manifest';` +
  `_l.href=URL.createObjectURL(new Blob([JSON.stringify(_m)],{type:'application/manifest+json'}));` +
  `document.head.appendChild(_l);}catch(e){}`);

const out = path.join(dir, 'zhejiuqu-offline.html');
fs.writeFileSync(out, html, 'utf8');
console.log('BUILT', out, (Buffer.byteLength(html, 'utf8') / 1024).toFixed(1) + ' KB');
