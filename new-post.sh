#!/usr/bin/env bash
# Arranca el post del día en borrador.
#   ./new-post.sh <sección> <slug> "<título>"
# Ejemplo:
#   ./new-post.sh concurrency ordered-fan-out "Ordered fan-out"
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "uso: $0 <sección> <slug> \"<título>\"" >&2
  echo "secciones: $(ls -d content/*/ | xargs -n1 basename | tr '\n' ' ')" >&2
  exit 1
fi

seccion=$1
slug=$2
titulo=$3
fichero="content/$seccion/$slug.md"

if [ ! -d "content/$seccion" ]; then
  echo "la sección '$seccion' no existe: crea antes content/$seccion/_index.md" >&2
  exit 1
fi

if [ -e "$fichero" ]; then
  echo "ya existe: $fichero" >&2
  exit 1
fi

cat > "$fichero" <<FRONTMATTER
+++
title = "$titulo"
date = $(date +%Y-%m-%d)
draft = true
+++

FRONTMATTER

echo "$fichero"
echo "Sigue en borrador: quita 'draft = true' el día que salga."
if [ -n "${EDITOR:-}" ]; then
  "$EDITOR" "$fichero"
fi
