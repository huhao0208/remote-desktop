// 原生客户端桥：页面 <-> 主进程（被控端 Agent 管理）
const { ipcRenderer } = require('electron');
const os = require('os');

// 机器级稳定指纹由主进程计算（与内置 agent.py 的 uuid.getnode() 完全一致），
// 通过 additionalArguments 传入，使「本机」与 Agent 注册的是同一台设备。
const fpArg = process.argv.find(a => a.startsWith('--rd-fp='));
window.RD_NATIVE = true;
window.RD_PLATFORM = 'pc';
window.RD_FP = fpArg ? fpArg.slice('--rd-fp='.length) : '';
window.RD_DEVNAME = require('os').hostname();

window.rdHost = {
  setSession(s) { ipcRenderer.send('rd-session', s); },
  onState(cb) { ipcRenderer.on('rd-agent-state', (_e, s) => cb(s)); },
  // 被控端上线后服务端返回的真实 device_id（与指纹推导一致，双保险）
  onDevice(cb) { ipcRenderer.on('rd-agent-device', (_e, id) => cb(id)); }
};