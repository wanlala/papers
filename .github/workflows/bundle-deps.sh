#!/bin/bash
set -euo pipefail

APP_DIR="$1"
if [ -z "$APP_DIR" ]; then
  echo "Usage: $0 <AppDir>"
  exit 1
fi
APP_DIR="$(realpath "$APP_DIR")"

echo "=== Bundling system dependencies into $APP_DIR ==="

LIBDIR="$APP_DIR/usr/lib64"
BINDIR="$APP_DIR/usr/bin"
mkdir -p "$LIBDIR" "$BINDIR"

# ===========================================================================
# 1. Collect all shared library dependencies via ldd
# ===========================================================================
declare -A SEEN_LIBS

collect_libs() {
  local binary="$1"
  [ -f "$binary" ] || return
  while IFS= read -r line; do
    local lib_path=""
    # libfoo.so => /path/libfoo.so (0x...)
    if [[ "$line" =~ [[:space:]]*([^[:space:]]+)[[:space:]]*'=>'[[:space:]]*'/'([^[:space:]]+) ]]; then
      lib_path="/${BASH_REMATCH[2]}"
    fi
    # /path/ld-linux-x86-64.so.2 (0x...)  (no "=>")
    if [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+) ]]; then
      lib_path="${BASH_REMATCH[1]}"
    fi
    if [ -n "$lib_path" ] && [ -f "$lib_path" ] && [ -z "${SEEN_LIBS[$lib_path]:-}" ]; then
      SEEN_LIBS["$lib_path"]=1
    fi
  done < <(ldd "$binary" 2>/dev/null || true)
}

# Collect from every ELF in bin/ and lib64/
while IFS= read -r -d '' f; do
  collect_libs "$f"
done < <(find "$APP_DIR/usr/bin" "$APP_DIR/usr/lib64" -type f -executable -print0 2>/dev/null || true)

echo "Found ${#SEEN_LIBS[@]} unique library paths from ldd"

# ===========================================================================
# 2. Copy libraries preserving symlinks
# ===========================================================================
for lib_path in "${!SEEN_LIBS[@]}"; do
  lib_dir="$(dirname "$lib_path")"
  base="$(basename "$lib_path")"
  # Copy the target file + all versioned symlinks (e.g. libfoo.so.1 → libfoo.so.1.0.0)
  cp -af "$lib_dir/$base"* "$LIBDIR/" 2>/dev/null || true
done

# ===========================================================================
# 3. Copy GTK4 / GDK / GIO modules
# ===========================================================================
# glibc/NSS/libstdc++ are NOT bundled — host or ablrun provides them

MODULE_DIRS=(
  /usr/lib64/gtk-4.0
  /usr/lib64/gdk-pixbuf-2.0
  /usr/lib64/gio/modules
)

for src_dir in "${MODULE_DIRS[@]}"; do
  if [ -d "$src_dir" ]; then
    target="$APP_DIR$src_dir"
    mkdir -p "$(dirname "$target")"
    cp -af "$src_dir" "$(dirname "$target")/" 2>/dev/null || true
  fi
done

# Step 3b: Collect transitive deps from newly copied module libraries
# (GTK4 modules, GIO modules, etc. are dlopen-ed and their ldd deps are missed)
while IFS= read -r -d '' f; do
  collect_libs "$f"
done < <(find "$APP_DIR/usr/lib64/gtk-4.0" "$APP_DIR/usr/lib64/gio" \
  -name "*.so*" -type f -print0 2>/dev/null || true)

for lib_path in "${!SEEN_LIBS[@]}"; do
  lib_dir="$(dirname "$lib_path")"
  base="$(basename "$lib_path")"
  if [ ! -f "$LIBDIR/$base" ] && [ ! -L "$LIBDIR/$base" ]; then
    cp -af "$lib_dir/$base"* "$LIBDIR/" 2>/dev/null || true
  fi
done

