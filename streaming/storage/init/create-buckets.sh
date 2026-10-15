#!/bin/sh
set -e

# Raw + processed market data (Parquet), and Flink checkpoints/savepoints
for bucket in "$MARKET_BUCKET" "$FLINK_BUCKET"; do
  echo "s3.bucket.create -name $bucket" \
    | weed shell -master=seaweedfs:9333 -filer=seaweedfs:8888
done

echo "s3.bucket.list" | weed shell -master=seaweedfs:9333 -filer=seaweedfs:8888
