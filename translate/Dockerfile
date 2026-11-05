# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The server's own translator (docs/TRANSLATION.md): LibreTranslate with only
# the languages sukhi offers (ja, en, ko) baked in, so it starts in seconds
# and never reaches out for models at runtime.
#
# It is reached only by the gateway, over the compose network — never publish
# its port. The gateway decides who may translate what (SukhiFedi.Translate);
# this container just translates.
#
# Pin the base to a release; bump it on purpose (and re-read the notes).
ARG LT_VERSION=v1.9.6
FROM libretranslate/libretranslate:${LT_VERSION}

# The base image ships without models (with_models=false), runs as the
# `libretranslate` user, and keeps them under $HOME/.local. Same call the
# upstream Dockerfile makes for its with_models build.
ARG LANGS=ja,en,ko
RUN ./venv/bin/python scripts/install_models.py --load_only_lang_codes "${LANGS}"

ENV LT_LOAD_ONLY=${LANGS} \
    # Models are baked in; never fetch or update at runtime.
    LT_UPDATE_MODELS=false \
    # No web page, no key database: only the JSON API, on the private network.
    LT_DISABLE_WEB_UI=true \
    # Workers match the gateway's in-flight cap (TRANSLATE_MAX_FLIGHT, default 2).
    LT_THREADS=2 \
    # The gateway refuses text over 3000 characters of prose; the HTML it
    # sends adds markup on top, so leave room.
    LT_CHAR_LIMIT=20000

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["./venv/bin/python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:5000/languages', timeout=4)"]
