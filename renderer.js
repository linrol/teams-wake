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

// Auto-Translate DOM Elements
const translateToggle = document.getElementById('translate-toggle');
const translateProviderSelect = document.getElementById('translate-provider-select');
const translateShortcutSelect = document.getElementById('translate-shortcut-select');
const translateDismissSelect = document.getElementById('translate-dismiss-select');
const btnRecordShortcut = document.getElementById('btn-record-shortcut');
const shortcutRecordingBox = document.getElementById('shortcut-recording-box');
const customShortcutOption = document.getElementById('custom-shortcut-option');
const shortcutDescKey = document.getElementById('shortcut-desc-key');

// Schedule DOM Elements & State
const scheduleToggle = document.getElementById('schedule-toggle');
const scheduleStatusBadge = document.getElementById('schedule-status-badge');
const scheduleList = document.getElementById('schedule-list');
const btnAddSchedule = document.getElementById('btn-add-schedule');
const scheduleCollapseToggle = document.getElementById('schedule-collapse-toggle');
const btnToggleSchedule = document.getElementById('btn-toggle-schedule');
const scheduleBody = document.getElementById('schedule-body');
const wakeScheduleAccessory = document.querySelector('.wake-schedule-accessory');

// Tab Navigation DOM Elements
const tabButtons = document.querySelectorAll('.tab-btn');
const tabPanels = document.querySelectorAll('.tab-panel');

let scheduleEnabled = false;
let schedules = [];
let isScheduleWindowActive = false;
let activeScheduleName = null;

const DAY_LABELS = [
  { day: 1, label: 'M', title: 'Monday' },
  { day: 2, label: 'T', title: 'Tuesday' },
  { day: 3, label: 'W', title: 'Wednesday' },
  { day: 4, label: 'T', title: 'Thursday' },
  { day: 5, label: 'F', title: 'Friday' },
  { day: 6, label: 'S', title: 'Saturday' },
  { day: 0, label: 'S', title: 'Sunday' }
];


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

      // Sync Auto-Translate Settings
      if (status.isAutoTranslateActive !== undefined && translateToggle) {
        translateToggle.checked = status.isAutoTranslateActive;
      }

      if (status.translationProvider && translateProviderSelect) {
        translateProviderSelect.value = status.translationProvider;
      }

      if (status.translationDismissSeconds !== undefined && translateDismissSelect) {
        translateDismissSelect.value = String(status.translationDismissSeconds);
      }

      // Sync Translation Shortcut
      if (status.translationShortcut && translateShortcutSelect) {
        const targetJson = JSON.stringify(status.translationShortcut);
        let matched = false;
        for (let i = 0; i < translateShortcutSelect.options.length; i++) {
          try {
            const optVal = JSON.parse(translateShortcutSelect.options[i].value);
            if (optVal.keyCode === status.translationShortcut.keyCode && optVal.modifiers === status.translationShortcut.modifiers) {
              translateShortcutSelect.selectedIndex = i;
              matched = true;
              break;
            }
          } catch (_) {}
        }
        if (!matched && status.translationShortcut.label) {
          customShortcutOption.value = targetJson;
          customShortcutOption.textContent = `★ ${status.translationShortcut.label} (Custom)`;
          customShortcutOption.style.display = 'block';
          translateShortcutSelect.value = targetJson;
        }
        if (shortcutDescKey && status.translationShortcut.label) {
          shortcutDescKey.textContent = status.translationShortcut.label;
        }
      }

      // Sync Schedule Settings
      if (status.scheduleEnabled !== undefined && scheduleToggle) {
        scheduleEnabled = status.scheduleEnabled;
        scheduleToggle.checked = scheduleEnabled;
      }
      if (Array.isArray(status.schedules)) {
        schedules = status.schedules;
      }
      isScheduleWindowActive = !!status.isScheduleWindowActive;
      renderScheduleList();
      updateScheduleBadge();

      // Check accessibility permission on startup
      await checkAndShowPermissionWarning();
      
      // Auto-adapt window height to content
      autoFitWindow();
    } catch (err) {
      console.error('Failed to get status:', err);
    }
  }
});
window.addEventListener('load', autoFitWindow);

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
  autoFitWindow();
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
  autoFitWindow();
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

