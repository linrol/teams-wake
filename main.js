const { app, BrowserWindow, ipcMain, Tray, Menu, systemPreferences, shell, powerMonitor } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const translationEngine = require('./translationEngine');

// Force integrated low-power GPU to prevent battery drain from discrete GPU switching on macOS
app.commandLine.appendSwitch('force_low_power_gpu');

let mainWindow;
let hudWindow = null;
let tray;
let isQuitting = false;
let isSystemSuspended = false;

// Keep-alive state managed in the main process
let isActive = false;
let intervalMinutes = 3;
let targetAppName = 'Microsoft Teams';
let timerId = null;
let startupTimeoutId = null;

// Auto-Translate state
let isAutoTranslateActive = false;
let arrowMonitorProc = null;
let translationProvider = 'microsoft';
let translationShortcut = {
  label: 'Down Arrow ↓',
  keyCode: 125,
  modifiers: 'none'
};
let isHudActive = false;


// Path to system tray status PNG icons
const inactiveIconPath = path.join(__dirname, 'assets', 'iconTemplate.png');
const activeIconPath = path.join(__dirname, 'assets', 'iconActive.png');

let contextMenu;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 380,
    height: 650,
    minWidth: 340,
    minHeight: 480,
    resizable: true,
    frame: false,
    titleBarStyle: 'hidden',
    vibrancy: 'under-window',
    visualEffectState: 'followWindow', // Only calculate blur when window is active, saving battery
    backgroundColor: '#00000000', // transparent for vibrancy
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: true // Throttle animations and timers when window is in background/hidden
    }
  });

  mainWindow.loadFile('index.html');

  // Prevent app from closing directly; hide to tray instead unless quitting
  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function createHudWindow() {
  if (hudWindow && !hudWindow.isDestroyed()) return;
  hudWindow = new BrowserWindow({
    width: 360,
    height: 160,
    resizable: false,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: true,
    show: false,
    hasShadow: false,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, 'hudPreload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  hudWindow.loadFile('hud.html');

  hudWindow.on('blur', () => {
    if (hudWindow && !hudWindow.isDestroyed() && hudWindow.isVisible()) {
      hudWindow.hide();
    }
    setTimeout(() => { isHudActive = false; }, 600);
  });

  hudWindow.on('closed', () => {
    hudWindow = null;
    isHudActive = false;
  });
}

function showTranslationHud(original, translated, provider, bounds = null, direction = '外文 → 中文') {
  isHudActive = true;
  if (!hudWindow || hudWindow.isDestroyed()) {
    createHudWindow();
  }
  const { screen } = require('electron');
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);

  const [width, height] = hudWindow.getSize();
  let x, y;

  if (bounds && bounds.minX > 0 && bounds.maxY > 0) {
    // Snap directly below the selected conversation bubble!
    // Align left edge with start of selection/bubble
    x = Math.round(bounds.minX);
    // Position cleanly 8px below the bottom of the conversation line
    y = Math.round(bounds.maxY + 8);
  } else {
    // Fallback: align near cursor without jumping to left sidebar
    x = Math.round(cursor.x - 30);
    y = Math.round(cursor.y + 24);
  }

  // Keep horizontally within current display bounds
  if (x < display.bounds.x + 12) {
    x = display.bounds.x + 12;
  }
  if (x + width > display.bounds.x + display.bounds.width - 12) {
    x = display.bounds.x + display.bounds.width - width - 12;
  }

  // If clipping below screen bottom, flip to above the message
  if (y + height > display.bounds.y + display.bounds.height - 15) {
    if (bounds && bounds.minY > 0) {
      y = Math.round(bounds.minY - height - 8);
    } else {
      y = Math.round(cursor.y - height - 16);
    }
  }

  hudWindow.setPosition(x, y);
  hudWindow.webContents.send('show-hud', {
    original,
    translated,
    provider,
    direction: direction || '外文 → 中文'
  });
  hudWindow.showInactive();
}

function createTray() {
  const { nativeImage } = require('electron');
  const icon = nativeImage.createFromPath(inactiveIconPath);
  const trayIcon = icon.resize({ width: 18, height: 18 });
  trayIcon.setTemplateImage(true); // Ensure icon is visible in both dark and light macOS menu bars
  tray = new Tray(trayIcon);

  updateTrayMenu();
  tray.setToolTip('Teams Wake');

  // Both left click and right click pop up the context menu
  tray.on('click', () => {
    tray.popUpContextMenu(contextMenu);
  });
  tray.on('right-click', () => {
    tray.popUpContextMenu(contextMenu);
  });
}

function updateTrayMenu() {
  if (!tray) return;
  contextMenu = Menu.buildFromTemplate([
    { label: 'Teams Wake', enabled: false },
    {
      label: 'Enable Wake-up',
      type: 'checkbox',
      checked: isActive,
      click: (menuItem) => {
        toggleWakeState(menuItem.checked);
      }
    },
    {
      label: 'Enable Auto-Translate (↓)',
      type: 'checkbox',
      checked: isAutoTranslateActive,
      click: (menuItem) => {
        toggleAutoTranslateState(menuItem.checked);
      }
    },
    { type: 'separator' },
    {
      label: 'Interval',
      submenu: [1, 3, 5, 8, 10].map(mins => ({
        label: `${mins} Minute${mins > 1 ? 's' : ''}`,
        type: 'radio',
        checked: intervalMinutes === mins,
        click: () => {
          updateIntervalAndSync(mins);
        }
      }))
    },
    { type: 'separator' },
    {
      label: 'Show Settings Window',
      click: () => {
        if (mainWindow) {
          if (mainWindow.isMinimized()) mainWindow.restore();
          mainWindow.show();
          mainWindow.focus();
        } else {
          createWindow();
        }
      }
    },
    { type: 'separator' },
    {
      label: 'Quit',
      click: () => {
        isQuitting = true;
        app.quit();
      }
    }
  ]);

  tray.setContextMenu(contextMenu);
}

function updateIntervalAndSync(newInterval) {
  intervalMinutes = newInterval;
  sendToRenderer('settings-changed-from-main', { intervalMinutes, targetAppName });
  if (isActive) {
    if (timerId) clearTimeout(timerId);
    timerId = setTimeout(runWakeIteration, intervalMinutes * 60 * 1000);
  }
  updateTrayMenu();
  sendToRenderer('log', { msg: `Interval changed to ${intervalMinutes} minutes from Status Bar`, type: 'info' });
}

async function isTargetAppRunning() {
  const jxaScript = `
    ObjC.import('Cocoa');
    var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    var targetKeyword = "${targetAppName}";
    var found = false;
    for (var i = 0; i < apps.count; i++) {
        var app = apps.objectAtIndex(i);
        var name = ObjC.unwrap(app.localizedName);
        if (name && name.toLowerCase().indexOf(targetKeyword.toLowerCase()) !== -1) {
            found = true;
            break;
        }
    }
    found;
  `;
  try {
    const result = await runJXA(jxaScript);
    return result === 'true';
  } catch (e) {
    return false;
  }
}

// Global state controller to turn Keep-Alive ON/OFF
async function toggleWakeState(enabled) {
  if (isActive === enabled) return;

  if (enabled) {
    // 1. Check Accessibility Permission
    const hasPermission = systemPreferences.isTrustedAccessibilityClient(false);
    if (!hasPermission) {
      sendToRenderer('log', {
        msg: 'Cannot enable: Accessibility permission is required. Redirecting to settings...',
        type: 'error'
      });
      shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');

      // Reset checkboxes in UI and Tray
      sendToRenderer('status-changed', { isActive: false });
      updateTrayMenu();
      return;
    }

    // 2. Check if Target App (Teams) is running
    const running = await isTargetAppRunning();
    if (!running) {
      sendToRenderer('log', {
        msg: `Cannot enable: "${targetAppName}" is not running. Please open it first.`,
        type: 'error'
      });

      // Reset checkboxes in UI and Tray
      sendToRenderer('status-changed', { isActive: false });
      updateTrayMenu();
      return;
    }
  }

  isActive = enabled;

  // Dynamically swap the tray icon based on status
  const { nativeImage } = require('electron');
  const iconPath = isActive ? activeIconPath : inactiveIconPath;
  const icon = nativeImage.createFromPath(iconPath);
  const trayIcon = icon.resize({ width: 18, height: 18 });
  if (!isActive) {
    trayIcon.setTemplateImage(true); // Adapt to dark/light menu bars when inactive
  }
  tray.setImage(trayIcon);

  updateTrayMenu();
  sendToRenderer('status-changed', { isActive });

  if (isActive) {
    sendToRenderer('log', {
      msg: `Smart Wake service STARTED (Interval: ${intervalMinutes}m). Initializing in 10 seconds...`,
      type: 'success'
    });

    if (startupTimeoutId) clearTimeout(startupTimeoutId);
    if (timerId) {
      clearTimeout(timerId);
      timerId = null;
    }

    startupTimeoutId = setTimeout(() => {
      if (isActive) {
        sendToRenderer('log', {
          msg: `Smart Wake monitoring active. First check in ${intervalMinutes} minutes.`,
          type: 'info'
        });
        timerId = setTimeout(runWakeIteration, intervalMinutes * 60 * 1000);
      }
    }, 10000);
  } else {
    sendToRenderer('log', { msg: 'Smart Wake service STOPPED', type: 'warning' });
    if (startupTimeoutId) {
      clearTimeout(startupTimeoutId);
      startupTimeoutId = null;
    }
    if (timerId) {
      clearTimeout(timerId);
      timerId = null;
    }
  }
}

function sendToRenderer(channel, data) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, data);
  }
}

