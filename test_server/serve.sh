#!/bin/bash
# Start a simple HTTP file server for fake Falco drivers.
# Update config/driver_server.yaml: server_url: http://localhost:8080

PORT="${1:-8080}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Serving fake Falco drivers on http://localhost:${PORT}"
echo "Files: $(ls "$DIR"/*.ko "$DIR"/*.o 2>/dev/null | wc -l) (.ko + .o)"
echo ""
echo "Set in config/driver_server.yaml:"
echo "  server_url: http://localhost:${PORT}"
echo ""
cd "$DIR" && python3 -m http.server "$PORT"
