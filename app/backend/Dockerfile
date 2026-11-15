# Backend slika (DO-5): dvije faze. Prva instalira zavisnosti, druga sadrži samo runtime.
# Zavisnosti se kopiraju prije koda, pa izmjena koda koristi keširani sloj sa zavisnostima.

# Bazna slika je zaključana digestom (Python 3.12.16): tag "3.12-slim" se vremenom pomjera,
# a digest garantuje identičnu sliku pri svakoj izgradnji (DO-5).
ARG PYTHON_IMAGE=python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

# --- faza 1: zavisnosti ---
FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /w
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# --- faza 2: runtime ---
FROM ${PYTHON_IMAGE}
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
