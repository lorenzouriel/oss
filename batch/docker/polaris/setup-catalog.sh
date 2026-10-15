#!/bin/sh
# Creates the lakehouse catalog and the bronze/silver/gold namespaces in Polaris.
# Idempotent: existing objects (HTTP 409) are left untouched, so `up` can be re-run.
set -eu

POLARIS=http://polaris:8181
REALM=POLARIS

apk add --no-cache jq >/dev/null

TOKEN=$(curl -sf "$POLARIS/api/catalog/v1/oauth/tokens" \
  --user "$POLARIS_CLIENT_ID:$POLARIS_CLIENT_SECRET" \
  -H "Polaris-Realm: $REALM" \
  -d grant_type=client_credentials \
  -d scope=PRINCIPAL_ROLE:ALL | jq -r .access_token)

# call METHOD PATH [BODY] -> fails on any status other than 2xx or 409
call() {
  status=$(curl -s -o /tmp/resp -w '%{http_code}' -X "$1" "$POLARIS$2" \
    -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM" \
    -H 'Content-Type: application/json' ${3:+-d "$3"})
  case "$status" in
    2*) echo "  $1 $2 -> $status" ;;
    409) echo "  $1 $2 -> already exists" ;;
    *) echo "  $1 $2 -> $status"; cat /tmp/resp; exit 1 ;;
  esac
}

echo "Creating catalog '$CATALOG_NAME'"
call POST /api/management/v1/catalogs "{
  \"catalog\": {
    \"name\": \"$CATALOG_NAME\",
    \"type\": \"INTERNAL\",
    \"readOnly\": false,
    \"properties\": {\"default-base-location\": \"s3://$S3_BUCKET/warehouse\"},
    \"storageConfigInfo\": {
      \"storageType\": \"S3\",
      \"allowedLocations\": [\"s3://$S3_BUCKET/warehouse\"],
      \"endpoint\": \"$S3_ENDPOINT\",
      \"endpointInternal\": \"http://rustfs:9000\",
      \"pathStyleAccess\": true,
      \"region\": \"$S3_REGION\"
    }
  }
}"

echo "Granting content management to catalog_admin"
call PUT "/api/management/v1/catalogs/$CATALOG_NAME/catalog-roles/catalog_admin/grants" \
  '{"type": "catalog", "privilege": "CATALOG_MANAGE_CONTENT"}'

echo "Creating medallion namespaces"
for ns in bronze silver gold; do
  call POST "/api/catalog/v1/$CATALOG_NAME/namespaces" "{\"namespace\": [\"$ns\"]}"
done

echo "Polaris setup complete."
