#!/bin/bash
echo "編譯 Benchmark 測試工具中..."
swiftc -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macosx14.0 -O \
    ChekiLens/Sources/Models/*.swift \
    ChekiLens/Sources/Services/VisionManager*.swift \
    BenchmarkTool/SourcesReal/main.swift \
    -o /tmp/benchmark_real

if [ $? -eq 0 ]; then
    echo "執行 Benchmark 測試..."
    /tmp/benchmark_real
else
    echo "編譯失敗"
fi
