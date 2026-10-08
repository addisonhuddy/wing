# Security policy

Do not put Schema Registry credentials in source control. Use environment
variables or a protected configuration file; wing creates secret-bearing
configuration with restrictive permissions and warns about readable files.
The schema cache may contain registry metadata and should be kept private.

`schema.registry.ssl.insecure=true` disables certificate verification and is
not suitable for production. Use a PEM CA bundle instead. HTTP debug output
redacts `Authorization`, but should still be treated as sensitive operational
data.

Report suspected vulnerabilities privately to the repository maintainer rather
than opening a public issue containing exploit details. Include the affected
version, impact, and steps to reproduce.
