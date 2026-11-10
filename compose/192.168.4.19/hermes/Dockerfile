FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    RESOLUTION=1280x800 \
    HOME=/home/hermes

# 1. Install base utilities, X11 virtual desktop, Openbox, noVNC, lxterminal, obconf, Python (glibc), git, and GitHub CLI (gh)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    ca-certificates \
    supervisor \
    xvfb \
    openbox \
    obconf \
    x11vnc \
    novnc \
    websockify \
    lxterminal \
    xdotool \
    scrot \
    xclip \
    chromium \
    python3 \
    python3-pip \
    python3-venv \
    git \
    openssh-client \
    procps \
    net-tools \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Configure Chromium default flags for Docker (disable sandbox requirement in unprivileged container)
RUN mkdir -p /etc/chromium.d \
    && echo 'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"' > /etc/chromium.d/no-sandbox

# 3. Symlink noVNC index so the root URL opens the web viewer directly
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# 4. Create non-root hermes user and workspace compatibility symlinks
RUN useradd -m -s /bin/bash -u 1000 hermes \
    && ln -sfn /home/hermes/workspace /opt/data \
    && mkdir -p /home/hermes/.config \
    && ln -sfn /home/hermes/workspace/.config/gh /home/hermes/.config/gh \
    && ln -sfn /home/hermes/workspace/.ssh /home/hermes/.ssh

# 5. Set up Hermes virtual environment and tools
USER hermes
WORKDIR /home/hermes
RUN python3 -m venv /home/hermes/venv \
    && /home/hermes/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /home/hermes/venv/bin/pip install --no-cache-dir \
       openai \
       litellm \
       playwright \
       pyautogui \
       pillow \
       requests

USER root
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
EXPOSE 6080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
