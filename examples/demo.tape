# wing in about 10 seconds: register a schema, write and read records through
# kite, and fit CSV-shaped records to the schema.
#
#   vhs examples/demo.tape        -> examples/demo.gif
#
# Needs: vhs (https://github.com/charmbracelet/vhs), wing, kite and jq on PATH,
# Kafka on localhost:9092 and Schema Registry on localhost:8081 (see README
# "Run Kafka and Schema Registry locally with Docker"). The hidden setup
# removes any leftover `orders`/`raw-orders` topics and subject, so reruns are clean.

Output examples/demo.gif

Set Shell bash
Set FontSize 22
Set Width 1260
Set Height 540
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 13ms
Set Framerate 30

Env BOOTSTRAP_SERVERS "localhost:9092"
Env SCHEMA_REGISTRY_URL "http://localhost:8081"

Hide
Type "cd examples; kite topic delete -y -q --if-exists orders raw-orders; wing rm orders -y -q --permanent 2>/dev/null; kite topic create -q orders; kite topic create -q raw-orders; kite produce -q --csv raw-orders < orders.csv; clear" Enter
Sleep 3s
Show

# 1. push: lint, check compatibility, register
Type "wing push orders < orders.schema.json"
Sleep 200ms
Enter
Sleep 1s

# 2. write: validate and add the schema-ID header, then produce with kite
Type "wing write orders < orders.jsonl | kite produce -q --json orders"
Sleep 200ms
Enter
Sleep 1s

# 3. read: resolve the header and validate each record
Type "kite consume -q -B -n 2 --json orders | wing read | jq -c .value"
Sleep 200ms
Enter
Sleep 1.2s

# 4. --fit: turn CSV strings into the schema's types and fill defaults
Type "kite consume -q -B -n 2 --json raw-orders | wing write --fit orders | jq -c .value"
Sleep 200ms
Enter
Sleep 1.6s
