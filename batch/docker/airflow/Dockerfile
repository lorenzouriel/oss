FROM apache/airflow:3.3.2-python3.12

ARG AIRFLOW_VERSION=3.3.2
ARG PYTHON_VERSION=3.12

# Engine libraries live in Airflow's environment, pinned against its constraints.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir \
      -r /tmp/requirements.txt \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

# dbt gets its own virtualenv: its dependency tree conflicts with Airflow's constraints.
COPY requirements-dbt.txt /tmp/requirements-dbt.txt
RUN python -m venv /opt/airflow/dbt-venv \
 && /opt/airflow/dbt-venv/bin/pip install --no-cache-dir -r /tmp/requirements-dbt.txt
ENV PATH="${PATH}:/opt/airflow/dbt-venv/bin"

# Pre-install DuckDB extensions so tasks don't download them at runtime.
RUN python -c "import duckdb; c = duckdb.connect(); [c.install_extension(e) for e in ('httpfs', 'iceberg', 'ducklake', 'postgres')]" \
 && /opt/airflow/dbt-venv/bin/python -c "import duckdb; c = duckdb.connect(); [c.install_extension(e) for e in ('httpfs', 'iceberg', 'ducklake', 'postgres')]"
