# Contexto de build: esta carpeta (image/).
#   docker build -t cpp-runner image/
FROM debian:stable-slim

# glibc (Debian) + g++ + make (GNU). findutils, sed, coreutils ya vienen en la base.
# Una sola capa; sin recomendados, sin docs/man/locales (se conserva solo "copyright")
# y sin cachés de apt para minimizar el tamaño.
RUN printf '%s\n' \
      'path-exclude=/usr/share/doc/*' \
      'path-include=/usr/share/doc/*/copyright' \
      'path-exclude=/usr/share/man/*' \
      'path-exclude=/usr/share/info/*' \
      'path-exclude=/usr/share/locale/*' \
      'path-exclude=/usr/share/lintian/*' \
      > /etc/dpkg/dpkg.cfg.d/01-minimal \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends g++ make \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/apt \
           /var/log/dpkg.log /var/log/alternatives.log

# Los Makefile viven aquí, fuera del proyecto del usuario.
# (image/makefiles/{Makefile,Makefile.local,gen.mk} -> /opt/mk/)
COPY makefiles/ /opt/mk/
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
