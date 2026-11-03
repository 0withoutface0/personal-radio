FROM python:3.13-slim

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 radio && useradd --uid 10001 --gid radio --create-home radio
WORKDIR /app
COPY requirements.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY pyproject.toml ./
COPY radio_prototype ./radio_prototype
RUN pip install --no-cache-dir --no-deps . \
    && mkdir -p /data && chown radio:radio /data
USER radio
ENV RADIO_DATA_DIR=/data RADIO_LOCAL_SETUP=0 PYTHONUNBUFFERED=1
EXPOSE 8765
CMD ["python", "-m", "uvicorn", "radio_prototype.api:create_app", "--factory", "--host", "0.0.0.0", "--port", "8765", "--no-proxy-headers", "--no-access-log"]