if (typeof window.api !== 'undefined' && window.api.onAccessibilityStateChanged) {
  window.api.onAccessibilityStateChanged(async (hasPermission) => {
    if (!hasPermission) {
      permissionWarning.classList.remove('hidden');
    } else {
      permissionWarning.classList.add('hidden');
    }
    autoFitWindow();
  });
}

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
  autoFitWindow();
}

function updateStatusUI(activeState) {
  const statusPanel = document.getElementById('status-panel');
  if (activeState) {
    if (statusPanel) statusPanel.classList.add('active');
    statusRing.classList.add('active');
    iconPath.setAttribute('d', ICON_ACTIVE);
    statusText.textContent = 'Active';
    statusSubtext.textContent = `Running every ${intervalMinutes} min`;
  } else {
    if (statusPanel) statusPanel.classList.remove('active');
    statusRing.classList.remove('active');
    iconPath.setAttribute('d', ICON_INACTIVE);
    statusText.textContent = 'Inactive';
    if (scheduleEnabled) {
      statusSubtext.textContent = 'Wake-up is currently idle (Scheduled)';
    } else {
      statusSubtext.textContent = 'Wake-up is currently disabled';
    }
  }
}

function updateScheduleBadge() {
  if (scheduleStatusBadge) {
    scheduleStatusBadge.className = 'badge-schedule';
    if (!scheduleEnabled) {
      scheduleStatusBadge.classList.add('status-off');
      scheduleStatusBadge.textContent = 'Disabled';
    } else if (isScheduleWindowActive) {
      scheduleStatusBadge.classList.add('status-active');
      scheduleStatusBadge.textContent = 'Active';
    } else {
      scheduleStatusBadge.classList.add('status-waiting');
      scheduleStatusBadge.textContent = 'Waiting';
    }
  }
}


function syncScheduleSettings() {
  if (typeof window.api !== 'undefined' && window.api.updateScheduleSettings) {
    window.api.updateScheduleSettings({
      scheduleEnabled,
      schedules
    });
  }
}

// Clean Direct Keyboard & Arrow-key Time Input (No Ugly Browser Popups)
function formatTimeStr(val, fallback = '09:00') {
  if (!val) return fallback;
  val = val.trim().replace(/[^\d:]/g, '');
  if (!val) return fallback;

  // Single or double digits: e.g. "9" -> "09:00", "18" -> "18:00"
  if (/^\d{1,2}$/.test(val)) {
    const h = Math.min(23, Math.max(0, parseInt(val, 10)));
    return `${String(h).padStart(2, '0')}:00`;
  }
  // 3 or 4 digits without colon: e.g. "930" -> "09:30", "1830" -> "18:30"
  if (/^\d{3,4}$/.test(val)) {
    const padded = val.padStart(4, '0');
    let h = Math.min(23, Math.max(0, parseInt(padded.slice(0, 2), 10)));
    let m = Math.min(59, Math.max(0, parseInt(padded.slice(2, 4), 10)));
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  }
  // Standard colon format: e.g. "9:30", "18:00"
  const parts = val.split(':');
  if (parts.length >= 2) {
    let h = parseInt(parts[0], 10);
    let m = parseInt(parts[1], 10);
    if (isNaN(h)) h = 0;
    if (isNaN(m)) m = 0;
    h = Math.min(23, Math.max(0, h));
    m = Math.min(59, Math.max(0, m));
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  }
  return fallback;
}

function createTimeInput(initialTime, onChange) {
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'schedule-time-input';
  input.value = initialTime || '09:00';
  input.placeholder = '09:00';
  input.maxLength = 5;
  input.spellcheck = false;

  let currentVal = input.value;

  const commitValue = () => {
    const formatted = formatTimeStr(input.value, currentVal);
    input.value = formatted;
    if (formatted !== currentVal) {
      currentVal = formatted;
      onChange(formatted);
    }
  };

  input.addEventListener('change', commitValue);
  input.addEventListener('blur', commitValue);

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      input.blur();
    }
  });

  return input;
}