app.whenReady().then(() => {
  if (process.platform === 'darwin') {
    app.dock.setIcon(path.join(__dirname, 'assets', 'icon.png'));
  }
  createTray();
  createWindow();
  createHudWindow();

  app.on('activate', () => {
    // If the activation was triggered by clicking the HUD window (close or copy button), do NOT bring up mainWindow
    if (isHudActive) {
      return;
    }
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
    } else {
      createWindow();
    }
  });

  // Suspend/Resume power event handling to save battery when laptop is closed
  powerMonitor.on('suspend', () => {
    isSystemSuspended = true;
    if (timerId) clearTimeout(timerId);
    if (startupTimeoutId) clearTimeout(startupTimeoutId);
    stopArrowTranslateMonitor();
  });

  powerMonitor.on('resume', () => {
    isSystemSuspended = false;
    if (isActive) {
      timerId = setTimeout(runWakeIteration, 10000);
    }
    if (isAutoTranslateActive) {
      startArrowTranslateMonitor();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('before-quit', () => {
  isQuitting = true;
  stopArrowTranslateMonitor();
  if (hudWindow && !hudWindow.isDestroyed()) {
    hudWindow.destroy();
    hudWindow = null;
  }
  if (startupTimeoutId) {
    clearTimeout(startupTimeoutId);
    startupTimeoutId = null;
  }
  if (timerId) {
    clearTimeout(timerId);
    timerId = null;
  }
});

app.on('will-quit', () => {
  stopArrowTranslateMonitor();
});

process.on('SIGTERM', () => {
  isQuitting = true;
  app.quit();
});

process.on('SIGINT', () => {
  isQuitting = true;
  app.quit();
});

// Arrow Key Translation Monitor Daemon Management
function startArrowTranslateMonitor() {
  stopArrowTranslateMonitor();
  const monitorPath = path.join(__dirname, 'helpers', 'arrow_translate_monitor');
  const fs = require('fs');
  if (!fs.existsSync(monitorPath)) {
    sendToRenderer('log', { msg: 'Arrow translate monitor binary not found at ' + monitorPath, type: 'error' });
    return;
  }

  const kc = translationShortcut.keyCode || 125;
  const mods = translationShortcut.modifiers || 'none';
  arrowMonitorProc = spawn(monitorPath, ['all', String(kc), mods], { stdio: ['pipe', 'pipe', 'pipe'] });
  sendToRenderer('log', { msg: `Translate Daemon ACTIVE (Shortcut: ${translationShortcut.label}).`, type: 'info' });

  let buffer = '';
  arrowMonitorProc.stdout.on('data', async (data) => {
    buffer += data.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop();

    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('TRANSLATE_REQ_ZH2EN ') || (trimmed.startsWith('TRANSLATE_REQ ') && !trimmed.startsWith('TRANSLATE_REQ_EN2ZH '))) {
        const prefix = trimmed.startsWith('TRANSLATE_REQ_ZH2EN ') ? 'TRANSLATE_REQ_ZH2EN ' : 'TRANSLATE_REQ ';
        const parts = trimmed.substring(prefix.length).trim().split(/\s+/);
        const b64 = parts[0];
        const minX = parts.length > 1 ? parseInt(parts[1], 10) : -1;
        const maxX = parts.length > 2 ? parseInt(parts[2], 10) : -1;
        const minY = parts.length > 3 ? parseInt(parts[3], 10) : -1;
        const maxY = parts.length > 4 ? parseInt(parts[4], 10) : -1;
        const bounds = (minX > 0 && maxY > 0) ? { minX, maxX, minY, maxY } : null;
        const isEditable = parts.length > 5 ? (parseInt(parts[5], 10) === 1) : false;

        try {
          const originalText = Buffer.from(b64, 'base64').toString('utf8');
          const currentProviderName = translationEngine.getProvider() === 'microsoft' ? 'Microsoft' : 'Google';
          sendToRenderer('log', { msg: `[Translate (${currentProviderName})] Selected (ZH->EN): "${originalText}"`, type: 'info' });

          const translated = await translationEngine.translate(originalText, 'zh-CN', 'en');
          sendToRenderer('log', { msg: `[Translate (${currentProviderName})] -> English: "${translated}"`, type: 'success' });

          if (isEditable) {
            // In editable input field: replace text in-place!
            const outB64 = Buffer.from(translated, 'utf8').toString('base64');
            if (arrowMonitorProc && arrowMonitorProc.stdin.writable) {
              arrowMonitorProc.stdin.write(`PASTE_TRANSLATION ${outB64}\n`);
            }
          } else {
            // In read-only text (划词翻译): Pop up HUD bubble with English translation!
            showTranslationHud(originalText, translated, translationEngine.getProvider(), bounds, '中文 → 英文');
          }
        } catch (err) {
          sendToRenderer('log', { msg: `[Translate Error] ${err.message}`, type: 'error' });
        }
      } else if (trimmed.startsWith('TRANSLATE_REQ_EN2ZH ')) {
        const parts = trimmed.substring('TRANSLATE_REQ_EN2ZH '.length).trim().split(/\s+/);
        const b64 = parts[0];
        const minX = parts.length > 1 ? parseInt(parts[1], 10) : -1;
        const maxX = parts.length > 2 ? parseInt(parts[2], 10) : -1;
        const minY = parts.length > 3 ? parseInt(parts[3], 10) : -1;
        const maxY = parts.length > 4 ? parseInt(parts[4], 10) : -1;
        const bounds = (minX > 0 && maxY > 0) ? { minX, maxX, minY, maxY } : null;

        try {
          const originalText = Buffer.from(b64, 'base64').toString('utf8');
          const currentProviderName = translationEngine.getProvider() === 'microsoft' ? 'Microsoft' : 'Google';
          sendToRenderer('log', { msg: `[Translate (${currentProviderName})] Selected Message (EN->ZH): "${originalText}"`, type: 'info' });

          const translated = await translationEngine.translate(originalText, 'en', 'zh-CN');
          sendToRenderer('log', { msg: `[Translate (${currentProviderName})] -> 中文: "${translated}"`, type: 'success' });

          // English to Chinese reading: ALWAYS show HUD bubble!
          showTranslationHud(originalText, translated, translationEngine.getProvider(), bounds, '外文 → 中文');
        } catch (err) {
          sendToRenderer('log', { msg: `[Translate Error] ${err.message}`, type: 'error' });
        }
      } else if (trimmed === 'TRANSLATE_SUCCESS') {
        sendToRenderer('log', { msg: '[Translate] Replaced in-place with English!', type: 'success' });
      } else if (trimmed === 'READY') {
        sendToRenderer('log', { msg: 'Down Arrow Translator daemon READY.', type: 'info' });
      } else if (trimmed === 'FAILED_TO_CREATE_TAP') {
        sendToRenderer('log', { msg: 'Failed to create system Event Tap. Please grant Accessibility permission.', type: 'error' });
      }
    }
  });

  arrowMonitorProc.stderr.on('data', (data) => {
    console.error('arrow_translate_monitor stderr:', data.toString());
  });

  arrowMonitorProc.on('exit', () => {
    arrowMonitorProc = null;
  });
}

function stopArrowTranslateMonitor() {
  if (arrowMonitorProc) {
    try {
      arrowMonitorProc.kill('SIGTERM');
    } catch (e) { }
    arrowMonitorProc = null;
  }
}

// IPC Handler: Synchronize settings changed in the frontend UI
ipcMain.on('settings-changed', (event, settings) => {
  intervalMinutes = settings.interval;
  targetAppName = settings.targetApp;

  // If timer is already running, restart it with new interval
  if (isActive) {
    if (timerId) clearTimeout(timerId);
    timerId = setTimeout(runWakeIteration, intervalMinutes * 60 * 1000);
  }

  // If auto-translate is active and target app changed, restart monitor with new target
  if (isAutoTranslateActive) {
    startArrowTranslateMonitor();
  }
});

// IPC Handler: Synchronize active toggle state from the UI checkbox
ipcMain.on('toggle-active', (event, activeState) => {
  toggleWakeState(activeState);
});

function toggleAutoTranslateState(activeState) {
  isAutoTranslateActive = activeState;
  if (isAutoTranslateActive) {
    const hasPermission = systemPreferences.isTrustedAccessibilityClient(false);
    if (!hasPermission) {
      sendToRenderer('log', { msg: 'Auto-Translate requires Accessibility permission.', type: 'error' });
      shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');
      isAutoTranslateActive = false;
      sendToRenderer('auto-translate-status-changed', { isActive: false });
      updateTrayMenu();
      return;
    }
    startArrowTranslateMonitor();
  } else {
    stopArrowTranslateMonitor();
    sendToRenderer('log', { msg: 'Down Arrow Translator STOPPED', type: 'warning' });
  }
  sendToRenderer('auto-translate-status-changed', { isActive: isAutoTranslateActive });
  updateTrayMenu();
}

// IPC Handler: Synchronize Auto-Translate toggle state
ipcMain.on('toggle-auto-translate', (event, activeState) => {
  toggleAutoTranslateState(activeState);
});

// IPC Handler: Synchronize translation provider
ipcMain.on('update-translation-provider', (event, provider) => {
  translationProvider = provider;
  translationEngine.setProvider(provider);
});

// IPC Handler: Synchronize translation shortcut
ipcMain.on('update-translation-shortcut', (event, shortcut) => {
  translationShortcut = shortcut;
  if (isAutoTranslateActive) {
    startArrowTranslateMonitor();
  }
});

// IPC Handler: Auto-adjust window height to fit content perfectly
ipcMain.on('adjust-window-height', (event, neededHeight) => {
  if (mainWindow && !mainWindow.isDestroyed()) {
    const { screen } = require('electron');
    const [currentWidth, currentHeight] = mainWindow.getSize();
    const display = screen.getDisplayNearestPoint(mainWindow.getBounds());
    const maxHeight = display.workAreaSize.height - 40;
    const targetHeight = Math.min(Math.max(Math.round(neededHeight), 480), maxHeight);
    if (Math.abs(currentHeight - targetHeight) > 3) {
      mainWindow.setSize(currentWidth, targetHeight);
    }
  }
});

// Floating HUD IPC Handlers
ipcMain.on('hide-hud', () => {
  if (hudWindow && !hudWindow.isDestroyed() && hudWindow.isVisible()) {
    hudWindow.hide();
  }
  setTimeout(() => { isHudActive = false; }, 600);
});

ipcMain.on('copy-to-clipboard', (event, text) => {
  const { clipboard } = require('electron');
  clipboard.writeText(text);
});

ipcMain.on('update-hud-height', (event, height) => {
  if (hudWindow && !hudWindow.isDestroyed()) {
    const [w] = hudWindow.getSize();
    hudWindow.setSize(w, Math.round(height));
  }
});

// IPC Handler: Request current status on DOMContentLoaded
ipcMain.handle('get-current-status', () => {
  return {
    isActive,
    intervalMinutes,
    targetAppName,
    isAutoTranslateActive,
    translationProvider,
    translationShortcut
  };
});

// IPC Handler: Check Accessibility Permission (kept for legacy support, not required for Cocoa)
ipcMain.handle('check-accessibility', () => {
  return systemPreferences.isTrustedAccessibilityClient(false);
});

// IPC Handler: Get running visible application names
ipcMain.handle('get-running-apps', async () => {
  const jxaScript = `
    ObjC.import('Cocoa');
    var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    var list = [];
    for (var i = 0; i < apps.count; i++) {
        var app = apps.objectAtIndex(i);
        if (app.activationPolicy == 0) {
            var name = ObjC.unwrap(app.localizedName);
            if (name) list.push(name);
        }
    }
    list.join("|");
  `;
  try {
    const result = await runJXA(jxaScript);
    const apps = result.split('|').map(app => app.trim()).filter(app => app.length > 0);
    return { success: true, apps };
  } catch (error) {
    console.error('Error getting running apps:', error);
    return { success: false, error: error.message };
  }
});

// IPC Handler: Open Accessibility Settings
ipcMain.on('open-accessibility-settings', () => {
  shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');
});

// Window control handlers
ipcMain.on('minimize-to-tray', () => {
  if (mainWindow) mainWindow.hide();
});

ipcMain.on('quit-app', () => {
  isQuitting = true;
  app.quit();
});

// Timer Routine Execution: Cocoa Window Switching / Mouse Jiggle
function getSystemIdleTime() {
  return new Promise((resolve) => {
    const { exec } = require('child_process');
    exec("ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF/1000000000; exit}'", (err, stdout) => {
      if (err) {
        resolve(0);
      } else {
        const seconds = parseFloat(stdout.trim());
        resolve(isNaN(seconds) ? 0 : seconds);
      }
    });
  });
}

// Timer Routine Execution: Cocoa Window Switching / Mouse Jiggle
async function runWakeIteration(force = false) {
  if (!isActive || isSystemSuspended) return;

  const scheduleNext = () => {
    if (isActive) {
      if (timerId) clearTimeout(timerId);
      timerId = setTimeout(runWakeIteration, intervalMinutes * 60 * 1000);
    }
  };

  if (!force) {
    const idleTime = await getSystemIdleTime();
    const threshold = intervalMinutes * 60;

    if (idleTime < threshold) {
      sendToRenderer('log', {
        msg: `System active (idle time: ${Math.round(idleTime)}s < configured interval: ${threshold}s). Skipping keep-alive check.`,
        type: 'info'
      });
      scheduleNext();
      return;
    }

    sendToRenderer('log', {
      msg: `System idle for ${Math.round(idleTime)}s. Executing keep-alive signal...`,
      type: 'info'
    });
  } else {
    sendToRenderer('log', {
      msg: `Executing initial keep-alive test...`,
      type: 'info'
    });
  }

  const jxaScript = `
    ObjC.import('Cocoa');
    var workspace = $.NSWorkspace.sharedWorkspace;
    var activeApp = workspace.frontmostApplication;
    var activeAppName = ObjC.unwrap(activeApp.localizedName) || "Unknown";
    
    var apps = workspace.runningApplications;
    var targetKeyword = "${targetAppName}";
    var targetApp = null;
    var matchedName = "";
    
    for (var i = 0; i < apps.count; i++) {
        var app = apps.objectAtIndex(i);
        var name = ObjC.unwrap(app.localizedName);
        if (name && name.toLowerCase().indexOf(targetKeyword.toLowerCase()) !== -1) {
            targetApp = app;
            matchedName = name;
            break;
        }
    }
    
    var launched = false;
    if (!targetApp) {
        var launchNames = [targetKeyword, "Microsoft Teams", "Microsoft Teams (work or school)"];
        for (var j = 0; j < launchNames.length; j++) {
            if (workspace.launchApplication(launchNames[j])) {
                launched = true;
                break;
            }
        }
        if (launched) {
            $.NSThread.sleepForTimeInterval(3.0);
            apps = workspace.runningApplications;
            for (var i = 0; i < apps.count; i++) {
                var app = apps.objectAtIndex(i);
                var name = ObjC.unwrap(app.localizedName);
                if (name && name.toLowerCase().indexOf(targetKeyword.toLowerCase()) !== -1) {
                    targetApp = app;
                    matchedName = name;
                    break;
                }
            }
        }
    }
    
    var activated = false;
    var actionTaken = "none";
    var foundProcessName = "";
    
    if (targetApp) {
        var hasAccessibility = false;
        try {
            var systemEvents = Application("System Events");
            var p = systemEvents.processes();
            hasAccessibility = true;
        } catch(e) {}

        if (hasAccessibility) {
            activated = targetApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
            $.NSThread.sleepForTimeInterval(1.0);
            
            try {
                var systemEvents = Application("System Events");
                var processes = systemEvents.processes();
                var targetProcess = null;
                for (var i = 0; i < processes.length; i++) {
                    var pName = processes[i].name();
                    if (pName && (pName.toLowerCase().indexOf("teams") !== -1 || pName.toLowerCase().indexOf(targetKeyword.toLowerCase()) !== -1)) {
                        targetProcess = processes[i];
                        foundProcessName = pName;
                        break;
                    }
                }
                
                if (targetProcess) {
                    targetProcess.frontmost = true;
                    $.NSThread.sleepForTimeInterval(0.5);
                    
                    try {
                        var windows = targetProcess.windows();
                        for (var w = 0; w < windows.length; w++) {
                            if (windows[w].attributes.byName("AXMinimized").value() === true) {
                                windows[w].attributes.byName("AXMinimized").value = false;
                            }
                        }
                        $.NSThread.sleepForTimeInterval(0.5);
                    } catch(wErr) {}
                    
                    // Clear any active dropdowns/modals/focus blocks (Escape key = KeyCode 53)
                    systemEvents.keyCode(53);
                    $.NSThread.sleepForTimeInterval(0.3);
                    
                    // Switch to Chat tab (Cmd + 2 - KeyCode 19 is layout-independent)
                    // We send it twice with a delay to handle virtual desktop Space switching or window focus transition latency
                    systemEvents.keyCode(19, { using: "command down" });
                    $.NSThread.sleepForTimeInterval(1.0);
                    systemEvents.keyCode(19, { using: "command down" });
                    $.NSThread.sleepForTimeInterval(1.5);
                    
                    // Switch down 3 times
                    for (var k = 0; k < 3; k++) {
                        systemEvents.keyCode(125, { using: "option down" });
                        $.NSThread.sleepForTimeInterval(2.0);
                    }
                    
                    // Switch back up 3 times
                    for (var k = 0; k < 3; k++) {
                        systemEvents.keyCode(126, { using: "option down" });
                        $.NSThread.sleepForTimeInterval(2.0);
                    }
                    
                    actionTaken = "chat_switch";
                } else {
                    actionTaken = "wiggle_fallback_no_process";
                }
            } catch (e) {
                actionTaken = "wiggle_fallback_error: " + e.message;
            }
            
            activeApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
        } else {
            actionTaken = "wiggle_fallback_no_accessibility";
        }
    } else {
        actionTaken = "wiggle_fallback_no_target_app";
    }
    
    // Fallback to Mouse Jiggle if we didn't switch chat
    if (actionTaken !== "chat_switch") {
        var loc = $.NSEvent.mouseLocation;
        var screenHeight = $.NSScreen.mainScreen.frame.size.height;
        var currentX = loc.x;
        var currentY = screenHeight - loc.y;
        var pt1 = $.CGPointMake(currentX + 2, currentY + 2);
        var pt2 = $.CGPointMake(currentX, currentY);
        
        $.CGWarpMouseCursorPosition(pt1);
        $.NSThread.sleepForTimeInterval(0.05);
        $.CGWarpMouseCursorPosition(pt2);
        
        if (actionTaken === "none") {
            actionTaken = "mouse_wiggle";
        }
    }
    
    var status = {
        matchedName: matchedName || targetKeyword,
        foundProcessName: foundProcessName,
        prevApp: activeAppName,
        activated: activated,
        launched: launched,
        actionTaken: actionTaken
    };
    JSON.stringify(status);
  `;

  try {
    const result = await runJXA(jxaScript);
    const status = JSON.parse(result);

    if (status.launched) {
      sendToRenderer('log', {
        msg: `Target app "${status.matchedName || targetAppName}" was not running. Started it successfully.`,
        type: 'info'
      });
    }

    if (status.actionTaken === 'chat_switch') {
      sendToRenderer('log', {
        msg: `Target app "${status.matchedName || targetAppName}" focused & chats switched successfully. Restored focus to "${status.prevApp || 'Unknown'}".`,
        type: 'success'
      });
    } else if (status.actionTaken === 'mouse_wiggle') {
      sendToRenderer('log', {
        msg: 'Mouse wiggled successfully to keep system active.',
        type: 'success'
      });
    } else if (status.actionTaken === 'wiggle_fallback_no_accessibility') {
      sendToRenderer('log', {
        msg: `Accessibility permission missing. Performed fallback mouse jiggle to keep system awake.`,
        type: 'warning'
      });
    } else if (status.actionTaken.startsWith('wiggle_fallback_error:')) {
      const errMsg = status.actionTaken.replace('wiggle_fallback_error: ', '');
      sendToRenderer('log', {
        msg: `Keystroke simulation failed (${errMsg}). Performed fallback mouse jiggle.`,
        type: 'warning'
      });
    } else if (status.actionTaken === 'wiggle_fallback_no_process') {
      sendToRenderer('log', {
        msg: `Process for "${targetAppName}" not found. Performed fallback mouse jiggle.`,
        type: 'warning'
      });
    } else if (status.actionTaken === 'wiggle_fallback_no_target_app') {
      sendToRenderer('log', {
        msg: `Target app containing "${targetAppName}" could not be opened. Performed fallback mouse jiggle.`,
        type: 'warning'
      });
    }
  } catch (error) {
    sendToRenderer('log', { msg: `Execution error: ${error.message}. Running emergency mouse jiggle.`, type: 'error' });
    await performMouseJiggle();
  } finally {
    scheduleNext();
  }
}

async function performMouseJiggle() {
  const jxaScript = `
    ObjC.import('Cocoa');
    var loc = $.NSEvent.mouseLocation;
    var screenHeight = $.NSScreen.mainScreen.frame.size.height;
    var currentX = loc.x;
    var currentY = screenHeight - loc.y;
    var pt1 = $.CGPointMake(currentX + 2, currentY + 2);
    var pt2 = $.CGPointMake(currentX, currentY);
    
    $.CGWarpMouseCursorPosition(pt1);
    $.NSThread.sleepForTimeInterval(0.05);
    $.CGWarpMouseCursorPosition(pt2);
    "Success";
  `;

  try {
    await runJXA(jxaScript);
    sendToRenderer('log', { msg: 'Mouse wiggled successfully to keep system active.', type: 'success' });
  } catch (error) {
    sendToRenderer('log', { msg: `Mouse wiggle failed: ${error.message}`, type: 'error' });
  }
}

async function fallbackToWiggle() {
  sendToRenderer('log', { msg: 'Initiating fallback mouse jiggle to keep system awake...', type: 'warning' });
  await performMouseJiggle();
}

// Helper: Run JXA via piped stdin
function runJXA(script) {
  return new Promise((resolve, reject) => {
    const child = spawn('osascript', ['-l', 'JavaScript']);
    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    child.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(stderr.trim()));
      } else {
        resolve(stdout.trim());
      }
    });

    child.stdin.write(script);
    child.stdin.end();
  });
}
