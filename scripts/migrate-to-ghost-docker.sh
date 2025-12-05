#!/usr/bin/env bash
set -euo pipefail

# Config (edit if needed)
OLD_SITE_DIR=${OLD_SITE_DIR:-/home/jugder/Projects/sandbox/blog/ghost}
NEW_REPO_DIR=${NEW_REPO_DIR:-/home/jugder/Apps/ghost-docker}
OLD_DB_CONTAINER=${OLD_DB_CONTAINER:-ghost-db}
BACKUP_BASE=${BACKUP_BASE:-"$HOME/ghost-migration-backup"}
GHOST_UID=${GHOST_UID:-1000}
GHOST_GID=${GHOST_GID:-1000}
MYSQL_TIMEOUT=${MYSQL_TIMEOUT:-120}
DRY_RUN=false

usage(){ echo "Usage: $0 [--dry-run|--run]"; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --run) DRY_RUN=false; shift ;;
    *) usage ;;
  esac
done

echo "Old site: $OLD_SITE_DIR"
echo "New repo: $NEW_REPO_DIR"
echo "Old DB container: $OLD_DB_CONTAINER"
echo "Backup base: $BACKUP_BASE"
echo "Dry-run: $DRY_RUN"

# Basic checks
for cmd in docker rsync mysqldump node jq bc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "WARN: host missing $cmd"
  fi
done

# Determine content source: prefer explicit content/ folder, else detect Ghost-style folder, else look for tarball
CONTENT_SRC=""
TARBALL_FOUND=""
SQL_DUMP_FOUND=""

if [[ -d "$OLD_SITE_DIR/content" ]]; then
  CONTENT_SRC="$OLD_SITE_DIR/content/"
elif [[ -d "$OLD_SITE_DIR/apps" || -d "$OLD_SITE_DIR/data" || -d "$OLD_SITE_DIR/files" || -d "$OLD_SITE_DIR/images" ]]; then
  # Old site already contains Ghost content structure (no nested content/)
  CONTENT_SRC="$OLD_SITE_DIR/"
