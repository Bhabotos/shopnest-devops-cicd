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

  // Near misses: values that look like "development" or "test" but are not the exact strings. The
  // match is exact and case-sensitive, so a typo, a stray space or an empty value falls back to "refuse".
  it.each(['Development', 'TEST', 'dev', ' development', 'development ', ''])(
    'blocks the near-miss NODE_ENV %j',
    (nodeEnv) => {
      expect(() => assertSeedAllowed({ NODE_ENV: nodeEnv })).toThrow('Refusing to seed');
    },
  );

  // Near misses of the opt-in flag: only the exact string "true" counts, nothing else.
  it.each(['True', 'true ', ' true', 'false', '0', ''])(
    'blocks production with the near-miss flag %j',
    (flag) => {
      expect(() => assertSeedAllowed({ NODE_ENV: 'production', ALLOW_PRODUCTION_SEED: flag })).toThrow(
        'Refusing to seed',
      );
    },
  );

  // The flag is a production-only override. In development and test it changes nothing; everywhere else
  // (staging, an unknown name, empty, unset) it must not unlock seeding, so a stray flag in a shared
  // environment file cannot open the door outside production.
  describe('the ALLOW_PRODUCTION_SEED override', () => {
    it.each(['development', 'test'])('does not matter in %s', (nodeEnv) => {
      for (const flag of [undefined, 'true', 'false', '1', '']) {
        expect(() => assertSeedAllowed({ NODE_ENV: nodeEnv, ALLOW_PRODUCTION_SEED: flag })).not.toThrow();
      }
    });

    it.each([
      ['staging', 'staging'],
      ['an unknown environment', 'qa'],
      ['a short production name', 'prod'],
      ['an empty NODE_ENV', ''],
      ['an unset NODE_ENV', undefined],
    ])('does not unlock %s', (_label, nodeEnv) => {
      const env = { ALLOW_PRODUCTION_SEED: 'true' };
      if (nodeEnv !== undefined) env.NODE_ENV = nodeEnv;
      expect(() => assertSeedAllowed(env)).toThrow('Refusing to seed');
    });

    it('is only honoured as exactly "true" in production', () => {
      expect(() => assertSeedAllowed({ NODE_ENV: 'production', ALLOW_PRODUCTION_SEED: 'true' })).not.toThrow();
      expect(() => assertSeedAllowed({ NODE_ENV: 'production' })).toThrow('Refusing to seed');
    });
  });

  it('names the offending NODE_ENV in the message, and "unset" when there is none', () => {
    expect(() => assertSeedAllowed({ NODE_ENV: 'staging' })).toThrow('NODE_ENV is "staging"');
    expect(() => assertSeedAllowed({})).toThrow('NODE_ENV is "unset"');
  });
});
