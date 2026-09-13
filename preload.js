const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  minimizeToTray: () => ipcRenderer.send('minimize-to-tray'),
  quitApp: () => ipcRenderer.send('quit-app'),
  checkAccessibility: () => ipcRenderer.invoke('check-accessibility'),
  openAccessibilitySettings: () => ipcRenderer.send('open-accessibility-settings'),
  getRunningApps: () => ipcRenderer.invoke('get-running-apps'),
  adjustWindowHeight: (height) => ipcRenderer.send('adjust-window-height', height),
  
  // Settings sync
  updateSettings: (settings) => ipcRenderer.send('settings-changed', settings),
  toggleActive: (isActive) => ipcRenderer.send('toggle-active', isActive),
  getCurrentStatus: () => ipcRenderer.invoke('get-current-status'),
  
  // Auto-Translate APIs
  toggleAutoTranslate: (isActive) => ipcRenderer.send('toggle-auto-translate', isActive),
  updateTranslationProvider: (provider) => ipcRenderer.send('update-translation-provider', provider),
  updateTranslationShortcut: (shortcut) => ipcRenderer.send('update-translation-shortcut', shortcut),
  onAutoTranslateStatusChanged: (callback) => ipcRenderer.on('auto-translate-status-changed', (event, data) => callback(data)),

  // Schedule APIs
  getScheduleSettings: () => ipcRenderer.invoke('get-schedule-settings'),
  updateScheduleSettings: (data) => ipcRenderer.send('update-schedule-settings', data),
  onScheduleStatusChanged: (callback) => ipcRenderer.on('schedule-status-changed', (event, data) => callback(data)),

  // Status and log events
  onStatusChanged: (callback) => ipcRenderer.on('status-changed', (event, data) => callback(data)),
  onSettingsChanged: (callback) => ipcRenderer.on('settings-changed-from-main', (event, data) => callback(data)),
  onLog: (callback) => ipcRenderer.on('log', (event, data) => callback(data))
});

