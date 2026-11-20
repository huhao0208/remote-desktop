const { app, BrowserWindow, shell, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

// ---------------------------------------------------------------- 内置被控端 Agent
// 远控 + 被控一体：登录后自动拉起 uu-agent（复用页面 token，不重复登录），
// 本机即出现在其它设备的可控列表里；退出登录/关闭开关即停止。
let agentProc = null;
let agentState = 'off';
let session = null;
let restartTimer = null;
let stopping = false;

function agentBinary() {
  const name = process.platform === 'win32' ? 'uu-agent.exe' : 'uu-agent';
  // 打包后：extraResources → resources/agent/；开发时：仓库 dist/
  const candidates = [
    path.join(process.resourcesPath || '', 'agent', name),
    path.join(__dirname, 'bin', name),
    path.join(__dirname, '..', 'dist', name)
  ];
  return candidates.find(p => { try { return fs.existsSync(p); } catch (e) { return false; } }) || null;
}

function broadcastState() {
  for (const w of BrowserWindow.getAllWindows()) {
    try { w.webContents.send('rd-agent-state', agentState); } catch (e) {}
  }
}

// 与 agent.py 完全一致的稳定指纹：node-SYSTEM-getnode()hex
// （Python uuid.getnode 取第一个非本地回环接口 MAC，Node networkInterfaces 顺序一致）
function machineFp() {
  const SYS = process.platform === 'win32' ? 'Windows' : process.platform === 'darwin' ? 'Darwin' : 'Linux';
  let mac = 0n;
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const a of ifs[name] || []) {
      if (!a.internal && a.mac && a.mac !== '00:00:00:00:00:00') {
        mac = BigInt('0x' + a.mac.replace(/:/g, ''));
        break;
      }
    }
    if (mac) break;
  }
  return `${os.hostname()}-${SYS}-${mac.toString(16)}`;
}

function stopAgent() {
  stopping = true;
  clearTimeout(restartTimer);
  if (agentProc) { try { agentProc.kill(); } catch (e) {} agentProc = null; }
  agentState = 'off';
  broadcastState();
}

function startAgent() {
  if (!session || !session.token || session.allow === false) { stopAgent(); return; }
  const bin = agentBinary();
  if (!bin) { agentState = 'error'; broadcastState(); console.error('[agent] 未找到内置 uu-agent 二进制'); return; }
  if (agentProc) return; // 已在运行
  stopping = false;
  agentState = 'starting';
  broadcastState();
  const args = ['--server', session.server, '--token', session.token,
                '--name', session.name || os.hostname()];
  agentProc = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let started = false;
  const onData = d => {
    const s = d.toString();
    process.stdout.write('[agent] ' + s);
    const m = s.match(/device=(\w+)/);
    if (m) {
      for (const w of BrowserWindow.getAllWindows()) {
        try { w.webContents.send('rd-agent-device', m[1]); } catch (e) {}
      }
    }
    if (!started && s.includes('room=')) { started = true; agentState = 'running'; broadcastState(); }
  };
  agentProc.stdout.on('data', onData);
  agentProc.stderr.on('data', onData);
  agentProc.on('error', e => { console.error('[agent] spawn error', e); agentProc = null; agentState = 'error'; broadcastState(); });
  agentProc.on('exit', code => {
    agentProc = null;
    if (stopping) { agentState = 'off'; broadcastState(); return; }
    // 异常退出：5s 后自动重启（token 失效等会反复失败，页面重新登录后恢复）
    agentState = 'error';
    broadcastState();
    clearTimeout(restartTimer);
    restartTimer = setTimeout(() => { if (session && session.allow !== false) startAgent(); }, 5000);
  });
}

ipcMain.on('rd-session', (_e, s) => {
  const prev = session;
  session = s && s.token ? s : null;
  if (!session) { stopAgent(); return; }
  // 同一会话重复同步不重启；token/开关变化才重启
  if (agentProc && prev && prev.token === session.token && prev.allow === session.allow) return;
  stopAgent();
  startAgent();
});

// ---------------------------------------------------------------- 窗口
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const w = BrowserWindow.getAllWindows()[0];
    if (w) { if (w.isMinimized()) w.restore(); w.focus(); }
  });
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 420,
    minHeight: 600,
    title: 'UU远程桌面',
    backgroundColor: '#0d1117',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: false,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false,
      additionalArguments: ['--rd-fp=' + machineFp()]
    }
  });
  win.loadFile(path.join(__dirname, 'web', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('did-finish-load', broadcastState);
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
app.on('before-quit', stopAgent);