import { describe, expect, it } from 'vitest';
import { createLogger } from '../src/logger.js';

const fixedNow = () => new Date('2026-01-02T03:04:05.000Z');

function capture(options = {}) {
  const lines = [];
  const logger = createLogger({ write: (l) => lines.push(l), now: fixedNow, ...options });
  return { logger, lines };
}

describe('logger', () => {
  it('writes one JSON object per line with time, level and message', () => {
    const { logger, lines } = capture();
    logger.info('hello');
    expect(JSON.parse(lines[0])).toEqual({
      time: '2026-01-02T03:04:05.000Z',
      level: 'info',
      msg: 'hello',
    });
  });

  it('includes extra fields', () => {
    const { logger, lines } = capture();
    logger.warn('slow', { durationMs: 900 });
    expect(JSON.parse(lines[0])).toMatchObject({ level: 'warn', durationMs: 900 });
  });

  it('suppresses messages below the configured level', () => {
    const { logger, lines } = capture({ level: 'warn' });
    logger.debug('a');
    logger.info('b');
    logger.error('c');
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0]).msg).toBe('c');
  });

  it('falls back to info for an unknown level', () => {
    const { logger, lines } = capture({ level: 'verbose' });
    logger.debug('a');
    logger.info('b');
    expect(lines).toHaveLength(1);
  });
});
