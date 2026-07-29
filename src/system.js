'use strict';

/**
 * Metricas de salud de la Raspberry Pi.
 * Todo se lee de /proc y /sys: sin dependencias, sin spawns caros.
 */

const fs = require('fs');
const os = require('os');

let lastCpu = null;

/** Uso de CPU % calculado por delta entre llamadas (no bloquea). */
function cpuUsage() {
  try {
    const line = fs.readFileSync('/proc/stat', 'utf8').split('\n')[0];
    const parts = line.trim().split(/\s+/).slice(1).map(Number);
    const idle = parts[3] + (parts[4] || 0);
    const total = parts.reduce((a, b) => a + b, 0);

    if (!lastCpu) {
      lastCpu = { idle, total };
      return null;
    }
    const dIdle = idle - lastCpu.idle;
    const dTotal = total - lastCpu.total;
    lastCpu = { idle, total };
    if (dTotal <= 0) return null;
    return Math.max(0, Math.min(100, Math.round((1 - dIdle / dTotal) * 100)));
  } catch (_) {
    // Fallback portable: load average normalizado por nucleos
    return Math.min(100, Math.round((os.loadavg()[0] / os.cpus().length) * 100));
  }
}

/** Temperatura del SoC en grados C. */
function temperature() {
  const paths = [
    '/sys/class/thermal/thermal_zone0/temp',
    '/sys/devices/virtual/thermal/thermal_zone0/temp',
  ];
  for (const p of paths) {
    try {
      const raw = parseInt(fs.readFileSync(p, 'utf8').trim(), 10);
      if (Number.isFinite(raw)) return Math.round(raw / 1000);
    } catch (_) {
      /* siguiente */
    }
  }
  return null;
}

/** Memoria real (usa MemAvailable, que es lo que importa en Linux). */
function memory() {
  try {
    const raw = fs.readFileSync('/proc/meminfo', 'utf8');
    const get = (k) => {
      const m = raw.match(new RegExp(`^${k}:\\s+(\\d+)`, 'm'));
      return m ? parseInt(m[1], 10) * 1024 : null;
    };
    const total = get('MemTotal');
    const available = get('MemAvailable');
    if (total && available) {
      return {
        total,
        used: total - available,
        percent: Math.round(((total - available) / total) * 100),
      };
    }
  } catch (_) {
    /* fallback */
  }
  const total = os.totalmem();
  const used = total - os.freemem();
  return { total, used, percent: Math.round((used / total) * 100) };
}

/** Uso de disco del filesystem raiz. */
function disk() {
  try {
    const st = fs.statfsSync('/');
    const total = st.blocks * st.bsize;
    const free = st.bavail * st.bsize;
    return { total, used: total - free, percent: Math.round(((total - free) / total) * 100) };
  } catch (_) {
    return null;
  }
}

/** Estado de throttling del firmware de RPi (undervoltage, thermal cap, etc). */
function throttled() {
  try {
    // Expuesto por el kernel de RPi sin necesidad de vcgencmd
    const raw = fs.readFileSync('/sys/devices/platform/soc/soc:firmware/get_throttled', 'utf8');
    const v = parseInt(raw.trim(), 16);
    if (!Number.isFinite(v)) return null;
    return {
      raw: v,
      underVoltageNow: Boolean(v & 0x1),
      throttledNow: Boolean(v & 0x4),
      underVoltageEver: Boolean(v & 0x10000),
      throttledEver: Boolean(v & 0x40000),
    };
  } catch (_) {
    return null;
  }
}

function snapshot() {
  const mem = memory();
  const temp = temperature();
  return {
    ts: Date.now(),
    cpu: cpuUsage(),
    temp,
    tempStatus: temp === null ? 'unknown' : temp >= 80 ? 'critical' : temp >= 68 ? 'warn' : 'ok',
    memory: mem,
    disk: disk(),
    throttled: throttled(),
    load: os.loadavg().map((n) => Math.round(n * 100) / 100),
    uptimeSystem: Math.round(os.uptime()),
    uptimeProcess: Math.round(process.uptime()),
    processMemory: process.memoryUsage().rss,
    hostname: os.hostname(),
    node: process.version,
  };
}

// Primera lectura para inicializar el delta de CPU
cpuUsage();

module.exports = { snapshot };