else
  # Look for tarball or SQL dump in OLD_SITE_DIR and its parent
  parent_dir=$(dirname "$OLD_SITE_DIR")
  # Search common names
  TARBALL_PATH=""
  SQL_PATH=""
  for p in "$OLD_SITE_DIR" "$parent_dir"; do
    if [[ -z "$TARBALL_PATH" ]]; then
      candidate=$(ls "$p"/ghost-content*.tgz 2>/dev/null | head -n1 || true)
      candidate2=$(ls "$p"/*ghost-content*.tgz 2>/dev/null | head -n1 || true)
      TARBALL_PATH=${candidate:-$candidate2}
    fi
    if [[ -z "$SQL_PATH" ]]; then
      candidate_sql=$(ls "$p"/full-backup*.sql 2>/dev/null | head -n1 || true)
      candidate_sql2=$(ls "$p"/*ghost*backup*.sql 2>/dev/null | head -n1 || true)
      SQL_PATH=${candidate_sql:-$candidate_sql2}
    fi
  done

  if [[ -n "$TARBALL_PATH" ]]; then
    TARBALL_FOUND="$TARBALL_PATH"
  fi
  if [[ -n "$SQL_PATH" ]]; then
    SQL_DUMP_FOUND="$SQL_PATH"
  fi

  if [[ -n "$TARBALL_FOUND" ]]; then
    echo "Found content tarball: $TARBALL_FOUND"
    CONTENT_SRC="tarball:$TARBALL_FOUND"
  elif [[ -n "$SQL_DUMP_FOUND" ]]; then
    echo "Found SQL dump: $SQL_DUMP_FOUND (will use for DB import)"
    # Even if no content folder, we may still proceed using SQL only
    CONTENT_SRC=""
    DUMP_FILE="$SQL_DUMP_FOUND"
  else
    echo "ERROR: missing content at $OLD_SITE_DIR/content and no tarball or SQL dump found nearby"
    exit 1
  fi
fi
if [[ ! -d "$NEW_REPO_DIR" ]]; then
  echo "ERROR: missing new repo at $NEW_REPO_DIR"
  exit 1
fi

# Read credentials if present
OLD_ENV="$OLD_SITE_DIR/.env"
if [[ -f "$OLD_ENV" ]]; then
  OLD_DB_ROOT_PASS=$(grep -E '^DATABASE_ROOT_PASSWORD=' "$OLD_ENV" | cut -d'=' -f2- || true)
fi
NEW_ENV="$NEW_REPO_DIR/.env"
if [[ -f "$NEW_ENV" ]]; then
  NEW_DB_ROOT_PASS=$(grep -E '^DATABASE_ROOT_PASSWORD=' "$NEW_ENV" | cut -d'=' -f2- || true)
fi

BACKUP_DIR="$BACKUP_BASE/$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="$BACKUP_DIR/ghost_db.sql"

echo "Planned actions:"
echo " - Create backup dir: $BACKUP_DIR"
if [[ -n "${DUMP_FILE:-}" && -f "$DUMP_FILE" ]]; then
  echo " - Use existing SQL dump: $DUMP_FILE"
else
  echo " - Dump DB from container $OLD_DB_CONTAINER -> will create SQL dump at $DUMP_FILE (mysqldump --no-tablespaces)"
fi
echo " - Ensure new repo DB container is running (docker compose up -d db)"
echo " - Import dump into new repo DB as root"
if [[ "$CONTENT_SRC" == tarball:* ]]; then
  echo " - Extract content tarball into $NEW_REPO_DIR/data/ghost/ and chown $GHOST_UID:$GHOST_GID"
elif [[ -n "$CONTENT_SRC" ]]; then
  echo " - Rsync content from $CONTENT_SRC -> $NEW_REPO_DIR/data/ghost/ and chown $GHOST_UID:$GHOST_GID"
else
  echo " - No content sync planned (using DB-only import)"
fi
echo " - Run node scripts/config-to-env.js against existing config.production.json (if present) and append to $NEW_REPO_DIR/.env"
if $DRY_RUN; then
  echo "DRY RUN only — exiting (no changes made)."
  exit 0
fi

mkdir -p "$BACKUP_DIR"

# Dump old DB (skip if we found an existing SQL dump)
if [[ -z "${DUMP_FILE:-}" || ! -f "$DUMP_FILE" ]]; then
  if ! docker ps --format '{{.Names}}' | grep -qx "$OLD_DB_CONTAINER"; then
    echo "ERROR: old DB container '$OLD_DB_CONTAINER' not found. Set OLD_DB_CONTAINER to the running container name for your old site."
    exit 1
  fi

  echo "Dumping old DB from container $OLD_DB_CONTAINER..."
  if [[ -n "${OLD_DB_ROOT_PASS:-}" ]]; then
    docker exec -e MYSQL_PWD="$OLD_DB_ROOT_PASS" "$OLD_DB_CONTAINER" mysqldump --no-tablespaces -h127.0.0.1 -uroot ghost > "$DUMP_FILE"
  else
    docker exec "$OLD_DB_CONTAINER" sh -c "exec mysqldump --no-tablespaces -h127.0.0.1 -uroot ghost" > "$DUMP_FILE"
  fi
  echo "DB dump saved to $DUMP_FILE"
else
  echo "Using existing SQL dump: $DUMP_FILE"
fi

# Start new repo DB
cd "$NEW_REPO_DIR"
echo "Ensuring new repo DB is running..."
docker compose up -d db

# Wait for new DB to be ready
echo -n "Waiting for new DB to accept connections"
t=0
until docker compose exec -e MYSQL_PWD="${NEW_DB_ROOT_PASS:-}" -T db sh -c 'mysqladmin ping -h 127.0.0.1' >/dev/null 2>&1; do
  sleep 1
  t=$((t+1))
  echo -n "."
  if [ $t -ge $MYSQL_TIMEOUT ]; then
    echo ""
    echo "ERROR: timed out waiting for new DB"
    exit 1
  fi
done
echo " OK"

# Import into new DB
echo "Importing dump into new DB..."
if [[ -n "${NEW_DB_ROOT_PASS:-}" ]]; then
  docker compose exec -e MYSQL_PWD="$NEW_DB_ROOT_PASS" -T db sh -c 'exec mysql -uroot ghost' < "$DUMP_FILE"
else
  docker compose exec -T db sh -c 'exec mysql -uroot ghost' < "$DUMP_FILE"
fi
echo "DB import complete."

# Sync or extract content
DEST_CONTENT="$NEW_REPO_DIR/data/ghost/"
mkdir -p "$DEST_CONTENT"
if [[ "$CONTENT_SRC" == tarball:* ]]; then
  TAR_PATH=${CONTENT_SRC#tarball:}
  echo "Extracting tarball $TAR_PATH -> $DEST_CONTENT"
  tar -xzf "$TAR_PATH" -C "$DEST_CONTENT" --strip-components=1
  echo "Setting ownership to $GHOST_UID:$GHOST_GID"
  chown -R "$GHOST_UID:$GHOST_GID" "$DEST_CONTENT"
elif [[ -n "$CONTENT_SRC" ]]; then
  echo "Syncing content -> $DEST_CONTENT"
  rsync -aH "$CONTENT_SRC" "$DEST_CONTENT"
  echo "Setting ownership to $GHOST_UID:$GHOST_GID"
  chown -R "$GHOST_UID:$GHOST_GID" "$DEST_CONTENT"
else
  echo "No content sync/extract required (DB-only migration)."
fi

# Convert config.production.json -> env (if present)
if [[ -f "$OLD_SITE_DIR/config.production.json" ]] && [[ -x "$NEW_REPO_DIR/scripts/config-to-env.js" ]]; then
  echo "Converting config.production.json to env and appending to $NEW_REPO_DIR/.env"
  node "$NEW_REPO_DIR/scripts/config-to-env.js" "$OLD_SITE_DIR/config.production.json" >> "$NEW_REPO_DIR/.env"
else
  echo "Skipping config conversion (missing config or conversion script)."
fi

echo ""
echo "MIGRATION STEPS COMPLETED (without stopping old services)."
echo "Next manual steps:"
echo " - Inspect $NEW_REPO_DIR/.env and adjust any secrets."
echo " - Start Ghost with: cd $NEW_REPO_DIR && docker compose up -d ghost"
echo " - Optionally start Caddy: docker compose up -d caddy"
echo " - Test site and admin."