function renderScheduleList() {
  if (!scheduleList) return;
  scheduleList.innerHTML = '';

  if (!schedules || schedules.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'schedule-empty';
    empty.textContent = 'No schedules configured. Click "+ Add Schedule" below.';
    scheduleList.appendChild(empty);
    autoFitWindow();
    return;
  }

  schedules.forEach((schedule, index) => {
    const item = document.createElement('div');
    item.className = `schedule-item${!schedule.enabled ? ' is-disabled' : ''}`;
    item.dataset.id = schedule.id;

    // Header row: Name input, toggle switch, and delete button
    const topRow = document.createElement('div');
    topRow.className = 'schedule-item-top';

    const nameInput = document.createElement('input');
    nameInput.type = 'text';
    nameInput.className = 'schedule-name-input';
    nameInput.value = schedule.name || `Schedule ${index + 1}`;
    nameInput.placeholder = 'Schedule Name';
    nameInput.addEventListener('change', (e) => {
      schedule.name = e.target.value.trim() || `Schedule ${index + 1}`;
      syncScheduleSettings();
    });

    const controls = document.createElement('div');
    controls.className = 'schedule-item-controls';

    // Switch container
    const switchLabel = document.createElement('label');
    switchLabel.className = 'switch-container switch-xs';
    const switchInput = document.createElement('input');
    switchInput.type = 'checkbox';
    switchInput.checked = !!schedule.enabled;
    const sliderSpan = document.createElement('span');
    sliderSpan.className = 'slider';
    switchLabel.appendChild(switchInput);
    switchLabel.appendChild(sliderSpan);

    switchInput.addEventListener('change', (e) => {
      schedule.enabled = e.target.checked;
      if (schedule.enabled) {
        item.classList.remove('is-disabled');
      } else {
        item.classList.add('is-disabled');
      }
      syncScheduleSettings();
      log(`Schedule "${schedule.name}" ${schedule.enabled ? 'enabled' : 'disabled'}`, 'info');
    });

    // Delete button
    const deleteBtn = document.createElement('button');
    deleteBtn.type = 'button';
    deleteBtn.className = 'btn-delete-schedule';
    deleteBtn.title = 'Delete Schedule';
    deleteBtn.innerHTML = `
      <svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor">
        <path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/>
      </svg>
    `;
    deleteBtn.addEventListener('click', () => {
      const removedName = schedule.name || 'Schedule';
      schedules.splice(index, 1);
      renderScheduleList();
      syncScheduleSettings();
      log(`Schedule "${removedName}" deleted.`, 'warning');
    });

    controls.appendChild(switchLabel);
    controls.appendChild(deleteBtn);

    topRow.appendChild(nameInput);
    topRow.appendChild(controls);
    item.appendChild(topRow);

    // Time row: Start Time to End Time
    const timeRow = document.createElement('div');
    timeRow.className = 'schedule-time-row';

    const startBox = document.createElement('div');
    startBox.className = 'schedule-time-box';
    const startLabel = document.createElement('label');
    startLabel.textContent = 'From';
    const startInput = createTimeInput(schedule.startTime || '09:00', (newTime) => {
      schedule.startTime = newTime;
      syncScheduleSettings();
    });
    startBox.appendChild(startLabel);
    startBox.appendChild(startInput);

    const timeSep = document.createElement('span');
    timeSep.className = 'schedule-time-sep';
    timeSep.textContent = '→';

    const endBox = document.createElement('div');
    endBox.className = 'schedule-time-box';
    const endLabel = document.createElement('label');
    endLabel.textContent = 'To';
    const endInput = createTimeInput(schedule.endTime || '18:00', (newTime) => {
      schedule.endTime = newTime;
      syncScheduleSettings();
    });
    endBox.appendChild(endLabel);
    endBox.appendChild(endInput);

    timeRow.appendChild(startBox);
    timeRow.appendChild(timeSep);
    timeRow.appendChild(endBox);
    item.appendChild(timeRow);

    // Days row: Day chips + Quick actions
    const daysRow = document.createElement('div');
    daysRow.className = 'schedule-days-row';

    const chipsContainer = document.createElement('div');
    chipsContainer.className = 'schedule-days-chips';

    DAY_LABELS.forEach(({ day, label, title }) => {
      const chip = document.createElement('div');
      chip.className = `day-chip${schedule.days && schedule.days.includes(day) ? ' active' : ''}`;
      chip.textContent = label;
      chip.title = title;

      chip.addEventListener('click', () => {
        if (!Array.isArray(schedule.days)) schedule.days = [];
        const idx = schedule.days.indexOf(day);
        if (idx >= 0) {
          schedule.days.splice(idx, 1);
          chip.classList.remove('active');
        } else {
          schedule.days.push(day);
          chip.classList.add('active');
        }
        syncScheduleSettings();
      });

      chipsContainer.appendChild(chip);
    });

    const quickDays = document.createElement('div');
    quickDays.className = 'schedule-quick-days';

    const btnWorkdays = document.createElement('button');
    btnWorkdays.type = 'button';
    btnWorkdays.className = 'btn-quick-day';
    btnWorkdays.textContent = 'Workdays';
    btnWorkdays.addEventListener('click', () => {
      schedule.days = [1, 2, 3, 4, 5];
      renderScheduleList();
      syncScheduleSettings();
    });

    const btnEveryday = document.createElement('button');
    btnEveryday.type = 'button';
    btnEveryday.className = 'btn-quick-day';
    btnEveryday.textContent = 'Daily';
    btnEveryday.addEventListener('click', () => {
      schedule.days = [1, 2, 3, 4, 5, 6, 0];
      renderScheduleList();
      syncScheduleSettings();
    });

    quickDays.appendChild(btnWorkdays);
    quickDays.appendChild(btnEveryday);

    daysRow.appendChild(chipsContainer);
    daysRow.appendChild(quickDays);
    item.appendChild(daysRow);

    scheduleList.appendChild(item);
  });

  autoFitWindow();
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

  if (window.api.onAutoTranslateStatusChanged) {
    window.api.onAutoTranslateStatusChanged((data) => {
      if (translateToggle) {
        translateToggle.checked = data.isActive;
      }
    });
  }

  if (window.api.onScheduleStatusChanged) {
    window.api.onScheduleStatusChanged((data) => {
      if (typeof data.scheduleEnabled === 'boolean') {
        scheduleEnabled = data.scheduleEnabled;
        if (scheduleToggle) scheduleToggle.checked = scheduleEnabled;
      }
      if (Array.isArray(data.schedules)) {
        schedules = data.schedules;
        renderScheduleList();
      }
      isScheduleWindowActive = !!data.isScheduleWindowActive;
      activeScheduleName = data.activeScheduleName || null;
      updateScheduleBadge();
      updateStatusUI(isActive);
    });
  }
}

