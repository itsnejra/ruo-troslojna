# Backend slika (DO-5): dvije faze. Prva instalira zavisnosti, druga sadrži samo runtime.
# Zavisnosti se kopiraju prije koda, pa izmjena koda koristi keširani sloj sa zavisnostima.

# --- faza 1: zavisnosti ---
FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /w
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# --- faza 2: runtime ---
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8000
# proces ne radi kao root; UID je fiksan da bi Ansible mogao dati vlasništvo nad datotekom s tajnom
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /install /usr/local
WORKDIR /srv
COPY app/ ./app/
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import os, urllib.request as u; u.urlopen('http://localhost:' + os.environ['UVICORN_PORT'] + '/api/healthz', timeout=2)"]
# uvicorn čita UVICORN_HOST/UVICORN_PORT iz okruženja; --proxy-headers jer je ispred nginx
CMD ["uvicorn", "app.main:app", "--proxy-headers", "--no-server-header"]
