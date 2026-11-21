import { describe, expect, it } from 'vitest';
import { assertSeedAllowed } from '../src/seed.js';

// assertSeedAllowed decides whether the demo catalogue may be loaded. Seeding writes products into the
// database, so outside development and test it must be an explicit, deliberate act.
// It only reads the environment object it is given, so these tests need no database. Every call passes
// `env` explicitly so the NODE_ENV of the machine running the tests cannot change the result.

describe('assertSeedAllowed', () => {
  it.each(['development', 'test'])('allows NODE_ENV=%s', (nodeEnv) => {
    expect(() => assertSeedAllowed({ NODE_ENV: nodeEnv })).not.toThrow();
  });

  // An unset NODE_ENV is treated like production: the safe default is to refuse.
  it.each([
    ['production', { NODE_ENV: 'production' }],
    ['staging', { NODE_ENV: 'staging' }],
    ['an unset NODE_ENV', {}],
  ])('blocks %s', (_label, env) => {
    expect(() => assertSeedAllowed(env)).toThrow('Refusing to seed');
  });

  it('needs the exact flag value to allow production', () => {
    // Values that look like "yes" are not enough: only the exact string "true" opts in.
    for (const flag of ['1', 'yes', 'TRUE']) {
      expect(() => assertSeedAllowed({ NODE_ENV: 'production', ALLOW_PRODUCTION_SEED: flag })).toThrow(
        'Refusing to seed',
      );
    }

    expect(() => assertSeedAllowed({ NODE_ENV: 'production', ALLOW_PRODUCTION_SEED: 'true' })).not.toThrow();
  });
});
