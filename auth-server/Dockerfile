FROM python:3.13-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends chromium xvfb x11vnc novnc websockify ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 radioauth
WORKDIR /app
COPY requirements.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements.lock \
    && pip install --no-cache-dir playwright==1.58.0
COPY radio_prototype ./radio_prototype
COPY auth-server/app.py auth-server/start.py ./
RUN install -d -m 0700 -o radioauth -g radioauth /state
USER radioauth
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 DISPLAY=:99
CMD ["python", "start.py"]
