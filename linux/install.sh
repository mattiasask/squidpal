#!/usr/bin/env bash
# DayLog för Linux – installerar systemberoenden och sätter upp autostart.
# Stödjer apt (Ubuntu/Debian) och zypper (openSUSE). Kör som vanlig användare;
# paketinstallationen använder sudo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

install_apt() {
    say "Installerar beroenden med apt…"
    sudo apt-get update
    sudo apt-get install -y \
        python3 python3-gi python3-pyatspi at-spi2-core \
        gir1.2-atspi-2.0 gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
        python3-regex xdg-utils
}

install_zypper() {
    say "Installerar beroenden med zypper…"
    sudo zypper --non-interactive install \
        python3 python3-gobject python3-gobject-Gdk at-spi2-core \
        typelib-1_0-Atspi-2_0 typelib-1_0-Gtk-3_0 python3-atspi \
        python3-regex xdg-utils
    # AppIndicator-typelib heter olika mellan versioner; försök i tur och ordning.
    sudo zypper --non-interactive install typelib-1_0-AyatanaAppIndicator3-0_1 \
        || sudo zypper --non-interactive install typelib-1_0-AppIndicator3-0_1 \
        || echo "OBS: hittade inget AppIndicator-typelib – panelikonen kan saknas."
}

# ---- install deps
if command -v apt-get >/dev/null 2>&1; then
    install_apt
elif command -v zypper >/dev/null 2>&1; then
    install_zypper
else
    echo "Okänd distribution. Installera manuellt: python3-gi, python3-pyatspi, at-spi2-core,"
    echo "gir/typelib för Atspi, Gtk 3.0 och AyatanaAppIndicator3, samt python3-regex."
    exit 1
fi

# ---- regex fallback if the distro package was unavailable
if ! python3 -c "import regex" >/dev/null 2>&1; then
    say "python3-regex saknas – installerar 'regex' med pip --user…"
    python3 -m pip install --user regex
fi

# ---- verify the core stack imports, so a missing package surfaces now
say "Kontrollerar att allt finns…"
if ! python3 - <<'PYCHECK'
import gi
gi.require_version("Gtk", "3.0"); gi.require_version("Atspi", "2.0")
from gi.repository import Gtk, Gio, GLib
import pyatspi, regex
print("OK: Gtk, Atspi, pyatspi, regex")
PYCHECK
then
    echo
    echo "FEL: något kärnberoende saknas (se raden ovan). Installera det paketet"
    echo "manuellt och kör ./install.sh igen. AppIndicator (panelikonen) är inte"
    echo "kritiskt – appen kör även utan, men då utan ikon."
    exit 1
fi

# ---- GNOME needs accessibility on for AT-SPI to expose app content
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true
fi

# ---- launcher
BIN="$HOME/.local/bin"; mkdir -p "$BIN"
cat > "$BIN/squidpal" <<EOF
#!/usr/bin/env bash
exec python3 -m daylog.app
EOF
chmod +x "$BIN/squidpal"
# keep the old name working for one release
ln -sf "$BIN/squidpal" "$BIN/daylog"
# run from the project dir so "python3 -m daylog.app" resolves the package
sed -i "s#exec python3 -m daylog.app#cd \"$HERE\" \&\& exec python3 -m daylog.app#" "$BIN/squidpal"

# ---- autostart entry
AUTO="$HOME/.config/autostart"; mkdir -p "$AUTO"
cat > "$AUTO/squidpal.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Squidpal
Comment=Loggar din arbetsdag lokalt
Exec=$BIN/squidpal
Icon=$HERE/daylog/icons/squidpal.png
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

say "Klart."
echo "Starta nu:  $BIN/squidpal     (eller logga ut och in – den startar automatiskt)"
echo
echo "GNOME (Ubuntu): panelikoner från appar kräver tillägget"
echo "  'AppIndicator and KStatusNotifierItem Support'."
echo "  Installera:  sudo apt-get install gnome-shell-extension-appindicator"
echo "  och slå på det i appen Tillägg (Extensions), logga sedan ut och in."
echo "KDE Plasma (openSUSE): fungerar direkt."
