"""Backend sloj aplikacije "Trezor" (povjerljive bilješke): REST API nad PostgreSQL bazom.

Pravila koja ovaj modul provodi:
  * konfiguracija dolazi isključivo iz okruženja (12-factor); u kodu nema adresa,
  * baza se adresira DNS imenom iz DB_HOST (AO-7), nikad IP adresom,
  * lozinka se čita iz datoteke DB_PASSWORD_FILE (AO-9), a ne iz varijable okruženja,
    jer se okruženje procesa vidi u `docker inspect` i u /proc/<pid>/environ.
"""

from __future__ import annotations

import logging
import os
import socket
from contextlib import asynccontextmanager
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException, Response, status
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool, PoolTimeout
from pydantic import BaseModel, Field

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("ruo.backend")

# Ime hosta koji je obradio zahtjev: na demonstraciji se vidi koja instanca odgovara.
HOSTNAME = socket.gethostname()


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if not value:
        raise RuntimeError(f"nedostaje varijabla okruženja {name}")
    return value


def _conninfo() -> str:
    password = Path(_env("DB_PASSWORD_FILE")).read_text(encoding="utf-8").strip()
    return make_conninfo(
        host=_env("DB_HOST"),  # DNS ime, npr. db.ruo.internal
        port=_env("DB_PORT", "5432"),
        dbname=_env("DB_NAME", "ruo"),
        user=_env("DB_USER", "ruo"),
        password=password,
        connect_timeout=3,
        application_name="ruo-backend",
    )


pool: ConnectionPool | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global pool
    pool = ConnectionPool(
        conninfo=_conninfo(),
        min_size=1,
        max_size=int(_env("DB_POOL_MAX", "5")),
        timeout=5,
        open=False,
        kwargs={"row_factory": dict_row},
        # Provjera veze pri izdavanju iz poola: nakon ponovnog kreiranja kontejnera baze
        # (AO-10) stare veze su mrtve, pa se zamjenjuju novim umjesto da zahtjev padne.
        check=ConnectionPool.check_connection,
        name="ruo",
    )
    # wait=False: backend se podiže i kad baza još nije spremna. /api/readyz to javlja (503),
    # a pool sam uspostavi veze čim baza proradi. Redoslijed se ne mora pogađati.
    pool.open(wait=False)
    try:
        yield
    finally:
        pool.close()


app = FastAPI(
    title="Trezor",
    version=os.environ.get("APP_VERSION", "dev"),
    lifespan=lifespan,
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
    redoc_url=None,
)


class NoteIn(BaseModel):
    text: str = Field(min_length=1, max_length=500)


@app.get("/api/healthz")
def healthz() -> dict:
    """Liveness: proces radi. Ne zavisi od baze, pa pad baze ne restartuje backend."""
    return {"status": "ok", "served_by": HOSTNAME}


@app.get("/api/readyz")
def readyz(response: Response) -> dict:
    """Readiness: backend može služiti zahtjeve, tj. baza odgovara."""
    try:
        with pool.connection(timeout=2) as conn:
            conn.execute("SELECT 1")
    except (psycopg.Error, PoolTimeout) as exc:
        log.warning("baza nije dostupna: %s", exc)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "baza nije dostupna", "served_by": HOSTNAME}
    return {"status": "ok", "served_by": HOSTNAME}


@app.get("/api/notes")
def list_notes() -> dict:
    try:
        with pool.connection() as conn:
            rows = conn.execute(
                "SELECT id, body AS text, created_at FROM notes ORDER BY id DESC LIMIT 50"
            ).fetchall()
    except (psycopg.Error, PoolTimeout) as exc:
        log.error("čitanje bilješki nije uspjelo: %s", exc)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "baza nije dostupna") from exc
    return {"served_by": HOSTNAME, "notes": rows}


@app.post("/api/notes", status_code=status.HTTP_201_CREATED)
def create_note(note: NoteIn) -> dict:
    try:
        with pool.connection() as conn:
            row = conn.execute(
                "INSERT INTO notes (body) VALUES (%s) RETURNING id, body AS text, created_at",
                (note.text,),
            ).fetchone()
    except (psycopg.Error, PoolTimeout) as exc:
        log.error("upis bilješke nije uspio: %s", exc)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "baza nije dostupna") from exc
    return {"served_by": HOSTNAME, "note": row}
