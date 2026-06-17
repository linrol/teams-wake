// Renderer Process

// Local state variables (synchronized with Main Process)
let isActive = false;
let intervalMinutes = 3;
let targetApp = 'Teams';

// DOM Elements
const wakeToggle = document.getElementById('wake-toggle');
const btnMinimize = document.getElementById('btn-minimize');
const statusRing = document.getElementById('status-ring');
const iconPath = document.getElementById('icon-path');
const statusText = document.getElementById('status-text');
const statusSubtext = document.getElementById('status-subtext');
const targetAppGroup = document.getElementById('target-app-group');
const targetAppSelect = document.getElementById('target-app-select');
const targetAppInput = document.getElementById('target-app');
const btnRefreshApps = document.getElementById('btn-refresh-apps');
const intervalSlider = document.getElementById('interval-slider');
const intervalVal = document.getElementById('interval-val');
const logContainer = document.getElementById('log-container');
const btnClearLog = document.getElementById('btn-clear-log');
const permissionWarning = document.getElementById('permission-warning');
const btnOpenAccessibility = document.getElementById('btn-open-accessibility');

// Icons SVG Paths
const ICON_ACTIVE = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z";
const ICON_INACTIVE = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm4-9H8v2h8v-2z";

// Initialize
window.addEventListener('DOMContentLoaded', async () => {
  // Load running apps first
  await loadRunningApps();

  // Sync state from the Main process
  if (typeof window.api !== 'undefined') {
    try {
      const status = await window.api.getCurrentStatus();
      isActive = status.isActive;
      intervalMinutes = status.intervalMinutes;
      targetApp = status.targetAppName;

      // Update UI Elements
      wakeToggle.checked = isActive;
      updateStatusUI(isActive);

      // Set Interval Slider
      intervalSlider.value = intervalMinutes;
      intervalVal.textContent = `${intervalMinutes} min`;

      // Pre-select the target application
      if (Array.from(targetAppSelect.options).some(opt => opt.value === targetApp)) {
        targetAppSelect.value = targetApp;
        targetAppInput.classList.add('hidden');
      } else {
        targetAppSelect.value = 'custom';
        targetAppInput.value = targetApp;
        targetAppInput.classList.remove('hidden');
      }

      // Check accessibility permission on startup
      await checkAndShowPermissionWarning();
    } catch (err) {
      console.error('Failed to get status:', err);
    }
  }
});

// Write to Log Console
function log(msg, type = 'info') {
  const time = new Date().toLocaleTimeString();
  const entry = document.createElement('div');
  entry.className = `log-entry ${type}`;
  entry.innerHTML = `
    <span class="log-time">[${time}]</span>
    <span class="log-msg">${msg}</span>
  `;
  logContainer.prepend(entry);
}

// Sync settings to the Main process
function syncSettings() {
  if (typeof window.api !== 'undefined') {
    window.api.updateSettings({
      interval: intervalMinutes,
      targetApp
    });
  }
}

// Accessibility Permission Check
async function checkAndShowPermissionWarning() {
  if (typeof window.api === 'undefined') return;
  const hasPermission = await window.api.checkAccessibility();
  if (!hasPermission) {
    permissionWarning.classList.remove('hidden');
  } else {
    permissionWarning.classList.add('hidden');
  }
}

// Open Accessibility Settings click handler
btnOpenAccessibility.addEventListener('click', () => {
  if (typeof window.api !== 'undefined') {
    window.api.openAccessibilitySettings();
  }
});

// Re-check permission when app window is focused
window.addEventListener('focus', async () => {
  await checkAndShowPermissionWarning();
});

// Populate running applications in the dropdown
async function loadRunningApps() {
  if (typeof window.api === 'undefined') return;
  
  const originalValue = targetAppSelect.value;
  const customOption = targetAppSelect.querySelector('option[value="custom"]');
  targetAppSelect.innerHTML = '';
  
  try {
    const response = await window.api.getRunningApps();
    let hasTeams = false;
    
    if (response.success && response.apps) {
      response.apps.sort((a, b) => a.localeCompare(b));
      
      response.apps.forEach(app => {
        if (app === 'Electron' || app === 'Teams Wake') return;
        
        const option = document.createElement('option');
        option.value = app;
        option.textContent = app;
        targetAppSelect.appendChild(option);
        
        if (app.toLowerCase().includes('teams')) {
          hasTeams = true;
        }
      });
    }
    
    if (!hasTeams) {
      const option = document.createElement('option');
      option.value = 'Microsoft Teams';
      option.textContent = 'Microsoft Teams (Not Running)';
      targetAppSelect.insertBefore(option, targetAppSelect.firstChild);
    }
    
    targetAppSelect.appendChild(customOption);
    
    let selectedValue = 'Microsoft Teams';
    if (originalValue && Array.from(targetAppSelect.options).some(opt => opt.value === originalValue)) {
      selectedValue = originalValue;
    } else {
      const teamsOption = Array.from(targetAppSelect.options).find(opt => opt.value.toLowerCase().includes('teams'));
      if (teamsOption) {
        selectedValue = teamsOption.value;
      }
    }
    
    targetAppSelect.value = selectedValue;
    handleAppSelectionChange();
  } catch (err) {
    log(`Failed to query running applications: ${err.message}`, 'error');
    targetAppSelect.appendChild(customOption);
  }
}

