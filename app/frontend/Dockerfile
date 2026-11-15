# Frontend slika (DO-5): statične datoteke + nginx kao reverse proxy prema backendu.
# Nema faze izgradnje jer UI nema build korak (čist HTML/JS), pa multi-stage ne bi ništa donio.
# Zaključano digestom (nginx 1.27.5): ista slika pri svakoj izgradnji (DO-5).
FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

# Konfiguracija je šablon: ime backenda dolazi iz okruženja pri pokretanju, ne pri izgradnji,
# pa ista slika radi i u razvojnom compose-u i na VM-u (build once, deploy many).
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY public/ /usr/share/nginx/html/

ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    BACKEND_PORT=8000

EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://localhost/healthz"]
