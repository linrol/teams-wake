const { app, BrowserWindow, ipcMain, Tray, Menu, systemPreferences, shell } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

let mainWindow;
let tray;
let isQuitting = false;

// Keep-alive state managed in the main process
let isActive = false;
let intervalMinutes = 3;
let targetAppName = 'Microsoft Teams';
let timerId = null;
let startupTimeoutId = null;

// Path to system tray status PNG icons
const inactiveIconPath = path.join(__dirname, 'assets', 'iconTemplate.png');
const activeIconPath = path.join(__dirname, 'assets', 'iconActive.png');

let contextMenu;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 380,
    height: 680,
    minWidth: 320,
    minHeight: 450,
    resizable: true,
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

  app.on('activate', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
    } else {
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
  intervalMinutes = settings.interval;
  targetAppName = settings.targetApp;

  // If timer is already running, restart it with new interval
  if (isActive) {
    if (timerId) clearTimeout(timerId);
    timerId = setTimeout(runWakeIteration, intervalMinutes * 60 * 1000);
  }
});

// IPC Handler: Synchronize active toggle state from the UI checkbox
ipcMain.on('toggle-active', (event, activeState) => {
  toggleWakeState(activeState);
});

// IPC Handler: Request current status on DOMContentLoaded
ipcMain.handle('get-current-status', () => {
  return { isActive, intervalMinutes, targetAppName };
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
  if (!isActive) return;

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
