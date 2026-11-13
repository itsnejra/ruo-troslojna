-- Šema aplikacije. Zvanična postgres slika izvršava skripte iz /docker-entrypoint-initdb.d
-- SAMO kad je direktorij podataka prazan, tj. pri prvom pokretanju. Kad podaci već postoje
-- (ponovno kreiran kontejner, AO-10), skripta se preskače i podaci ostaju netaknuti.
CREATE TABLE IF NOT EXISTS notes (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body       text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 500),
    created_at timestamptz NOT NULL DEFAULT now()
);
