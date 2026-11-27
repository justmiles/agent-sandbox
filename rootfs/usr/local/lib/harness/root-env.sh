# Sourced first by every script that runs as root. A fixed PATH keeps root
# from running programs from places the sandbox user can write, such as
# /home/sandbox and /nix.
export PATH=/command:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
