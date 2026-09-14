const { spawn, exec } = require('child_process');

/**
 * Get macOS system current HIDIdleTime (in seconds)
 * Matches Electron internal powerMonitor.getSystemIdleTime() implementation
 */
function getSystemIdleTime() {
  return new Promise((resolve) => {
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

/**
 * Perform micro wiggle (inject kCGEventMouseMoved hardware-level input events via CoreGraphics)
 */
function performMicroWiggle() {
  return new Promise((resolve, reject) => {
    const script = `
      ObjC.import('Cocoa');
      ObjC.import('CoreGraphics');
      
      var loc = $.NSEvent.mouseLocation;
      var screenHeight = $.NSScreen.mainScreen.frame.size.height;
      var currentX = loc.x;
      var currentY = screenHeight - loc.y;

      var pt1 = $.CGPointMake(currentX + 1, currentY + 1);
      var pt2 = $.CGPointMake(currentX, currentY);

      // 1. Move 1px and post real mouse moved event
      $.CGWarpMouseCursorPosition(pt1);
      var ev1 = $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, pt1, 0);
      $.CGEventPost($.kCGHIDEventTap, ev1);

      $.NSThread.sleepForTimeInterval(0.02);

      // 2. Immediately move back to original coordinates
      $.CGWarpMouseCursorPosition(pt2);
      var ev2 = $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, pt2, 0);
      $.CGEventPost($.kCGHIDEventTap, ev2);

      "ok";
    `;

    const child = spawn('osascript', ['-l', 'JavaScript']);
    let stderr = '';

    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.on('close', (code) => {
      if (code !== 0) reject(new Error(stderr.trim()));
      else resolve();
    });

    child.stdin.write(script);
    child.stdin.end();
  });
}

// Minute counter
let minuteCount = 0;
const RESET_INTERVAL_MINUTES = 6;

async function runCheckIteration() {
  minuteCount++;
  const timeStr = new Date().toLocaleTimeString();
  const currentIdle = await getSystemIdleTime();

  // Check if 6th minute reset cycle reached
  if (minuteCount % RESET_INTERVAL_MINUTES === 0) {
    try {
      await performMicroWiggle();
      await new Promise((r) => setTimeout(r, 100)); // Wait 100ms for kernel registry refresh
      const afterIdle = await getSystemIdleTime();

      console.log(
        `[${timeStr}] (Minute ${minuteCount} ⚡Reset Triggered) Before: ${currentIdle.toFixed(2)}s  ➔  After: ${afterIdle.toFixed(2)}s (✔ Reset)`
      );
    } catch (err) {
      console.error(`[${timeStr}] Micro-wiggle failed:`, err.message);
    }
  } else {
    // Normal interval: query and log current idle time
    const remainingMins = RESET_INTERVAL_MINUTES - (minuteCount % RESET_INTERVAL_MINUTES);
    console.log(
      `[${timeStr}] (Minute ${minuteCount}) Current idle: ${currentIdle.toFixed(2)}s (Next reset in: ${remainingMins} min)`
    );
  }
}

console.log('==================================================================');
console.log('  macOS powerMonitor.getSystemIdleTime() Monitor & 6min Reset Script');
console.log('  - Interval: Log current system idle time every 1 minute');
console.log('  - Reset: Trigger hardware idle clock reset every 6 minutes');
console.log('  - Advice: Leave mouse untouched to verify idle time accumulation and reset');
console.log('==================================================================\n');

// Print baseline idle time upon launch (Minute 0)
(async () => {
  const initIdle = await getSystemIdleTime();
  console.log(`[${new Date().toLocaleTimeString()}] (Initial) Current idle time: ${initIdle.toFixed(2)}s\n`);
})();

// Run check every 1 minute
setInterval(runCheckIteration, 60 * 1000);
