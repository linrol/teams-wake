const { app, BrowserWindow, ipcMain, Tray, Menu, systemPreferences, shell } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

let mainWindow;
let tray;
let isQuitting = false;

// Keep-alive state managed in the main process
let isActive = false;
let mode = 'focus'; // 'focus' or 'wiggle'
let intervalMinutes = 3;
let targetAppName = 'Microsoft Teams';
let timerId = null;

// Path to system tray status PNG icons
const inactiveIconPath = path.join(__dirname, 'assets', 'iconTemplate.png');
const activeIconPath = path.join(__dirname, 'assets', 'iconActive.png');

let contextMenu;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 380,
    height: 520,
    resizable: false,
    frame: false,
    titleBarStyle: 'hidden',
    vibrancy: 'under-window',
    visualEffectState: 'active',
    backgroundColor: '#00000000', // transparent for vibrancy
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
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
    { type: 'separator' },
    {
      label: 'Mode',
      submenu: [
        {
          label: 'Window Switch',
          type: 'radio',
          checked: mode === 'focus',
          click: () => {
            updateModeAndSync('focus');
          }
        },
        {
          label: 'Mouse Jiggle',
          type: 'radio',
          checked: mode === 'wiggle',
          click: () => {
            updateModeAndSync('wiggle');
          }
        }
      ]
    },
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
          mainWindow.show();
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

function updateModeAndSync(newMode) {
  mode = newMode;
  sendToRenderer('settings-changed-from-main', { mode, intervalMinutes, targetAppName });
  if (isActive) {
    if (timerId) clearInterval(timerId);
    timerId = setInterval(runWakeIteration, intervalMinutes * 60 * 1000);
    runWakeIteration(); // run immediately with new mode
  }
  updateTrayMenu();
  sendToRenderer('log', { msg: `Mode changed to "${mode === 'focus' ? 'Window Switch' : 'Mouse Jiggle'}" from Status Bar`, type: 'info' });
}

function updateIntervalAndSync(newInterval) {
  intervalMinutes = newInterval;
  sendToRenderer('settings-changed-from-main', { mode, intervalMinutes, targetAppName });
  if (isActive) {
    if (timerId) clearInterval(timerId);
    timerId = setInterval(runWakeIteration, intervalMinutes * 60 * 1000);
  }
  updateTrayMenu();
  sendToRenderer('log', { msg: `Interval changed to ${intervalMinutes} minutes from Status Bar`, type: 'info' });
}

// Global state controller to turn Keep-Alive ON/OFF
function toggleWakeState(enabled) {
  if (isActive === enabled) return;
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
      msg: `Wake-up service STARTED (Interval: ${intervalMinutes}m, Mode: ${mode === 'focus' ? 'Window Switch' : 'Mouse Jiggle'})`, 
      type: 'success' 
    });
    runWakeIteration(); // run once immediately
    
    if (timerId) clearInterval(timerId);
    timerId = setInterval(runWakeIteration, intervalMinutes * 60 * 1000);
  } else {
    sendToRenderer('log', { msg: 'Wake-up service STOPPED', type: 'warning' });
    if (timerId) {
      clearInterval(timerId);
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
  createTray();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// IPC Handler: Synchronize settings changed in the frontend UI
ipcMain.on('settings-changed', (event, settings) => {
  mode = settings.mode;
  intervalMinutes = settings.interval;
  targetAppName = settings.targetApp;
  
  // If timer is already running, restart it with new interval
  if (isActive) {
    if (timerId) clearInterval(timerId);
    timerId = setInterval(runWakeIteration, intervalMinutes * 60 * 1000);
  }
});

// IPC Handler: Synchronize active toggle state from the UI checkbox
ipcMain.on('toggle-active', (event, activeState) => {
  toggleWakeState(activeState);
});

// IPC Handler: Request current status on DOMContentLoaded
ipcMain.handle('get-current-status', () => {
  return { isActive, mode, intervalMinutes, targetAppName };
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
async function runWakeIteration() {
  if (!isActive) return;

  sendToRenderer('log', { msg: 'Executing keep-alive signal...', type: 'info' });

  if (mode === 'focus') {
    // 1. Focus Mode using JXA Cocoa APIs
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
      
      var activated = false;
      if (targetApp) {
          activated = targetApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
          $.NSThread.sleepForTimeInterval(0.5);
          activeApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
      }
      matchedName + "," + activeAppName + "," + activated;
    `;

    try {
      const result = await runJXA(jxaScript);
      const [matchedName, prevApp, activatedStr] = result.split(',');
      const found = activatedStr === 'true';

      if (found) {
        sendToRenderer('log', {
          msg: `Target app "${matchedName || targetAppName}" brought to front, and restored focus to "${prevApp || 'Unknown'}".`,
          type: 'success'
        });
      } else {
        sendToRenderer('log', {
          msg: `Target app containing "${targetAppName}" is not running.`,
          type: 'warning'
        });
        await fallbackToWiggle();
      }
    } catch (error) {
      sendToRenderer('log', { msg: `Execution error: ${error.message}`, type: 'error' });
      await fallbackToWiggle();
    }
  } else {
    // 2. Mouse Jiggle Mode
    await performMouseJiggle();
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
