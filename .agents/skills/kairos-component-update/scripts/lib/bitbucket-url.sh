# bitbucket-url.sh — map a Bitbucket Cloud SSH URL onto the host that serves SSH.
# Sourceable helper. Usage:
#   . "$HERE/lib/bitbucket-url.sh"
#   canonical_ssh_url <url>
#
# WHY THIS EXISTS: Bitbucket Cloud serves git over SSH only on ssh.bitbucket.org
# after 2026-11-12; bitbucket.org is HTTPS-only from then on. Manifests written
# before the move record template.repo / frontend.repo as git@bitbucket.org:…,
# and pre-flight clones the mirrors FROM those values before any upgrade-file
# could change them. Mapping the URL at the clone, and writing the mapped value
# back at the baseline advance, is what keeps an old manifest usable on a
# machine with no `insteadOf` rule for the old host.
#
# Only the two SSH spellings of the OLD host are rewritten. Every other value —
# HTTPS (still served by bitbucket.org), another host, a local path, a value
# already on ssh.bitbucket.org, an empty string — is printed unchanged, so a
# caller can pass any clone origin through it.

canonical_ssh_url() {
  case "$1" in
    git@bitbucket.org:*)       printf '%s' "git@ssh.bitbucket.org:${1#git@bitbucket.org:}" ;;
    ssh://git@bitbucket.org/*) printf '%s' "ssh://git@ssh.bitbucket.org/${1#ssh://git@bitbucket.org/}" ;;
    *)                         printf '%s' "$1" ;;
  esac
}
