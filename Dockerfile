
FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive

# Setup sandbox user
RUN useradd --shell /bin/bash --create-home sandbox

# Install System Packages
RUN apt-get update \
  && apt-get install -y \
    docker.io \
    docker-buildx \
    docker-compose-v2 \
    gnupg \
    locales \
    lsb-release \
    xz-utils \
    curl wget \
    make \
    openssh-client \
    rsync \
    jq \
    bubblewrap \
    socat \
  && apt-get clean autoclean \
  && apt-get autoremove --yes \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/ \
  && find /var/log -type f | xargs -I % truncate -s0 %

# Install tailscale
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.gpg | apt-key add - \
  && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.list | tee /etc/apt/sources.list.d/tailscale.list \
  && apt-get update \
  && apt-get install -y tailscale \
  && apt-get clean autoclean \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/
  
# Install Nix
RUN curl -fsSL https://nixos.org/nix/install -o /tmp/nix-install \
  && chmod 666 /tmp/nix-install \
  && groupadd nixbld \
  && usermod -a -G nixbld sandbox \
  && mkdir -m 0755 /nix && chown -R sandbox /nix

USER sandbox

RUN sh /tmp/nix-install --no-daemon

WORKDIR /home/sandbox

RUN export PATH=/home/sandbox/.nix-profile/bin:$PATH \
  && nix-env -iA \
  nixpkgs.busybox \
  nixpkgs.devbox \
  nixpkgs.awscli2 \
  nixpkgs.gh \
  nixpkgs.nodejs \
  nixpkgs.go \
  nixpkgs.gopls \
  nixpkgs.git \
  nixpkgs.gnugrep \
  nixpkgs.git-lfs \
  nixpkgs.less \
  nixpkgs.nettools \
  nixpkgs.procps \
  nixpkgs.tree \
  nixpkgs.util-linux \
  nixpkgs.direnv \
  nixpkgs.docker-compose \
  nixpkgs.jq \
  nixpkgs.rclone \
  nixpkgs.unzip \
  nixpkgs.unixtools.ping \
  nixpkgs.watchexec \
  nixpkgs.wget \
  nixpkgs.yq \
 && nix-env --delete-generations old \
 && nix-store --gc

# Copy user dotfiles
COPY --chown=sandbox:sandbox home /home/sandbox

RUN mkdir -p ~/.ssh

USER root

RUN groupmod -g 997 docker \
  && usermod -a -G docker sandbox \
  && install -d -o root -g root -m 0755 /etc/docker

# https://wiki.debian.org/Locale#Manually
RUN sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen \
  && locale-gen

# Pinned Versions - GitHub Releases
ENV GITHUB_RELEASE_SST__OPENCODE=1.19.4
ENV GITHUB_RELEASE_JUST_CONTAINERS__S6_OVERLAY=3.2.1.0

# Install s6-overlay. Archives record their builders' owners, so each tar here
# uses --no-same-owner and root owns what it extracts.
RUN curl -sfLo - https://github.com/just-containers/s6-overlay/releases/download/v${GITHUB_RELEASE_JUST_CONTAINERS__S6_OVERLAY}/s6-overlay-noarch.tar.xz | tar --no-same-owner -Jxpf - -C /
RUN curl -sfLo - https://github.com/just-containers/s6-overlay/releases/download/v${GITHUB_RELEASE_JUST_CONTAINERS__S6_OVERLAY}/s6-overlay-x86_64.tar.xz | tar --no-same-owner -Jxpf - -C /

# Install https://github.com/sst/opencode
RUN curl -sfLo - https://github.com/sst/opencode/releases/download/v${GITHUB_RELEASE_SST__OPENCODE}/opencode-linux-x64.tar.gz | tar --no-same-owner -xzf - -C /usr/local/bin

# Pinned Versions - Claude Code. The image decides the version, so updates are off.
ENV CLAUDE_CODE_VERSION=2.1.330
ENV DISABLE_UPDATES=1

# Install the official Claude Code release, unmodified. Anthropic's release key
# must have signed the manifest, and the binary must match its checksum. gpg
# reports GOODSIG only while the key is neither expired nor revoked, so the build
# fails closed on either, on purpose.
RUN tmp=$(mktemp -d) \
  && cd "$tmp" \
  && release=https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION} \
  && curl -fsSLO "$release/manifest.json" \
  && curl -fsSLO "$release/manifest.json.sig" \
  && curl -fsSLO "$release/linux-x64/claude" \
  && curl -fsSLO https://downloads.claude.ai/keys/claude-code.asc \
  && export GNUPGHOME="$tmp/gnupg" \
  && mkdir -m 0700 "$GNUPGHOME" \
  && gpg --batch --import claude-code.asc \
  && gpg --batch --status-fd 1 --verify manifest.json.sig manifest.json >status \
  && grep '^\[GNUPG:\] VALIDSIG 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ' status \
  && grep '^\[GNUPG:\] GOODSIG BAA929FF1A7ECACE ' status \
  && echo "$(jq -r '.platforms["linux-x64"].checksum' manifest.json)  claude" | sha256sum -c - \
  && install -o root -g root -m 0755 claude /usr/local/bin/claude \
  && cd / \
  && rm -rf "$tmp"

USER sandbox

USER root

# Copy s6-overlay services, the entry script and the agent launchers
COPY rootfs/ /

# Set default environment variables
ENV S6_VERBOSITY=0
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME=300000

# Copy the built home directory to a skeleton directory. Root owns it, so the
# sandbox user cannot change what is copied into a new home.
RUN mkdir -p /home_skel && cp -a /home/sandbox/. /home_skel/ \
  && chown -R -h root:root /home_skel && chmod -R a+rX,go-w /home_skel

EXPOSE 8080
WORKDIR /home/sandbox
ENTRYPOINT ["/init"]
CMD ["/usr/local/bin/start.sh"]
