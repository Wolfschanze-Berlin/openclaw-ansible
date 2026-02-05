# syntax=docker/dockerfile:1.4

# =============================================================================
# Stage 1: Base Dependencies
# System packages that rarely change - maximize cache hits
# =============================================================================
FROM python:3.12-slim AS base-deps

# Install system dependencies with BuildKit cache mount
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    sshpass \
    curl \
    wget \
    unzip \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev \
    ca-certificates \
    && ln -s /usr/local/bin/python3 /usr/bin/python3

# =============================================================================
# Stage 2: Tool Installation
# Install version managers (fnm, pyenv) - cached separately
# =============================================================================
FROM base-deps AS tools

# Install fnm (Fast Node Manager)
ENV FNM_DIR=/root/.fnm
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell \
    && ln -s "$FNM_DIR/fnm" /usr/local/bin/fnm

# Install pyenv
ENV PYENV_ROOT=/root/.pyenv
RUN curl https://pyenv.run | bash \
    && ln -s "$PYENV_ROOT/bin/pyenv" /usr/local/bin/pyenv

# =============================================================================
# Stage 3: Ansible Setup
# Install Ansible and collections with pip cache mount
# =============================================================================
FROM tools AS ansible-setup

# Install Ansible with pip cache mount
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir ansible>=2.14

# Install Ansible collections with cache mount
RUN --mount=type=cache,target=/root/.ansible/collections \
    ansible-galaxy collection install \
    'community.docker>=3.4.0' \
    'community.general>=8.0.0'

# =============================================================================
# Stage 4: Final Runtime Image
# Full dev environment with all tools
# =============================================================================
FROM python:3.12-slim AS final

# Install runtime dependencies and dev CLI tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    # Core tools
    git \
    openssh-client \
    sshpass \
    curl \
    wget \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    # Runtime libs
    libssl3 \
    libreadline8 \
    libsqlite3-0 \
    # CLI utilities
    jq \
    tree \
    htop \
    less \
    rsync \
    file \
    make \
    # Editors
    vim \
    nano \
    # Network tools
    netcat-openbsd \
    dnsutils \
    iputils-ping \
    iproute2 \
    # Search tools
    ripgrep \
    fd-find \
    fzf \
    # Terminal tools
    tmux \
    screen \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install yq (YAML processor)
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Install bat (cat with syntax highlighting)
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then ARCH="aarch64"; fi && \
    curl -fsSL "https://github.com/sharkdp/bat/releases/download/v0.24.0/bat-v0.24.0-${ARCH}-unknown-linux-gnu.tar.gz" | tar xzf - -C /tmp \
    && mv /tmp/bat-*/bat /usr/local/bin/bat \
    && rm -rf /tmp/bat-*

# Install lazygit
RUN LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | jq -r '.tag_name' | sed 's/v//') \
    && ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then ARCH="x86_64"; fi && \
    curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${ARCH}.tar.gz" | tar xzf - -C /usr/local/bin lazygit

# Install delta (better git diff)
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then ARCH="aarch64"; fi && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/0.18.2/delta-0.18.2-${ARCH}-unknown-linux-gnu.tar.gz" | tar xzf - -C /tmp \
    && mv /tmp/delta-*/delta /usr/local/bin/delta \
    && rm -rf /tmp/delta-*

# Copy fnm from tools stage
COPY --from=tools /root/.fnm /root/.fnm
ENV FNM_DIR=/root/.fnm
RUN ln -sf "$FNM_DIR/fnm" /usr/local/bin/fnm

# Copy pyenv from tools stage
COPY --from=tools /root/.pyenv /root/.pyenv
ENV PYENV_ROOT=/root/.pyenv
ENV PATH="$PYENV_ROOT/bin:$PATH"
RUN ln -sf "$PYENV_ROOT/bin/pyenv" /usr/local/bin/pyenv

# Copy Ansible installation from ansible-setup stage
COPY --from=ansible-setup /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=ansible-setup /usr/local/bin/ansible* /usr/local/bin/
COPY --from=ansible-setup /root/.ansible /root/.ansible

# Setup SSH directory and fetch GitHub keys for francisvarga
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh \
    && curl -fsSL https://github.com/francisvarga.keys > /root/.ssh/authorized_keys \
    && chmod 600 /root/.ssh/authorized_keys

# Configure git to use delta as pager
RUN git config --global core.pager delta \
    && git config --global interactive.diffFilter 'delta --color-only' \
    && git config --global delta.navigate true \
    && git config --global delta.side-by-side true

# Set working directory
WORKDIR /ansible

# Copy the ansible playbook directory (this changes most frequently - last layer)
COPY openclaw-ansible/ .

# Default command - show help
CMD ["ansible-playbook", "--help"]
