#!/bin/bash
# MQTT Broker ベンチマーク: mqtt-zig (Debug) vs mqtt-zig (ReleaseFast) vs mosquitto
set +e

MOSQ_CONF="/tmp/mosq_bench.conf"

cleanup() {
    pkill -f "mqtt-broker" 2>/dev/null
    pkill -f "mosquitto_sub" 2>/dev/null
    pkill -f "mosquitto -c $MOSQ_CONF" 2>/dev/null
    rm -f "$MOSQ_CONF"
    sleep 0.5
}
trap cleanup EXIT

run_bench() {
    local label="$1"
    local port="$2"

    echo ""
    echo "--- $label (port $port) ---"
    ./zig-out/bin/mqtt-bench 127.0.0.1 "$port" 2>&1 | grep -E "^  "

    # メモリ計測
    local broker_pid
    broker_pid=$(lsof -ti :$port 2>/dev/null | head -1)
    if [ -n "$broker_pid" ]; then
        # 20 clients 接続
        local sub_pids=""
        for i in $(seq 1 20); do
            mosquitto_sub -h 127.0.0.1 -p "$port" -t "#" -q 0 >/dev/null 2>&1 &
            sub_pids="$sub_pids $!"
        done
        sleep 2
        local rss
        rss=$(ps -o rss= -p "$broker_pid" 2>/dev/null | tr -d ' ')
        echo "  Memory:   $(python3 -c "print(f'{int(${rss:-0})/1024:.1f}')") MB (20 clients, RSS)"
        for p in $sub_pids; do kill $p 2>/dev/null; done
        sleep 0.5
    fi
}

echo "======================================"
echo " MQTT Broker Benchmark"
echo " mqtt-zig (Debug) vs mqtt-zig (ReleaseFast) vs mosquitto 2.1.2"
echo "======================================"

# ビルド
echo ""
echo "Building Debug..."
zig build 2>/dev/null
cp zig-out/bin/mqtt-broker zig-out/bin/mqtt-broker-debug
cp zig-out/bin/mqtt-bench zig-out/bin/mqtt-bench-debug

echo "Building ReleaseFast..."
zig build -Doptimize=ReleaseFast 2>/dev/null
cp zig-out/bin/mqtt-broker zig-out/bin/mqtt-broker-release
cp zig-out/bin/mqtt-bench zig-out/bin/mqtt-bench-release

# Debug ビルドのベンチツールに戻す（bench は常に同じツールで計測）
zig build 2>/dev/null

echo ""
echo "Binary sizes:"
echo "  Debug:       $(python3 -c "import os; print(f'{os.path.getsize(\"zig-out/bin/mqtt-broker-debug\")/1024:.0f}')") KB"
echo "  ReleaseFast: $(python3 -c "import os; print(f'{os.path.getsize(\"zig-out/bin/mqtt-broker-release\")/1024:.0f}')") KB"
MOSQ_PATH=$(realpath /opt/homebrew/sbin/mosquitto)
echo "  mosquitto:   $(python3 -c "import os; print(f'{os.path.getsize(\"$MOSQ_PATH\")/1024:.0f}')") KB (+dynamic libs)"

# === mqtt-zig Debug ===
echo ""
echo "============================================"
echo " 1/3: mqtt-zig (Debug)"
echo "============================================"
zig-out/bin/mqtt-broker-debug 11881 >/dev/null 2>&1 &
sleep 2
run_bench "mqtt-zig Debug" 11881
kill $(lsof -ti :11881) 2>/dev/null; sleep 1

# === mqtt-zig ReleaseFast ===
echo ""
echo "============================================"
echo " 2/3: mqtt-zig (ReleaseFast)"
echo "============================================"
zig-out/bin/mqtt-broker-release 11882 >/dev/null 2>&1 &
sleep 2
run_bench "mqtt-zig ReleaseFast" 11882
kill $(lsof -ti :11882) 2>/dev/null; sleep 1

# === mosquitto ===
echo ""
echo "============================================"
echo " 3/3: mosquitto 2.1.2"
echo "============================================"
cat > "$MOSQ_CONF" << 'EOF'
listener 11883 127.0.0.1
allow_anonymous true
EOF
/opt/homebrew/sbin/mosquitto -c "$MOSQ_CONF" >/dev/null 2>&1 &
sleep 2
run_bench "mosquitto 2.1.2" 11883
kill $(lsof -ti :11883) 2>/dev/null; sleep 1

echo ""
echo "======================================"
echo " COMPLETE"
echo "======================================"
