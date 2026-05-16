#!/usr/bin/env bash
# Podman install + Docker compatibility for Arch Linux
# Covers: rootless setup, subuid/subgid, socket compat, compose, registries
set -euo pipefail

info() { printf '\e[34m[INFO]\e[0m  %s\n' "$*"; }
ok()   { printf '\e[32m[ OK ]\e[0m  %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m  %s\n' "$*"; }
die()  { printf '\e[31m[ERR ]\e[0m  %s\n' "$*" >&2; exit 1; }

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"

# ── 1. Packages ──────────────────────────────────────────────────────────────
info "Installing packages..."
sudo pacman -S --needed --noconfirm \
    podman \
    podman-docker \
    podman-compose \
    docker-compose \
    fuse-overlayfs \
    passt \
    crun \
    shadow

ok "Packages installed. Podman: $(podman --version)"

# ── 2. Subuid / subgid (critical for rootless) ───────────────────────────────
# Without this, rootless containers fail with newuidmap errors.
info "Configuring subuid/subgid for rootless Podman..."

sudo touch /etc/subuid /etc/subgid

add_id_range() {
    local file="$1"
    local user="$2"
    local start=100000
    local count=65536

    if grep -q "^${user}:" "$file" 2>/dev/null; then
        warn "$file already has entry for $user — skipping"
    else
        # Find a non-overlapping start offset if multiple users exist
        local max_end
        max_end=$(awk -F: '{print $2+$3}' "$file" 2>/dev/null | sort -n | tail -1)
        if [[ -n "$max_end" && "$max_end" -ge "$start" ]]; then
            start=$(( (max_end / count + 1) * count ))
        fi
        echo "${user}:${start}:${count}" | sudo tee -a "$file" > /dev/null
        ok "Added ${user}:${start}:${count} to $file"
    fi
}

add_id_range /etc/subuid "$CURRENT_USER"
add_id_range /etc/subgid "$CURRENT_USER"

# Verify newuidmap/newgidmap have correct capabilities (needed on some setups)
for bin in newuidmap newgidmap; do
    path="$(command -v $bin)"
    if [[ -n "$path" ]] && ! getcap "$path" 2>/dev/null | grep -q cap_set; then
        sudo setcap "cap_set${bin##new}+ep" "$path" 2>/dev/null || true
    fi
done

podman system migrate 2>/dev/null || true
ok "subuid/subgid configured and migrated"

# ── 3. Registry config (unqualified image names) ─────────────────────────────
# Without this, 'podman run nginx' fails — must use full name docker.io/library/nginx
info "Configuring container registries..."
sudo mkdir -p /etc/containers/registries.conf.d

