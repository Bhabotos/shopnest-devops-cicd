import { describe, expect, it } from 'vitest';
import { assertSafeTestDatabase } from './helpers/test-db.js';

// assertSafeTestDatabase is the gatekeeper that stops destructive database tests from running against
// anything but a disposable test database. It only reads the URL text, so these tests need no database.
// Every call passes `env` explicitly so a variable set on this machine cannot change the result.

// A recognisable marker, not a real credential: if it ever shows up in an error message, a password leaked.
const PASSWORD = 'password-canary';

// Runs fn and returns the error it throws, so a test can inspect the message.
function errorFrom(fn) {
  try {
    fn();
  } catch (err) {
    return err;
  }
  throw new Error('expected the call to throw, but it returned normally');
}

describe('assertSafeTestDatabase', () => {
  it('rejects a database name that does not end in _test', () => {
    expect(() => assertSafeTestDatabase('postgres://u:p@127.0.0.1:5432/shopnest', {})).toThrow('_test');
  });

  it('rejects a non-loopback host', () => {
    expect(() =>
      assertSafeTestDatabase('postgres://u:p@db.example.internal:5432/shopnest_test', {}),
    ).toThrow('non-loopback');
  });

  it('allows a non-loopback host only with the explicit opt-in', () => {
    const url = 'postgres://u:p@db.example.internal:5432/shopnest_test';

    expect(assertSafeTestDatabase(url, { ALLOW_REMOTE_TEST_DATABASE: 'true' })).toEqual({
      database: 'shopnest_test',
      host: 'db.example.internal',
    });
    // The opt-in must be the exact string "true": other truthy-looking values do not count.
    expect(() => assertSafeTestDatabase(url, { ALLOW_REMOTE_TEST_DATABASE: '1' })).toThrow('non-loopback');
  });

  it.each([
    ['text that is not a URL', 'not a url'],
    ['an empty string', ''],
    ['a URL for another database engine', 'mysql://u:p@127.0.0.1/x_test'],
  ])('rejects %s', (_label, rawUrl) => {
    expect(() => assertSafeTestDatabase(rawUrl, {})).toThrow();
  });

  it('never puts the password in the error message', () => {
    const rejected = [
      `postgres://u:${PASSWORD}@127.0.0.1:5432/shopnest`, // wrong database name
      `postgres://u:${PASSWORD}@db.example.internal:5432/shopnest_test`, // remote host
      `mysql://u:${PASSWORD}@127.0.0.1:3306/x_test`, // wrong protocol
    ];

    for (const rawUrl of rejected) {
      const err = errorFrom(() => assertSafeTestDatabase(rawUrl, {}));
      expect(err.message).not.toContain(PASSWORD);
    }
  });

  it('accepts a loopback _test URL and returns the database and host', () => {
    expect(assertSafeTestDatabase('postgres://u:p@127.0.0.1:55432/shopnest_test', {})).toEqual({
      database: 'shopnest_test',
      host: '127.0.0.1',
    });
  });
});
