# RDS CA bundle (pinned)

`rds-global-bundle.pem` is the Amazon RDS global certificate bundle. The backend uses it to VERIFY the RDS server
certificate and host name (`ssl.rejectUnauthorized = true`); TLS verification is mandatory and there is no setting
that turns it off. The file is copied into the backend image (`/app/certs/rds-global-bundle.pem`), so the running
application, the migrator and the bootstrap job all use the same file and no host download or mount is involved.

| Item | Value |
|---|---|
| Source | `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem` |
| Retrieved | 2026-11-21 over HTTPS (the serving certificate was issued by Amazon RSA 2048 S23) |
| SHA-256 | `90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b` |
| Size | 174,560 bytes |
| Contents | 114 self-signed root certificates, all issued by "Amazon Web Services, Inc., OU=Amazon RDS", including the three `ap-south-1` roots |
| Validity | none expired when retrieved; the earliest `notAfter` is 2061-05-18 |

## What was verified and what was NOT

Verified when the file was added:
- it was served over HTTPS from the AWS truststore domain;
- every certificate parses, none is expired, every issuer names Amazon Web Services / Amazon RDS;
- the test `backend/test/rds-ca-bundle.test.js` pins the SHA-256 above, so any later change fails CI.

**NOT verified: the SHA-256 against a value PUBLISHED BY AWS.** AWS did not offer a retrievable checksum for this file
(the `.sha256` and `.sha1` URLs answered HTTP 403, and the documentation page carries no checksum in its static text).
The hash above is therefore a record of what was downloaded, not a comparison with an AWS-published value. Before
relying on it for production, compare it with the checksum shown in the AWS documentation
("Using SSL/TLS to encrypt a connection to a DB instance", RDS User Guide) and record the result here.

## Changing the bundle

Download the new file, repeat the checks above, update the SHA-256 in this file and in
`backend/test/rds-ca-bundle.test.js` in the same pull request, and say in the pull request how it was verified.