sudo tee /etc/containers/registries.conf.d/00-unqualified-search.conf > /dev/null <<'EOF'
# Search order for unqualified image names (e.g. "nginx" → "docker.io/library/nginx")
unqualified-search-registries = ["docker.io", "quay.io", "ghcr.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry]]
prefix = "quay.io"
location = "quay.io"

[[registry]]
prefix = "ghcr.io"
location = "ghcr.io"
EOF
ok "Registry config written"

# ── 4. Storage: native overlay ───────────────────────────────────────────────
info "Configuring storage..."
STORAGE_CONF="$HOME/.config/containers/storage.conf"
mkdir -p "$(dirname "$STORAGE_CONF")"
# Always write — removes invalid keys like mountprogram that cause WARN logs
cat > "$STORAGE_CONF" <<'EOF'
[storage]
driver = "overlay"
EOF
ok "Storage config written (native overlay)"

# ── 5. Suppress Docker emulation messages ────────────────────────────────────
info "Suppressing Docker emulation messages..."

# Silences: "Emulate Docker CLI using podman. Create /etc/containers/nodocker..."
sudo touch /etc/containers/nodocker
ok "Created /etc/containers/nodocker"

# Silences: ">>>> Executing external compose provider <<<<" banner
CONTAINERS_CONF="$HOME/.config/containers/containers.conf"
cat > "$CONTAINERS_CONF" <<'EOF'
[engine]
compose_warning_logs = false
EOF
ok "compose_warning_logs = false written to containers.conf"

# ── 6. Podman group (non-root access to system socket) ───────────────────────
info "Configuring 'podman' group..."
if ! getent group podman &>/dev/null; then
    sudo groupadd podman
    ok "Created 'podman' group"
fi
if id -nG "$CURRENT_USER" | grep -qw podman; then
    warn "$CURRENT_USER already in 'podman' group"
else
    sudo usermod -aG podman "$CURRENT_USER"
    ok "Added $CURRENT_USER to 'podman' group (re-login to activate)"
fi

# ── 7. Rootless socket ───────────────────────────────────────────────────────
info "Enabling rootless Podman socket..."
systemctl --user enable --now podman.socket
ROOTLESS_SOCK="${XDG_RUNTIME_DIR:-/run/user/$CURRENT_UID}/podman/podman.sock"

# Enable linger so the socket stays active without an open login session
loginctl enable-linger "$CURRENT_USER"
ok "Rootless socket: $ROOTLESS_SOCK (linger enabled)"

# ── 8. System socket + /var/run/docker.sock symlink ─────────────────────────
# For tools that hardcode /var/run/docker.sock (CI runners, IDEs, etc.)
info "Enabling Podman system socket for /var/run/docker.sock compatibility..."
sudo systemctl enable --now podman.socket

SYSTEM_SOCK="/run/podman/podman.sock"
if [[ -S "$SYSTEM_SOCK" ]]; then
    sudo ln -sf "$SYSTEM_SOCK" /var/run/docker.sock
    ok "Symlinked $SYSTEM_SOCK → /var/run/docker.sock"
else
    warn "System socket not yet at $SYSTEM_SOCK — will be available after reboot"
    # Create a drop-in to ensure the symlink is recreated on start
    sudo mkdir -p /etc/tmpfiles.d
    echo "L /var/run/docker.sock - - - - /run/podman/podman.sock" \
        | sudo tee /etc/tmpfiles.d/podman-docker.conf > /dev/null
    ok "tmpfiles.d rule written — symlink will appear after reboot/systemd-tmpfiles"
fi

# ── 9. Docker Compose plugin wiring ─────────────────────────────────────────
info "Wiring Docker Compose as a CLI plugin..."
PLUGIN_DIR="$HOME/.docker/cli-plugins"
mkdir -p "$PLUGIN_DIR"
COMPOSE_BIN="$(command -v docker-compose)"
if [[ -L "$PLUGIN_DIR/docker-compose" ]]; then
    warn "$PLUGIN_DIR/docker-compose symlink already exists — not modified"
else
    ln -sf "$COMPOSE_BIN" "$PLUGIN_DIR/docker-compose"
    ok "Compose plugin linked: $PLUGIN_DIR/docker-compose → $COMPOSE_BIN"
fi

# ── 10. Shell environment ────────────────────────────────────────────────────
info "Adding environment config to shell rc files..."

SHELL_BLOCK='
# ── Podman / Docker compatibility ────────────────────────────────────────────
# DOCKER_HOST points CLI tools at the rootless Podman socket
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/podman/podman.sock"
'

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if grep -q "DOCKER_HOST" "$rc"; then
        warn "$rc already sets DOCKER_HOST — skipping"
    else
        printf '%s\n' "$SHELL_BLOCK" >> "$rc"
        ok "DOCKER_HOST added to $rc"
    fi
done

# Apply to current session
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$CURRENT_UID}/podman/podman.sock"

# ── 11. Smoke test ───────────────────────────────────────────────────────────
info "Running smoke test..."
if podman run --rm docker.io/library/hello-world 2>&1 | grep -q "Hello from Docker"; then
    ok "Smoke test passed"
else
    warn "Smoke test output unexpected — check 'podman run docker.io/library/hello-world'"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n\e[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n'
printf '\e[32m  Podman setup complete\e[0m\n'
printf '\e[32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n'
printf '\n  Reload shell:  source ~/.zshrc   (or ~/.bashrc)\n'
printf '\n  Quick checks:\n'
printf '    podman info\n'
printf '    docker ps                 # via podman-docker shim\n'
printf '    docker-compose --version\n'
printf '    podman run docker.io/library/hello-world\n'
printf '\n  Docker socket:  /var/run/docker.sock → %s\n' "$SYSTEM_SOCK"
printf '  Rootless socket: %s\n\n' "$ROOTLESS_SOCK"
