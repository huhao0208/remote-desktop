// 把 srv2/control.html 同步进 www/，注入内置服务器地址（RD_SERVER 环境变量可覆盖）
const fs = require('fs');
const path = require('path');

const SERVER = process.env.RD_SERVER || 'https://47-251-105-202.sslip.io:8444';
const src = path.join(__dirname, '..', '..', 'srv2', 'control.html');
const outDir = path.join(__dirname, '..', 'www');
const out = path.join(outDir, 'index.html');

let html = fs.readFileSync(src, 'utf8');
const inject = `<script>window.RD_SERVER=${JSON.stringify(SERVER)};</script>\n`;
html = html.replace('<script>\nconst $=', inject + '<script>\nconst $=');
if (!html.includes('window.RD_SERVER')) {
  html = html.replace('<script>', inject + '<script>');
}
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(out, html);
console.log('[sync-web] control.html -> www/index.html, RD_SERVER=' + SERVER);