const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('hudApi', {
  onShowHud: (callback) => ipcRenderer.on('show-hud', (event, data) => callback(data)),
  hideHud: () => ipcRenderer.send('hide-hud'),
  copyToClipboard: (text) => ipcRenderer.send('copy-to-clipboard', text),
  updateHudHeight: (height) => ipcRenderer.send('update-hud-height', height)
});
