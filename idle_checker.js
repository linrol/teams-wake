const { spawn, exec } = require('child_process');

/**
 * 获取 macOS 系统当前的 HIDIdleTime（单位：秒）
 * 对应 Electron 内部 powerMonitor.getSystemIdleTime() 的底层实现
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
 * 执行微移动（利用 CoreGraphics 触发真实的 kCGEventMouseMoved 硬件级输入事件）
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

      // 1. 瞬移 1 像素并向驱动注入真实鼠标移动事件
      $.CGWarpMouseCursorPosition(pt1);
      var ev1 = $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, pt1, 0);
      $.CGEventPost($.kCGHIDEventTap, ev1);

      $.NSThread.sleepForTimeInterval(0.02);

      // 2. 立即瞬移回原位，肉眼完全无感
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

// 统计分钟计数器
let minuteCount = 0;
const RESET_INTERVAL_MINUTES = 6;

async function runCheckIteration() {
  minuteCount++;
  const timeStr = new Date().toLocaleTimeString();
  const currentIdle = await getSystemIdleTime();

  // 判断是否到达第 6 分钟复位周期
  if (minuteCount % RESET_INTERVAL_MINUTES === 0) {
    try {
      await performMicroWiggle();
      await new Promise((r) => setTimeout(r, 100)); // 等待 100ms 内核注册表刷新
      const afterIdle = await getSystemIdleTime();

      console.log(
        `[${timeStr}] (第 ${minuteCount} 分钟 ⚡触发复位) 移动前空闲: ${currentIdle.toFixed(2)}s  ➔  移动后空闲: ${afterIdle.toFixed(2)}s (✔ 成功归零)`
      );
    } catch (err) {
      console.error(`[${timeStr}] 移动复位失败:`, err.message);
    }
  } else {
    // 普通分钟周期：仅查询并打印当前的空闲时间
    const remainingMins = RESET_INTERVAL_MINUTES - (minuteCount % RESET_INTERVAL_MINUTES);
    console.log(
      `[${timeStr}] (第 ${minuteCount} 分钟) 当前空闲时间: ${currentIdle.toFixed(2)}s (距离下次复位还剩: ${remainingMins} 分钟)`
    );
  }
}

console.log('==================================================================');
console.log('  macOS powerMonitor.getSystemIdleTime() 监控与 6min 复位脚本');
console.log('  - 输出频率：每 1 分钟打印一次当前系统空闲时间');
console.log('  - 复位频率：每 6 分钟真正触发一次内核硬件级空闲时钟清零');
console.log('  - 观察建议：静置鼠标不要动，观察空闲时间持续增长并在第 6 分钟被清零');
console.log('==================================================================\n');

// 启动时立即打印当前空闲时间作为基准（第 0 分钟）
(async () => {
  const initIdle = await getSystemIdleTime();
  console.log(`[${new Date().toLocaleTimeString()}] (初始状态) 当前空闲时间: ${initIdle.toFixed(2)}s\n`);
})();

// 每 1 分钟检查一次
setInterval(runCheckIteration, 60 * 1000);
