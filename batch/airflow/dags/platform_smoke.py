"""Write/read round-trip against every storage layer the stack exposes.

Lite profile: DuckLake must pass; the Iceberg and OpenMetadata checks skip.
Full profile: all three must pass.
"""

import os

import requests
from airflow.sdk.exceptions import AirflowSkipException
from airflow.sdk import dag, task


def _reachable(url: str) -> bool:
    try:
        requests.get(url, timeout=5)
        return True
    except requests.ConnectionError:
        return False


@dag(schedule=None, catchup=False, tags=["platform"])
def platform_smoke():
    @task
    def ducklake_roundtrip() -> int:
        import duckdb

        con = duckdb.connect()
        con.execute(
            f"ATTACH 'ducklake:postgres:{os.environ['DUCKLAKE_CATALOG_DSN']}' AS lake "
            f"(DATA_PATH '{os.environ['DUCKLAKE_DATA_PATH']}')"
        )
        con.execute("CREATE SCHEMA IF NOT EXISTS lake.smoke")
        con.execute("CREATE OR REPLACE TABLE lake.smoke.ping AS SELECT range AS id FROM range(10)")
        rows = con.execute("SELECT count(*) FROM lake.smoke.ping").fetchone()[0]
        assert rows == 10, rows
        return rows

    @task
    def iceberg_roundtrip() -> int:
        if not _reachable(os.environ["POLARIS_URI"]):
            raise AirflowSkipException("Polaris not running (lite profile)")

        import pyarrow as pa
        from pyiceberg.catalog.rest import RestCatalog

        catalog = RestCatalog(
            "polaris",
            uri=os.environ["POLARIS_URI"],
            warehouse=os.environ["POLARIS_CATALOG"],
            credential=f"{os.environ['POLARIS_CLIENT_ID']}:{os.environ['POLARIS_CLIENT_SECRET']}",
            scope="PRINCIPAL_ROLE:ALL",
            **{"header.X-Iceberg-Access-Delegation": "vended-credentials"},
        )
        data = pa.table({"id": pa.array(range(10), pa.int64())})
        if catalog.table_exists("bronze._smoke"):
            catalog.drop_table("bronze._smoke", purge_requested=True)
        table = catalog.create_table("bronze._smoke", schema=data.schema)
        table.append(data)
        rows = table.scan().to_arrow().num_rows
        assert rows == 10, rows
        return rows

    @task
    def duckdb_reads_polaris() -> int:
        if not _reachable(os.environ["POLARIS_URI"]):
            raise AirflowSkipException("Polaris not running (lite profile)")

        import duckdb

        con = duckdb.connect()
        con.execute(f"""
            CREATE SECRET polaris (
                TYPE iceberg,
                CLIENT_ID '{os.environ['POLARIS_CLIENT_ID']}',
                CLIENT_SECRET '{os.environ['POLARIS_CLIENT_SECRET']}',
                OAUTH2_SCOPE 'PRINCIPAL_ROLE:ALL',
                OAUTH2_SERVER_URI '{os.environ['POLARIS_URI']}/v1/oauth/tokens'
            )""")
        con.execute(f"""
            ATTACH '{os.environ['POLARIS_CATALOG']}' AS lh (
                TYPE iceberg,
                ENDPOINT '{os.environ['POLARIS_URI']}',
                SECRET polaris
            )""")
        rows = con.execute("SELECT count(*) FROM lh.bronze._smoke").fetchone()[0]
        assert rows == 10, rows
        return rows

    @task
    def openmetadata_health() -> str:
        url = f"{os.environ['OPENMETADATA_HOST']}/v1/system/version"
        if not _reachable(url):
            raise AirflowSkipException("OpenMetadata not running (lite profile)")
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        return response.json()["version"]

    ducklake_roundtrip()
    iceberg_roundtrip() >> duckdb_reads_polaris()
    openmetadata_health()


platform_smoke()