# ===========================================================================
# 4. Generate GDK pixbuf loaders cache
# ===========================================================================
PIXBUF_DIR="$APP_DIR/usr/lib64/gdk-pixbuf-2.0"
if [ -d "$PIXBUF_DIR" ]; then
  LOADER_DIR=$(find "$PIXBUF_DIR" -maxdepth 2 -name "loaders" -type d 2>/dev/null | head -1)
  if [ -n "$LOADER_DIR" ] && command -v gdk-pixbuf-query-loaders &>/dev/null; then
    CACHE_FILE="$(dirname "$LOADER_DIR")/loaders.cache"
    LD_LIBRARY_PATH="$LIBDIR:${LD_LIBRARY_PATH:-}" \
      gdk-pixbuf-query-loaders > "$CACHE_FILE" 2>/dev/null || true
    # Strip the system prefix so AppRun can rewrite at runtime
    sed -i 's|"/usr/lib64|"/.//lib64|g' "$CACHE_FILE" 2>/dev/null || true
  fi
fi

# ===========================================================================
# 5. Compile GSettings schemas
# ===========================================================================
SCHEMA_DIR="$APP_DIR/usr/share/glib-2.0/schemas"
mkdir -p "$SCHEMA_DIR"

# Copy Papers schemas (already installed by DESTDIR) and system schemas
for pattern in /usr/share/glib-2.0/schemas/*.xml /usr/share/glib-2.0/schemas/*.gschema.override; do
  [ -f "$pattern" ] && cp -a "$pattern" "$SCHEMA_DIR/" 2>/dev/null || true
done

if command -v glib-compile-schemas &>/dev/null; then
  glib-compile-schemas "$SCHEMA_DIR" 2>/dev/null || true
fi

# ===========================================================================
# 6. Copy icon theme
# ============================================================================
for theme in Adwaita hicolor; do
  src="/usr/share/icons/$theme"
  if [ -d "$src" ]; then
    dst="$APP_DIR/usr/share/icons/$theme"
    mkdir -p "$dst"
    cp -af "$src/"* "$dst/" 2>/dev/null || true
  fi
done

# Previewer icon: copy to AppDir root where appimagetool expects it
# First try to find a non-symbolic version, fall back to any document-print-preview icon
ICON_PREVIEW=$(find /usr/share/icons -name "document-print-preview.svg" -not -name "*-symbolic*" 2>/dev/null | head -1)
if [ -z "$ICON_PREVIEW" ]; then
  ICON_PREVIEW=$(find /usr/share/icons -name "document-print-preview*" 2>/dev/null | head -1)
fi
if [ -n "$ICON_PREVIEW" ]; then
  cp "$ICON_PREVIEW" "$APP_DIR/document-print-preview.svg" 2>/dev/null
fi

# ===========================================================================
# 7. Copy fonts
# ===========================================================================
if [ -d /usr/share/fonts ]; then
  mkdir -p "$APP_DIR/usr/share/fonts"
  cp -af /usr/share/fonts/* "$APP_DIR/usr/share/fonts/" 2>/dev/null || true
fi

# ===========================================================================
# 8. Strip RPATH/RUNPATH from binaries to ensure LD_LIBRARY_PATH works
# ===========================================================================
if command -v patchelf &>/dev/null; then
  while IFS= read -r -d '' f; do
    patchelf --remove-rpath "$f" 2>/dev/null || true
  done < <(find "$APP_DIR/usr/bin" "$APP_DIR/usr/lib64" -type f -name "*.so*" -print0 2>/dev/null || true)
  while IFS= read -r -d '' f; do
    patchelf --remove-rpath "$f" 2>/dev/null || true
  done < <(find "$APP_DIR/usr/bin" -type f -executable -print0 2>/dev/null || true)
fi

# ===========================================================================
# 9. Create AppRun entry point
# ===========================================================================
cat > "$APP_DIR/AppRun" << 'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"

export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib64:$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"
export GTK_EXE_PREFIX="$HERE/usr"
export GTK_DATA_PREFIX="$HERE/usr"
export GDK_BACKEND="wayland,x11"

# Rewrite gdk-pixbuf loaders.cache paths to match the AppDir
LOADERS_CACHE="$HERE/usr/lib64/gdk-pixbuf-2.0/2.10.0/loaders.cache"
if [ -f "$LOADERS_CACHE" ]; then
  if ! grep -q "^\"$HERE" "$LOADERS_CACHE" 2>/dev/null; then
    sed -i "s|\"/\.//lib64|\"$HERE/usr/lib64|g" "$LOADERS_CACHE" 2>/dev/null || true
  fi
  export GDK_PIXBUF_MODULE_FILE="$LOADERS_CACHE"
fi

# Direct execution — glibc provided by host system or ablrun
exec "$HERE/usr/bin/papers" "$@"
APPRUN
chmod +x "$APP_DIR/AppRun"

# ===========================================================================
# 10. Ensure .desktop file
# ===========================================================================
DESKTOP_FILE=$(find "$APP_DIR/usr/share/applications" -name "org.gnome.Papers.desktop" 2>/dev/null | head -1)
if [ -z "$DESKTOP_FILE" ]; then
  DESKTOP_FILE=$(find "$APP_DIR/usr/share/applications" -name "*.desktop" 2>/dev/null | head -1)
fi
if [ -z "$DESKTOP_FILE" ]; then
  cat > "$APP_DIR/org.gnome.Papers.desktop" << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=GNOME Papers
Comment=Document Viewer
Exec=papers
Icon=org.gnome.Papers
Categories=Office;Viewer;
MimeType=application/pdf;application/x-bzpdf;application/x-gzpdf;application/x-xzpdf;application/x-ext-pdf;image/vnd.djvu;image/vnd.djvu+multipage;image/tiff;application/vnd.comicbook+zip;application/vnd.comicbook-rar;application/x-cbr;application/x-cbz;application/x-cb7;application/x-cbt;
Keywords=pdf;djvu;document;viewer;
Terminal=false
StartupNotify=true
DESKTOP
else
  cp "$DESKTOP_FILE" "$APP_DIR/"
fi

# ===========================================================================
# 11. Ensure icon
# ============================================================================
ICON=$(find "$APP_DIR/usr/share/icons" -name "org.gnome.Papers.png" -o -name "org.gnome.Papers.svg" 2>/dev/null | head -1)
if [ -z "$ICON" ]; then
  ICON=$(find "$APP_DIR/usr/share/icons" -name "*.png" -type f 2>/dev/null | head -1)
fi
if [ -n "$ICON" ]; then
  cp "$ICON" "$APP_DIR/org.gnome.Papers.png"
fi

# ===========================================================================
# 12. Strip debugging symbols
# ===========================================================================
if command -v strip &>/dev/null; then
  find "$APP_DIR/usr/bin" -type f -executable -exec strip --strip-all {} \; 2>/dev/null || true
  find "$APP_DIR/usr/lib64" -type f -name "*.so*" -exec strip --strip-unneeded {} \; 2>/dev/null || true
fi

# ===========================================================================
# 13. Remove development leftovers
# ===========================================================================
rm -rf \
  "$APP_DIR/usr/include" \
  "$APP_DIR/usr/share/man" \
  "$APP_DIR/usr/share/help" \
  "$APP_DIR/usr/share/gtk-doc" \
  "$APP_DIR/usr/share/vala" \
  "$APP_DIR/usr/lib64/pkgconfig" \
  "$APP_DIR/usr/share/pkgconfig" \
  "$APP_DIR/usr/share/aclocal" \
  "$APP_DIR/usr/lib64/"*.la \
  "$APP_DIR/usr/lib64/"*.a \
  2>/dev/null || true

echo "=== Bundle complete ==="
echo "AppDir size : $(du -sh "$APP_DIR" | cut -f1)"
echo "Files in lib64 : $(ls "$LIBDIR" 2>/dev/null | wc -l)"
echo "Files in bin   : $(ls "$BINDIR" 2>/dev/null | wc -l)"
echo "=== Done ==="
