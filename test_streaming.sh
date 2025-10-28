#!/bin/bash

echo "=== Starting streaming execution ==="
curl -X POST http://localhost:3003 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4000,"method":"tools/call","params":{"name":"exec_repl","arguments":{"expression":"for i in 1:5; println(\"Step \", i); sleep(1); end","stream":true}}}' &

sleep 0.5

echo ""
echo "=== Connecting to SSE stream ==="
curl -N -v http://localhost:3003/sse/4000

echo ""
echo "=== Stream complete ==="