function handleAppSelectionChange() {
  const value = targetAppSelect.value;
  if (value === 'custom') {
    targetAppInput.classList.remove('hidden');
    targetApp = targetAppInput.value.trim() || 'Teams';
  } else {
    targetAppInput.classList.add('hidden');
    targetApp = value;
  }
}

function updateStatusUI(activeState) {
  if (activeState) {
    statusRing.classList.add('active');
    iconPath.setAttribute('d', ICON_ACTIVE);
    statusText.textContent = 'Active';
    statusSubtext.textContent = `Running every ${intervalMinutes} min`;
  } else {
    statusRing.classList.remove('active');
    iconPath.setAttribute('d', ICON_INACTIVE);
    statusText.textContent = 'Inactive';
    statusSubtext.textContent = 'Wake-up is currently disabled';
  }
}

// App Dropdown Selection Change
targetAppSelect.addEventListener('change', () => {
  handleAppSelectionChange();
  log(`Target app updated to: "${targetApp}"`, 'system-msg');
  syncSettings();
});

// Refresh button click
btnRefreshApps.addEventListener('click', async () => {
  log('Refreshing running applications list...', 'info');
  await loadRunningApps();
  syncSettings();
});

// Target App Manual Input Change
targetAppInput.addEventListener('change', (e) => {
  targetApp = e.target.value.trim() || 'Teams';
  log(`Target custom app updated to: "${targetApp}"`, 'system-msg');
  syncSettings();
});

// Interval Slider Input
intervalSlider.addEventListener('input', (e) => {
  intervalMinutes = parseInt(e.target.value, 10);
  intervalVal.textContent = `${intervalMinutes} min`;
});

intervalSlider.addEventListener('change', () => {
  log(`Wake-up interval adjusted to: ${intervalMinutes} minutes`, 'system-msg');
  syncSettings();
});

// Wake Toggle Checkbox Change
wakeToggle.addEventListener('change', async (e) => {
  if (e.target.checked) {
    // 1. Check Accessibility Permission
    const hasPermission = await window.api.checkAccessibility();
    if (!hasPermission) {
      log('Cannot enable: Accessibility permission is required.', 'error');
      alert('Cannot enable Smart Wake:\nAccessibility permission is required. Please grant permission in System Settings first.');
      e.target.checked = false;
      window.api.openAccessibilitySettings();
      return;
    }

    // 2. Check if Target App (Teams) is running
    const response = await window.api.getRunningApps();
    let teamsRunning = false;
    if (response.success && response.apps) {
      teamsRunning = response.apps.some(app => app.toLowerCase().includes(targetApp.toLowerCase()));
    }
    if (!teamsRunning) {
      log(`Cannot enable: "${targetApp}" is not running.`, 'error');
      alert(`Cannot enable Smart Wake:\n"${targetApp}" is not running. Please open it first.`);
      e.target.checked = false;
      return;
    }
  }

  if (typeof window.api !== 'undefined') {
    window.api.toggleActive(e.target.checked);
  }
});

// Window Controls
btnMinimize.addEventListener('click', () => {
  window.api.minimizeToTray();
});

btnClearLog.addEventListener('click', () => {
  logContainer.innerHTML = '';
  log('Logs cleared.', 'system-msg');
});

// IPC listeners for updates coming from the Main Process (e.g. Tray clicks)
if (typeof window.api !== 'undefined') {
  window.api.onStatusChanged((data) => {
    isActive = data.isActive;
    wakeToggle.checked = isActive;
    updateStatusUI(isActive);
  });

  window.api.onSettingsChanged(async (data) => {
    intervalMinutes = data.intervalMinutes;
    targetApp = data.targetAppName;

    // Update Interval Slider & Value Text
    intervalSlider.value = intervalMinutes;
    intervalVal.textContent = `${intervalMinutes} min`;
    
    // Update Subtext in Status Panel if active
    if (isActive) {
      statusSubtext.textContent = `Running every ${intervalMinutes} min`;
    }

    // Pre-select the target application
    if (Array.from(targetAppSelect.options).some(opt => opt.value === targetApp)) {
      targetAppSelect.value = targetApp;
      targetAppInput.classList.add('hidden');
    } else {
      targetAppSelect.value = 'custom';
      targetAppInput.value = targetApp;
      targetAppInput.classList.remove('hidden');
    }

    await checkAndShowPermissionWarning();
  });

  window.api.onLog((data) => {
    log(data.msg, data.type);
  });
}
