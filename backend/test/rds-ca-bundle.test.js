import { X509Certificate, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// The pinned RDS CA bundle (backend/certs/README.md). These tests do not prove that AWS published this exact
// file (the README says what was and was not verified); they make any later, silent change fail.
const backendDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BUNDLE = resolve(backendDir, 'certs', 'rds-global-bundle.pem');
const PINNED_SHA256 = '90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b';

const bytes = readFileSync(BUNDLE);
const certificates = bytes
  .toString('utf8')
  .match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g)
  .map((pem) => new X509Certificate(pem));

describe('backend/certs/rds-global-bundle.pem', () => {
  it('is exactly the pinned file', () => {
    expect(createHash('sha256').update(bytes).digest('hex')).toBe(PINNED_SHA256);
  });

  it('contains only parseable certificates, all issued by Amazon RDS', () => {
    expect(certificates.length).toBeGreaterThan(50);
    for (const cert of certificates) {
      expect(cert.issuer).toContain('Amazon Web Services');
      expect(cert.issuer).toContain('OU=Amazon RDS');
    }
  });

  it('contains only roots (each certificate is self-signed)', () => {
    for (const cert of certificates) expect(cert.subject).toBe(cert.issuer);
  });

  it('has no expired certificate', () => {
    const now = Date.now();
    for (const cert of certificates) expect(new Date(cert.validTo).getTime()).toBeGreaterThan(now);
  });

  it('covers the Mumbai region this project deploys to', () => {
    const mumbai = certificates.filter((cert) => cert.subject.includes('CN=Amazon RDS ap-south-1 Root CA'));
    expect(mumbai.length).toBeGreaterThanOrEqual(1);
  });

  it('is copied into the image by the Dockerfile', () => {
    const dockerfile = readFileSync(resolve(backendDir, 'Dockerfile'), 'utf8');
    expect(dockerfile).toMatch(/^COPY certs \.\/certs$/m);
  });
});
