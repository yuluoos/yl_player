Owned local TLS fixture. This deliberately public server private key must never
be used outside tests. No production host, license or credentials are involved.

Generated 2026-09-27 with OpenSSL RSA-2048/SHA-256: a self-signed CA with
basicConstraints CA:TRUE and keyCertSign/cRLSign; a CA-signed server certificate
with CA:FALSE, digitalSignature/keyEncipherment, serverAuth, and SANs localhost
and 127.0.0.1. The server certificate expires 2027-09-27 and must be regenerated
before then (365-day validity keeps Apple TLS policy checks active). The CA's
private key is not committed; regenerate the CA, server certificate and server
key together. Test trust uses ca.pem only in an explicit private context passed
to the internal transport. Public clients retain default system trust and must
reject this fixture. The first assertion verifies that rejection; the successful
transfer uses the private context without bypassing certificate verification.
