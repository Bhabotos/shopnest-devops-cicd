const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

export function createLogger({
  level = 'info',
  write = (line) => process.stdout.write(`${line}\n`),
  now = () => new Date(),
} = {}) {
  const minimum = LEVELS[level] ?? LEVELS.info;

  const log = (name, msg, fields = {}) => {
    if (LEVELS[name] < minimum) return;
    write(JSON.stringify({ time: now().toISOString(), level: name, msg, ...fields }));
  };

  return {
    debug: (msg, fields) => log('debug', msg, fields),
    info: (msg, fields) => log('info', msg, fields),
    warn: (msg, fields) => log('warn', msg, fields),
    error: (msg, fields) => log('error', msg, fields),
  };
}