// Schedule Drawer Collapse / Expand Engine
function toggleScheduleDrawer(forceOpen) {
  if (!scheduleBody || !wakeScheduleAccessory) return;
  const isCurrentlyCollapsed = scheduleBody.classList.contains('collapsed');
  const shouldOpen = forceOpen !== undefined ? forceOpen : isCurrentlyCollapsed;

  if (shouldOpen) {
    scheduleBody.classList.remove('collapsed');
    wakeScheduleAccessory.classList.add('expanded');
  } else {
    scheduleBody.classList.add('collapsed');
    wakeScheduleAccessory.classList.remove('expanded');
  }
  autoFitWindow();
}

if (scheduleCollapseToggle) {
  scheduleCollapseToggle.addEventListener('click', (e) => {
    if (e.target.closest('.switch-container')) return;
    toggleScheduleDrawer();
  });
}

if (btnToggleSchedule) {
  btnToggleSchedule.addEventListener('click', (e) => {
    e.stopPropagation();
    toggleScheduleDrawer();
  });
}

// Auto Schedule Event Listeners
if (scheduleToggle) {
  scheduleToggle.addEventListener('change', (e) => {
    scheduleEnabled = e.target.checked;
    updateScheduleBadge();
    syncScheduleSettings();
    log(`Auto Schedule ${scheduleEnabled ? 'ENABLED' : 'DISABLED'}`, scheduleEnabled ? 'success' : 'warning');
    updateStatusUI(isActive);
    if (scheduleEnabled) {
      toggleScheduleDrawer(true);
    }
  });
}

if (btnAddSchedule) {
  btnAddSchedule.addEventListener('click', () => {
    const newId = 'sched_' + Date.now();
    const newIndex = schedules.length + 1;
    const newSched = {
      id: newId,
      name: `Schedule ${newIndex}`,
      enabled: true,
      startTime: '09:00',
      endTime: '18:00',
      days: [1, 2, 3, 4, 5]
    };
    schedules.push(newSched);
    renderScheduleList();
    syncScheduleSettings();
    log(`Added new schedule: "${newSched.name}" (09:00 - 18:00, Mon-Fri)`, 'info');
  });
}

// Auto-Translate Event Listeners
if (translateToggle) {
  translateToggle.addEventListener('change', (e) => {
    if (typeof window.api !== 'undefined') {
      window.api.toggleAutoTranslate(e.target.checked);
    }
  });
}


