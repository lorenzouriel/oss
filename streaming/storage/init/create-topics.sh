#!/bin/bash
set -e

# Keyed by symbol: per-instrument ordering, parallelism up to TOPIC_PARTITIONS
for topic in market.raw market.trades market.quotes market.metrics market.alerts; do
  rpk topic create "$topic" -X brokers=redpanda:9092 \
    --partitions "$TOPIC_PARTITIONS" --replicas 1 || true
done

rpk topic list -X brokers=redpanda:9092
