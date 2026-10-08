# Security policy

## Reporting a vulnerability

Report vulnerabilities through GitHub private vulnerability reporting:
[Security → Report a vulnerability](https://github.com/addisonhuddy/wing/security/advisories/new).

Please do not open a public issue for a vulnerability. Include the affected
version, reproduction steps, impact, and relevant configuration details.

## Supported versions

Only the latest release is supported with security fixes.

## Sensitive configuration

Do not put Schema Registry credentials in source control. Use environment
variables or a protected configuration file; wing creates secret-bearing
configuration with restrictive permissions and warns about readable files.
Restrict secret-bearing files to the owner:

```sh
chmod 600 wing.yaml
```

The schema cache may contain registry metadata and should be kept private.

## TLS and debug output

`schema.registry.ssl.insecure=true` disables certificate verification and is
not suitable for production. Use a PEM CA bundle instead.

`WING_DEBUG=1` writes request and response details to stderr. WING_DEBUG
redacts `Authorization` and configured `http.header.*` values, but debug output
should still be treated as sensitive operational data.