if (translateProviderSelect) {
  translateProviderSelect.addEventListener('change', (e) => {
    const val = e.target.value;
    log(`Translation engine switched to: ${val === 'microsoft' ? 'Microsoft Translator' : 'Google Translate'}`, 'system-msg');
    if (typeof window.api !== 'undefined') {
      window.api.updateTranslationProvider(val);
    }
  });
}

if (translateDismissSelect) {
  translateDismissSelect.addEventListener('change', (e) => {
    const val = parseInt(e.target.value, 10);
    const label = val === 0 ? 'Never (Manual Esc)' : `${val}s`;
    log(`Auto-close delay set to: ${label}`, 'system-msg');
    if (typeof window.api !== 'undefined' && window.api.updateTranslationDismissSeconds) {
      window.api.updateTranslationDismissSeconds(val);
    }
  });
}

// Shortcut Select and Custom Recording
const MAC_KEY_CODES = {
  KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7, KeyC: 8, KeyV: 9,
  KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17, KeyOne: 18, KeyTwo: 19,
  KeyThree: 20, KeyFour: 21, KeySix: 22, KeyFive: 23, Equal: 24, KeyNine: 25, KeySeven: 26,
  Minus: 27, KeyEight: 28, KeyZero: 29, BracketRight: 30, KeyO: 31, KeyU: 32, BracketLeft: 33,
  KeyI: 34, KeyP: 35, KeyL: 37, KeyJ: 38, Quote: 39, KeyK: 40, Semicolon: 41, Backslash: 42,
  Comma: 43, Slash: 44, KeyN: 45, KeyM: 46, Period: 47, Backquote: 50,
  Space: 49, Tab: 48,
  ArrowLeft: 123, ArrowRight: 124, ArrowDown: 125, ArrowUp: 126,
  F1: 122, F2: 120, F3: 99, F4: 118, F5: 96, F6: 97, F7: 98, F8: 100, F9: 101, F10: 109, F11: 103, F12: 111,
  Home: 115, PageUp: 116, Delete: 117, End: 119, PageDown: 121
};

function getKeyLabel(code, key) {
  if (code.startsWith('Key')) return code.replace('Key', '');
  if (code.startsWith('Digit')) return code.replace('Digit', '');
  if (code === 'Space') return 'Space';
  if (code === 'ArrowDown') return 'Down Arrow ↓';
  if (code === 'ArrowUp') return 'Up Arrow ↑';
  if (code === 'ArrowLeft') return 'Left Arrow ←';
  if (code === 'ArrowRight') return 'Right Arrow →';
  if (code.startsWith('F') && !isNaN(code.slice(1))) return code;
  return key ? key.toUpperCase() : code;
}

if (translateShortcutSelect) {
  translateShortcutSelect.addEventListener('change', (e) => {
    try {
      const parsed = JSON.parse(e.target.value);
      if (shortcutDescKey) shortcutDescKey.textContent = parsed.label;
      log(`Translation shortcut switched to: ${parsed.label}`, 'system-msg');
      if (typeof window.api !== 'undefined') {
        window.api.updateTranslationShortcut(parsed);
      }
    } catch (err) {
      console.error(err);
    }
  });
}

let isRecordingShortcut = false;

if (btnRecordShortcut) {
  btnRecordShortcut.addEventListener('click', () => {
    if (isRecordingShortcut) {
      stopRecordingShortcut();
      return;
    }
    startRecordingShortcut();
  });
}

function startRecordingShortcut() {
  isRecordingShortcut = true;
  if (shortcutRecordingBox) shortcutRecordingBox.style.display = 'block';
  btnRecordShortcut.textContent = 'Cancel';
  btnRecordShortcut.style.background = 'rgba(255, 71, 87, 0.2)';
  btnRecordShortcut.style.borderColor = 'rgba(255, 71, 87, 0.4)';
  btnRecordShortcut.style.color = '#ff4757';
  window.addEventListener('keydown', handleKeyRecord, true);
  autoFitWindow();
}

