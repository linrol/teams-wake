const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  minimizeToTray: () => ipcRenderer.send('minimize-to-tray'),
  quitApp: () => ipcRenderer.send('quit-app'),
  checkAccessibility: () => ipcRenderer.invoke('check-accessibility'),
  openAccessibilitySettings: () => ipcRenderer.send('open-accessibility-settings'),
  getRunningApps: () => ipcRenderer.invoke('get-running-apps'),
  
  // Settings sync
  updateSettings: (settings) => ipcRenderer.send('settings-changed', settings),
  toggleActive: (isActive) => ipcRenderer.send('toggle-active', isActive),
  getCurrentStatus: () => ipcRenderer.invoke('get-current-status'),
  
  // Status and log events
  onStatusChanged: (callback) => ipcRenderer.on('status-changed', (event, data) => callback(data)),
  onSettingsChanged: (callback) => ipcRenderer.on('settings-changed-from-main', (event, data) => callback(data)),
  onLog: (callback) => ipcRenderer.on('log', (event, data) => callback(data))
});
