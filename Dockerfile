FROM ghcr.io/mlflow/mlflow:v3.11.1-full
RUN pip install --no-cache-dir 'mlflow[auth]'