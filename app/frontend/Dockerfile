# Frontend slika (DO-5): statične datoteke + nginx kao reverse proxy prema backendu.
# Nema faze izgradnje jer UI nema build korak (čist HTML/JS), pa multi-stage ne bi ništa donio.
FROM nginx:1.27-alpine

# Konfiguracija je šablon: ime backenda dolazi iz okruženja pri pokretanju, ne pri izgradnji,
# pa ista slika radi i u razvojnom compose-u i na VM-u (build once, deploy many).
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY public/ /usr/share/nginx/html/

ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    BACKEND_PORT=8000

EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://localhost/healthz"]