function stopRecordingShortcut() {
  isRecordingShortcut = false;
  if (shortcutRecordingBox) shortcutRecordingBox.style.display = 'none';
  btnRecordShortcut.textContent = 'Record';
  btnRecordShortcut.style.background = 'rgba(0, 255, 213, 0.12)';
  btnRecordShortcut.style.borderColor = 'rgba(0, 255, 213, 0.3)';
  btnRecordShortcut.style.color = 'var(--accent-active)';
  window.removeEventListener('keydown', handleKeyRecord, true);
  autoFitWindow();
}

function handleKeyRecord(e) {
  e.preventDefault();
  e.stopPropagation();

  if (e.key === 'Escape') {
    stopRecordingShortcut();
    return;
  }

  // Ignore pure modifier presses
  if (['Meta', 'Control', 'Alt', 'Shift'].includes(e.key)) {
    return;
  }

  const keyCode = MAC_KEY_CODES[e.code] !== undefined ? MAC_KEY_CODES[e.code] : e.keyCode;
  
  const mods = [];
  const modLabels = [];
  if (e.metaKey) { mods.push('cmd'); modLabels.push('⌘'); }
  if (e.ctrlKey) { mods.push('ctrl'); modLabels.push('⌃'); }
  if (e.altKey) { mods.push('alt'); modLabels.push('⌥'); }
  if (e.shiftKey) { mods.push('shift'); modLabels.push('⇧'); }

  const keyName = getKeyLabel(e.code, e.key);
  const fullLabel = modLabels.length > 0 ? `${modLabels.join(' ')} ${keyName}` : keyName;
  const modStr = mods.length > 0 ? mods.join('+') : 'none';

  const shortcutData = {
    label: fullLabel,
    keyCode: keyCode,
    modifiers: modStr
  };

  const jsonStr = JSON.stringify(shortcutData);
  if (customShortcutOption) {
    customShortcutOption.value = jsonStr;
    customShortcutOption.textContent = `★ ${fullLabel} (Custom)`;
    customShortcutOption.style.display = 'block';
  }
  if (translateShortcutSelect) {
    translateShortcutSelect.value = jsonStr;
  }
  if (shortcutDescKey) {
    shortcutDescKey.textContent = fullLabel;
  }

  log(`Custom shortcut registered: ${fullLabel}`, 'system-msg');
  if (typeof window.api !== 'undefined') {
    window.api.updateTranslationShortcut(shortcutData);
  }

  stopRecordingShortcut();
}

// Tab Navigation Engine
function switchTab(targetTabId) {
  tabButtons.forEach(btn => {
    if (btn.dataset.tab === targetTabId) {
      btn.classList.add('active');
    } else {
      btn.classList.remove('active');
    }
  });

  tabPanels.forEach(panel => {
    if (panel.id === targetTabId) {
      panel.classList.add('active');
    } else {
      panel.classList.remove('active');
    }
  });

  autoFitWindow();
}

tabButtons.forEach(btn => {
  btn.addEventListener('click', () => {
    switchTab(btn.dataset.tab);
  });
});



// Window Height Auto-Adaptation Engine
let autoFitTimer = null;
function autoFitWindow() {
  if (autoFitTimer) clearTimeout(autoFitTimer);
  autoFitTimer = setTimeout(() => {
    const titleBar = document.querySelector('.title-bar');
    const container = document.querySelector('.app-container');
    if (!titleBar || !container) return;

    const titleH = titleBar.offsetHeight || 38;
    const containerStyle = window.getComputedStyle(container);
    const padTop = parseFloat(containerStyle.paddingTop) || 14;
    const padBottom = parseFloat(containerStyle.paddingBottom) || 16;
    const gap = parseFloat(containerStyle.gap) || 12;

    const tabNav = document.querySelector('.tab-nav');
    const navH = tabNav ? tabNav.offsetHeight : 38;

    const activePanel = document.querySelector('.tab-panel.active');
    const panelH = activePanel ? activePanel.offsetHeight : 260;

    // Dynamically expand with log content, capped between 240px and 360px
    const logContainerEl = document.getElementById('log-container');
    const logScrollH = logContainerEl ? (logContainerEl.scrollHeight + 46) : 240;
    const logH = Math.min(Math.max(logScrollH, 240), 360);

    const contentHeight = Math.ceil(titleH + padTop + padBottom + navH + gap + panelH + gap + logH + 8);
    const neededHeight = Math.max(contentHeight, 580);

    if (window.api && window.api.adjustWindowHeight) {
      window.api.adjustWindowHeight(neededHeight);
    }
  }, 40);
}



